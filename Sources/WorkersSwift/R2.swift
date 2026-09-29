import JavaScriptKit

/// A Workers R2 bucket binding, such as `r2_buckets` in wrangler.jsonc:
/// workers-rs' `Bucket`.
///
///     let bucket = env.r2("ASSETS")
///     try await bucket.put("greeting.txt", "hello")
///     let object = try await bucket.get("greeting.txt")
///     let text = try await object?.text()
public final class R2Bucket: @unchecked Sendable {
    /// The underlying JavaScript `R2Bucket`.
    public let jsObject: JSObject

    public init(_ jsObject: JSObject) {
        self.jsObject = jsObject
    }

    /// The metadata for `key`, without its body, or `nil` when there is none.
    public func head(_ key: String) async throws -> R2Object? {
        let result = try await awaitValue(jsObject.head!(key))
        guard result.object != nil else {
            return nil
        }
        return R2Object(result)
    }

    /// The object stored under `key`, with its body, or `nil` when there is
    /// none.
    ///
    /// - Note: when `onlyIf` names a condition that fails, the real R2
    ///   binding returns the object's metadata with its body withheld
    ///   rather than `nil` — a distinction this binding does not expose;
    ///   calling `text()`/`bytes()` on that result throws instead.
    public func get(
        _ key: String,
        onlyIf: R2Conditional? = nil,
        range: R2Range? = nil
    ) async throws -> R2ObjectBody? {
        let options = JSObject()
        if let onlyIf {
            options["onlyIf"] = onlyIf.jsValue
        }
        if let range {
            options["range"] = range.jsValue
        }
        let result = try await awaitValue(jsObject.get!(key, options))
        guard result.object != nil else {
            return nil
        }
        return R2ObjectBody(result)
    }

    /// Stores `value` under `key`. Returns the stored object's metadata, or
    /// `nil` when `onlyIf` names a condition that fails.
    ///
    /// - Parameters:
    ///   - key: the key to store the value under.
    ///   - value: the text to store.
    ///   - httpMetadata: headers echoed back on `get`/`head`, such as
    ///     `contentType`.
    ///   - customMetadata: user-defined key/value pairs stored with the
    ///     object.
    ///   - onlyIf: a condition the object must currently satisfy (or not
    ///     exist, for a create-only write) for the write to proceed.
    @discardableResult
    public func put(
        _ key: String,
        _ value: String,
        httpMetadata: R2HTTPMetadata? = nil,
        customMetadata: [String: String]? = nil,
        onlyIf: R2Conditional? = nil
    ) async throws -> R2Object? {
        try await put(key, .string(value), httpMetadata: httpMetadata, customMetadata: customMetadata, onlyIf: onlyIf)
    }

    /// Stores the bytes `value` under `key`. See
    /// `put(_:_:httpMetadata:customMetadata:onlyIf:)`.
    @discardableResult
    public func put(
        _ key: String,
        _ value: [UInt8],
        httpMetadata: R2HTTPMetadata? = nil,
        customMetadata: [String: String]? = nil,
        onlyIf: R2Conditional? = nil
    ) async throws -> R2Object? {
        try await put(
            key, JSTypedArray<UInt8>(value).jsValue,
            httpMetadata: httpMetadata, customMetadata: customMetadata, onlyIf: onlyIf
        )
    }

    private func put(
        _ key: String,
        _ value: JSValue,
        httpMetadata: R2HTTPMetadata?,
        customMetadata: [String: String]?,
        onlyIf: R2Conditional?
    ) async throws -> R2Object? {
        let options = JSObject()
        if let httpMetadata {
            options["httpMetadata"] = httpMetadata.jsValue
        }
        if let customMetadata {
            options["customMetadata"] = customMetadata.jsValue
        }
        if let onlyIf {
            options["onlyIf"] = onlyIf.jsValue
        }
        let result = try await awaitValue(jsObject.put!(key, value, options))
        guard result.object != nil else {
            return nil
        }
        return R2Object(result)
    }

    /// Deletes `key`. Deleting a key that does not exist succeeds.
    public func delete(_ key: String) async throws {
        _ = try await awaitValue(jsObject.delete!(key))
    }

