import JavaScriptEventLoop
import JavaScriptKit

/// The request's execution context: the runtime's `ctx` object.
public final class Context: @unchecked Sendable {
    /// The underlying JavaScript `ctx` object, when the runtime passed one.
    public let jsObject: JSObject?

    public init(_ jsObject: JSObject?) {
        self.jsObject = jsObject
    }

    /// Keeps the isolate alive until `promise` settles, after the response
    /// has been returned.
    public func waitUntil(_ promise: JSPromise) {
        _ = jsObject?.waitUntil?(promise.jsObject)
    }

    /// Runs `operation` after the response has been returned, keeping the
    /// isolate alive until it finishes.
    public func waitUntil(_ operation: @escaping @Sendable () async -> Void) {
        waitUntil(JSPromise.async(body: { () async throws(JSException) -> Void in
            await operation()
        }))
    }

    /// Forwards the request to the origin if the worker throws an exception.
    public func passThroughOnException() {
        _ = jsObject?.passThroughOnException?()
    }
}
