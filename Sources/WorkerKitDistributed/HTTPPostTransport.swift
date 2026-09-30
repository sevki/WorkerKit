#if os(macOS) || os(Linux)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension WorkersActorSystem {
    /// One `POST` per message `outgoing` yields, run concurrently, each reply
    /// handed to `deliver`. A request that fails (no connection, a non-200
    /// status, a timeout) is answered with an error reply under the call's own
    /// id, so only that call fails.
    static func httpPostTransport(
        url: URL, headers: [String: String], session: URLSession,
        outgoing: AsyncStream<String>, deliver: @escaping @Sendable (String) -> Void
    ) async throws {
        await withTaskGroup(of: Void.self) { group in
            for await text in outgoing {
                group.addTask {
                    deliver(await postCall(text, to: url, headers: headers, session: session))
                }
            }
            // `outgoing` ends on `close()`: requests still in flight fail, as the
            // calls on a closed WebSocket do, instead of being waited for. A
            // cancelled request throws, which `postCall` answers as an error.
            group.cancelAll()
        }
    }

    /// The reply text for the call `text`: the response body of a `200`, or an
    /// error envelope under the call's id when the request did not succeed.
    static func postCall(_ text: String, to url: URL, headers: [String: String], session: URLSession) async -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(text.utf8)
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return errorReply(for: text, "not an HTTP response")
            }
            guard http.statusCode == 200 else {
                let detail = String(decoding: data.prefix(200), as: UTF8.self)
                return errorReply(for: text, "HTTP \(http.statusCode): \(detail)")
            }
            return validated(String(decoding: data, as: UTF8.self), for: text)
        } catch {
            return errorReply(for: text, "\(error)")
        }
    }

    /// `reply` if it is a JSON object carrying the id of the call `text`, otherwise
    /// an error reply for that call. A 200 that is not such a reply (HTML from an
    /// intermediary, malformed JSON, another call's id) would be discarded by the
    /// shared parser, or resolve a different call, and the call would never
    /// finish.
    static func validated(_ reply: String, for text: String) -> String {
        let expected = callID(of: text)
        guard let object = (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any],
              let id = object["id"] as? String else {
            return errorReply(for: text, "the response is not a reply (no JSON object with an id)")
        }
        guard id == expected else {
            return errorReply(for: text, "the response answers call \"\(id)\", not \"\(expected)\"")
        }
        return reply
    }

    /// The `id` of the call `text`, or `""` when it cannot be read.
    static func callID(of text: String) -> String {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["id"] as? String ?? ""
    }

    /// `{"id": <the call's id>, "error": message}`, which `remoteCall` turns into
    /// a thrown ``RemoteCallError`` for that one call.
    static func errorReply(for call: String, _ message: String) -> String {
        let reply: [String: Any] = ["id": callID(of: call), "error": message]
        let data = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
