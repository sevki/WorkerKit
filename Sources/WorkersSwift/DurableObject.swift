import JavaScriptEventLoop
import JavaScriptKit

/// A Durable Object class, like workers-rs' `DurableObject` trait. Mark the
/// class with `@DurableObject` and its RPC methods with `@RPC`:
///
///     @DurableObject
///     final class Counter: DurableObject {
///         let state: DurableObjectState
///
///         init(state: DurableObjectState, env: Env) {
///             self.state = state
///         }
///
///         @RPC func increment(by amount: Int) async throws -> Int {
///             let count = (try await state.storage.get("count", as: Int.self) ?? 0) + amount
///             try await state.storage.put("count", count)
///             return count
///         }
///     }
///
/// The runtime creates one instance per object id and calls it on a single
/// thread, so a class can keep mutable state without being `Sendable`.
public protocol DurableObject: AnyObject {
    init(state: DurableObjectState, env: Env)

    /// Handles a request sent with `DurableObjectStub.fetch(_:)`.
    func fetch(_ req: Request) async throws -> Response

    /// Runs when an alarm set with `storage.setAlarm` fires.
    func alarm() async throws

    /// Runs when a WebSocket accepted with
    /// `DurableObjectState.acceptWebSocket(tags:)` receives `message`,
    /// including after the object was evicted and hibernated between
    /// messages.
    func webSocketMessage(_ ws: WebSocket, _ message: WebSocketMessage) async throws

    /// Runs when a WebSocket accepted with
    /// `DurableObjectState.acceptWebSocket(tags:)` receives a close frame.
    /// The runtime does not complete the closing handshake on its own — the
    /// default implementation calls `ws.close(code:reason:)` with the same
    /// code and reason, so an override that needs to run cleanup first must
    /// still call it itself before returning, or the peer's own `close()`
    /// hangs until it times out.
    func webSocketClose(_ ws: WebSocket, code: Int, reason: String, wasClean: Bool) async throws

    /// Runs when a WebSocket accepted with
    /// `DurableObjectState.acceptWebSocket(tags:)` errors.
    func webSocketError(_ ws: WebSocket, _ error: JSException) async throws
}

extension DurableObject {
    public func fetch(_ req: Request) async throws -> Response {
        .error("Not Implemented", 501)
    }

    public func alarm() async throws {}

    public func webSocketMessage(_ ws: WebSocket, _ message: WebSocketMessage) async throws {}

    // The runtime doesn't complete the closing handshake on its own (see
    // this requirement's doc comment) - a no-op default would leave every
    // peer-initiated close hanging until timeout for any conformer that
    // doesn't override this. An override that needs to run cleanup before
    // closing still can; it just has to call ws.close(code:reason:) itself
    // instead of calling super, since this is a protocol extension.
    public func webSocketClose(_ ws: WebSocket, code: Int, reason: String, wasClean: Bool) async throws {
        ws.close(code: code, reason: reason)
    }

    public func webSocketError(_ ws: WebSocket, _ error: JSException) async throws {}
}

/// The Durable Object's state: the runtime's `ctx` object.
public final class DurableObjectState: @unchecked Sendable {
    /// The underlying JavaScript `DurableObjectState`.
    public let jsObject: JSObject

    public init(_ jsObject: JSObject) {
        self.jsObject = jsObject
    }

    /// The object's id, as a hex string.
    public var id: String {
        jsObject.id.toString().string ?? ""
    }

    /// The object's transactional storage.
    public var storage: DurableObjectStorage {
        DurableObjectStorage(jsObject.storage.object!)
    }

    /// Creates a WebSocket pair and accepts the server end for hibernation:
    /// the runtime may evict this object between messages and recreate it on
    /// the next one, calling `DurableObject.webSocketMessage(_:_:)` etc. as
    /// if it had never left. Returns the client end — hand it to
    /// `Response.webSocketUpgrade(_:)` to complete the upgrade.
    public func acceptWebSocket(tags: [String] = []) -> WebSocket {
        let pair = JSObject.global.WebSocketPair.function!.new()
        let client = pair[0].object!
        let server = pair[1].object!
        let tagArray = JSObject.global.Array.object!.new()
        for tag in tags {
            _ = tagArray.push!(tag)
        }
        _ = jsObject.acceptWebSocket!(server, tagArray)
        return WebSocket(client)
    }

    /// The WebSockets accepted with `acceptWebSocket(tags:)`, including ones
    /// hibernated and woken back up, optionally filtered to those accepted
    /// with `tag`.
    public func getWebSockets(tag: String? = nil) -> [WebSocket] {
        let result = tag.map { jsObject.getWebSockets!($0) } ?? jsObject.getWebSockets!()
        return JSArray(result.object!)?.compactMap { $0.object }.map(WebSocket.init) ?? []
    }

