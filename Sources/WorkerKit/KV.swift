import JavaScriptEventLoop
import JavaScriptKit

/// A Workers KV namespace binding, such as `kv_namespaces` in wrangler.jsonc:
/// workers-rs' `KvStore`.
///
///     let kv = env.kv("CACHE")
///     try await kv.put("greeting", "hello", expirationTtl: 3600)
///     let greeting = try await kv.get("greeting")
public final class KVStore: @unchecked Sendable {
    /// The underlying JavaScript `KVNamespace`.
    public let jsObject: JSObject

    public init(_ jsObject: JSObject) {
        self.jsObject = jsObject
    }

    /// The value stored under `key` as text, or `nil` when there is none.
    public func get(_ key: String) async throws -> String? {
        try await awaitValue(jsObject.get!(key)).string
    }

    /// The value stored under `key` as bytes, or `nil` when there is none.
    public func bytes(_ key: String) async throws -> [UInt8]? {
        let options = JSObject()
        options["type"] = .string("arrayBuffer")
        let buffer = try await awaitValue(jsObject.get!(key, options))
        guard buffer.object != nil else {
            return nil
        }
        let array = JSTypedArray<UInt8>(unsafelyWrapping: JSObject.global.Uint8Array.object!.new(buffer))
        return array.withUnsafeBytes { Array($0) }
    }

    /// The value stored under `key` as text with its metadata, or `nil` when
    /// there is none. The metadata is `null` when the value has none.
    public func getWithMetadata(_ key: String) async throws -> (value: String, metadata: JSValue)? {
        let result = try await awaitValue(jsObject.getWithMetadata!(key))
        guard let value = result.value.string else {
            return nil
        }
        return (value, result.metadata)
    }

    /// Stores `value` under `key`.
    ///
    /// - Parameters:
    ///   - key: the key to store the value under.
    ///   - value: the text to store.
    ///   - expiration: when the key expires, in seconds since the Unix epoch.
    ///   - expirationTtl: how long the key lives, in seconds (at least 60).
    ///   - metadata: a JSON-serializable value stored with the key, such as
    ///     `["version": 2]`.
    public func put(
        _ key: String,
        _ value: String,
        expiration: Int? = nil,
        expirationTtl: Int? = nil,
        metadata: (any ConvertibleToJSValue)? = nil
    ) async throws {
        try await put(key, .string(value), expiration: expiration, expirationTtl: expirationTtl, metadata: metadata)
    }

    /// Stores the bytes `value` under `key`. See `put(_:_:expiration:expirationTtl:metadata:)`.
    public func put(
        _ key: String,
        _ value: [UInt8],
        expiration: Int? = nil,
        expirationTtl: Int? = nil,
        metadata: (any ConvertibleToJSValue)? = nil
    ) async throws {
        try await put(key, JSTypedArray<UInt8>(value).jsValue, expiration: expiration, expirationTtl: expirationTtl, metadata: metadata)
    }

    private func put(
        _ key: String,
        _ value: JSValue,
        expiration: Int?,
        expirationTtl: Int?,
        metadata: (any ConvertibleToJSValue)?
    ) async throws {
        let options = JSObject()
        if let expiration {
            options["expiration"] = .number(Double(expiration))
        }
        if let expirationTtl {
            options["expirationTtl"] = .number(Double(expirationTtl))
        }
        if let metadata {
            options["metadata"] = metadata.jsValue
        }
        _ = try await awaitValue(jsObject.put!(key, value, options))
    }

    /// Deletes `key`. Deleting a key that does not exist succeeds.
    public func delete(_ key: String) async throws {
        _ = try await awaitValue(jsObject.delete!(key))
    }

    /// Lists keys in lexicographic order, a page at a time: pass the
    /// previous page's `cursor` for the next one.
    public func list(prefix: String? = nil, limit: Int? = nil, cursor: String? = nil) async throws -> KVListResult {
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
        let result = try await awaitValue(jsObject.list!(options))
        let keys = result.keys.object!
        let count = Int(keys.length.number ?? 0)
        return KVListResult(
            keys: (0..<count).map { index in
                let key = keys[index]
                return KVKey(
                    name: key.name.string ?? "",
                    expiration: key.expiration.number.map { Int($0) },
                    metadata: key.metadata
                )
            },
            listComplete: result.list_complete.boolean ?? true,
            cursor: result.cursor.string
        )
    }
}

/// A page of keys from `KVStore.list(prefix:limit:cursor:)`.
public struct KVListResult: @unchecked Sendable {
    public let keys: [KVKey]
    /// Whether this is the last page.
    public let listComplete: Bool
    /// The cursor for the next page, when there is one.
    public let cursor: String?
}

/// A key listed by `KVStore.list(prefix:limit:cursor:)`.
public struct KVKey: @unchecked Sendable {
    public let name: String
    /// When the key expires, in seconds since the Unix epoch.
    public let expiration: Int?
    /// The key's metadata, or `undefined` when it has none.
    public let metadata: JSValue
}
