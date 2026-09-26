import JavaScriptKit
import WorkersSwift

@Event(.fetch)
func fetch(req: Request, env: Env, ctx: Context) async throws -> Response {
    switch (req.method, req.path) {
    case ("GET", "/"):
        return .ok("Hello from Swift on workerd/celld")

    case ("GET", "/health"):
        return .ok("ok")

    case ("GET", "/headers"):
        let value = req.headers.get("x-echo") ?? ""
        return Response.ok(value).withHeader("x-echo", value)

    case ("GET", "/env"):
        return .ok(env.variable("GREETING") ?? "")

    case ("POST", "/echo"):
        return .ok(try await req.text())

    case ("GET", "/digest"):
        // Any Web API is one JavaScriptKit call away: here, crypto.subtle.
        let bytes = JSObject.global.TextEncoder.object!.new().encode!("hello")
        let promise = JSPromise(JSObject.global.crypto.subtle.digest("SHA-256", bytes).object!)!
        let digest = JSTypedArray<UInt8>(unsafelyWrapping: JSObject.global.Uint8Array.object!.new(try await promise.value))
        let hex = digest.withUnsafeBytes { bytes in
            bytes.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
        }
        return .ok(hex)

    case ("GET", "/no-content"):
        return .empty()

    case ("GET", "/throw"):
        struct Failure: Error {}
        throw Failure()

    default:
        return .error("Not Found", 404)
    }
}
