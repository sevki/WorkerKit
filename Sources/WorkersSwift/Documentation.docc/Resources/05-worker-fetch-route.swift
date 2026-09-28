import WorkersDistributed
import WorkersSwift

@Event(.fetch)
func fetch(req: Request, env: Env, ctx: Context) async throws -> Response {
    switch (req.method, req.path) {
    case ("GET", WorkersActorSystem.gatewayPath):
        // A hibernatable WebSocket a native CLI can call this worker's
        // distributed actors through. Each connection gets its own fresh
        // RPCGateway instance, so connections don't queue through one
        // object.
        let gateways = env.durableObject("RPCGATEWAY")
        return try await gateways.get(id: gateways.newUniqueID()).fetch(req)

    default:
        return .error("Not Found", 404)
    }
}
