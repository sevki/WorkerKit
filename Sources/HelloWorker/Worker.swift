import Distributed
import HelloWorkerActors
import JavaScriptKit
import WorkersDistributed
import WASILibc
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

    case ("GET", "/distributed/bignumber"):
        // 2^53 + 1: not exactly representable as a Double, so this proves
        // JSValueEncoder/JSValueDecoder round-trip Int64 through a JS
        // BigInt rather than JavaScriptKit's default Double-backed number.
        let callerSystem = WorkersActorSystem(stub: env.service("SELF"))
        let doubler = try Doubler.resolve(id: "doubler", using: callerSystem)
        let n: Int64 = 9_007_199_254_740_993
        let result = try await doubler.bigNumber(n)
        return .ok(result == n ? "match" : "mismatch: \(result) != \(n)")

    case ("GET", "/distributed/bignumbers"):
        // Same as /distributed/bignumber, but nested in a [Int64]: the
        // regression case Codex flagged, where Array's own
        // ConvertibleToJSValue conformance could bypass the Int64 fix.
        let callerSystem = WorkersActorSystem(stub: env.service("SELF"))
        let doubler = try Doubler.resolve(id: "doubler", using: callerSystem)
        let values: [Int64] = [1, 9_007_199_254_740_993, -9_007_199_254_740_993]
        let result = try await doubler.bigNumbers(values)
        return .ok(result == values ? "match" : "mismatch: \(result) != \(values)")

    case ("GET", "/distributed/dog"):
        // Exercises JSValueEncoder's superEncoder()/superEncoder(forKey:)
        // through a two-level Codable class hierarchy.
        let callerSystem = WorkersActorSystem(stub: env.service("SELF"))
        let doubler = try Doubler.resolve(id: "doubler", using: callerSystem)
        let result = try await doubler.identify(Dog(name: "Rex", breed: "Labrador"))
        return .ok(result)

    case ("GET", "/dining/round"):
        // One round of the dining philosophers, run concurrently: five
        // distributed actor instances (Philosopher, one per Durable Object
        // id) each try to eat by making distributed calls of their own to
        // two of five Fork instances. Adjacent philosophers share a fork,
        // so concurrent rounds genuinely contend for them — this is real
        // concurrent distributed-actor traffic against real Durable
        // Objects, not a simulation.
        let table = DiningTable(env: env)
        let philosophers = try table.philosophers()
        let outcomes = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for i in 0..<5 {
                let (leftForkID, rightForkID) = table.forkIDs(for: i)
                group.addTask {
                    (i, try await philosophers[i].tryEat(leftForkID: leftForkID, rightForkID: rightForkID))
                }
            }
            var results: [Int: String] = [:]
            for try await (i, outcome) in group {
                results[i] = outcome
            }
            return results
        }
        let lines = (0..<5).map { "phil-\($0): \(outcomes[$0] ?? "?")" }
        return .ok(lines.joined(separator: "\n"))

    case ("GET", "/dining/simulate"):
        // Thirty concurrent rounds: proof the resource-ordering protocol
        // never deadlocks and every philosopher keeps making progress
        // (no permanent starvation) under real, repeated contention.
        let table = DiningTable(env: env)
        let philosophers = try table.philosophers()
        for _ in 0..<30 {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for i in 0..<5 {
                    let (leftForkID, rightForkID) = table.forkIDs(for: i)
                    group.addTask { _ = try await philosophers[i].tryEat(leftForkID: leftForkID, rightForkID: rightForkID) }
                }
                try await group.waitForAll()
            }
        }
        var totals: [Int] = []
        for philosopher in philosophers {
            totals.append(try await philosopher.meals())
        }
        return .ok(totals.map(String.init).joined(separator: ","))

    case ("GET", "/ws/echo"):
        // Forwards the upgrade request to EchoSocket.fetch(_:), which
        // accepts a hibernatable WebSocket and returns the 101 response
        // carrying its client end; RPCStub.fetch(_:Request) hands that
        // response straight back so the runtime completes the handshake
        // with the original caller.
        return try await env.durableObject("ECHO").get(named: "e2e").fetch(req)

    case ("GET", WorkersActorSystem.gatewayPath):
        // Forwards the upgrade request to a fresh RPCGateway per connection:
        // a hibernatable WebSocket a native CLI (see HelloWorkerCLI, using
        // WorkersActorSystem's native build) can call this worker's distributed
        // actors through, in plain JSON instead of JavaScriptKit's JSValue.
        let gateways = env.durableObject("RPCGATEWAY")
        return try await gateways.get(id: gateways.newUniqueID()).fetch(req)

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

