#if arch(wasm32)
import Distributed
import JavaScriptKit
import WorkersSwift

/// A `DistributedActorSystem` backed by Workers RPC — this is the wasm32
/// implementation, for code running inside a worker. A native process gets
/// the same type backed by a WebSocket instead (see
/// `WorkersActorSystem+WebSocket.swift`), so a `distributed actor` declared
/// once against `WorkersActorSystem` compiles, and mangles, identically for
/// both.
///
/// A `distributed func` call is transported the same way `@RPC` already
/// transports a call — through an ``RPCStub`` (a service binding or a
/// Durable Object stub) — but the mangled `RemoteCallTarget.identifier` is
/// never interpreted by this code. It's passed through opaquely to the
/// callee, which hands it to `executeDistributedTarget`: the Swift runtime's
/// own accessor lookup resolves it and invokes the real method. See
/// `rfcs/distributed-actor-rpc.md` for why that's sound and how it was
/// verified.
///
/// A generic `distributed func` is supported: each generic parameter's
/// concrete type crosses the wire as its mangled type name
/// (`_mangledTypeName`), and the callee resolves it back to a real `Any.Type`
/// with `_typeByName` — the same "let the Swift runtime do it" approach that
/// makes the method identifier itself safe to leave mangled. A substitution
/// that names a type not present in the callee's binary (or stripped from
/// it) fails to resolve and throws, same as any other decode failure.
///
/// A `WorkersActorSystem` backs either a **singleton** actor (one instance
/// per worker, reached through a fixed ``RPCStub``) or **one distributed
/// actor instance per Durable Object id** (reached through a
/// `DurableObjectNamespace`, routed by `ActorID`) — see ``host(_:)`` for the
/// singleton case and ``host(_:as:)`` for the per-id case.
///
/// A system plays one of two roles:
///
///     // Caller side, singleton — reaches the actor through a stub, e.g.
///     // the worker's own SELF service binding:
///     let system = WorkersActorSystem(stub: env.service("SELF"))
///     let doubler = try Doubler.resolve(id: "doubler", using: system)
///     let result = try await doubler.double(21)
///
///     // Caller side, one instance per Durable Object id — `id` must be
///     // the namespace's own hex id (from `idFromName(_:)`, matching what
///     // the hosting object's own `DurableObjectState.id` is), not an
///     // arbitrary friendly string; the routing and the hosted actor's own
///     // identity need to agree on the same id:
///     let namespace = env.durableObject("FORKS")
///     let system = WorkersActorSystem(durableObjects: namespace)
///     let fork = try Fork.resolve(id: namespace.idFromName("fork-0"), using: system)
///     let picked = try await fork.tryPickUp()
///
///     // Callee side — hosts the real instance and exposes the one fixed
///     // RPC entry point every WorkersActorSystem call arrives through:
///     let calleeSystem = WorkersActorSystem()
///     calleeSystem.host(Doubler(actorSystem: calleeSystem))
///
///     @RPC func __workersSwiftDistributedCall(
///         _ identifier: String, _ arguments: JSValue, _ genericSubstitutions: [String]
///     ) async throws -> JSValue {
///         try await calleeSystem.receive(
///             identifier: identifier, arguments: arguments, genericSubstitutions: genericSubstitutions
///         )
///     }
///
/// For the per-Durable-Object-id case, the callee is a `@DurableObject`
/// itself and hosts an actor whose id is the object's own id — see
/// ``host(_:as:)``.
public final class WorkersActorSystem: DistributedActorSystem, @unchecked Sendable {
    public typealias ActorID = String
    public typealias SerializationRequirement = Codable
    public typealias InvocationEncoder = WorkersInvocationEncoder
    public typealias InvocationDecoder = WorkersInvocationDecoder
    public typealias ResultHandler = WorkersInvocationResultHandler

