# Durable Objects and RPC

Stateful objects with their own storage, reachable by fetch or by RPC, like workers-rs' `#[durable_object]`.

## Overview

Mark a class ``DurableObject()`` and its RPC methods ``RPC()``:

```swift
@DurableObject
final class Counter {
    let state: DurableObjectState

    init(state: DurableObjectState, env: Env) {
        self.state = state
    }

    // Requests sent with stub.fetch(_:). Optional; the default answers 501.
    func fetch(_ req: Request) async throws -> Response {
        .ok(String(try await state.storage.get("count", as: Int.self) ?? 0))
    }

    // Callable from other workers and objects through the stub.
    @RPC func increment(by amount: Int) async throws -> Int {
        let count = (try await state.storage.get("count", as: Int.self) ?? 0) + amount
        try await state.storage.put("count", count)
        return count
    }
}
```

- ``DurableObject()`` adds the ``DurableObject`` conformance
  (`init(state:env:)`, and optional `fetch(_:)` and `alarm()`), and generates
  a Wasm export named after the class and its ``RPC()`` methods.
- `worker-build` reads those exports and writes an `export class Counter
  extends DurableObject` (from `cloudflare:workers`) into `worker.mjs`, with
  one method per ``RPC()`` method, so the runtime sees an ordinary Durable
  Object class with RPC methods.
- RPC arguments and results convert through JavaScriptKit's
  `ConstructibleFromJSValue` and `ConvertibleToJSValue` (`Int`, `Double`,
  `String`, `Bool`, …). ``RPC()`` methods cannot take variadic, `inout` or
  defaulted parameters, because the generated call passes one JavaScript
  argument per parameter, by value.
- ``DurableObjectState/storage`` offers `get(_:as:)`, `put(_:_:)` and
  `delete(_:)`, and `jsObject` for the rest of the storage API.
- Bind the class as usual, for example in wrangler.jsonc:
  `"durable_objects": { "bindings": [{ "name": "COUNTER", "class_name":
  "Counter" }] }` with a migration that adds `Counter`.

## Calling a Durable Object

```swift
let counter = env.durableObject("COUNTER").get(named: "global")
let count = try await counter.call("increment", 1, as: Int.self)
let response = try await counter.fetch("https://counter/")
```

``Env/durableObject(_:)`` returns a ``DurableObjectNamespace``;
``DurableObjectNamespace/get(named:)`` returns a ``DurableObjectStub``, which
is an ``RPCStub``: `call(_:_:...as:)` for RPC and `fetch(_:)` for a plain
request.

## RPC over service bindings

`@RPC` on a top-level function makes it a method of the worker's default
entrypoint, which other workers (or the worker itself) call through a
service binding:

```swift
@RPC func add(_ a: Int, _ b: Int) -> Int {
    a + b
}

// In another worker, with "services": [{ "binding": "MATH", "service": "my-swift-worker" }]:
let sum = try await env.service("MATH").call("add", 2, 3, as: Int.self)
```

When a worker has top-level ``RPC()`` functions, `worker-build` makes its
default export a `WorkerEntrypoint` class (from `cloudflare:workers`) with
`fetch` and one method per function; otherwise the default export is a plain
`{ fetch }` object. ``Env/service(_:)`` returns a ``Fetcher``, another
``RPCStub``, that also forwards requests with `fetch(_:)`.

## Topics

### Declaring Durable Objects

- ``DurableObject()``
- ``RPC()``
- ``DurableObject``

### State and storage

- ``DurableObjectState``
- ``DurableObjectStorage``

### Calling Durable Objects and service bindings

- ``DurableObjectNamespace``
- ``DurableObjectStub``
- ``Fetcher``
- ``RPCStub``
- ``FetchResponse``
