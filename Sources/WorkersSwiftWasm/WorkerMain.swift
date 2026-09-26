// Entry point for WorkersSwift.wasm. It is linked as a WASI reactor, so `main`
// never runs: the JavaScript shim calls `_initialize` and then the `workers_*`
// exports, including the one `@Event(.fetch)` generates in HelloWorker.
import HelloWorker

@main
enum WorkerMain {
    static func main() {}
}