    /// The fixed RPC method name every `WorkersActorSystem` call goes
    /// through, on both sides. Mark exactly one top-level function `@RPC`
    /// with this name per worker that hosts a distributed actor.
    public static let entryPointName = "__workersSwiftDistributedCall"

    /// How a caller-side system reaches a remote actor: either always the
    /// same stub (the singleton case), or a `DurableObjectNamespace` stub
    /// looked up by the target actor's own id (one instance per id).
    private enum Transport {
        case fixed(RPCStub)
        case perID(DurableObjectNamespace)
    }

    private let transport: Transport?
    private var localActor: (any DistributedActor)?

    /// Set immediately before constructing a locally-hosted actor whose id
    /// should be something specific (typically a Durable Object's own id)
    /// rather than the type-name default `assignID` otherwise falls back
    /// to. See ``host(_:as:)``.
    private var nextAssignedID: ActorID?

    /// A caller-side system backing a singleton actor: every actor resolved
    /// against it is remote, reached through `stub`, regardless of its id.
    public init(stub: RPCStub) {
        self.transport = .fixed(stub)
    }

    /// A caller-side system backing one distributed actor instance per
    /// Durable Object id: a resolved actor's calls are routed to the
    /// Durable Object named by its own `id`.
    public init(durableObjects: DurableObjectNamespace) {
        self.transport = .perID(durableObjects)
    }

    /// A callee-side system: never originates a call itself. Register the
    /// actor it hosts with ``host(_:)`` or ``host(_:as:)``, then forward
    /// ``WorkersActorSystem/entryPointName``'s `@RPC` method to
    /// ``receive(identifier:arguments:genericSubstitutions:)``.
    public init() {
        self.transport = nil
    }

    /// Registers `actor` as this system's one locally-hosted singleton
    /// distributed actor: what `receive(identifier:arguments:genericSubstitutions:)`
    /// runs a call against. Pairs with the caller-side `init(stub:)`.
    public func host<Act: DistributedActor>(_ actor: Act) where Act.ActorSystem == WorkersActorSystem {
        localActor = actor
    }

    /// Constructs and registers this system's one locally-hosted distributed
    /// actor with the explicit id `id` — typically a Durable Object's own
    /// id, so the actor's identity matches the object hosting it. Pairs with
    /// the caller-side `init(durableObjects:)`.
    ///
    /// `actorType`'s local initializer must not be the compiler-synthesized
    /// default; it must accept `actorSystem:` (as every `distributed actor`
    /// does) and otherwise construct the actor however it needs to — this
    /// method only arranges for the *id* that initializer's implicit
    /// `assignID` call receives.
    @discardableResult
    public func host<Act: DistributedActor>(
        _ id: ActorID,
        as make: (WorkersActorSystem) -> Act
    ) -> Act where Act.ActorSystem == WorkersActorSystem {
        nextAssignedID = id
        let actor = make(self)
        localActor = actor
        return actor
    }

    /// The callee side of a call: decodes `arguments`, resolves `identifier`
    /// against the hosted actor via `executeDistributedTarget` (which
    /// interprets the mangled identifier itself), and returns the encoded
    /// result — or throws, if the call target doesn't exist, decoding
    /// fails, or the method itself threw.
    ///
    /// `genericSubstitutions` is each generic parameter's mangled type name,
    /// in order, for a generic `distributed func` (empty for a non-generic
    /// one) — see `recordGenericSubstitution`/`decodeGenericSubstitutions`.
    public func receive(
        identifier: String,
        arguments: JSValue,
        genericSubstitutions: [String] = []
    ) async throws -> JSValue {
        guard let actor = localActor else {
            throw JSException(message: "WorkersActorSystem has no locally-hosted actor to dispatch \(identifier) to")
        }
        guard let argumentList = arguments.object.flatMap(JSArray.init) else {
            throw JSException(message: "WorkersActorSystem: arguments for \(identifier) is not an array")
        }
        var decoder = WorkersInvocationDecoder(
            arguments: Array(argumentList), genericSubstitutions: genericSubstitutions, system: self
        )
        let box = WorkersResultBox()
        let handler = WorkersInvocationResultHandler(box: box)
        try await executeDistributedTarget(
            on: actor,
            target: RemoteCallTarget(identifier),
            invocationDecoder: &decoder,
            handler: handler
        )
        if let error = box.errorThrown {
            throw (error as? JSException) ?? JSException(message: "\(error)")
        }
        return box.result
    }

