import JavaScriptKit

/// An outgoing HTTP response. It is a Swift value until the handler returns
/// it; the runtime then turns it into a JavaScript `Response`.
public struct Response: Sendable {
    /// The HTTP status code, such as `200`.
    public var status: Int
    /// Header fields in order. A name may appear more than once.
    public var headers: [(name: String, value: String)]
    /// The response body, as raw bytes.
    public var body: [UInt8]
    /// The client end of a WebSocket pair to upgrade the connection to, set
    /// by ``webSocketUpgrade(_:)``. When set, `jsValue` hands it to the
    /// JavaScript `Response` constructor's `webSocket` option instead of
    /// building a body from `body`/`headers`.
    var webSocket: WebSocket?

    /// An already-built JavaScript `Response`, returned by `jsValue`
    /// unchanged — no reconstruction, so a WebSocket a nested `fetch` call's
    /// target Durable Object accepted (see `RPCStub.fetch(_:Request)`) stays
    /// attached. `webSocketUpgrade(_:)` doesn't use this: it builds its 101
    /// response itself.
    ///
    /// `status`/`headers` are snapshotted from it below so code inspecting
    /// this `Response` sees the real values, but they're read-only in
    /// effect: `jsValue` always returns `raw` unchanged when this is set,
    /// so mutating them (`withHeader(_:_:)`, or `status`/`headers`
    /// directly) doesn't change what's actually sent. `body` stays empty —
    /// reading it would need an async call `init(raw:)` can't make.
    var raw: FetchResponse?

    /// Creates a response directly. Most handlers instead start from
    /// ``ok(_:)``, ``text(_:status:)``, ``error(_:_:)`` or ``empty(status:)``.
    public init(status: Int = 200, headers: [(name: String, value: String)] = [], body: [UInt8] = []) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// Wraps an already-built JavaScript `Response`, unchanged (see `raw`'s
    /// doc comment for what that means for `status`/`headers`/`body`).
    init(raw: FetchResponse) {
        status = raw.status
        headers = Self.headerPairs(from: raw.headers.jsObject)
        body = []
        self.raw = raw
    }

    /// Snapshots a JS `Headers` object's entries as name/value pairs, for
    /// `init(raw:)`.
    private static func headerPairs(from jsHeaders: JSObject) -> [(name: String, value: String)] {
        let entries = JSObject.global.Array.function!.from!(jsHeaders)
        guard let array = entries.array else { return [] }
        return array.compactMap { entry -> (name: String, value: String)? in
            guard let pair = entry.array, pair.count == 2,
                  let name = pair[0].string, let value = pair[1].string else {
                return nil
            }
            return (name, value)
        }
    }

    /// A `200 OK` plain-text response.
    public static func ok(_ text: String) -> Response {
        .text(text, status: 200)
    }

    /// A plain-text response.
    public static func text(_ text: String, status: Int) -> Response {
        Response(status: status, headers: [("content-type", "text/plain; charset=utf-8")], body: Array(text.utf8))
    }

    /// A plain-text error response, such as `.error("Not Found", 404)`.
    public static func error(_ message: String, _ status: Int) -> Response {
        .text(message, status: status)
    }

    /// A response without a body, `204 No Content` by default.
    public static func empty(status: Int = 204) -> Response {
        Response(status: status)
    }

    /// A `101 Switching Protocols` response that upgrades the connection to
    /// `client`, the WebSocket `DurableObjectState.acceptWebSocket(tags:)`
    /// returned. Return this from `DurableObject.fetch(_:)` to complete a
    /// WebSocket upgrade request.
    public static func webSocketUpgrade(_ client: WebSocket) -> Response {
        var response = Response(status: 101)
        response.webSocket = client
        return response
    }

    /// Returns a copy with the header field `name: value` appended.
    public func withHeader(_ name: String, _ value: String) -> Response {
        var response = self
        response.headers.append((name, value))
        return response
    }
}

extension Response {
    /// The statuses the Fetch `Response` constructor accepts.
    static let validStatuses: ClosedRange<Int> = 200...599

    /// Statuses for which `Response` rejects any body, even an empty one.
    static let bodylessStatuses: Set<Int> = [204, 205, 304]

    /// Returns this response, or a 500 explaining why the JavaScript
    /// `Response` constructor would throw on it.
    func validated() -> Response {
        if !Self.validStatuses.contains(status) {
            return .error("Response status \(status) is outside 200-599", 500)
        }
        if !headers.allSatisfy({ isValidHeaderName($0.name) && isValidHeaderValue($0.value) }) {
            return .error("Response header is not a valid HTTP header", 500)
        }
        return self
    }

    /// The JavaScript `Response` for this response.
    public var jsValue: JSValue {
        if let raw {
            return .object(raw.jsObject)
        }
        if let webSocket {
            // Not `validated()`: that also checks `status` against
            // 200...599, which a 101 upgrade is never in. Only the header
            // check applies here - same reason the normal branch validates
            // them, so an invalid one (e.g. a bad Sec-WebSocket-Protocol
            // value) gets the same graceful 500 instead of a raw JS throw.
            guard headers.allSatisfy({ isValidHeaderName($0.name) && isValidHeaderValue($0.value) }) else {
                return Response.error("Response header is not a valid HTTP header", 500).jsValue
            }
            let jsHeaders = JSObject.global.Headers.object!.new()
            for (name, value) in headers {
                _ = jsHeaders.append!(name, value)
            }
            let options = JSObject()
            options["status"] = .number(101)
            options["headers"] = .object(jsHeaders)
            options["webSocket"] = .object(webSocket.jsObject)
            return JSObject.global.Response.object!.new(JSValue.null, options).jsValue
        }

        let response = validated()

        let headers = JSObject.global.Headers.object!.new()
        for (name, value) in response.headers {
            _ = headers.append!(name, value)
        }

        let options = JSObject()
        options["status"] = .number(Double(response.status))
        options["headers"] = .object(headers)

        let body: JSValue = Self.bodylessStatuses.contains(response.status)
            ? .null
            : JSTypedArray<UInt8>(response.body).jsValue
        return JSObject.global.Response.object!.new(body, options).jsValue
    }
}
