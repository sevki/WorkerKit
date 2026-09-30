#if os(macOS) || os(Linux)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import WorkerKitDistributed

/// Answers every request from `Stub.respond`, so the transport is exercised
/// without a network.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var respond: ((URLRequest, Data) -> (Int, Data))?
    nonisolated(unsafe) static var seen: [(URLRequest, Data)] = []
    /// When set, a request is accepted and never answered.
    nonisolated(unsafe) static var hang = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        Self.seen.append((request, body))
        if Self.hang { return }
        let (status, data) = Self.respond?(request, body) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func stubSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return URLSession(configuration: configuration)
}

private let url = URL(string: "https://worker.example/__rpc?token=t")!
private func call(_ id: String) -> String {
    #"{"id":"\#(id)","identifier":"x","arguments":[],"genericSubstitutions":[]}"#
}

@Suite(.serialized) struct HTTPPostTransportTests {
    @Test func aCallIsPostedAndTheResponseBodyIsItsReply() async {
        StubProtocol.seen = []
        StubProtocol.respond = { _, _ in (200, Data(#"{"id":"7","result":true}"#.utf8)) }
        let reply = await WorkersActorSystem.postCall(
            call("7"), to: url, headers: ["authorization": "Bearer t"], session: stubSession())
        #expect(reply == #"{"id":"7","result":true}"#)
        let (request, body) = try! #require(StubProtocol.seen.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url == url)
        #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer t")
        #expect(String(decoding: body, as: UTF8.self) == call("7"))
    }

    @Test func aFailedRequestFailsOnlyItsOwnCallUnderItsOwnID() async throws {
        StubProtocol.respond = { _, _ in (503, Data("try later".utf8)) }
        let reply = await WorkersActorSystem.postCall(call("12"), to: url, headers: [:], session: stubSession())
        let object = try #require(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        #expect(object["id"] as? String == "12")
        let message = try #require(object["error"] as? String)
        #expect(message.contains("503") && message.contains("try later"))
        #expect(object["result"] == nil)
    }

    @Test func aConnectionErrorBecomesAnErrorReplyToo() async throws {
        let refused = URLSessionConfiguration.ephemeral
        refused.protocolClasses = []
        let reply = await WorkersActorSystem.postCall(
            call("3"), to: URL(string: "http://127.0.0.1:9/__rpc")!, headers: [:], session: URLSession(configuration: refused))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        #expect(object["id"] as? String == "3")
        #expect(object["error"] is String)
    }

    @Test(arguments: [
        "<html>502 Bad Gateway</html>",          // not JSON
        #"{"result":true}"#,                     // no id
        #"{"id":"99","result":true}"#,           // another call's id
        #"{"id":7,"result":true}"#,              // an id that is not a string
    ]) func aSuccessfulResponseThatIsNotThisCallsReplyFailsTheCall(body: String) async throws {
        StubProtocol.hang = false
        StubProtocol.respond = { _, _ in (200, Data(body.utf8)) }
        let reply = await WorkersActorSystem.postCall(call("5"), to: url, headers: [:], session: stubSession())
        let object = try #require(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        #expect(object["id"] as? String == "5")
        #expect(object["error"] is String)
        #expect(object["result"] == nil)
    }

    @Test func aReplyWithNoResultIsStillAReply() async throws {
        // A call that returns nothing comes back as {"id": ...} alone.
        StubProtocol.hang = false
        StubProtocol.respond = { _, _ in (200, Data(#"{"id":"8"}"#.utf8)) }
        let reply = await WorkersActorSystem.postCall(call("8"), to: url, headers: [:], session: stubSession())
        #expect(reply == #"{"id":"8"}"#)
    }

    @Test func closingFailsCallsStillInFlightInsteadOfWaitingForThem() async throws {
        StubProtocol.hang = true
        defer { StubProtocol.hang = false }
        let (outgoing, continuation) = AsyncStream<String>.makeStream()
        let replies = LockedReplies()
        let finished = LockedFlag()
        _ = Task {
            try? await WorkersActorSystem.httpPostTransport(
                url: url, headers: [:], session: stubSession(), outgoing: outgoing, deliver: { replies.add($0) })
            finished.set()
        }
        continuation.yield(call("1"))
        try await Task.sleep(for: .milliseconds(100))   // the request is in flight and never answered
        continuation.finish()                            // close()
        // The transport must end promptly; poll rather than wait, so a transport that
        // waits for the unanswered request fails this test instead of hanging it.
        for _ in 0..<100 where !finished.isSet { try await Task.sleep(for: .milliseconds(50)) }
        #expect(finished.isSet, "the transport is still waiting for an in-flight request after close()")
        guard finished.isSet else { return }
        let first = try #require(replies.all.first)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any])
        #expect(object["id"] as? String == "1")
        #expect(object["error"] is String)
    }

    @Test func errorReplyWithoutAnIDStillParses() throws {
        let reply = WorkersActorSystem.errorReply(for: "not json", "boom")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        #expect(object["id"] as? String == "")
        #expect(object["error"] as? String == "boom")
    }

    @Test func manyCallsRunTogetherAndEachGetsItsOwnReply() async throws {
        StubProtocol.seen = []
        StubProtocol.respond = { _, body in
            let id = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["id"] as? String ?? "?"
            return (200, Data(#"{"id":"\#(id)","result":"\#(id)"}"#.utf8))
        }
        let (outgoing, continuation) = AsyncStream<String>.makeStream()
        let replies = LockedReplies()
        let transport = Task {
            try await WorkersActorSystem.httpPostTransport(
                url: url, headers: [:], session: stubSession(), outgoing: outgoing, deliver: { replies.add($0) })
        }
        for n in 1...50 { continuation.yield(call(String(n))) }
        continuation.finish()
        try await transport.value
        let ids = replies.all.compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["id"] as? String
        }
        #expect(Set(ids) == Set((1...50).map(String.init)))
        #expect(ids.count == 50)
    }
}

final class LockedReplies: @unchecked Sendable {
    private let lock = NSLock()
    private var replies = [String]()
    func add(_ reply: String) { lock.lock(); replies.append(reply); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return replies }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
#endif
