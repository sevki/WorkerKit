import Distributed
import JavaScriptKit

/// A `DistributedActorSystem` backed by Workers RPC.
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
/// **v1 scope:** exactly one locally-hosted actor per `WorkersActorSystem`
/// (see ``host(_:)``). There's no `ActorID`-based routing to multiple
/// instances yet — that's future work if this needs to back, say, one
/// distributed actor per Durable Object id rather than a singleton.
///
/// A system plays one of two roles:
///
///     // Caller side — reaches the actor through a stub, e.g. the worker's
///     // own SELF service binding, and calls it like any distributed actor:
///     let system = WorkersActorSystem(stub: env.service("SELF"))
///     let doubler = try Doubler.resolve(id: "doubler", using: system)
///     let result = try await doubler.double(21)
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

    private let stub: RPCStub?
    private var localActor: (any DistributedActor)?

    /// A caller-side system: every actor resolved against it is remote,
    /// reached through `stub`.
    public init(stub: RPCStub) {
        self.stub = stub
    }

    /// A callee-side system: never originates a call itself. Register the
    /// actor it hosts with ``host(_:)``, then forward
    /// ``WorkersActorSystem/entryPointName``'s `@RPC` method to
    /// ``receive(identifier:arguments:genericSubstitutions:)``.
    public init() {
        self.stub = nil
    }

    /// Registers `actor` as this system's one locally-hosted distributed
    /// actor: what `receive(identifier:arguments:genericSubstitutions:)` runs a call against.
    public func host<Act: DistributedActor>(_ actor: Act) where Act.ActorSystem == WorkersActorSystem {
        localActor = actor
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
        var decoder = WorkersInvocationDecoder(arguments: Array(argumentList), genericSubstitutions: genericSubstitutions)
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
        // v1: one hosted instance per WorkersActorSystem (see `host(_:)`),
        // so the id only needs to be stable, not globally unique.
        "\(actorType)"
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
        let value = try await send(target: target, invocation: invocation)
        return try JSValueDecoder().decode(Res.self, from: value)
    }

    public func remoteCallVoid<Act, Err>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        throwing: Err.Type
    ) async throws
    where Act: DistributedActor, Act.ID == ActorID, Err: Error {
        _ = try await send(target: target, invocation: invocation)
    }

    private func send(target: RemoteCallTarget, invocation: InvocationEncoder) async throws -> JSValue {
        guard let stub else {
            throw JSException(message: "WorkersActorSystem has no RPCStub to send \(target.identifier) through")
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
        return try JSValueDecoder().decode(Argument.self, from: arguments[index])
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