    public func resolve<Act>(id: ActorID, as actorType: Act.Type) throws -> Act?
    where Act: DistributedActor, Act.ID == ActorID {
        nil // a caller-side system always treats the actor as remote
    }

    public func assignID<Act>(_ actorType: Act.Type) -> ActorID
    where Act: DistributedActor, Act.ID == ActorID {
        if let id = nextAssignedID {
            nextAssignedID = nil
            return id
        }
        // The singleton case (see `host(_:)`): one hosted instance per
        // WorkersActorSystem, so the id only needs to be stable, not
        // globally unique.
        return "\(actorType)"
    }

    public func actorReady<Act>(_ actor: Act)
    where Act: DistributedActor, Act.ID == ActorID {}

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
        let value = try await send(id: actor.id, target: target, invocation: invocation)
        return try JSValueDecoder().decode(Res.self, from: value, userInfo: [.actorSystemKey: self])
    }

    public func remoteCallVoid<Act, Err>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        throwing: Err.Type
    ) async throws
    where Act: DistributedActor, Act.ID == ActorID, Err: Error {
        _ = try await send(id: actor.id, target: target, invocation: invocation)
    }

    private func send(id: ActorID, target: RemoteCallTarget, invocation: InvocationEncoder) async throws -> JSValue {
        guard let transport else {
            throw JSException(message: "WorkersActorSystem has no transport to send \(target.identifier) through")
        }
        let stub: RPCStub
        switch transport {
        case .fixed(let fixedStub): stub = fixedStub
        case .perID(let namespace): stub = namespace.get(id: id)
        }
        let arguments = JSObject.global.Array.object!.new()
        for value in invocation.recorded {
            _ = arguments.push!(value)
        }
        return try await stub.call(
            Self.entryPointName, target.identifier, arguments, invocation.genericSubstitutions,
            as: JSValue.self
        )
    }
}

extension WorkersActorSystem {
    /// A JSON front door onto `receive(identifier:arguments:genericSubstitutions:)`,
    /// for exposing this system's locally-hosted actor to a caller that
    /// can't use `JSValue`/JavaScriptKit — a native Swift CLI (see
    /// `WorkersActorSystem`'s native build) talking plain JSON over a WebSocket, for
    /// instance. Parses `text` as
    /// `{"id","identifier","arguments","genericSubstitutions"}` (`id` and
    /// `genericSubstitutions` optional) and returns `{"id","result"}` or
    /// `{"id","error"}` as JSON text, `id` echoed back unchanged so a caller
    /// can correlate replies on a connection carrying several calls at
    /// once.
    ///
    /// Not safe yet for a call whose arguments or result contain an `Int64`/
    /// `UInt64` outside ±2^53: this goes through a JS `JSON.parse`/
    /// `JSON.stringify` round trip, which collapses a number that size to a
    /// Double regardless of `JSValueEncoder`'s own BigInt handling.
    public func receiveJSON(_ text: String) async -> String {
        await Self.handleJSONCall(text) { identifier, arguments, genericSubstitutions in
            try await receive(identifier: identifier, arguments: arguments, genericSubstitutions: genericSubstitutions)
        }
    }

