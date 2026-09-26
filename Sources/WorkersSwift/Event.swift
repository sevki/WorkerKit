/// The events a worker can handle, like workers-rs' `#[event(...)]`.
public enum WorkerEvent {
    /// HTTP requests, delivered to the Worker `fetch` handler.
    case fetch
}

/// Marks a top-level function as the worker's handler for `event`, like
/// workers-rs' `#[event(fetch)]`:
///
///     @Event(.fetch)
///     func fetch(req: Request, env: Env, ctx: Context) async throws -> Response {
///         .ok("Hello from Swift")
///     }
///
/// The function may be `async` and may `throw`; a thrown error is logged and
/// becomes a 500 response. The macro generates the `workers_js_main` export
/// that the JavaScript shim calls once per isolate, so a worker has exactly one
/// `@Event(.fetch)` function.
@attached(peer, names: named(__workersSwift_main))
public macro Event(_ event: WorkerEvent) = #externalMacro(module: "WorkersSwiftMacros", type: "EventMacro")
