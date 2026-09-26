import JavaScriptEventLoop
import JavaScriptKit

/// The entry points that `@Event` expansions call.
public enum WorkersRuntime {
    /// Installs the Swift concurrency executor on the JavaScript event loop
    /// and registers `handler` as `globalThis.__workersSwiftFetch`, which the
    /// shim calls with the runtime's `request`, `env`, and `ctx`.
    public static func registerFetch(
        _ handler: @escaping @Sendable (Request, Env, Context) async throws -> Response
    ) {
        JavaScriptEventLoop.installGlobalExecutor()

        let fetch = JSClosure { arguments in
            guard let requestObject = arguments.first?.object else {
                return JSPromise.reject("fetch was called without a Request").jsValue
            }
            let request = Request(requestObject)
            let env = Env(arguments.count > 1 ? arguments[1].object ?? JSObject() : JSObject())
            let context = Context(arguments.count > 2 ? arguments[2].object : nil)

            return JSPromise.async { () async throws(JSException) -> JSValue in
                do {
                    return try await handler(request, env, context).jsValue
                } catch {
                    _ = JSObject.global.console.object!.error!("Swift worker threw:", "\(error)")
                    return Response.error("Internal Server Error", 500).jsValue
                }
            }.jsValue
        }
        JSObject.global.__workersSwiftFetch = .object(fetch)
    }
}
