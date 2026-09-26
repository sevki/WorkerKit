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
                    // The runtime can only forward to the origin if it sees
                    // the exception.
                    if context.passThroughRequested {
                        throw (error as? JSException) ?? JSException(message: "\(error)")
                    }
                    _ = JSObject.global.console.object!.error!("Swift worker threw:", "\(error)")
                    return Response.error("Internal Server Error", 500).jsValue
                }
            }.jsValue
        }
        JSObject.global.__workersSwiftFetch = .object(fetch)
    }

    /// An `@RPC` method: calls it on an instance with the JavaScript
    /// arguments and returns its result as a JavaScript value.
    public typealias RPCMethod<Object> = (Object, [JSValue]) async throws -> JSValue

    /// Registers Durable Object class `name` in
    /// `globalThis.__workersSwiftDurableObjects`. For each object the runtime
    /// creates, the shim calls the registered factory with `ctx` and `env`; it
    /// creates a `T` and returns the `fetch`, `alarm` and `rpc` entry points
    /// the generated JavaScript class forwards to.
    public static func registerDurableObject<T: DurableObject>(
        _ type: T.Type,
        name: String,
        rpc methods: [String: RPCMethod<T>]
    ) {
        JavaScriptEventLoop.installGlobalExecutor()

        let factory = JSClosure { arguments in
            // The runtime calls an object from one thread, so the instance is
            // only ever used where it was created.
            nonisolated(unsafe) let object = T(
                state: DurableObjectState(arguments[0].object!),
                env: Env(arguments.count > 1 ? arguments[1].object ?? JSObject() : JSObject())
            )
            nonisolated(unsafe) let rpcMethods = methods

            let entryPoints = JSObject()
            entryPoints["fetch"] = .object(JSClosure { arguments in
                let request = Request(arguments[0].object!)
                return JSPromise.async { () async throws(JSException) -> JSValue in
                    do {
                        return try await object.fetch(request).jsValue
                    } catch {
                        throw (error as? JSException) ?? JSException(message: "\(error)")
                    }
                }.jsValue
            })
            entryPoints["alarm"] = .object(JSClosure { _ in
                JSPromise.async { () async throws(JSException) -> JSValue in
                    do {
                        try await object.alarm()
                        return .undefined
                    } catch {
                        throw (error as? JSException) ?? JSException(message: "\(error)")
                    }
                }.jsValue
            })
            entryPoints["rpc"] = .object(JSClosure { arguments in
                let method = arguments[0].string ?? ""
                let rpcArguments = arguments.count > 1 ? JSArray(arguments[1].object!)?.map { $0 } ?? [] : []
                return JSPromise.async { () async throws(JSException) -> JSValue in
                    guard let call = rpcMethods[method] else {
                        throw JSException(message: "\(name) has no RPC method \(method)")
                    }
                    do {
                        return try await call(object, rpcArguments)
                    } catch {
                        throw (error as? JSException) ?? JSException(message: "\(error)")
                    }
                }.jsValue
            })
            return .object(entryPoints)
        }

        if JSObject.global.__workersSwiftDurableObjects.isUndefined {
            JSObject.global.__workersSwiftDurableObjects = .object(JSObject())
        }
        JSObject.global.__workersSwiftDurableObjects.object![name] = .object(factory)
    }

    /// Converts argument `index` of an `@RPC` call to `T`.
    public static func rpcArgument<T: ConstructibleFromJSValue>(
        _ arguments: [JSValue],
        _ index: Int,
        as type: T.Type = T.self
    ) throws(JSException) -> T {
        let value = index < arguments.count ? arguments[index] : .undefined
        guard let argument = T.construct(from: value) else {
            throw JSException(message: "RPC argument \(index + 1) is \(value), not a \(T.self)")
        }
        return argument
    }
}
