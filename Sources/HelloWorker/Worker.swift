import JavaScriptKit
import WorkersSwift

#if canImport(WASILibc)
import WASILibc
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

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

    case ("GET", "/log"):
        // Writes "split: café done\n" to stdout in three unbuffered writes,
        // splitting both the "é" and the line across fd_write calls.
        let bytes = Array("split: café done\n".utf8)
        for chunk in [bytes[..<11], bytes[11..<12], bytes[12...]] {
            _ = chunk.withUnsafeBufferPointer { write(1, $0.baseAddress, $0.count) }
        }
        return .ok("logged")

    case ("GET", "/log-unterminated"):
        // Writes to stdout without a final newline; the shim logs it when
        // the request finishes.
        let bytes = Array("unterminated output".utf8)
        _ = bytes.withUnsafeBufferPointer { write(1, $0.baseAddress, $0.count) }
        return .ok("logged")

    case ("GET", "/rpc/add"):
        // Service binding RPC: calls this worker's own @RPC add(_:_:) through
        // the SELF binding.
        let sum = try await env.service("SELF").call("add", 2, 3, as: Int.self)
        return .ok(String(sum))

    case ("GET", "/counter/increment"):
        // Durable Object RPC: calls Counter.increment(by:) on the object named
        // "e2e".
        let count = try await env.durableObject("COUNTER").get(named: "e2e").call("increment", 1, as: Int.self)
        return .ok(String(count))

    case ("GET", "/counter"):
        // Durable Object fetch: forwards to Counter.fetch(_:).
        let response = try await env.durableObject("COUNTER").get(named: "e2e").fetch("https://counter/")
        return .text(try await response.text(), status: response.status)

    case ("GET", "/no-content"):
        return .empty()

    case ("GET", "/throw"):
        struct Failure: Error {}
        throw Failure()

    default:
        return .error("Not Found", 404)
    }
}

/// Callable by other workers through a service binding, as a method of this
/// worker's default entrypoint.
@RPC func add(_ a: Int, _ b: Int) -> Int {
    a + b
}

/// A Durable Object that counts in its storage.
@DurableObject
final class Counter {
    let state: DurableObjectState

    init(state: DurableObjectState, env: Env) {
        self.state = state
    }

    func fetch(_ req: Request) async throws -> Response {
        .ok(String(try await state.storage.get("count", as: Int.self) ?? 0))
    }

    @RPC func increment(by amount: Int) async throws -> Int {
        let count = (try await state.storage.get("count", as: Int.self) ?? 0) + amount
        try await state.storage.put("count", count)
        return count
    }
}
