# Getting Started

Set up a Swift package, add `WorkersSwift`, build it to WebAssembly, and run it on workerd or celld.

## Add the dependency

Create a Swift package (or add to an existing one) and depend on
`WorkersSwift` and its `worker-build` plugin:

```swift
// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "MyWorker",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "MyWorker", targets: ["MyWorker"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sevki/workers-swift.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "MyWorker",
            dependencies: [.product(name: "WorkersSwift", package: "workers-swift")]
        ),
    ]
)
```

Write your handler in `Sources/MyWorker/main.swift`:

```swift
import WorkersSwift

@Event(.fetch)
func fetch(req: Request, env: Env, ctx: Context) async throws -> Response {
    .ok("Hello from Swift")
}
```

## Install the Swift SDK for WebAssembly

Workers use Swift concurrency, so install the SDK build that matches your
toolchain version — see [Getting Started with Swift SDKs for
WebAssembly](https://www.swift.org/documentation/articles/wasm-getting-started.html).
The Embedded Swift SDK is not supported.

## Build the worker

```bash
swift package --allow-writing-to-package-directory worker-build
```

This builds `MyWorker` as a WASI reactor module and writes:

```
build/worker/worker.mjs        JavaScriptKit's runtime.mjs + the WorkersSwift shim, as one module
build/worker/MyWorker.wasm
```

Useful options: `--swift-sdk <id>` (default: the SDK matching your toolchain),
`--product <name>`, `-c debug|release` (default `release`), and `--output
<dir>`. On macOS, add `--disable-sandbox` if the plugin sandbox blocks the
nested `swift build`.

## Run it

Both workerd and celld resolve a `worker.mjs`'s `import "./MyWorker.wasm"` to
a compiled `WebAssembly.Module`.

### celld (and Wrangler)

```jsonc
// wrangler.jsonc
{
  "name": "my-worker",
  "main": "build/worker/worker.mjs",
  "no_bundle": true,
  "compatibility_date": "2026-01-01"
}
```

```bash
celld dev
```

### workerd

```capnp
modules = [
  (name = "worker.mjs", esModule = embed "build/worker/worker.mjs"),
  (name = "MyWorker.wasm", wasm = embed "build/worker/MyWorker.wasm"),
],
```

Workers runtimes do not provide WASI, so the bundled shim supplies the WASI
functions the Swift runtime uses (stdout/stderr to `console`, clocks,
randomness) and answers every other WASI import with `ENOSYS`.

## Next steps

- <doc:DurableObjects> for stateful objects and RPC.
- <doc:KVStorage> for the `KVStore` binding.
- ``Response`` for building responses, and ``Request``/``Headers`` for
  reading them.
