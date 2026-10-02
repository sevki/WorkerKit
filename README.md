# WorkerKit

Write [Workers](https://developers.cloudflare.com/workers/) in Swift, in the style of [workers-rs](https://github.com/cloudflare/workers-rs). Workers compile to WebAssembly and run on [workerd](https://github.com/cloudflare/workerd) and [denoland/celld](https://github.com/denoland/celld).

📖 **[API documentation](https://sevki.github.io/WorkerKit/documentation/workerkit/)**, built with DocC.

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

## How it maps to workers-rs

| workers-rs | WorkerKit |
|---|---|
| `worker` (`Request`, `Response`, `Env`, `Context`, `KvStore`, `Bucket`, `SqlStorage`, …) | `WorkerKit` (`KVStore` for `KvStore`, `R2Bucket` for `Bucket`, `SQLStorage` for `SqlStorage`) |
| `#[event(fetch)]` | `@Event(.fetch)` (`WorkerKitMacros`) |
| `#[durable_object]` + `impl DurableObject` | `@DurableObject` class, with `@RPC` methods |
| `wasm-bindgen`, `js-sys`, `wasm-bindgen-futures` | [JavaScriptKit](https://github.com/swiftwasm/JavaScriptKit) and JavaScriptEventLoop |
| `worker-build` and its `shim.mjs` | `swift package worker-build` (`Plugins/WorkerBuild`) and `JavaScript/shim.mjs` |

`Request`, `Headers`, `Env` and `Context` wrap the runtime's own JavaScript objects, and each exposes it as `jsObject`, so any Web or Workers API is one JavaScriptKit call away (see the `/digest` route in `Sources/HelloWorker`, which awaits `crypto.subtle.digest`). `Response` is a Swift value until the handler returns it:

- `Response.ok(_:)`, `.text(_:status:)`, `.error(_:_:)`, `.empty(status:)`, and `withHeader(_:_:)`.
- A status outside 200–599 or a header that the Fetch `Headers` class would reject becomes a `500` rather than a JavaScript exception, and 204, 205 and 304 are sent without a body.
- An error thrown by the handler is logged with `console.error` and becomes `500 Internal Server Error`.

`Env` reads plain-text bindings (`env.variable("NAME")`, `env.secret("NAME")`), KV namespaces (`env.kv("NAME")`), R2 buckets (`env.r2("NAME")`), Durable Object namespaces (`env.durableObject("NAME")`) and service bindings (`env.service("NAME")`), and `Context` exposes `waitUntil` and `passThroughOnException`. Other typed bindings such as D1 are not wrapped yet.

## KV

```swift
let kv = env.kv("CACHE")
try await kv.put("greeting", "hello", expirationTtl: 3600, metadata: ["by": "swift"] as [String: String])
let greeting = try await kv.get("greeting")              // String?
let entry = try await kv.getWithMetadata("greeting")     // (value: String, metadata: JSValue)?
let page = try await kv.list(prefix: "user/", limit: 100) // keys, listComplete, cursor
try await kv.delete("greeting")
```

`KVStore` is workers-rs' `KvStore`. It also reads and writes bytes (`bytes(_:)`, and `put(_:_:)` with a `[UInt8]`). Bind a namespace with `"kv_namespaces": [{ "binding": "CACHE", "id": "…" }]`.

## R2

```swift
let bucket = env.r2("ASSETS")
try await bucket.put("greeting.txt", "hello", httpMetadata: R2HTTPMetadata(contentType: "text/plain"))
let object = try await bucket.get("greeting.txt")   // R2ObjectBody?
let text = try await object?.text()                 // String
let page = try await bucket.list(prefix: "user/", limit: 100) // objects, truncated, cursor
try await bucket.delete("greeting.txt")
```

`R2Bucket` is workers-rs' `Bucket`. `get`/`put` also take conditional (`onlyIf:`) and ranged-read (`range:`) options, and `put(_:_:)` reads/writes bytes with a `[UInt8]`; multipart uploads aren't wrapped yet. Bind a bucket with `"r2_buckets": [{ "binding": "ASSETS", "bucket_name": "…" }]`.

## Durable Objects and RPC

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

// In a handler:
let counter = env.durableObject("COUNTER").get(named: "global")
let count = try await counter.call("increment", 1, as: Int.self)
let response = try await counter.fetch("https://counter/")
```

- `@DurableObject` adds the `DurableObject` conformance (`init(state:env:)`, and optional `fetch(_:)` and `alarm()`), and generates a Wasm export named after the class and its `@RPC` methods.
- `worker-build` reads those exports and writes an `export class Counter extends DurableObject` (from `cloudflare:workers`) into `worker.mjs`, with one method per `@RPC` method, so the runtime sees an ordinary Durable Object class with RPC methods.
- RPC arguments and results convert through JavaScriptKit's `ConstructibleFromJSValue` and `ConvertibleToJSValue` (`Int`, `Double`, `String`, `Bool`, …).
- `DurableObjectState.storage` offers `get(_:as:)`, `put(_:_:)` and `delete(_:)`, and `jsObject` for the rest of the storage API.
- Bind the class as usual, for example in wrangler.jsonc: `"durable_objects": { "bindings": [{ "name": "COUNTER", "class_name": "Counter" }] }` with a migration that adds `Counter`.

### SQL storage

Every Durable Object is SQLite-backed once created with `new_sqlite_classes` (the migration above), and `state.storage.sql` gives direct access to that database:

```swift
let sql = state.storage.sql
try sql.exec("CREATE TABLE IF NOT EXISTS counters (name TEXT PRIMARY KEY, value INTEGER)")
try sql.exec(
    "INSERT INTO counters (name, value) VALUES (?, ?) ON CONFLICT(name) DO UPDATE SET value = value + excluded.value",
    "x", amount
)
let count = try sql.exec("SELECT value FROM counters WHERE name = ?", "x").rows().first?["value", as: Int.self]
```

- `SQLStorage`, like workers-rs' `SqlStorage`: `exec(_:_:)` runs a query with positional `?` bindings and returns a `SQLCursor`. SQLite runs in the same process as the Durable Object, so `exec` is synchronous even though it can throw — a syntax error or constraint violation is thrown from `exec` itself, not later.
- `SQLCursor.rows()` returns each row as a `SQLRow` (`row["column", as: Int.self]`, or `.bytes("column")` for a `BLOB`); `.columnNames`, `.rowsRead` and `.rowsWritten` are also available.
- `SQLStorage.query(_:_:as:)` and `SQLCursor.decode(as:)` decode rows straight into a `Decodable` type, matching columns to its properties by name.
- workerd's own configuration (not Wrangler's) also needs `enableSql = true` on the namespace.

## RPC over service bindings

`@RPC` on a top-level function makes it a method of the worker's default entrypoint, which other workers (or the worker itself) call through a service binding:

```swift
@RPC func add(_ a: Int, _ b: Int) -> Int {
    a + b
}

// In another worker, with "services": [{ "binding": "MATH", "service": "my-swift-worker" }]:
let sum = try await env.service("MATH").call("add", 2, 3, as: Int.self)
```

When a worker has top-level `@RPC` functions, `worker-build` makes its default export a `WorkerEntrypoint` class (from `cloudflare:workers`) with `fetch` and one method per function; otherwise the default export is a plain `{ fetch }` object. A service binding's `Fetcher` also forwards requests with `fetch(_:)`.

## Distributed actors over Workers RPC

`WorkersActorSystem` (from the `WorkerKitDistributed` library) backs Swift's `distributed actor` with the same `@RPC`/`RPCStub` transport above, instead of a hand-written stub:

```swift
import WorkerKitDistributed

distributed actor Greeter {
    typealias ActorSystem = WorkersActorSystem

    distributed func hello(_ name: String) -> String {
        "Hello, \(name)!"
    }
}

// Callee side: host the one instance, and forward the one fixed entry point
// every WorkersActorSystem call arrives through.
private let greeterSystem = WorkersActorSystem()
private let greeter: Greeter = {
    let actor = Greeter(actorSystem: greeterSystem)
    greeterSystem.host(actor)
    return actor
}()

@RPC func __workerKitDistributedCall(
    _ identifier: String, _ arguments: JSValue, _ genericSubstitutions: [String]
) async throws -> JSValue {
    _ = greeter // force the lazy top-level `let` to initialize
    return try await greeterSystem.receive(
        identifier: identifier, arguments: arguments, genericSubstitutions: genericSubstitutions
    )
}

// Caller side:
let system = WorkersActorSystem(stub: env.service("SELF"))
let greeter = try Greeter.resolve(id: "greeter", using: system)
let greeting = try await greeter.hello("world")
```

- A `distributed func`'s mangled identifier is never interpreted by this library — it's passed through opaquely to `executeDistributedTarget`, the same Swift runtime mechanism that resolves it on every other platform. Generic `distributed func`s work too, the same way.
- `WorkersActorSystem(stub:)` + `host(_:)` back one singleton actor per worker, as above. `WorkersActorSystem(durableObjects:)` + `host(_:as:)` instead back one distributed actor instance per Durable Object id, routed dynamically per call — see the [Distributed actors article](https://sevki.github.io/WorkerKit/documentation/workerkit/distributedactors) (or `Sources/HelloWorker/Worker.swift`'s `Fork`/`Philosopher` dining-philosophers example) for that case.
- Outside a worker, the same `WorkersActorSystem` type talks JSON over a WebSocket instead: `WorkersActorSystem(worker: URL(string: "https://…")!)`, served by the library's `RPCGateway` Durable Object at `WorkersActorSystem.gatewayPath`. Declare an actor once in a module both the worker and a native tool depend on, and the tool calls it with the same `Greeter.resolve(id:using:)` — see `Sources/HelloWorkerActors` and `Sources/HelloWorkerCLI`.
- See [`rfcs/distributed-actor-rpc.md`](rfcs/distributed-actor-rpc.md) for the full design discussion.

## Repository layout

- `Sources/WorkerKit`: the library.
- `Sources/WorkerKit/Documentation.docc`: the DocC catalog (articles and the landing page); see [Documentation](#documentation).
- `Sources/WorkerKitMacros`: `@Event`.
- `Sources/HelloWorker`: an example worker, which `Sources/WorkerKitWasm` links into `WorkerKit.wasm`.
- `Plugins/WorkerBuild`: `swift package worker-build`.
- `JavaScript/shim.mjs`: the Worker entry point that instantiates the module and calls into Swift.
- `Tests/WorkerKitTests`, `Tests/WorkerKitMacrosTests`: native tests (`swift test`).
- `Tests/e2e`: runs the built worker in real workerd and celld processes.

## Building

1. Install the Swift SDK for WebAssembly that matches your toolchain version (see [Getting Started with Swift SDKs for WebAssembly](https://www.swift.org/documentation/articles/wasm-getting-started.html)). Workers use Swift concurrency, so use the `*_wasm` SDK; the Embedded Swift SDK is not supported.

2. Build the worker:

   ```bash
   swift package --allow-writing-to-package-directory worker-build
   ```

   The plugin builds the `WorkerKitWasm` product as a WASI reactor module and writes:

   ```
   build/worker/worker.mjs        JavaScriptKit's runtime.mjs + JavaScript/shim.mjs, as one module
   build/worker/WorkerKit.wasm
   ```

   Options: `--swift-sdk <id>`, `--product <name>` (in your own package, the executable that holds your `@Event(.fetch)` function), `-c debug|release` (default `release`), and `--output <dir>`. On macOS, add `--disable-sandbox` if the plugin sandbox blocks the nested `swift build`.

## Running on workerd or celld

Both runtimes resolve `worker.mjs`'s `import "./WorkerKit.wasm"` to a compiled `WebAssembly.Module`.

For [celld](https://github.com/denoland/celld) (and Wrangler), point `main` at the built worker:

```jsonc
{
  "name": "my-swift-worker",
  "main": "build/worker/worker.mjs",
  "no_bundle": true,
  "compatibility_date": "2026-01-01",
  "vars": { "GREETING": "hello" }
}
```

```bash
celld dev
```

For workerd, list both files as modules:

```capnp
modules = [
  (name = "worker.mjs", esModule = embed "build/worker/worker.mjs"),
  (name = "WorkerKit.wasm", wasm = embed "build/worker/WorkerKit.wasm"),
],
```

Workers runtimes do not provide WASI, so the shim supplies the WASI functions the Swift runtime uses (stdout/stderr to `console`, clocks, randomness) and answers every other WASI import with `ENOSYS`.

## Tests

```bash
swift test          # Response and @Event, natively
npm ci
npm run test:e2e    # the built worker in workerd (after worker-build)
```

`npm run test:e2e` serves `build/worker` (or `WORKER_DIR`) with workerd from npm. Set `E2E_RUNTIMES=workerd,celld` to also run it on a `celld` binary on `PATH` (or `CELLD_BIN`). CI builds the worker with the Wasm SDK and runs the suite on both runtimes, and runs `swift test` on Linux and macOS.

CI compiles this package through [llbuild-worker](https://github.com/sevki/llbuild-worker)'s compilation cache, the live cache this package's own build is also a test of. Each job downloads the released `CASPlugin` and `casd` (a small local daemon that keeps one connection to the cache and serves the compiler from the loopback, `Scripts/ci-compile-cache.sh`) and compiles through them, so a build that has not changed replays its results instead of compiling them. A pull request from a fork has no cache token and builds without it.

## Documentation

The public API is documented with [DocC](https://www.swift.org/documentation/docc/) in doc comments and in `Sources/WorkerKit/Documentation.docc`, and published at <https://sevki.github.io/WorkerKit/documentation/workerkit/> on every push to `main`.

To read it locally instead:

```bash
swift package --disable-sandbox preview-documentation --target WorkerKit
```

This serves the docs and opens them in your browser, rebuilding as you edit. It needs `--disable-sandbox` because the preview server binds a local port; the plugin sandboxes only that server, not your code.

To build the static site yourself, as CI does:

```bash
swift package --allow-writing-to-directory docs \
  generate-documentation --target WorkerKit \
  --disable-indexing \
  --transform-for-static-hosting \
  --hosting-base-path WorkerKit \
  --output-path docs
```

`--hosting-base-path WorkerKit` matches this repository being served from `https://sevki.github.io/WorkerKit/`; drop it (and adjust the links above) if you publish from a custom domain or the root of a `<user>.github.io` repository instead. CI also runs `swift package generate-documentation --target WorkerKit --warnings-as-errors` on every pull request, so a broken `<doc:...>` link or an undocumented symbol referenced from an article fails the build before it reaches `main`.

### Publishing to GitHub Pages

The `docs` and `publish-docs` jobs in `.github/workflows/ci.yml` build the static site on every push to `main` and deploy it with `actions/deploy-pages`. That needs GitHub Pages enabled once, with its source set to **GitHub Actions**: repository **Settings → Pages → Build and deployment → Source → GitHub Actions**. After that, every push to `main` that changes the docs (or the code they document) updates the published site within a few minutes.
