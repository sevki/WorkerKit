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

**Update: option 4's premise is now verified, not just proposed.** The
spike was extended so `remoteCall`/`remoteCallVoid` capture
`target`/the encoded arguments (as a real transport's send side would),
then re-dispatch by calling `executeDistributedTarget(on:target:
invocationDecoder:handler:)` against a real local `Greeter` instance — the
same shape a callee-side `WorkersActorSystem` would use after receiving a
call over Workers RPC. Both natively (x86_64) and under real workerd on
wasm32, this correctly resolved every mangled identifier and invoked the
actual method:

```
greet -> identifier=$s10DistSpike27GreeterC5greet_5timesS2S_SitYaKFTE
greet -> result=Hello, world! x3 (expect "Hello, world! x3")
increment -> identifier=$s10DistSpike27GreeterC9increment2byS2i_tYaKFTE
increment -> result=6 (expect 6)
reset -> identifier=$s10DistSpike27GreeterC5resetyyYaKFTE
reset -> completed without throwing (expect "reset() actually ran" printed above)
```

`greet` returned exactly `"Hello, world! x3"`, `increment` returned `6`
(the compiler-computed result, not an echo of the input), and `reset`
genuinely ran. No code anywhere parsed or demangled the identifier — the
Swift runtime's own accessor lookup did the resolution, on wasm32, under
workerd. This answers open question 1 below: yes, option 4 holds up, and
options 1–3 are not needed for dispatch.

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

### 4. Pass the mangled identifier straight through (Codex's correction — verified)

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

**Verified** (see "What's confirmed" above): a round-trip spike — capture
`target`/encoded arguments in `remoteCall`, then call
`executeDistributedTarget` against a real local instance, exactly as a
callee-side `WorkersActorSystem` would — correctly resolved and invoked
`greet`, `increment`, and `reset` under real workerd on wasm32, matching a
native (x86_64) run exactly. This removes the mangling problem as
originally framed: no demangler, no build-time table, no `worker-build`
involvement. Options 1 and 2 are not needed for dispatch (they might still
be useful for logging/observability of a human-readable method name, but
that's a much smaller ask, and not something this document pursues further
for now).

The remaining options (1–3) are kept below for completeness/record, but are
no longer live candidates for dispatch — see "What's confirmed" for why.

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

Question 1 from the previous revision of this document — whether
`executeDistributedTarget`'s mangled-identifier resolution actually works
under wasm32/workerd — is answered: yes, verified by spike (see "What's
confirmed"). What's left is about actually building option 4:

1. What does `WorkersActorSystem`'s wire format need to carry per call?
   Concretely: `target.identifier` (opaque string), the actor `id` to route
   to (which Durable Object / binding), and the encoder's recorded
   arguments — encoded how? The spike's `MinimalInvocationEncoder` just
   boxes Swift values in `[Any]` in-process; a real transport needs actual
   serialization (JSON via `Codable`, most likely) crossing the Workers RPC
   boundary.
2. What does the "one fixed, always-registered Workers RPC method" per
   Durable Object/binding look like concretely — a reserved method name
   (e.g. `__distributedCall`) that `worker-build` always emits, separate
   from `rpcExports`/`durableObjectExports`? Does it need `worker-build`
   involvement at all, or can it be plain `WorkersSwift` library code (an
   RPC target the macros don't need to know about)?
3. How does the callee side know *which* local actor instance to run
   `executeDistributedTarget` against for a given call — is this scoped to
   "one distributed actor per Durable Object instance" (so the DO's own
   identity is the actor's identity), or does a single DO/binding need to
   host multiple distributed actor ids?
4. Error handling: `executeDistributedTarget`'s `handler.onThrow` receives
   the real thrown error, but that error has to cross the RPC boundary back
   to the caller somehow — does that reuse whatever `@RPC`/`RPCStub`
   already does for thrown errors, or does it need its own encoding?
5. Is this worth building at all over just keeping `@RPC`/`RPCStub` (option
   3)? The demangling risk that originally made this feel exploratory is
   gone; the remaining cost is a small, self-contained transport (per Q1–4
   above), which changes the tradeoff considerably in favor of building it.
6. ~~**(New, per Codex's review.)** Generic `distributed func`s...~~
   **Resolved.** Generic `distributed func`s are supported: the same
   "let the Swift runtime resolve it" approach that makes leaving the method
   identifier mangled safe also works for generic substitutions.
   `recordGenericSubstitution` captures each generic parameter's mangled
   type name via the stdlib's `_mangledTypeName` (the same underscored-but-
   public mechanism `swift-distributed-actors` uses for this); it crosses
   the wire alongside the identifier and arguments, and
   `decodeGenericSubstitutions` resolves each one back to a real `Any.Type`
   via `_typeByName` on the callee side. Verified by spike first (`Int`/
   `String`/a custom struct/`Array<Int>` round-tripped through
   `_mangledTypeName`/`_typeByName` under real workerd on wasm32), then in
   the real implementation (`Doubler.echo<T: Codable & Sendable>(_:)` in
   `HelloWorker`, passing against real workerd).

Options 1–3 above are kept for the record but are no longer live
candidates — see "What's confirmed".

## Implementation status

A v1 `WorkersActorSystem` is in progress (see the PR stacked on this one).
It answers Q1–4 above concretely, all scoped down from what those
questions considered:

- **Wire format (Q1):** no JSON. Each argument is encoded straight to a
  `JSValue` with a new `JSValueEncoder` (the `Encodable` counterpart to
  JavaScriptKit's existing `JSValueDecoder`), and the caller sends
  `(target.identifier, [JSValue])` as real RPC arguments — Workers RPC
  structured-clones them across the boundary itself, so there's no text
  serialization step at all.
- **Fixed RPC method (Q2):** no `worker-build` involvement. The one fixed
  entry point is a plain top-level `@RPC` function
  (`__workersSwiftDistributedCall`), reusing 100% of the existing `@RPC`
  macro/dispatch machinery instead of adding a new export kind.
- **Actor routing (Q3):** supported both ways. `WorkersActorSystem.host(_:)`
  still gives the narrowest case — one hosted singleton actor per system,
  mirroring how a top-level `@RPC` function is already "one instance of the
  default `WorkerEntrypoint` per request" — but `init(durableObjects:)` plus
  `host(_:as:)` now also route to one distributed actor instance per
  Durable Object id, chosen dynamically per call from the target actor's
  own `id`. The two sides have to agree on what that id *is*: a Durable
  Object's own `DurableObjectState.id` is a hex string, not a friendly
  name, so the caller resolves using `DurableObjectNamespace.idFromName(_:)`
  (not an arbitrary string) and the callee hosts itself under `state.id`
  directly — see `WorkersActorSystem`'s doc comment and the dining
  philosophers example (`Fork`/`Philosopher` in `HelloWorker`) for the
  concrete pattern.
- **Errors (Q4):** the callee's `@RPC` method surfaces
  `executeDistributedTarget`'s `handler.onThrow` as a `JSException`, the
  same path an ordinary `@RPC` method's thrown error already takes; the
  caller sees whatever `RPCStub.call` throws.
- **Generics (Q6):** supported. `recordGenericSubstitution` sends each
  generic parameter's mangled type name (`_mangledTypeName`);
  `decodeGenericSubstitutions` resolves it back with `_typeByName` on the
  callee side.
