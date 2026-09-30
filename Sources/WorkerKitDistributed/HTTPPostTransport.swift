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
            return String(decoding: data, as: UTF8.self)
        } catch {
            return errorReply(for: text, "\(error)")
        }
    }

    /// `{"id": <the call's id>, "error": message}`, which `remoteCall` turns into
    /// a thrown ``RemoteCallError`` for that one call.
    static func errorReply(for call: String, _ message: String) -> String {
        let id = (try? JSONSerialization.jsonObject(with: Data(call.utf8)) as? [String: Any])?["id"] as? String ?? ""
        let reply: [String: Any] = ["id": id, "error": message]
        let data = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
