import JavaScriptEventLoop
import JavaScriptKit

/// Runs once when the shim instantiates the module: installs the Swift
/// concurrency executor on the JavaScript event loop and registers the fetch
/// handler that the shim calls with the runtime's own `Request`.
@main
enum JSKitWorker {
    static func main() {
        JavaScriptEventLoop.installGlobalExecutor()

        let fetch = JSClosure { arguments in
            guard let request = arguments.first?.object else {
                return JSPromise.reject("fetch called without a Request").jsValue
            }
            return JSPromise.async { () async throws(JSException) -> JSValue in
                try await handle(request)
            }.jsValue
        }
        JSObject.global.__workersSwiftFetch = .object(fetch)
    }
}

func handle(_ request: JSObject) async throws(JSException) -> JSValue {
    let url = JSObject.global.URL.object!.new(request.url)
    let method = request.method.string ?? ""
    let path = url.pathname.string ?? ""

    switch (method, path) {
    case ("GET", "/"):
        return makeResponse("Hello from JavaScriptKit on workerd/celld")

    case ("GET", "/digest"):
        // Awaits a real Workers API promise from Swift.
        let bytes = JSObject.global.TextEncoder.object!.new().encode!("hello")
        let promise = JSPromise(JSObject.global.crypto.subtle.digest("SHA-256", bytes).object!)!
        let digest = JSObject.global.Uint8Array.object!.new(try await promise.value)
        var hex = ""
        for index in 0..<Int(digest.length.number!) {
            let byte = Int(digest[index].number!)
            hex += (byte < 16 ? "0" : "") + String(byte, radix: 16)
        }
        return makeResponse(hex)

    case ("GET", "/headers"):
        let value = request.headers.get("x-echo").string ?? ""
        return makeResponse(value, headers: ["x-echo": value])

    default:
        return makeResponse("Not Found", status: 404)
    }
}

func makeResponse(_ body: String, status: Int = 200, headers: [String: String] = [:]) -> JSValue {
    let responseHeaders = JSObject()
    responseHeaders["content-type"] = .string("text/plain; charset=utf-8")
    for (name, value) in headers {
        responseHeaders[name] = .string(value)
    }

    let options = JSObject()
    options["status"] = .number(Double(status))
    options["headers"] = .object(responseHeaders)
    return JSObject.global.Response.object!.new(body, options).jsValue
}
