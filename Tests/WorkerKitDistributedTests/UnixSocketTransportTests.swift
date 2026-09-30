#if os(macOS) || os(Linux)
import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import WorkerKitDistributed

@Suite struct NewlineFramesTests {
    @Test func splitsLinesAndKeepsAnUnfinishedOneForLater() throws {
        var frames = NewlineFrames(maxLineLength: 100)
        #expect(try frames.feed(Array("one\ntw".utf8)) == ["one"])
        #expect(try frames.feed(Array("o\nthree\n".utf8)) == ["two", "three"])
        #expect(try frames.feed(Array("".utf8)) == [])
    }

    @Test func aLineCanArriveOneByteAtATime() throws {
        var frames = NewlineFrames(maxLineLength: 100)
        var lines = [String]()
        for byte in Array("{\"id\":\"1\"}\n".utf8) { lines += try frames.feed([byte]) }
        #expect(lines == ["{\"id\":\"1\"}"])
    }

    @Test func multibyteTextSurvivesBeingSplitAcrossChunks() throws {
        var frames = NewlineFrames(maxLineLength: 100)
        let bytes = Array("héllo wörld\n".utf8)
        let cut = bytes.firstIndex(of: 0xC3)! + 1          // inside the two-byte é
        var lines = try frames.feed(Array(bytes[..<cut]))
        lines += try frames.feed(Array(bytes[cut...]))
        #expect(lines == ["héllo wörld"])
    }

    @Test func aLineWithoutANewlineIsBoundedNotBufferedForever() {
        var frames = NewlineFrames(maxLineLength: 10)
        #expect(throws: NewlineFrames.LineTooLong.self) { try frames.feed(Array(repeating: UInt8(ascii: "a"), count: 11)) }
    }
}

/// A unix-socket server that answers each line `{"id":..}` with `{"id":..,"result":<id>}`,
/// and closes the connection after `closeAfter` lines when set.
private func serve(on path: String, closeAfter: Int? = nil) async throws -> NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never> {
    try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .bind(unixDomainSocketPath: path, cleanupExistingSocketFile: true) { channel in
            channel.eventLoop.makeCompletedFuture(withResultOf: {
                try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
            })
        }
}

private func run(_ server: NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>, closeAfter: Int?) -> Task<Void, Never> {
    Task {
        try? await server.executeThenClose { connections in
            for try await connection in connections {
                Task {
                    try? await connection.executeThenClose { inbound, outbound in
                        var frames = NewlineFrames(maxLineLength: 1 << 20)
                        var served = 0
                        for try await chunk in inbound {
                            for line in try frames.feed(chunk.readableBytesView) {
                                let id = (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["id"] as? String ?? "?"
                                var reply = ByteBuffer()
                                reply.writeString(#"{"id":"\#(id)","result":"\#(id)"}"# + "\n")
                                try await outbound.write(reply)
                                served += 1
                                if let closeAfter, served >= closeAfter { return }
                            }
                        }
                    }
                }
            }
        }
    }
}

private func socketPath() -> String { "/tmp/wk-\(UInt32.random(in: 0...UInt32.max)).sock" }
private func call(_ id: String) -> String { #"{"id":"\#(id)","identifier":"x","arguments":[],"genericSubstitutions":[]}"# }

@Suite(.serialized) struct UnixSocketTransportTests {
    @Test func manyCallsOverOneConnectionEachGetTheirOwnReply() async throws {
        let path = socketPath(); defer { try? FileManager.default.removeItem(atPath: path) }
        let server = try await serve(on: path); let serving = run(server, closeAfter: nil)
        defer { serving.cancel() }

        let (outgoing, continuation) = AsyncStream<String>.makeStream()
        let replies = LockedReplies()
        let transport = Task {
            try await WorkersActorSystem.unixSocketTransport(path: path, outgoing: outgoing, deliver: { replies.add($0) })
        }
        for n in 1...200 { continuation.yield(call(String(n))) }
        for _ in 0..<100 where replies.all.count < 200 { try await Task.sleep(for: .milliseconds(50)) }
        continuation.finish()                                        // close()
        try await transport.value                                     // ends, does not hang

        let ids = replies.all.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["id"] as? String }
        #expect(Set(ids) == Set((1...200).map(String.init)))
        #expect(ids.count == 200)
    }

    @Test func aPeerThatClosesEndsTheTransport() async throws {
        let path = socketPath(); defer { try? FileManager.default.removeItem(atPath: path) }
        let server = try await serve(on: path); let serving = run(server, closeAfter: 1)
        defer { serving.cancel() }

        let (outgoing, continuation) = AsyncStream<String>.makeStream()
        let replies = LockedReplies()
        let finished = LockedFlag()
        _ = Task {
            try? await WorkersActorSystem.unixSocketTransport(path: path, outgoing: outgoing, deliver: { replies.add($0) })
            finished.set()
        }
        continuation.yield(call("1"))
        for _ in 0..<100 where !finished.isSet { try await Task.sleep(for: .milliseconds(50)) }
        #expect(finished.isSet, "the transport is still open after the peer closed the connection")
        #expect(replies.all.count == 1)
        continuation.finish()
    }

    @Test func aSocketThatIsNotThereThrows() async {
        let (outgoing, _) = AsyncStream<String>.makeStream()
        await #expect(throws: (any Error).self) {
            try await WorkersActorSystem.unixSocketTransport(
                path: "/tmp/wk-no-such-\(UInt32.random(in: 0...UInt32.max)).sock", outgoing: outgoing, deliver: { _ in })
        }
    }

    @Test func aSystemOverAMissingSocketEndsItsConnectionTaskInsteadOfHanging() async {
        // Through the public initializer. A call made on such a system fails at once
        // (the shared drain in `init(transport:)` fails pending and later calls when
        // the connection task ends, covered with the WebSocket transport); this only
        // shows that the task does end.
        let system = WorkersActorSystem(unixSocket: "/tmp/wk-no-such-\(UInt32.random(in: 0...UInt32.max)).sock")
        await system.wait()
    }
}
#endif