    /// Parses one JSON call, runs it with `dispatch`, and returns the JSON
    /// reply — shared by `receiveJSON(_:)` (dispatches locally) and
    /// `RPCGateway` (relays to the worker's entry point).
    static func handleJSONCall(
        _ text: String,
        dispatch: (_ identifier: String, _ arguments: JSValue, _ genericSubstitutions: [String]) async throws -> JSValue
    ) async -> String {
        let call = JSObject.global.JSON.object!.parse!(text).object ?? JSObject()
        let id = call["id"]
        guard let identifier = call["identifier"].string else {
            return jsonReply(id: id, error: "malformed call: missing identifier")
        }
        let genericSubstitutions = JSArray(call["genericSubstitutions"].object ?? JSObject())?.compactMap(\.string) ?? []
        do {
            return jsonReply(id: id, result: try await dispatch(identifier, call["arguments"], genericSubstitutions))
        } catch {
            return jsonReply(id: id, error: "\(error)")
        }
    }

    private static func jsonReply(id: JSValue, result: JSValue? = nil, error: String? = nil) -> String {
        let reply = JSObject()
        reply["id"] = id
        if let result {
            reply["result"] = result
        }
        if let error {
            reply["error"] = .string(error)
        }
        return JSObject.global.JSON.object!.stringify!(reply).string ?? "{}"
    }
}


public struct WorkersInvocationEncoder: DistributedTargetInvocationEncoder {
    public typealias SerializationRequirement = Codable

    var recorded: [JSValue] = []
    var genericSubstitutions: [String] = []

    public mutating func recordGenericSubstitution<T>(_ type: T.Type) throws {
        guard let name = _mangledTypeName(type) else {
            throw JSException(message: "WorkersActorSystem: no mangled type name for \(type) (needed for a generic distributed func call)")
        }
        genericSubstitutions.append(name)
    }

    public mutating func recordArgument<Value: Codable>(_ argument: RemoteCallArgument<Value>) throws {
        recorded.append(try JSValueEncoder().encode(argument.value))
    }

    public mutating func recordErrorType<E: Error>(_ type: E.Type) throws {}
    public mutating func recordReturnType<R: Codable>(_ type: R.Type) throws {}
    public mutating func doneRecording() throws {}
}

public struct WorkersInvocationDecoder: DistributedTargetInvocationDecoder {
    public typealias SerializationRequirement = Codable

    var arguments: [JSValue]
    var genericSubstitutions: [String] = []
    var system: WorkersActorSystem?
    var index = 0

    public mutating func decodeGenericSubstitutions() throws -> [Any.Type] {
        try genericSubstitutions.map { name in
            guard let type = _typeByName(name) else {
                throw JSException(message: "WorkersActorSystem: no type named \(name) in this binary (generic substitution)")
            }
            return type
        }
    }

    public mutating func decodeNextArgument<Argument: Codable>() throws -> Argument {
        guard index < arguments.count else {
            throw JSException(message: "WorkersActorSystem: expected an argument at index \(index)")
        }
        defer { index += 1 }
        // An Argument that is itself a distributed actor reference needs
        // .actorSystemKey in userInfo to resolve its encoded id.
        let userInfo: [CodingUserInfoKey: Any] = system.map { [.actorSystemKey: $0] } ?? [:]
        return try JSValueDecoder().decode(Argument.self, from: arguments[index], userInfo: userInfo)
    }

    public mutating func decodeErrorType() throws -> (any Any.Type)? { nil }
    public mutating func decodeReturnType() throws -> Any.Type? { nil }
}

final class WorkersResultBox: @unchecked Sendable {
    var result: JSValue = .undefined
    var errorThrown: Error?
}

public struct WorkersInvocationResultHandler: DistributedTargetInvocationResultHandler {
    public typealias SerializationRequirement = Codable

    let box: WorkersResultBox

    public func onReturn<Success: Codable>(value: Success) async throws {
        box.result = try JSValueEncoder().encode(value)
    }

    public func onReturnVoid() async throws {
        box.result = .undefined
    }

    public func onThrow<Err: Error>(error: Err) async throws {
        box.errorThrown = error
    }
}
#endif
