import WorkersSwift

@Event(.fetch)
func fetch(_ request: WorkerRequest) -> WorkerResponse {
    switch (request.method.uppercased(), request.path) {
    case ("GET", "/"):
        return WorkerResponse(status: 200, body: "Hello from Swift on workerd/celld")
    case ("GET", "/health"):
        return WorkerResponse(status: 200, body: "ok")
    default:
        return WorkerResponse(status: 404, body: "Not Found")
    }
}
