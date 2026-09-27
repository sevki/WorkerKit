import Distributed
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

    case ("GET", "/counter/sql"):
        // SQL storage: increments a row in a SQLite table kept by the
        // object's own state.storage.sql, and returns it decoded as a
        // Decodable struct.
        let count = try await env.durableObject("COUNTER").get(named: "e2e").call("sqlIncrement", 1, as: Int.self)
        return .ok(String(count))

    case ("GET", "/kv"):
        // Lists the KV keys under ?prefix=, a page of ?limit= at a time.
        let query = JSObject.global.URL.object!.new(req.url).searchParams.object!
        let page = try await env.kv("KV").list(
            prefix: query.get!("prefix").string,
            limit: query.get!("limit").string.flatMap { Int($0) },
            cursor: query.get!("cursor").string
        )
        return Response.ok(page.keys.map(\.name).joined(separator: ","))
            .withHeader("x-list-complete", String(page.listComplete))
            .withHeader("x-cursor", page.cursor ?? "")

    case (let method, let path) where path.hasPrefix("/kv/"):
        // A key-value store over KV: GET, PUT and DELETE /kv/<key>.
        let key = String(path.dropFirst("/kv/".count))
        let kv = env.kv("KV")
        switch method {
        case "GET":
            guard let entry = try await kv.getWithMetadata(key) else {
                return .error("Not Found", 404)
            }
            let metadata = JSObject.global.JSON.object!.stringify!(entry.metadata).string ?? "null"
            return Response.ok(entry.value).withHeader("x-metadata", metadata)
        case "PUT":
            try await kv.put(key, try await req.text(), expirationTtl: 3600, metadata: ["by": "swift"] as [String: String])
            return .empty(status: 201)
        case "DELETE":
            try await kv.delete(key)
            return .empty()
        default:
            return .error("Method Not Allowed", 405)
        }

    case ("POST", "/kv-bytes"):
        // Stores the request body as bytes and reads it back as bytes.
        let kv = env.kv("KV")
        try await kv.put("bytes", try await req.bytes())
        return Response(status: 200, headers: [], body: try await kv.bytes("bytes") ?? [])

    case (let method, let path) where path.hasPrefix("/distributed/double/"):
        guard method == "GET" else {
            return .error("Method Not Allowed", 405)
        }
        // distributed actor over Workers RPC: calls this worker's own
        // Doubler through the SELF binding, via WorkersActorSystem. The
        // caller never sees a plain RPC method name — the compiler-
        // generated distributed thunk and executeDistributedTarget resolve
        // the call end to end. See rfcs/distributed-actor-rpc.md.
        let n = Int(path.dropFirst("/distributed/double/".count)) ?? 0
        let callerSystem = WorkersActorSystem(stub: env.service("SELF"))
        let doubler = try Doubler.resolve(id: "doubler", using: callerSystem)
        let doubled = try await doubler.double(n)
        return .ok(String(doubled))

    case ("POST", "/distributed/echo"):
        // The same call path as /distributed/double/, but through a generic
        // distributed func: exercises recordGenericSubstitution /
        // decodeGenericSubstitutions, not just plain arguments.
        let callerSystem = WorkersActorSystem(stub: env.service("SELF"))
        let doubler = try Doubler.resolve(id: "doubler", using: callerSystem)
        let echoed = try await doubler.echo(try await req.text())
        return .ok(echoed)

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

/// A `distributed actor` reachable over Workers RPC through
/// `WorkersActorSystem`. See `rfcs/distributed-actor-rpc.md`.
distributed actor Doubler {
    typealias ActorSystem = WorkersActorSystem

    distributed func double(_ n: Int) -> Int {
        n * 2
    }

    /// A generic distributed func: exercises generic-substitution transport
    /// (recordGenericSubstitution/decodeGenericSubstitutions), not just
    /// plain arguments.
    distributed func echo<T: Codable & Sendable>(_ value: T) -> T {
        value
    }
}

/// The callee-side system this worker hosts `Doubler` on, and the one fixed
/// RPC entry point every `WorkersActorSystem` call arrives through.
private let distributedSystem = WorkersActorSystem()
private let doubler: Doubler = {
    let actor = Doubler(actorSystem: distributedSystem)
    distributedSystem.host(actor)
    return actor
}()

@RPC func __workersSwiftDistributedCall(
    _ identifier: String, _ arguments: JSValue, _ genericSubstitutions: [String]
) async throws -> JSValue {
    // A top-level `let` initializes lazily, on first access — and nothing
    // else in this file touches the module-level `doubler`, so without this
    // its initializer (which hosts it on `distributedSystem`) would never
    // run before a call arrives here.
    _ = doubler
    return try await distributedSystem.receive(
        identifier: identifier, arguments: arguments, genericSubstitutions: genericSubstitutions
    )
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

    /// A second counter, kept in a SQLite table instead of the key-value
    /// store `increment(by:)` uses, to exercise `state.storage.sql`.
    @RPC func sqlIncrement(by amount: Int) throws -> Int {
        struct CounterRow: Decodable {
            let value: Int
        }
        let sql = state.storage.sql
        try sql.exec("CREATE TABLE IF NOT EXISTS counters (name TEXT PRIMARY KEY, value INTEGER NOT NULL)")
        try sql.exec(
            "INSERT INTO counters (name, value) VALUES (?, ?) ON CONFLICT(name) DO UPDATE SET value = value + excluded.value",
            "sql", amount
        )
        let rows = try sql.query("SELECT value FROM counters WHERE name = ?", "sql", as: CounterRow.self)
        guard let row = rows.first else {
            throw JSException(message: "counters row went missing")
        }
        return row.value
    }
}
