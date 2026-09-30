#if os(macOS) || os(Linux)
import NIOCore
import NIOPosix

/// Splits a byte stream into newline-terminated lines. A line that grows past
/// `maxLineLength` without a newline is an error, so a peer that never sends one
/// cannot make the reader buffer without bound.
struct NewlineFrames {
    struct LineTooLong: Error, CustomStringConvertible {
        let limit: Int
        var description: String { "a message is longer than \(limit) bytes" }
    }

    let maxLineLength: Int
    private var pending = [UInt8]()

    init(maxLineLength: Int) {
        self.maxLineLength = maxLineLength
    }

    /// The complete lines in `bytes` after whatever was left over from before,
    /// without their terminators; an unfinished last line waits for more.
    mutating func feed(_ bytes: some Sequence<UInt8>) throws -> [String] {
        var lines = [String]()
        for byte in bytes {
            if byte == UInt8(ascii: "\n") {
                lines.append(String(decoding: pending, as: UTF8.self))
                pending.removeAll(keepingCapacity: true)
            } else {
                pending.append(byte)
                if pending.count > maxLineLength { throw LineTooLong(limit: maxLineLength) }
            }
        }
        return lines
    }
}

extension WorkersActorSystem {
    static func unixSocketTransport(
        path: String, outgoing: AsyncStream<String>, deliver: @escaping @Sendable (String) -> Void
    ) async throws {
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connect(unixDomainSocketPath: path) { channel in
                channel.eventLoop.makeCompletedFuture(withResultOf: {
                    try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
                })
            }
        try await channel.executeThenClose { inbound, outbound in
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await text in outgoing {
                        var line = ByteBuffer()
                        line.writeString(text)
                        line.writeInteger(UInt8(ascii: "\n"))
                        try await outbound.write(line)
                    }
                }
                group.addTask {
                    var frames = NewlineFrames(maxLineLength: maxMessageSize)
                    for try await chunk in inbound {
                        for line in try frames.feed(chunk.readableBytesView) { deliver(line) }
                    }
                }
                // As for the WebSocket: either side ending ends the connection.
                try await group.next()
                group.cancelAll()
            }
        }
    }
}
#endif
