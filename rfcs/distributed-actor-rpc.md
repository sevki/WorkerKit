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

## The blocker

`DistributedActorSystem.remoteCall`/`remoteCallVoid` receive a
`RemoteCallTarget`, and `RemoteCallTarget.identifier` is not the method's
plain name — it's a **mangled Swift symbol**, e.g.:

```
$s9DistSpike7GreeterC5greet_5timesS2S_SitYaKFTE
```

Our entire dispatch convention (`@RPC`, `worker-build`'s `rpcExports`,
the JS shim's string-keyed call table) is built around plain names. To back
`DistributedActorSystem` with the same dispatch path, something has to bridge
mangled identifier → plain name (or we bypass the existing dispatch path
entirely and give distributed actors their own).

## Options

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
  get one into `worker-build`:
  - Shell out to `swift demangle`, which ships with every Swift toolchain.
    Simple, always correct for the installed toolchain's mangling scheme, but
    makes `worker-build` depend on finding a toolchain binary on `PATH` at
    build time (should normally be true — it's the same toolchain building
    the package — but is an external-process dependency the plugin doesn't
    currently have).
  - Vendor a small pure-Swift demangler, e.g.
    [oozoofrog/SwiftDemangle](https://github.com/oozoofrog/SwiftDemangle), as
    a dependency of the `WorkerBuild` plugin target. Keeps `worker-build`
    self-contained (no external process, no `PATH` dependency), but adds a
    third-party dependency whose correctness/maintenance status against
    current Swift mangling isn't yet evaluated.

### 3. Don't use `distributed actor` for RPC dispatch

Keep `@RPC` / `RPCStub` as the only cross-binding call mechanism and treat
the distributed-actor spike as a feasibility answer ("yes, it works") without
building a transport. Simplest, zero new risk, but gives up the ergonomic
win (compiler-enforced `async throws`, no per-method stub) that motivated
looking at this in the first place.

## Open questions for review

1. Are the mangled identifiers actually recoverable from the compiled
   `.wasm` module at build time (see option 2's first bullet), or does that
   require a spike result we don't have yet before this plan is viable at
   all?
2. If option 2 is viable: shell out to `swift demangle`, or vendor
   `oozoofrog/SwiftDemangle`? Trade-off is a `PATH`-dependent external
   process vs. a small third-party dependency of unknown maturity.
3. Where should the resolved `{mangled: plain}` table live at runtime —
   inlined as JSON into the generated `worker.mjs`, or as a Wasm custom
   section read at `_initialize()`?
4. How does this handle generic `distributed func`s, where the mangled
   identifier encodes the generic signature? Does the dispatch table need to
   be keyed more coarsely than "one entry per identifier", or is genericity
   on a distributed method out of scope entirely?
5. Given all of the above is toolchain-mangling-scheme-dependent: is a
   build-time table regenerated per build (so it can't drift from the
   toolchain actually used) an acceptable answer to versioning concerns, or
   does this need an explicit compatibility check?
6. Is this worth the complexity over option 3 at all, given `@RPC` already
   works and is shipped?