    /// Deletes up to 1000 keys in one call. Deleting a key that does not
    /// exist succeeds.
    public func delete(_ keys: [String]) async throws {
        _ = try await awaitValue(jsObject.delete!(keys))
    }

    /// Lists objects, a page at a time: pass the previous page's `cursor`
    /// for the next one. Returns the first 1000 entries by default.
    public func list(
        prefix: String? = nil,
        limit: Int? = nil,
        cursor: String? = nil,
        delimiter: String? = nil
    ) async throws -> R2ListResult {
        let options = JSObject()
        if let prefix {
            options["prefix"] = .string(prefix)
        }
        if let limit {
            options["limit"] = .number(Double(limit))
        }
        if let cursor {
            options["cursor"] = .string(cursor)
        }
        if let delimiter {
            options["delimiter"] = .string(delimiter)
        }
        let result = try await awaitValue(jsObject.list!(options))
        let objects = result.objects.object!
        let count = Int(objects.length.number ?? 0)
        let prefixes = result.delimitedPrefixes.object!
        let prefixCount = Int(prefixes.length.number ?? 0)
        return R2ListResult(
            objects: (0..<count).map { R2Object(objects[$0]) },
            truncated: result.truncated.boolean ?? false,
            cursor: result.cursor.string,
            delimitedPrefixes: (0..<prefixCount).map { prefixes[$0].string ?? "" }
        )
    }
}

/// An object's metadata, as returned by `R2Bucket.head(_:)`,
/// `R2Bucket.put(_:_:httpMetadata:customMetadata:onlyIf:)` and
/// `R2Bucket.list(prefix:limit:cursor:delimiter:)`.
public struct R2Object: Sendable {
    public let key: String
    public let version: String
    /// The object's size in bytes.
    public let size: Int
    /// R2's own strong etag for the object.
    public let etag: String
    /// The etag as it appears in an HTTP `ETag` header (quoted).
    public let httpEtag: String
    /// When the object was uploaded, in milliseconds since the Unix epoch.
    public let uploaded: Double
    public let httpMetadata: R2HTTPMetadata
    public let customMetadata: [String: String]
    public let checksums: R2Checksums

    init(_ value: JSValue) {
        key = value.key.string ?? ""
        version = value.version.string ?? ""
        size = Int(value.size.number ?? 0)
        etag = value.etag.string ?? ""
        httpEtag = value.httpEtag.string ?? ""
        uploaded = value.uploaded.object!.getTime!().number ?? 0
        httpMetadata = R2HTTPMetadata(value.httpMetadata)
        customMetadata = R2Object.stringMap(value.customMetadata)
        checksums = R2Checksums(value.checksums)
    }

    static func stringMap(_ value: JSValue) -> [String: String] {
        guard let object = value.object,
              let keys = JSObject.global.Object.function!.keys!(object).array else {
            return [:]
        }
        var result: [String: String] = [:]
        for key in keys {
            guard let key = key.string else {
                continue
            }
            result[key] = object[key].string ?? ""
        }
        return result
    }
}

/// An `R2Object` together with its body, as returned by
/// `R2Bucket.get(_:onlyIf:range:)`.
public struct R2ObjectBody: @unchecked Sendable {
    public let metadata: R2Object

    private let jsObject: JSObject

    init(_ value: JSValue) {
        metadata = R2Object(value)
        jsObject = value.object!
    }

    /// The body as text.
    public func text() async throws -> String {
        try await awaitValue(jsObject.text!()).string ?? ""
    }

    /// The body as bytes.
    public func bytes() async throws -> [UInt8] {
        let buffer = try await awaitValue(jsObject.arrayBuffer!())
        let array = JSTypedArray<UInt8>(unsafelyWrapping: JSObject.global.Uint8Array.object!.new(buffer))
        return array.withUnsafeBytes { Array($0) }
    }
}

/// Various HTTP headers associated with an object, automatically echoed back
/// on `get`/`head` (and, for `contentType`, `contentEncoding` and
/// `contentDisposition`, rendered into R2's own public HTTP API responses).
public struct R2HTTPMetadata: Sendable {
    public var contentType: String?
    public var contentLanguage: String?
    public var contentDisposition: String?
    public var contentEncoding: String?
    public var cacheControl: String?