// Doubler, Animal and Dog live in HelloWorkerActors, shared with
// HelloWorkerCLI; this worker hosts the real Doubler instance below.

// MARK: - Dining philosophers

/// A fork: one distributed actor instance per Durable Object id, exercising
/// `WorkersActorSystem`'s per-id routing (`init(durableObjects:)`/
/// `host(_:as:)`) rather than the one-hosted-actor-per-worker singleton
/// `Doubler` above uses. `tryPickUp`/`putDown` are a non-blocking try-lock:
/// a Durable Object's own single-threaded execution makes `held`'s
/// check-then-set atomic, with no separate locking needed.
distributed actor Fork {
    typealias ActorSystem = WorkersActorSystem

    private var held = false

    distributed func tryPickUp() -> Bool {
        guard !held else { return false }
        held = true
        return true
    }

    distributed func putDown() {
        held = false
    }
}

@DurableObject
final class ForkObject {
    let hostSystem: WorkersActorSystem
    let fork: Fork

    init(state: DurableObjectState, env: Env) {
        let hostSystem = WorkersActorSystem()
        self.hostSystem = hostSystem
        fork = hostSystem.host(state.id) { Fork(actorSystem: $0) }
    }
}

/// A philosopher: also one distributed actor instance per Durable Object id
/// (see `Fork`), told which two forks to use on each call rather than
/// knowing its own seat at construction — a Durable Object's real id (what
/// `ForkObject`/`PhilosopherObject` assign themselves internally) is an
/// opaque hex string, not the friendly `"fork-<n>"`/`"phil-<n>"` name a
/// caller resolves by, so the seating plan has to travel with the call
/// instead. Always picks up the lower-id fork first (a classic resource-
/// ordering deadlock avoidance: two neighbors can never each hold the
/// other's first fork), and releases immediately on a failed second
/// pickup rather than blocking, so a failed attempt never wedges a fork.
///
/// A single attempt isn't enough on its own, though: measured against real
/// workerd, five concurrent callers with no jitter resolve their pickups in
/// a *consistent* order every round (nothing here is genuinely racing at
/// the OS/network level the way real separate processes would), so a
/// give-up-immediately philosopher starves permanently rather than
/// occasionally — one philosopher won every single round, 30/30, while the
/// other four never ate once. `tryEat` retries with random backoff between
/// attempts specifically to break that determinism.
distributed actor Philosopher {
    typealias ActorSystem = WorkersActorSystem

    private let forksSystem: WorkersActorSystem
    private var mealsEaten = 0

    init(actorSystem: WorkersActorSystem, forksSystem: WorkersActorSystem) {
        self.actorSystem = actorSystem
        self.forksSystem = forksSystem
    }

    distributed func tryEat(leftForkID: String, rightForkID: String) async throws -> String {
        let (firstID, secondID) = leftForkID < rightForkID ? (leftForkID, rightForkID) : (rightForkID, leftForkID)
        let first = try Fork.resolve(id: firstID, using: forksSystem)
        let second = try Fork.resolve(id: secondID, using: forksSystem)

        let maxAttempts = 6
        for attempt in 0..<maxAttempts {
            // Tracked outside the do block, not inferred from control flow,
            // so a throw from *any* of these calls (a transient RPC
            // failure, cancellation) — not just a plain `false` result —
            // still releases whatever this attempt actually holds instead
            // of stranding it indefinitely.
            var firstHeld = false
            var secondHeld = false
            do {
                guard try await first.tryPickUp() else {
                    if attempt + 1 < maxAttempts {
                        try await Task.sleep(nanoseconds: UInt64.random(in: 1_000_000...8_000_000))
                    }
                    continue
                }
                firstHeld = true

                guard try await second.tryPickUp() else {
                    try await first.putDown()
                    firstHeld = false
                    if attempt + 1 < maxAttempts {
                        try await Task.sleep(nanoseconds: UInt64.random(in: 1_000_000...8_000_000))
                    }
                    continue
                }
                secondHeld = true

                mealsEaten += 1
                let meal = mealsEaten
                try await first.putDown()
                firstHeld = false
                try await second.putDown()
                secondHeld = false
                return "ate (meal #\(meal))"
            } catch {
                if firstHeld { try? await first.putDown() }
                if secondHeld { try? await second.putDown() }
                throw error
            }
        }
        return "starved this round (\(maxAttempts) attempts, forks \(firstID)/\(secondID) stayed contended)"
    }

    distributed func meals() -> Int {
        mealsEaten
    }
}

