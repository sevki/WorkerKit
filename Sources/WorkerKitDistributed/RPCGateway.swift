#if arch(wasm32)
import JavaScriptKit
import WorkerKit

/// The worker end of `WorkersActorSystem`'s native build: a Durable Object
/// serving a hibernatable WebSocket where each text message is one JSON
/// call, answered with one JSON reply.
///
/// It hosts nothing itself. Each call is relayed over Workers RPC to the
/// worker's own `WorkersActorSystem.entryPointName` method through its
/// `SELF` service binding, so it reaches whatever the worker hosts exactly
/// as a call from another worker would. Bind it and route to it:
///
///     // wrangler.jsonc
///     "durable_objects": { "bindings": [{ "name": "RPCGATEWAY", "class_name": "RPCGateway" }] },
///     "services": [{ "binding": "SELF", "service": "<this worker>" }]
///
///     // @Event(.fetch): one gateway per connection, created near the caller
///     case ("GET", WorkersActorSystem.gatewayPath):
///         let gateways = env.durableObject("RPCGATEWAY")
///         return try await gateways.get(id: gateways.newUniqueID()).fetch(req)
///
/// Not safe yet for a call whose arguments or result contain an `Int64`/
/// `UInt64` outside ±2^53: calls go through a JS `JSON.parse`/
/// `JSON.stringify` round trip, which collapses a number that size to a
/// Double.
@DurableObject
public final class RPCGateway {
    let state: DurableObjectState
    let worker: Fetcher

    public init(state: DurableObjectState, env: Env) {
        self.state = state
        worker = env.service("SELF")
    }

    public func fetch(_ req: Request) async throws -> Response {
        // HTTP upgrade protocol names are case-insensitive - a standards-
        // compliant client may send "WebSocket" or any other capitalization.
        guard req.headers.get("Upgrade")?.lowercased() == "websocket" else {
            return .error("Expected Upgrade: websocket", 426)
        }
        return .webSocketUpgrade(state.acceptWebSocket(tags: ["rpc"]))
    }

    public func webSocketMessage(_ ws: WebSocket, _ message: WebSocketMessage) async throws {
        guard case .text(let text) = message else { return }
        let worker = self.worker
        ws.send(await WorkersActorSystem.handleJSONCall(text) { identifier, arguments, genericSubstitutions in
            try await worker.call(
                WorkersActorSystem.entryPointName, identifier, arguments, genericSubstitutions, as: JSValue.self
            )
        })
    }

    // webSocketClose isn't overridden: DurableObject's default already
    // completes the close handshake by echoing the peer's code and reason
    // (see its doc comment), which is all this gateway needs to do too.
}
#endif
