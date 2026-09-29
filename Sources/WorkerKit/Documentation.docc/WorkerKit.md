# ``WorkerKit``

Write Cloudflare Workers in Swift, in the style of [workers-rs](https://github.com/cloudflare/workers-rs), and run them on [workerd](https://github.com/cloudflare/workerd) and [denoland/celld](https://github.com/denoland/celld).

## Overview

A worker is a Swift package that depends on `WorkerKit` and exposes one
`@Event(.fetch)` function:

```swift
import WorkerKit

@Event(.fetch)
func fetch(req: Request, env: Env, ctx: Context) async throws -> Response {
    switch (req.method, req.path) {
    case ("GET", "/"):
        return .ok("Hello from Swift")
    case ("POST", "/echo"):
        return .ok(try await req.text())
    default:
        return .error("Not Found", 404)
    }
}
```

`swift package worker-build` compiles that into a WASI reactor module and
bundles it with a JavaScript shim into a single `worker.mjs`, which workerd
and celld run directly. See <doc:GettingStarted> for the full setup.

`Request`, `Headers`, `Env`, `Context` and `Response` wrap the runtime's own
JavaScript objects; each type's `jsObject` property is one JavaScriptKit call
away from any Web or Workers API the library does not wrap yet.

## Topics

### Getting started

- <doc:GettingStarted>
- ``Event(_:)``
- ``WorkerEvent``

### Tutorials

- <doc:RPCGatewayTutorials>

### Requests and responses

- ``Request``
- ``Headers``
- ``Response``

### Bindings

- ``Env``
- ``Context``
- <doc:KVStorage>
- <doc:R2Storage>
- <doc:DurableObjects>
- <doc:DistributedActors>

### Durable Objects and RPC

- ``DurableObject``
- ``DurableObject()``
- ``RPC()``
- ``DurableObjectState``
- ``DurableObjectStorage``
- ``SQLStorage``
- ``SQLCursor``
- ``SQLRow``
- ``DurableObjectNamespace``
- ``DurableObjectStub``
- ``Fetcher``
- ``RPCStub``
- ``FetchResponse``

### KV

- ``KVStore``
- ``KVListResult``
- ``KVKey``

### R2

- ``R2Bucket``
- ``R2Object``
- ``R2ObjectBody``
- ``R2HTTPMetadata``
- ``R2Checksums``
- ``R2Conditional``
- ``R2Range``
- ``R2ListResult``

### The generated runtime entry points

- ``WorkersRuntime``