@DurableObject
final class PhilosopherObject {
    let hostSystem: WorkersActorSystem
    let philosopher: Philosopher

    init(state: DurableObjectState, env: Env) {
        let hostSystem = WorkersActorSystem()
        self.hostSystem = hostSystem
        let forksSystem = WorkersActorSystem(durableObjects: env.durableObject("FORKS"))
        philosopher = hostSystem.host(state.id) { Philosopher(actorSystem: $0, forksSystem: forksSystem) }
    }
}

/// Computes the real Durable Object hex ids for the table's five forks and
/// philosophers up front. `WorkersActorSystem`'s per-Durable-Object-id
/// routing needs the same canonical id the hosted object assigns itself
/// (its own `DurableObjectState.id`) — not the friendly `"fork-<n>"`/
/// `"phil-<n>"` name, which only `idFromName(_:)` can turn into that id.
struct DiningTable {
    let philosopherIDs: [String]
    let forkHexIDs: [String]
    let philosopherSystem: WorkersActorSystem

    init(env: Env) {
        let philosophersNamespace = env.durableObject("PHILOSOPHERS")
        let forksNamespace = env.durableObject("FORKS")
        philosopherIDs = (0..<5).map { philosophersNamespace.idFromName("phil-\($0)") }
        forkHexIDs = (0..<5).map { forksNamespace.idFromName("fork-\($0)") }
        philosopherSystem = WorkersActorSystem(durableObjects: philosophersNamespace)
    }

    func philosophers() throws -> [Philosopher] {
        try philosopherIDs.map { try Philosopher.resolve(id: $0, using: philosopherSystem) }
    }

    func forkIDs(for index: Int) -> (left: String, right: String) {
        (forkHexIDs[index], forkHexIDs[(index + 1) % 5])
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

/// A Durable Object that accepts a hibernatable WebSocket and echoes each
/// message back prefixed with a running count, kept as a WebSocket
/// attachment rather than instance state — so it would survive the object
/// being evicted and hibernated between messages, not just kept alive by
/// this process staying up.
@DurableObject
final class EchoSocket {
    let state: DurableObjectState

    init(state: DurableObjectState, env: Env) {
        self.state = state
    }

    func fetch(_ req: Request) async throws -> Response {
        // HTTP upgrade protocol names are case-insensitive - a standards-
        // compliant client may send "WebSocket" or any other capitalization.
        guard req.headers.get("Upgrade")?.lowercased() == "websocket" else {
            return .error("Expected Upgrade: websocket", 426)
        }
        return .webSocketUpgrade(state.acceptWebSocket(tags: ["echo"]))
    }

    func webSocketMessage(_ ws: WebSocket, _ message: WebSocketMessage) async throws {
        let count = (ws.deserializeAttachment(as: Int.self) ?? 0) + 1
        ws.serializeAttachment(count)
        switch message {
        case .text(let text):
            ws.send("\(count): \(text)")
        case .binary(let bytes):
            ws.send(bytes)
        }
    }

    func webSocketClose(_ ws: WebSocket, code: Int, reason: String, wasClean: Bool) async throws {
        try await state.storage.put("lastClose", "\(code) \(reason) \(wasClean)")
        // The runtime does not complete the closing handshake on its own;
        // this echoes the client's own code/reason back to finish it (code
        // 1005's own special case, if it's that: see closeEchoing).
        ws.closeEchoing(code: code, reason: reason)
    }
}
