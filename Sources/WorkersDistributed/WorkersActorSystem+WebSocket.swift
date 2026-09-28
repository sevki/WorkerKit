// Matches exactly the platforms Package.swift declares WSClient/Logging
// dependencies for (.macOS, .linux) - not every non-wasm architecture:
// `#if !arch(wasm32)` would also be true on, say, iOS, where those two
// imports don't exist as dependencies at all and fail to resolve.
#if os(macOS) || os(Linux)
import Distributed
import Foundation
import Logging
import WSClient

/// A `DistributedActorSystem` that calls a worker's distributed actors —
/// this is the native implementation, for a process outside the worker (a
/// CLI, say). Inside a worker, the same type is backed by Workers RPC
/// instead (see `WorkersActorSystem+Workers.swift`), so a `distributed
/// actor` declared once against `WorkersActorSystem` compiles, and mangles,
/// identically for both.
///
/// Transports the same `identifier`/`arguments`/`genericSubstitutions`
/// shape as JSON over a real WebSocket client (hummingbird-project/
/// swift-websocket's `WebSocketClient` — not swift-corelibs-foundation's
/// `URLSessionWebSocketTask`, which is libcurl-backed on Linux, and libcurl
/// doesn't implement WebSockets at all), against the worker's `RPCGateway`.
///
///     let system = WorkersActorSystem(worker: URL(string: "https://swift.example.workers.dev")!)
///     let doubler = try Doubler.resolve(id: "doubler", using: system)
///     let result = try await doubler.double(21)
///     system.close()
public final class WorkersActorSystem: DistributedActorSystem, @unchecked Sendable {
    public typealias ActorID = String
    public typealias SerializationRequirement = Codable
    public typealias InvocationEncoder = WorkersInvocationEncoder
    public typealias InvocationDecoder = WorkersInvocationDecoder
    public typealias ResultHandler = WorkersInvocationResultHandler

    private let state = LockedBox(State())
    private let outgoingContinuation: AsyncStream<String>.Continuation
    private let connectionTask: Task<Void, Never>

    private struct State {
        var pending: [String: CheckedContinuation<RemoteReply, Error>] = [:]
        var nextCallID = 0
        /// Set once the connection ends, however it ends — a thrown error,
        /// or `group.next()` returning normally (the outgoing stream
        /// finishing because of `close()`, or the server closing cleanly).
        /// `send(identifier:invocation:)` checks this before registering a
        /// new pending call, so a call made after termination fails
        /// immediately instead of waiting on a continuation nothing will
        /// ever resume.
        var terminationError: Error?
    }

    /// Opens a WebSocket to the `RPCGateway` of the worker at `worker` (its
    /// `http`/`https` address; the path is ``gatewayPath``) and keeps it open
    /// until `close()`.
    public convenience init(worker: URL, logger: Logger = Logger(label: "WorkersActorSystem")) {
        var components = URLComponents(url: worker, resolvingAgainstBaseURL: false) ?? URLComponents()
        switch components.scheme {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: break
        }
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = basePath + Self.gatewayPath
        self.init(gatewayURL: components.string ?? "", logger: logger)
    }

