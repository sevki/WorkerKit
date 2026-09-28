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

/// Makes a top-level class a Durable Object, like workers-rs'
/// `#[durable_object]`. The class conforms to `DurableObject`; mark the
/// methods other workers may call through `DurableObjectStub.call` with
/// `@RPC`. Bind it under its class name, as in wrangler.jsonc:
///
///     "durable_objects": { "bindings": [{ "name": "COUNTER", "class_name": "Counter" }] }
///
/// If the class declares exactly one property of type `WorkersActorSystem`,
/// this also generates the `__workersSwiftDistributedCall` forwarder that
/// hosts a distributed actor through it, so a Durable Object that hosts one
/// needs only:
///
///     @DurableObject
///     final class CounterObject {
///         let hostSystem: WorkersActorSystem
///         let counter: Counter
///
///         init(state: DurableObjectState, env: Env) {
///             let hostSystem = WorkersActorSystem()
///             self.hostSystem = hostSystem
///             counter = hostSystem.host(state.id) { Counter(actorSystem: $0) }
///         }
///     }
///
/// Write the forwarder by hand instead when the class hosts more than one
/// `WorkersActorSystem` (the convention only applies when there's exactly
/// one to be unambiguous) — see `WorkersActorSystem`'s documentation.
@attached(peer, names: prefixed(__workersSwift_do_))
@attached(member, names: named(__workersSwiftDistributedCall))
@attached(extension, conformances: DurableObject)
public macro DurableObject() = #externalMacro(module: "WorkersSwiftMacros", type: "DurableObjectMacro")

/// Makes a function callable by other workers over RPC:
///
/// - a method of a `@DurableObject` class, through `DurableObjectStub.call`;
/// - a top-level function, as a method of the worker's default entrypoint,
///   through a service binding's `Fetcher.call`.
///
/// Arguments and results convert through JavaScriptKit's
/// `ConstructibleFromJSValue` and `ConvertibleToJSValue`.
@attached(peer, names: prefixed(__workersSwift_rpc_))
public macro RPC() = #externalMacro(module: "WorkersSwiftMacros", type: "RPCMacro")
