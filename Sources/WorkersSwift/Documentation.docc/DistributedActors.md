# Distributed actors over Workers RPC

Call a Durable Object, or another worker, as an ordinary Swift `distributed actor` — no hand-written stub, no string-keyed dispatch table.

## Overview

`WorkersActorSystem`, from the `WorkersDistributed` library, backs Swift's
`distributed actor` with the same transport ``RPC()`` already uses (an
``RPCStub``), instead of a new one. A
`distributed func`'s mangled identifier is never interpreted by this
library — it's passed through opaquely to the callee, which hands it to the
Swift runtime's own `executeDistributedTarget`, the same mechanism that
resolves it on every other platform. See
[`rfcs/distributed-actor-rpc.md`](https://github.com/sevki/workers-swift/blob/main/rfcs/distributed-actor-rpc.md)
in the repository for the full design discussion.

A `WorkersActorSystem` plays one of two roles, and every worker that hosts a
distributed actor needs exactly one fixed RPC entry point on the callee
side, forwarding to `WorkersActorSystem.receive(identifier:arguments:genericSubstitutions:)`:

```swift
@RPC func __workersSwiftDistributedCall(
    _ identifier: String, _ arguments: JSValue, _ genericSubstitutions: [String]
) async throws -> JSValue {
    try await system.receive(
        identifier: identifier, arguments: arguments, genericSubstitutions: genericSubstitutions
    )
}
```

The method must be named exactly `WorkersActorSystem.entryPointName`
(`__workersSwiftDistributedCall`) — `worker-build` finds it the same way it
finds any other ``RPC()`` method, through the Wasm export it generates.

A ``DurableObject()`` class that declares exactly one `WorkersActorSystem`
property gets this forwarder generated for free — see the per-Durable-Object-
id case below. Writing it out by hand, as here, is only needed for the
singleton case (a top-level function, not a `@DurableObject` class body) or
when a class hosts more than one `WorkersActorSystem`.

## One singleton actor per worker

The simplest case: one actor instance, shared by the whole worker, reached
through a fixed ``RPCStub`` (typically the worker's own `SELF` service
binding).

```swift
distributed actor Greeter {
    typealias ActorSystem = WorkersActorSystem

    distributed func hello(_ name: String) -> String {
        "Hello, \(name)!"
    }
}

// Callee side: construct the one instance eagerly and host it.
private let greeterSystem = WorkersActorSystem()
private let greeter: Greeter = {
    let actor = Greeter(actorSystem: greeterSystem)
    greeterSystem.host(actor)
    return actor
}()

@RPC func __workersSwiftDistributedCall(
    _ identifier: String, _ arguments: JSValue, _ genericSubstitutions: [String]
) async throws -> JSValue {
    // A top-level `let` initializes lazily, on first access — touch
    // `greeter` here so it's hosted before the first call arrives if
    // nothing else in the file references it.
    _ = greeter
    return try await greeterSystem.receive(
        identifier: identifier, arguments: arguments, genericSubstitutions: genericSubstitutions
    )
}

// Caller side, anywhere in the worker (or another worker, through a
// service binding to this one):
let system = WorkersActorSystem(stub: env.service("SELF"))
let greeter = try Greeter.resolve(id: "greeter", using: system)
let greeting = try await greeter.hello("world")
```

The id passed to `.resolve(id:using:)` is never interpreted in this mode —
`WorkersActorSystem.host(_:)` always dispatches to the one hosted
instance, regardless of what id a caller used.

## One instance per Durable Object id

For a distributed actor with real per-instance identity and state — the
Durable Object case — `WorkersActorSystem(durableObjects:)` routes
each call to the Durable Object instance named by the target actor's own
id, and `WorkersActorSystem.host(_:as:)` hosts the actor a Durable Object
represents, under that same object's id.

```swift
distributed actor Counter {
    typealias ActorSystem = WorkersActorSystem

    private var count = 0

    distributed func increment() -> Int {
        count += 1
        return count
    }
}

@DurableObject
final class CounterObject {
    let hostSystem: WorkersActorSystem
    let counter: Counter

    init(state: DurableObjectState, env: Env) {
        let hostSystem = WorkersActorSystem()
        self.hostSystem = hostSystem
        counter = hostSystem.host(state.id) { Counter(actorSystem: $0) }
    }
}
```

`@DurableObject` sees the `hostSystem` property above and generates the
`__workersSwiftDistributedCall` forwarder itself — write it out by hand only
when the class hosts more than one `WorkersActorSystem` (unambiguous
otherwise, so the macro leaves it alone whenever there's more than one to
choose from).

```swift
// Caller side:
let namespace = env.durableObject("COUNTERS")
let system = WorkersActorSystem(durableObjects: namespace)
let counter = try Counter.resolve(id: namespace.idFromName("main"), using: system)
let value = try await counter.increment()
```

The caller and the hosted object have to agree on the same id space: a
Durable Object's own ``DurableObjectState/id`` is a hex string, not a
friendly name, so the caller resolves using
``DurableObjectNamespace/idFromName(_:)`` — not an arbitrary string — and
the callee hosts itself under `state.id` directly, as above.

For a real, larger example — multiple instances of two different actor
types calling each other concurrently — see the dining philosophers example
(`Fork`/`Philosopher` in the repository's `HelloWorker` target).

## Generic distributed functions

A generic `distributed func` works too — its concrete type arguments cross
the wire as their mangled type names (the standard library's
`_mangledTypeName`), and the callee resolves them back to real types with
`_typeByName`, the same "let the Swift runtime do it" approach that makes
leaving the method identifier itself mangled safe.

```swift
distributed actor Greeter {
    typealias ActorSystem = WorkersActorSystem

    distributed func echo<T: Codable & Sendable>(_ value: T) -> T {
        value
    }
}
```

## Calling from outside a worker

Outside a worker — a native CLI, a server, a test — the same
`WorkersActorSystem` type is backed by a WebSocket instead of Workers RPC.
Declare the actor once, in a module both the worker and the native tool
depend on, and the tool calls it exactly as another worker would:

```swift
let system = WorkersActorSystem(worker: URL(string: "https://swift.example.workers.dev")!)
let greeter = try Greeter.resolve(id: "greeter", using: system)
let greeting = try await greeter.hello("world")
system.close()
```

Both builds compile the same declaration against the same actor system
type, so they agree on every distributed method's mangled identifier. The
worker end is the library's `RPCGateway` Durable Object, served at
`WorkersActorSystem.gatewayPath`, which relays each call to the worker's
entry point through its `SELF` service binding. Give each connection its
own gateway:

```swift
case ("GET", WorkersActorSystem.gatewayPath):
    let gateways = env.durableObject("RPCGATEWAY")
    return try await gateways.get(id: gateways.newUniqueID()).fetch(req)
```

See `HelloWorkerActors` and `HelloWorkerCLI` in the repository for a
complete example.

## Topics

### Routing to a Durable Object instance

- ``DurableObjectNamespace/idFromName(_:)``
- ``DurableObjectNamespace/get(id:)``
- ``DurableObjectNamespace/newUniqueID()``
