# workers-swift

Write [Workers](https://developers.cloudflare.com/workers/) in Swift, in the style of [workers-rs](https://github.com/cloudflare/workers-rs). Workers compile to WebAssembly and run on [workerd](https://github.com/cloudflare/workerd) and [denoland/celld](https://github.com/denoland/celld).

```swift
import WorkersSwift

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

| workers-rs | workers-swift |
|---|---|
| `worker` (`Request`, `Response`, `Env`, `Context`, …) | `WorkersSwift` |
| `#[event(fetch)]` | `@Event(.fetch)` (`WorkersSwiftMacros`) |
| `wasm-bindgen`, `js-sys`, `wasm-bindgen-futures` | [JavaScriptKit](https://github.com/swiftwasm/JavaScriptKit) and JavaScriptEventLoop |
| `worker-build` and its `shim.mjs` | `swift package worker-build` (`Plugins/WorkerBuild`) and `JavaScript/shim.mjs` |

`Request`, `Headers`, `Env` and `Context` wrap the runtime's own JavaScript objects, and each exposes it as `jsObject`, so any Web or Workers API is one JavaScriptKit call away (see the `/digest` route in `Sources/HelloWorker`, which awaits `crypto.subtle.digest`). `Response` is a Swift value until the handler returns it:

- `Response.ok(_:)`, `.text(_:status:)`, `.error(_:_:)`, `.empty(status:)`, and `withHeader(_:_:)`.
- A status outside 200–599 or a header that the Fetch `Headers` class would reject becomes a `500` rather than a JavaScript exception, and 204, 205 and 304 are sent without a body.
- An error thrown by the handler is logged with `console.error` and becomes `500 Internal Server Error`.

`Env` reads plain-text bindings (`env.variable("NAME")`, `env.secret("NAME")`), and `Context` exposes `waitUntil` and `passThroughOnException`. Typed bindings such as KV, R2, D1 and Durable Objects are not wrapped yet.

## Repository layout

- `Sources/WorkersSwift`: the library.
- `Sources/WorkersSwiftMacros`: `@Event`.
- `Sources/HelloWorker`: an example worker, which `Sources/WorkersSwiftWasm` links into `WorkersSwift.wasm`.
- `Plugins/WorkerBuild`: `swift package worker-build`.
- `JavaScript/shim.mjs`: the Worker entry point that instantiates the module and calls into Swift.
- `Tests/WorkersSwiftTests`, `Tests/WorkersSwiftMacrosTests`: native tests (`swift test`).
- `Tests/e2e`: runs the built worker in real workerd and celld processes.

## Building

1. Install the Swift SDK for WebAssembly that matches your toolchain version (see [Getting Started with Swift SDKs for WebAssembly](https://www.swift.org/documentation/articles/wasm-getting-started.html)). Workers use Swift concurrency, so use the `*_wasm` SDK; the Embedded Swift SDK is not supported.

2. Build the worker:

   ```bash
   swift package --allow-writing-to-package-directory worker-build
   ```

   The plugin builds the `WorkersSwiftWasm` product as a WASI reactor module and writes:

   ```
   build/worker/worker.mjs        JavaScriptKit's runtime.mjs + JavaScript/shim.mjs, as one module
   build/worker/WorkersSwift.wasm
   ```

   Options: `--swift-sdk <id>`, `--product <name>` (in your own package, the executable that holds your `@Event(.fetch)` function), `-c debug|release` (default `release`), and `--output <dir>`. On macOS, add `--disable-sandbox` if the plugin sandbox blocks the nested `swift build`.

## Running on workerd or celld

Both runtimes resolve `worker.mjs`'s `import "./WorkersSwift.wasm"` to a compiled `WebAssembly.Module`.

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
  (name = "WorkersSwift.wasm", wasm = embed "build/worker/WorkersSwift.wasm"),
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
