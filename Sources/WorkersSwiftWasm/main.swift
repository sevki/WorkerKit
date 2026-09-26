// Entry module for WorkersSwift.wasm. It is linked as a WASI reactor, so this
// top-level code never runs: the JavaScript shim calls `_initialize` and then
// the `workers_*` exports, including the one `@Event(.fetch)` generates in
// Worker.swift.
