# Distributed actors over Workers RPC

Status: **discussion** — no implementation yet. This document exists to pose
open questions to reviewers before any code lands.

## Motivation

`workers-swift` currently exposes cross-binding RPC through `@RPC` /
`RPCStub`: a method is marked `@RPC`, the macro registers it under its plain
name, and `worker-build` wires that name into the generated JS shim's
dispatch table. It works, but it's hand-rolled — every RPC-callable method
needs the attribute, a stub type, and a string-keyed dispatch.

Swift's `distributed actor` gives the same shape of capability (a
location-transparent method call that may cross a process boundary) as a
first-class language feature, with static isolation checking. If workers-swift
could back a `DistributedActorSystem` with Workers RPC, a Durable Object (or
a service binding) could be called as an ordinary `distributed func`, with
the compiler enforcing `async throws` and `Codable`-ish argument/result
requirements instead of us hand-writing a dispatch table per method.

## What's confirmed

A spike (`/tmp/dist-spike2`, not part of the real repo) confirmed
`distributed actor` compiles and runs correctly under this project's actual
target: wasm32, `-mexec-model=reactor`, JavaScriptKit's
`JavaScriptEventLoop.installGlobalExecutor()`. A minimal
`DistributedActorSystem` doing purely local dispatch (`resolve` always
succeeds, `remoteCall` never actually leaves the process) built, ran under
workerd, and correctly routed calls through the distributed-actor machinery
end to end.

## The blocker (revised — see Codex's review)

`DistributedActorSystem.remoteCall`/`remoteCallVoid` receive a
`RemoteCallTarget`, and `RemoteCallTarget.identifier` is not the method's
plain name — it's a **mangled Swift symbol**, e.g.:

```
$s9DistSpike7GreeterC5greet_5timesS2S_SitYaKFTE
```

This document originally framed that as *the* blocker, on the assumption
that dispatch would have to go through our existing `@RPC` machinery —
`worker-build`'s `rpcExports` and the JS shim's plain-name-keyed call table
— which meant bridging mangled identifier → plain name somehow.

Codex's review of this PR correctly points out that this premise is wrong:
`DistributedActorSystem`
already defines the receive-side half of dispatch —
`executeDistributedTarget(on:target:invocationDecoder:handler:)` — and it
takes the *full* `RemoteCallTarget`, not a plain name. It invokes the
compiler-generated distributed target accessor directly, resolving the
mangled identifier through the Swift runtime's own distributed-method
lookup — nothing we write has to demangle it. So the actual shape of the
transport is: a `WorkersActorSystem.remoteCall`/`remoteCallVoid` on the
caller side serializes `target.identifier` (opaque, still mangled) plus the
encoded invocation, sends both over a single fixed Workers RPC endpoint to
the callee, and the callee's `WorkersActorSystem` hands them straight to
`executeDistributedTarget` — which does the resolution. Also as Codex notes,
the existing plain-name `@RPC` path *couldn't* have dispatched to a
`distributed func` anyway — no `@RPC` expansion registers a closure for one
— so options 1 and 2 below, as originally framed (build a mangled → plain
table to feed into the `@RPC` dispatch table), were solving a problem that
routing through `executeDistributedTarget` sidesteps entirely. See option 4.

## Options

### 4. Pass the mangled identifier straight through (Codex's correction)

Give `distributed actor` its own transport entirely, separate from `@RPC`,
and never interpret `target.identifier` at all:

- Caller-side `WorkersActorSystem.remoteCall`/`remoteCallVoid` serializes
  the (still-mangled, opaque) identifier plus the encoded invocation and
  sends both to one fixed, always-registered Workers RPC method on the
  callee (a Durable Object or service binding backed by workers-swift) —
  not a per-method entry in `rpcExports`.
- The callee's `WorkersActorSystem` decodes that payload and calls
  `executeDistributedTarget(on:target:invocationDecoder:handler:)` with the
  identifier passed through unchanged. Resolution happens inside the Swift
  runtime, using the same mangled-name-keyed accessor lookup the language
  runtime already relies on for distributed actors on every other platform.

If this holds up, it removes the mangling problem as originally framed —
no demangler, no build-time table, no `worker-build` involvement — and
options 1 and 2 become unnecessary for *dispatch* (they might still be
useful for logging/observability of a human-readable method name, but
that's a much smaller ask). The open question this raises is new: does the
runtime machinery behind `executeDistributedTarget`'s accessor lookup — the
"distributed thunk" / accessor-table mechanism the Swift runtime normally
uses to resolve a mangled identifier back to a callable function — actually
work under this project's real constraints (wasm32, no Darwin runtime,
whatever subset of Swift's runtime metadata `swift-wasm`'s build carries)?
That needs its own spike before this can be trusted over options 1–3: a
`WorkersActorSystem.executeDistributedTarget` call, on a `distributed actor`
whose identifier arrived as a value (not a compile-time literal at the same
call site), needs to actually resolve and invoke correctly on wasm32/
workerd.

The remaining options are fallbacks if option 4's runtime resolution turns
out not to work under wasm32, and describe converting the mangled
identifier into something we dispatch on ourselves instead.

### 1. Runtime parsing

A narrow, targeted parse inside the shipped Wasm binary — not full
demangling. Empirically, the plain method name is the identifier chunk
immediately following the type's mangled chunk:
`$s9DistSpike7GreeterC5greet_...` → skip `9DistSpike` → skip `7GreeterC` →
read `5greet` → `"greet"`. Cheap, no new dependency, ships as Swift source in
`WorkersSwift`. Fragile against anything the narrow parser doesn't
anticipate: extensions, nested types, operators, generic methods, and any
mangling-scheme change across Swift versions all risk silently
misparsing rather than failing loudly.