    public init(
        contentType: String? = nil,
        contentLanguage: String? = nil,
        contentDisposition: String? = nil,
        contentEncoding: String? = nil,
        cacheControl: String? = nil
    ) {
        self.contentType = contentType
        self.contentLanguage = contentLanguage
        self.contentDisposition = contentDisposition
        self.contentEncoding = contentEncoding
        self.cacheControl = cacheControl
    }

    init(_ value: JSValue) {
        contentType = value.contentType.string
        contentLanguage = value.contentLanguage.string
        contentDisposition = value.contentDisposition.string
        contentEncoding = value.contentEncoding.string
        cacheControl = value.cacheControl.string
    }

    var jsValue: JSValue {
        let object = JSObject()
        if let contentType {
            object["contentType"] = .string(contentType)
        }
        if let contentLanguage {
            object["contentLanguage"] = .string(contentLanguage)
        }
        if let contentDisposition {
            object["contentDisposition"] = .string(contentDisposition)
        }
        if let contentEncoding {
            object["contentEncoding"] = .string(contentEncoding)
        }
        if let cacheControl {
            object["cacheControl"] = .string(cacheControl)
        }
        return .object(object)
    }
}

/// Hashes of an object's content, as hex strings, for whichever algorithm
/// `put(_:_:...)` was given (or R2's own default) — the rest are `nil`.
public struct R2Checksums: Sendable {
    public let md5: String?
    public let sha1: String?
    public let sha256: String?
    public let sha384: String?
    public let sha512: String?

    init(_ value: JSValue) {
        md5 = value.md5.string
        sha1 = value.sha1.string
        sha256 = value.sha256.string
        sha384 = value.sha384.string
        sha512 = value.sha512.string
    }
}

/// A condition `R2Bucket.get(_:onlyIf:range:)` or `put(_:_:...:onlyIf:)`
/// must currently satisfy to proceed. See
/// [RFC 7232](https://datatracker.ietf.org/doc/html/rfc7232).
public struct R2Conditional: Sendable {
    public var etagMatches: String?
    public var etagDoesNotMatch: String?
    /// Milliseconds since the Unix epoch.
    public var uploadedBefore: Double?
    /// Milliseconds since the Unix epoch.
    public var uploadedAfter: Double?

    public init(
        etagMatches: String? = nil,
        etagDoesNotMatch: String? = nil,
        uploadedBefore: Double? = nil,
        uploadedAfter: Double? = nil
    ) {
        self.etagMatches = etagMatches
        self.etagDoesNotMatch = etagDoesNotMatch
        self.uploadedBefore = uploadedBefore
        self.uploadedAfter = uploadedAfter
    }

    var jsValue: JSValue {
        let object = JSObject()
        if let etagMatches {
            object["etagMatches"] = .string(etagMatches)
        }
        if let etagDoesNotMatch {
            object["etagDoesNotMatch"] = .string(etagDoesNotMatch)
        }
        if let uploadedBefore {
            object["uploadedBefore"] = .object(JSObject.global.Date.function!.new(uploadedBefore))
        }
        if let uploadedAfter {
            object["uploadedAfter"] = .object(JSObject.global.Date.function!.new(uploadedAfter))
        }
        return .object(object)
    }
}

/// A byte range to read from an object, for `R2Bucket.get(_:onlyIf:range:)`.
public enum R2Range: Sendable {
    /// `length` bytes starting at `offset`.
    case offset(_ offset: Int, length: Int)
    /// From `offset` to the end of the object.
    case suffix(from: Int)
    /// The last `length` bytes of the object.
    case last(_ length: Int)

    var jsValue: JSValue {
        let object = JSObject()
        switch self {
        case .offset(let offset, let length):
            object["offset"] = .number(Double(offset))
            object["length"] = .number(Double(length))
        case .suffix(let from):
            object["offset"] = .number(Double(from))
        case .last(let length):
            object["suffix"] = .number(Double(length))
        }
        return .object(object)
    }
}

/// A page of objects from `R2Bucket.list(prefix:limit:cursor:delimiter:)`.
public struct R2ListResult: Sendable {
    public let objects: [R2Object]
    /// Whether there are more results beyond this page.
    public let truncated: Bool
    /// The cursor for the next page, when `truncated` is `true`.
    public let cursor: String?
    /// Prefixes grouped by `delimiter`, when one was given.
    public let delimitedPrefixes: [String]
}