    private init(gatewayURL url: String, logger: Logger) {
        var continuation: AsyncStream<String>.Continuation!
        let outgoing = AsyncStream<String> { continuation = $0 }
        outgoingContinuation = continuation

        let state = self.state
        connectionTask = Task {
            let terminationError: Error
            do {
                _ = try await WebSocketClient.connect(url: url, logger: logger) { inbound, outbound, _ in
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for try await text in outgoing {
                                try await outbound.write(.text(text))
                            }
                        }
                        group.addTask {
                            for try await message in inbound.messages(maxSize: 1 << 20) {
                                guard case .text(let text) = message, let data = text.data(using: .utf8),
                                      let reply = try? RemoteReply(jsonData: data) else {
                                    continue
                                }
                                let continuation = state.withLock { $0.pending.removeValue(forKey: reply.id) }
                                continuation?.resume(returning: reply)
                            }
                        }
                        // Either side finishing (outgoing closed by close(),
                        // or the server closing the connection) ends the
                        // whole call, which is what makes WebSocketClient
                        // perform the closing handshake. Neither is an
                        // error, so `group.next()` returns normally here —
                        // the pending-call drain below still has to run.
                        try await group.next()
                        group.cancelAll()
                    }
                }
                terminationError = RemoteCallError(message: "WorkersActorSystem: connection closed")
            } catch {
                terminationError = error
            }
            let waiting = state.withLock { state in
                let pending = state.pending
                state.pending.removeAll()
                state.terminationError = terminationError
                return pending
            }
            for pendingContinuation in waiting.values {
                pendingContinuation.resume(throwing: terminationError)
            }
        }
    }

    /// Closes the underlying WebSocket and fails every in-flight call.
    public func close() {
        outgoingContinuation.finish()
    }

    /// Waits for the connection to finish closing — mainly for a short-lived
    /// CLI that should exit only once the close handshake is done.
    public func wait() async {
        await connectionTask.value
    }

    private func nextID() -> String {
        state.withLock {
            $0.nextCallID += 1
            return "\($0.nextCallID)"
        }
    }

    private func send(identifier: String, invocation: InvocationEncoder) async throws -> RemoteReply {
        let id = nextID()
        let call = RemoteCall(
            id: id, identifier: identifier,
            arguments: invocation.recorded, genericSubstitutions: invocation.genericSubstitutions
        )
        return try await withCheckedThrowingContinuation { continuation in
            let terminationError: Error? = state.withLock { state in
                if let terminationError = state.terminationError {
                    return terminationError
                }
                state.pending[id] = continuation
                return nil
            }
            if let terminationError {
                continuation.resume(throwing: terminationError)
                return
            }
            do {
                let data = try call.jsonData()
                outgoingContinuation.yield(String(decoding: data, as: UTF8.self))
            } catch {
                _ = state.withLock { $0.pending.removeValue(forKey: id) }
                continuation.resume(throwing: error)
            }
        }
    }

    public func resolve<Act>(id: ActorID, as actorType: Act.Type) throws -> Act?
    where Act: DistributedActor, Act.ID == ActorID {
        nil // outside a worker, every actor is remote
    }

    public func assignID<Act>(_ actorType: Act.Type) -> ActorID
    where Act: DistributedActor, Act.ID == ActorID {
        "\(actorType)"
    }

    public func actorReady<Act>(_ actor: Act) where Act: DistributedActor, Act.ID == ActorID {}

    public func resignID(_ id: ActorID) {}

    public func makeInvocationEncoder() -> InvocationEncoder {
        WorkersInvocationEncoder()
    }

    public func remoteCall<Act, Err, Res>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        throwing: Err.Type,
        returning: Res.Type
    ) async throws -> Res
    where Act: DistributedActor, Act.ID == ActorID, Err: Error, Res: SerializationRequirement {
        let reply = try await send(identifier: target.identifier, invocation: invocation)
        if let error = reply.error {
            throw RemoteCallError(message: error)
        }
        guard let result = reply.result else {
            throw RemoteCallError(message: "no result for \(target.identifier)")
        }
        let decoder = JSONDecoder()
        // A result that is, or contains, a distributed actor reference
        // needs this to resolve the encoded id back to a local stub — the
        // same reason the worker-side transport sets it (see
        // WorkersActorSystem+Workers.swift).
        decoder.userInfo[.actorSystemKey] = self
        // JSONDecoder's default dataDecodingStrategy expects Data as a
        // base64 string, but the worker side's JSValueEncoder doesn't
        // special-case Data at all - it encodes (and JSValueDecoder
        // decodes) through Data's own Codable conformance, an unkeyed byte
        // array. Match that here instead of JSONEncoder/Decoder's own
        // Foundation-specific default.
        decoder.dataDecodingStrategy = .deferredToData
        return try decoder.decode(Res.self, from: JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]))
    }

    public func remoteCallVoid<Act, Err>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        throwing: Err.Type
    ) async throws
    where Act: DistributedActor, Act.ID == ActorID, Err: Error {
        let reply = try await send(identifier: target.identifier, invocation: invocation)
        if let error = reply.error {
            throw RemoteCallError(message: error)
        }
    }
}

