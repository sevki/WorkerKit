// Entry point for WorkersSwift.wasm. It is linked as a WASI reactor, so this
// never runs: the shim calls the `workers_js_main` export that `@Event(.fetch)`
// generates in HelloWorker.
import HelloWorker

@main
enum WorkerMain {
    static func main() {}
}
