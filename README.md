# workers-swift

A tiny Swift starting point for a `workers-rs`-style project that can be compiled to WebAssembly and loaded by both [workerd](https://github.com/cloudflare/workerd) and [denoland/celld](https://github.com/denoland/celld).

## What is in this repository?

- `Sources/WorkersSwift/WorkersSwift.swift` contains the request/response types, the `@Event` macro declaration, and the Wasm ABI exports. It does not use Foundation, so it also builds with the Embedded Swift Wasm SDK.
- `Sources/WorkersSwiftMacros` implements `@Event`.
- `Sources/WorkersSwiftWasm` is an example worker; `worker-build` links it into `WorkersSwift.wasm`.
- `Plugins/WorkerBuild` is the `swift package worker-build` command plugin, the Swift counterpart of workers-rs' `worker-build`.
- `Examples/workerd-celld/worker.mjs` is the JavaScript shim that instantiates the Swift WebAssembly module and forwards `fetch` requests into Swift.
- `Tests/WorkersSwiftTests` covers the Swift request handling and ABI behavior.
- `Tests/e2e` serves the shim from real `workerd` and `celld` processes and sends HTTP requests to it.

## Writing a worker

Like workers-rs' `#[event(fetch)]`, mark one top-level function in an executable target with `@Event(.fetch)`:

```swift
import WorkersSwift

@Event(.fetch)
func fetch(_ request: WorkerRequest) -> WorkerResponse {
    switch (request.method.uppercased(), request.path) {
    case ("GET", "/"):
        return WorkerResponse(status: 200, body: "Hello from Swift on workerd/celld")
    default:
        return WorkerResponse(status: 404, body: "Not Found")
    }
}
```

The macro generates the `workers_handle_request` export that the JavaScript shim calls for each request, so a module has exactly one `@Event(.fetch)` function. The function may `throw`; an error becomes a `500 Internal Server Error` response. `async` handlers are not supported yet.

## Native development

```bash
swift test
```

## Building for WebAssembly

1. Install the Swift SDK for WebAssembly that matches your toolchain version (see [Getting Started with Swift SDKs for WebAssembly](https://www.swift.org/documentation/articles/wasm-getting-started.html)) and check its identifier:

   ```bash
   swift sdk list
   ```

2. Build the worker:

   ```bash
   swift package --allow-writing-to-package-directory worker-build
   ```

   The plugin picks the installed `*_wasm` SDK (or `*_wasm-embedded` when that is the only one), builds the `WorkersSwiftWasm` product as a WASI reactor module, and writes:

   ```
   build/worker/worker.mjs
   build/worker/WorkersSwift.wasm
   ```

   Options: `--swift-sdk <id>`, `--product <name>`, `-c debug|release` (default `release`), and `--output <dir>`. On macOS, add `--disable-sandbox` if the nested `swift build` is blocked by the plugin sandbox.

The JavaScript shim expects these WebAssembly exports:

- `workers_alloc`
- `workers_free`
- `workers_handle_request`
- `workers_response_status`
- `workers_response_body_len`
- `workers_response_body_copy`
- `workers_response_release`
- `memory`
- `_initialize` (called once before any other export, as a WASI reactor requires)

## Using with workerd or celld

Point your Worker at `build/worker/worker.mjs`. Both runtimes resolve its `import "./WorkersSwift.wasm"` to a compiled `WebAssembly.Module`.

For [celld](https://github.com/denoland/celld) (and Wrangler), a `wrangler.jsonc` like this works:

```jsonc
{
  "name": "my-swift-worker",
  "main": "build/worker/worker.mjs",
  "no_bundle": true,
  "compatibility_date": "2026-01-01"
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

Workers runtimes do not provide WASI, so the shim supplies the few WASI functions the Swift runtime uses (stdout/stderr to `console`, clocks, randomness) and answers every other WASI import with `ENOSYS`. To pass extra imports, call `createWorkerHandler(module, imports)` from the shim.

The default Swift routes are:

- `GET /` → `200 Hello from Swift on workerd/celld`
- `GET /health` → `200 ok`
- everything else → `404 Not Found`

## End-to-end tests

```bash
npm ci
npm run test:e2e
```

This starts `workerd` (from npm) with the shim and sends requests to it. By default it loads `Tests/e2e/fixture.wat`, a hand-written module with the same ABI, so it runs without a Swift SDK. Set `WORKERS_SWIFT_WASM=build/worker/WorkersSwift.wasm` to test the real Swift build, and `E2E_RUNTIMES=workerd,celld` to also run against a `celld` binary on `PATH` (or `CELLD_BIN`). CI runs both runtimes against the fixture and against the output of both the `wasm` and the `wasm-embedded` SDK.
