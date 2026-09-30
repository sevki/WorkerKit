import JavaScriptEventLoop
import JavaScriptKit

/// An incoming HTTP request: the runtime's own JavaScript `Request`.
///
/// Workers isolates are single-threaded, so the JavaScript wrappers in this
/// module are `@unchecked Sendable`.
public final class Request: @unchecked Sendable {
    /// The underlying JavaScript `Request`.
    public let jsObject: JSObject

    /// Wraps the runtime's `Request` object. `@Event(.fetch)` constructs
    /// this for you.
    public init(_ jsObject: JSObject) {
        self.jsObject = jsObject
    }

    /// The request method, such as `GET`.
    public var method: String {
        jsObject.method.string ?? ""
    }

    /// The full request URL.
    public var url: String {
        jsObject.url.string ?? ""
    }

    /// The path of the request URL, such as `/users/1`.
    public var path: String {
        JSObject.global.URL.object!.new(jsObject.url).pathname.string ?? ""
    }

    /// The request headers.
    public var headers: Headers {
        Headers(jsObject.headers.object!)
    }

    /// Reads the body as UTF-8 text.
    public func text() async throws -> String {
        try await JSPromise(jsObject.text!().object!)!.value.string ?? ""
    }

    /// Reads the body as bytes.
    public func bytes() async throws -> [UInt8] {
        let buffer = try await JSPromise(jsObject.arrayBuffer!().object!)!.value
        let array = JSTypedArray<UInt8>(unsafelyWrapping: JSObject.global.Uint8Array.object!.new(buffer))
        return array.withUnsafeBytes { Array($0) }
    }
}

extension Request {
    /// Cloudflare-populated request metadata. `nil` for a request that never
    /// passed through Cloudflare's network (e.g. local dev without cf
    /// emulation, or a direct service-binding call).
    public struct CFProperties: Sendable {
        public var asn: Int?
        public var asOrganization: String?
        public var country: String?
        public var colo: String?
    }

    public var cf: CFProperties? {
        guard let object = jsObject.cf.object else { return nil }
        return CFProperties(
            asn: object.asn.number.map(Int.init),
            asOrganization: object.asOrganization.string,
            country: object.country.string,
            colo: object.colo.string)
    }
}
