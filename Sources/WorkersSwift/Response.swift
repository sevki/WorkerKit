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

    /// Creates a response directly. Most handlers instead start from
    /// ``ok(_:)``, ``text(_:status:)``, ``error(_:_:)`` or ``empty(status:)``.
    public init(status: Int = 200, headers: [(name: String, value: String)] = [], body: [UInt8] = []) {
        self.status = status
        self.headers = headers
        self.body = body
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
