// What both builds of `WorkersActorSystem` share. Each build's transport is
// in its own file: `WorkersActorSystem+Workers.swift` (wasm32) and
// `WorkersActorSystem+WebSocket.swift` (everywhere else).

extension WorkersActorSystem {
    /// The route a worker serves `RPCGateway` at, and the one the native
    /// build's `init(worker:)` connects to.
    public static let gatewayPath = "/__rpc"
}