### 2. Build-time resolution in `worker-build`

Move the mangled → plain mapping out of the shipped binary and into the
build step. `Plugins/WorkerBuild/WorkerBuild.swift` already parses the
compiled `.wasm` module's structure (`wasmExportNames`,
`durableObjectExports`, `rpcExports`) to build the JS shim's dispatch table —
this would be the same kind of pass, just also reading identifier strings out
of the module and shipping a resolved `{mangled: plain}` table in the
generated `worker.mjs` instead of parsing logic in the binary. At runtime,
`WorkersActorSystem` would do a dictionary lookup, not string surgery.

This needs two things neither of which is verified yet:

- **That the mangled identifiers are actually present as extractable string
  data in the compiled module.** The compiler embeds
  `RemoteCallTarget(mangled:)`'s argument as a string literal at each
  distributed-thunk call site; whether that literal survives into the
  `.wasm` binary's data section in a form `worker-build` can find (versus,
  e.g., being resolved through some other mechanism, or optimized/deduped in
  a way that's hard to correlate back to a specific method) hasn't been
  checked against a real build. The next concrete step, before writing any
  of this into the real repo, is inspecting `DistSpike2.wasm`'s data section
  for `$s...` byte patterns and confirming they match `RemoteCallTarget`
  identifiers actually produced at a real call site.
- **A demangler to turn the extracted mangled string into a plain name**,
  reliably enough to trust over the narrow parser in option 1. Two ways to
  get one into `worker-build`, revised per Codex's review:
  - Shell out to `swift demangle`, which ships with every Swift toolchain.
    This is *not* a new `PATH` dependency, as originally claimed here:
    `WorkerBuild.performCommand` already resolves the toolchain's `swift`
    executable via `swiftExecutable(_:)` and shells out to it for `build`,
    `--show-bin-path`, `sdk list`, and `--version`. Calling `swift demangle`
    through that same resolved path costs nothing new and guarantees the
    demangler matches the exact toolchain that produced the Wasm. The
    remaining work is parsing `swift demangle`'s human-oriented text output
    back into a plain method name reliably.
  - Vendor a small pure-Swift demangler, e.g.
    [oozoofrog/SwiftDemangle](https://github.com/oozoofrog/SwiftDemangle).
    Codex points out this can't be a plain dependency of the `WorkerBuild`
    plugin target the way this document first suggested: SwiftPM plugins
    can only depend on executable or binary tool targets, not library
    products, so `swift build` on SwiftPM 6.3 rejects a plugin-to-library
    dependency outright. Using it would mean either copying its sources
    directly into the plugin, or wrapping it in a separate executable tool
    target the plugin invokes as a subprocess — both add real complexity
    that the "self-contained, no external process" framing understated.
    Given the first bullet no longer has a real `PATH` downside, this
    option looks weaker by comparison.

### 3. Don't use `distributed actor` for RPC dispatch

Keep `@RPC` / `RPCStub` as the only cross-binding call mechanism and treat
the distributed-actor spike as a feasibility answer ("yes, it works") without
building a transport. Simplest, zero new risk, but gives up the ergonomic
win (compiler-enforced `async throws`, no per-method stub) that motivated
looking at this in the first place.

## Open questions for review

1. **(New, per Codex's review.)** Does `executeDistributedTarget`'s
   mangled-identifier resolution actually work under this project's real
   constraints — wasm32, no Darwin runtime, whatever subset of Swift's
   runtime metadata `swift-wasm` carries? This needs a dedicated spike
   before option 4 can be trusted over the fallbacks. If it works, most of
   the rest of this document (options 1–3, and most of the questions below)
   is moot for dispatch purposes.
2. If option 4 doesn't hold up and we fall back to options 1–3: are the
   mangled identifiers actually recoverable from the compiled `.wasm`
   module at build time (see option 2's first bullet), or does that require
   a spike result we don't have yet before option 2 is viable at all?
3. If option 2 is viable: shell out to `swift demangle` via the toolchain
   path `WorkerBuild` already resolves, or vendor `oozoofrog/SwiftDemangle`
   (which per Codex's review would need to be copied into the plugin's
   sources or wrapped as a separate executable tool target, not linked as a
   plugin dependency)? The `PATH`/external-process concern that originally
   motivated vendoring doesn't hold, so shelling out now looks like the
   default unless the output-parsing burden changes that.
4. Where should a resolved `{mangled: plain}` table (options 1–3 only) live
   at runtime — inlined as JSON into the generated `worker.mjs`, or as a
   Wasm custom section read at `_initialize()`?
5. How do any of these approaches handle generic `distributed func`s, where
   the mangled identifier encodes the generic signature? Does a dispatch
   table need to be keyed more coarsely than "one entry per identifier", or
   is genericity on a distributed method out of scope entirely? (For option
   4 this may not matter, since resolution happens in the runtime rather
   than a table we build.)
6. For options 1–3, which are toolchain-mangling-scheme-dependent: is a
   build-time table regenerated per build (so it can't drift from the
   toolchain actually used) an acceptable answer to versioning concerns, or
   does this need an explicit compatibility check?
7. Is any of this (option 4 included) worth the complexity over option 3 —
   not using `distributed actor` for RPC dispatch at all — given `@RPC`
   already works and is shipped?