    /// The tags `ws` was accepted with — a hibernatable `WebSocket` doesn't
    /// carry its own tags (there's no `tags` property on the runtime's
    /// WebSocket object); the hosting object's state looks them up instead.
    public func getTags(_ ws: WebSocket) -> [String] {
        JSArray(jsObject.getTags!(ws.jsObject).object!)?.compactMap(\.string) ?? []
    }
}

/// A message received in `DurableObject.webSocketMessage(_:_:)`.
public enum WebSocketMessage: Sendable {
    case text(String)
    case binary([UInt8])

    /// Wraps the JavaScript `MessageEvent.data` the runtime passes to a
    /// hibernatable WebSocket's message handler: a `string` or an
    /// `ArrayBuffer`.
    init(_ value: JSValue) {
        if let string = value.string {
            self = .text(string)
        } else {
            let array = JSTypedArray<UInt8>(unsafelyWrapping: JSObject.global.Uint8Array.object!.new(value.object!))
            self = .binary(array.withUnsafeBytes { Array($0) })
        }
    }
}

/// A hibernatable WebSocket, accepted with
/// `DurableObjectState.acceptWebSocket(tags:)` and delivered back to
/// `DurableObject.webSocketMessage(_:_:)`/`webSocketClose`/`webSocketError`,
/// or read with `DurableObjectState.getWebSockets(tag:)`.
public final class WebSocket: @unchecked Sendable {
    /// The underlying JavaScript `WebSocket`.
    public let jsObject: JSObject

    public init(_ jsObject: JSObject) {
        self.jsObject = jsObject
    }

    /// Sends a text message.
    public func send(_ text: String) {
        _ = jsObject.send!(text)
    }

    /// Sends a binary message.
    public func send(_ bytes: [UInt8]) {
        _ = jsObject.send!(JSTypedArray<UInt8>(bytes).jsObject)
    }

    /// Closes the connection.
    public func close(code: Int = 1000, reason: String = "") {
        _ = jsObject.close!(code, reason)
    }

    /// Stores `value` on this WebSocket so it survives hibernation, readable
    /// later with `deserializeAttachment(as:)`. workerd limits the
    /// serialized attachment to 2,048 bytes.
    public func serializeAttachment(_ value: some ConvertibleToJSValue) {
        _ = jsObject.serializeAttachment!(value)
    }

    /// The value stored with `serializeAttachment(_:)`, or `nil` when there
    /// is none or it is not a `T`.
    public func deserializeAttachment<T: ConstructibleFromJSValue>(as type: T.Type = T.self) -> T? {
        let value = jsObject.deserializeAttachment!()
        return value.isUndefined || value.isNull ? nil : T.construct(from: value)
    }
}

/// A Durable Object's key-value storage: the runtime's `ctx.storage`.
public final class DurableObjectStorage: @unchecked Sendable {
    /// The underlying JavaScript `DurableObjectStorage`.
    public let jsObject: JSObject

    public init(_ jsObject: JSObject) {
        self.jsObject = jsObject
    }

    /// The value stored under `key`, or `nil` when there is none or it is not
    /// a `T`.
    public func get<T: ConstructibleFromJSValue>(_ key: String, as type: T.Type = T.self)
        async throws -> T?
    {
        let value = try await JSPromise(jsObject.get!(key).object!)!.value
        return value.isUndefined ? nil : T.construct(from: value)
    }

    /// Stores `value` under `key`.
    public func put(_ key: String, _ value: some ConvertibleToJSValue) async throws {
        _ = try await JSPromise(jsObject.put!(key, value).object!)!.value
    }

    /// Deletes `key`, returning whether it existed.
    @discardableResult
    public func delete(_ key: String) async throws -> Bool {
        try await JSPromise(jsObject.delete!(key).object!)!.value.boolean ?? false
    }
}

/// A Durable Object namespace binding, such as `env.durableObject("COUNTER")`.
public final class DurableObjectNamespace: @unchecked Sendable {
    /// The underlying JavaScript `DurableObjectNamespace`.
    public let jsObject: JSObject

    public init(_ jsObject: JSObject) {
        self.jsObject = jsObject
    }

    /// The stub for the object named `name`.
    public func get(named name: String) -> DurableObjectStub {
        DurableObjectStub(jsObject.get!(jsObject.idFromName!(name)).object!)
    }