/// A remote call's error, or a decoding/transport failure — either way, all
/// the native `WorkersActorSystem` ever throws.
public struct RemoteCallError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// One call, on the wire: `{"id","identifier","arguments","genericSubstitutions"}`.
/// `arguments` holds each argument's own JSON tree — already-parsed, so it
/// nests directly into the envelope instead of double-encoding as a string
/// — built by `WorkersInvocationEncoder.recordArgument(_:)`.
struct RemoteCall {
    var id: String
    var identifier: String
    var arguments: [Any]
    var genericSubstitutions: [String]

    func jsonData() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "id": id,
            "identifier": identifier,
            "arguments": arguments,
            "genericSubstitutions": genericSubstitutions,
        ] as [String: Any])
    }
}

/// A reply, on the wire: `{"id","result"}` or `{"id","error"}` — see
/// `RPCGateway`, which produces it.
struct RemoteReply {
    var id: String
    var result: Any?
    var error: String?

    init(jsonData: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: jsonData, options: [.fragmentsAllowed]) as? [String: Any],
              let id = object["id"] as? String else {
            throw RemoteCallError(message: "malformed reply: not a {\"id\", ...} object")
        }
        self.id = id
        result = object["result"]
        error = object["error"] as? String
    }
}

public struct WorkersInvocationEncoder: DistributedTargetInvocationEncoder {
    public typealias SerializationRequirement = Codable

    var recorded: [Any] = []
    var genericSubstitutions: [String] = []

    public mutating func recordGenericSubstitution<T>(_ type: T.Type) throws {
        guard let name = _mangledTypeName(type) else {
            throw RemoteCallError(message: "no mangled type name for \(type) (needed for a generic distributed func call)")
        }
        genericSubstitutions.append(name)
    }

    public mutating func recordArgument<Value: Codable>(_ argument: RemoteCallArgument<Value>) throws {
        let encoder = JSONEncoder()
        // Match the worker side's JSValueEncoder, which doesn't
        // special-case Data - see the matching note on the decode side in
        // remoteCall(on:target:invocation:throwing:returning:).
        encoder.dataEncodingStrategy = .deferredToData
        let data = try encoder.encode(argument.value)
        recorded.append(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    public mutating func recordErrorType<E: Error>(_ type: E.Type) throws {}
    public mutating func recordReturnType<R: Codable>(_ type: R.Type) throws {}
    public mutating func doneRecording() throws {}
}

public struct WorkersInvocationDecoder: DistributedTargetInvocationDecoder {
    public typealias SerializationRequirement = Codable

    public mutating func decodeGenericSubstitutions() throws -> [Any.Type] {
        // Outside a worker nothing is hosted, so nothing ever decodes an
        // incoming call with this.
        []
    }

    public mutating func decodeNextArgument<Argument: Codable>() throws -> Argument {
        throw RemoteCallError(message: "WorkersActorSystem only sends calls outside a worker, never receives them")
    }

    public mutating func decodeErrorType() throws -> (any Any.Type)? { nil }
    public mutating func decodeReturnType() throws -> Any.Type? { nil }
}

public struct WorkersInvocationResultHandler: DistributedTargetInvocationResultHandler {
    public typealias SerializationRequirement = Codable

    public func onReturn<Success: Codable>(value: Success) async throws {}
    public func onReturnVoid() async throws {}
    public func onThrow<Err: Error>(error: Err) async throws {}
}

/// A plain `NSLock`-backed box, freely capturable (it's an ordinary class
/// reference) into the escaping closures `WorkersActorSystem`'s
/// connection task needs — unlike `Synchronization.Mutex`, which is
/// noncopyable and so can't be captured into a second closure once it's a
/// stored property a `self`-capturing closure would need to move out of.
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
#endif
