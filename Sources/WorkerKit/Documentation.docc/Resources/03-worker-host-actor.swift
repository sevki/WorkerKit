import GreeterKit
import JavaScriptKit
import WorkerKitDistributed
import WorkerKit

// The worker hosts one `Greeter` instance, shared by the whole worker (a
// singleton, not one per Durable Object id) — reached through a fixed
// `WorkersActorSystem`, exactly the way the RPC gateway's relay expects to
// find it.
private let greeterSystem = WorkersActorSystem()
private let greeter: Greeter = {
    let actor = Greeter(actorSystem: greeterSystem)
    greeterSystem.host(actor)
    return actor
}()

// The one fixed RPC entry point every `WorkersActorSystem` call arrives
// through — including calls the gateway relays from a native caller.
@RPC func __workerKitDistributedCall(
    _ identifier: String, _ arguments: JSValue, _ genericSubstitutions: [String]
) async throws -> JSValue {
    // A top-level `let` initializes lazily, on first access — touch
    // `greeter` here so it's hosted before the first call arrives.
    _ = greeter
    return try await greeterSystem.receive(
        identifier: identifier, arguments: arguments, genericSubstitutions: genericSubstitutions
    )
}