    /// The id `name` deterministically maps to in this namespace, as a hex
    /// string — what `get(named:)` computes internally, exposed so it can
    /// be used as a portable id (see `WorkersActorSystem`'s per-Durable-
    /// Object-id routing, which needs the same id on both the caller's and
    /// the hosting object's side: the object's own `DurableObjectState.id`
    /// is already this same hex form, not the friendly name).
    public func idFromName(_ name: String) -> String {
        jsObject.idFromName!(name).toString().string ?? name
    }

    /// A new id no other object has, as a hex string: the object is created
    /// near the first request that reaches it, and never shared.
    public func newUniqueID() -> String {
        jsObject.newUniqueId!().toString().string ?? ""
    }

    /// The stub for the object with hex id `id` (from `idFromName(_:)` or
    /// a Durable Object's own `DurableObjectState.id`) — unlike
    /// `get(named:)`, `id` is used as-is, not re-hashed as a name.
    public func get(id: String) -> DurableObjectStub {
        DurableObjectStub(jsObject.get!(jsObject.idFromString!(id)).object!)
    }
}

/// A client for one Durable Object.

public final class DurableObjectStub: RPCStub, @unchecked Sendable {}

/// A service binding, such as `services` in wrangler.jsonc: calls another
/// worker's `@RPC` functions and `fetch` handler.
public final class Fetcher: RPCStub, @unchecked Sendable {}

/// A JavaScript RPC stub: a Durable Object stub or a service binding.
public class RPCStub: @unchecked Sendable {
    /// The underlying JavaScript stub.
    public let jsObject: JSObject

    public init(_ jsObject: JSObject) {
        self.jsObject = jsObject
    }

    /// Calls the `@RPC` method `method` with `arguments` and returns its
    /// result as a `T`.
    public func call<T: ConstructibleFromJSValue>(
        _ method: String,
        _ arguments: any ConvertibleToJSValue...,
        as type: T.Type = T.self
    ) async throws -> T {
        let value = try await awaitValue(invoke(method, arguments))
        guard let result = T.construct(from: value) else {
            throw JSException(message: "RPC method \(method) returned \(value), not a \(T.self)")
        }
        return result
    }

    /// Calls the `@RPC` method `method`, ignoring its result.
    public func call(_ method: String, _ arguments: any ConvertibleToJSValue...) async throws {
        _ = try await awaitValue(invoke(method, arguments))
    }

    /// Sends a request to the target's `fetch` handler.
    public func fetch(_ url: String) async throws -> FetchResponse {
        let response = try await awaitValue(invoke("fetch", [url]))
        return FetchResponse(response.object!)
    }

    /// Sends `req` to the target's `fetch` handler and returns its response
    /// unchanged — including any WebSocket a Durable Object target accepted
    /// with `DurableObjectState.acceptWebSocket(tags:)`, so returning it
    /// from `@Event(.fetch)` completes the upgrade `req` started.
    public func fetch(_ req: Request) async throws -> Response {
        let response = try await awaitValue(invoke("fetch", [req.jsObject]))
        return Response(raw: FetchResponse(response.object!))
    }

    /// Calls `stub[method](...arguments)` through `Reflect.apply`. JavaScriptKit
    /// calls functions with `function.apply(this, arguments)`, but on a
    /// workerd stub every property of an RPC method is itself a remote call,
    /// so `.apply` would be sent to the target as a method call.
    private func invoke(_ method: String, _ arguments: [any ConvertibleToJSValue]) -> JSValue {
        let argumentList = JSObject.global.Array.object!.new()
        for argument in arguments {
            _ = argumentList.push!(argument)
        }
        return JSObject.global.Reflect.object!.apply!(jsObject[method], jsObject, argumentList)
    }
}

/// Awaits `value` the way JavaScript's `await` does. Stubs return RPC
/// thenables that are not `Promise` instances, so they go through
/// `Promise.resolve` first.
func awaitValue(_ value: JSValue) async throws -> JSValue {
    let promise = JSObject.global.Promise.object!.resolve!(value).object!
    return try await JSPromise(promise)!.value
}

/// A response received from `fetch`: the runtime's JavaScript `Response`.
public final class FetchResponse: @unchecked Sendable {
    /// The underlying JavaScript `Response`.
    public let jsObject: JSObject

    public init(_ jsObject: JSObject) {
        self.jsObject = jsObject
    }

    public var status: Int {
        Int(jsObject.status.number ?? 0)
    }

    public var headers: Headers {
        Headers(jsObject.headers.object!)
    }

    /// Reads the body as UTF-8 text.
    public func text() async throws -> String {
        try await JSPromise(jsObject.text!().object!)!.value.string ?? ""
    }
}
