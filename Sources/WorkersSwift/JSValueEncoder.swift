import JavaScriptKit

/// Encodes an `Encodable` Swift value into a `JSValue` tree: an `Encodable`
/// counterpart to JavaScriptKit's `JSValueDecoder`. A keyed container becomes
/// a JS object, an unkeyed container becomes a JS array, and a value that is
/// itself `ConvertibleToJSValue` (`String`, `Int`, `Bool`, ...) is encoded
/// directly rather than through its `Codable` conformance.
public final class JSValueEncoder {
    public init() {}

    public func encode<T: Encodable>(_ value: T) throws -> JSValue {
        if let convertible = value as? ConvertibleToJSValue {
            return convertible.jsValue
        }
        let encoder = _Encoder(userInfo: [:])
        try value.encode(to: encoder)
        return encoder.storage.value
    }
}

private final class _EncodingStorage {
    var value: JSValue = .undefined
}

private struct _Encoder: Swift.Encoder {
    let storage: _EncodingStorage
    let codingPath: [CodingKey]
    let userInfo: [CodingUserInfoKey: Any]

    init(storage: _EncodingStorage = _EncodingStorage(), codingPath: [CodingKey] = [], userInfo: [CodingUserInfoKey: Any]) {
        self.storage = storage
        self.codingPath = codingPath
        self.userInfo = userInfo
    }

    func container<Key>(keyedBy _: Key.Type) -> KeyedEncodingContainer<Key> where Key: CodingKey {
        let object = JSObject()
        storage.value = .object(object)
        return KeyedEncodingContainer(_KeyedEncodingContainer(encoder: self, object: object))
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        let array = JSObject.global.Array.object!.new()
        storage.value = .object(array)
        return _UnkeyedEncodingContainer(encoder: self, array: array)
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        self
    }

    func nestedEncoder(with key: CodingKey) -> _Encoder {
        _Encoder(codingPath: codingPath + [key], userInfo: userInfo)
    }
}

private struct _KeyedEncodingContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let encoder: _Encoder
    let object: JSObject

    var codingPath: [CodingKey] { encoder.codingPath }

    private func _encode(_ value: JSValue, forKey key: Key) {
        object[key.stringValue] = value
    }

    mutating func encodeNil(forKey key: Key) throws {
        _encode(.null, forKey: key)
    }

    mutating func encode<T>(_ value: T, forKey key: Key) throws where T: Encodable {
        if let convertible = value as? ConvertibleToJSValue {
            _encode(convertible.jsValue, forKey: key)
        } else {
            let nested = encoder.nestedEncoder(with: key)
            try value.encode(to: nested)
            _encode(nested.storage.value, forKey: key)
        }
    }

    mutating func nestedContainer<NestedKey>(
        keyedBy _: NestedKey.Type,
        forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> where NestedKey: CodingKey {
        let nested = encoder.nestedEncoder(with: key)
        let container = nested.container(keyedBy: NestedKey.self)
        _encode(nested.storage.value, forKey: key)
        return container
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        let nested = encoder.nestedEncoder(with: key)
        let container = nested.unkeyedContainer()
        _encode(nested.storage.value, forKey: key)
        return container
    }

    mutating func superEncoder() -> Encoder {
        encoder.nestedEncoder(with: _JSCodingKey(stringValue: "super")!)
    }

    mutating func superEncoder(forKey key: Key) -> Encoder {
        encoder.nestedEncoder(with: key)
    }
}

private struct _UnkeyedEncodingContainer: UnkeyedEncodingContainer {
    let encoder: _Encoder
    let array: JSObject
    var count = 0

    var codingPath: [CodingKey] { encoder.codingPath }

    private mutating func _append(_ value: JSValue) {
        _ = array.push!(value)
        count += 1
    }

    mutating func encodeNil() throws {
        _append(.null)
    }

    mutating func encode<T>(_ value: T) throws where T: Encodable {
        if let convertible = value as? ConvertibleToJSValue {
            _append(convertible.jsValue)
        } else {
            let nested = encoder.nestedEncoder(with: _JSCodingKey(index: count))
            try value.encode(to: nested)
            _append(nested.storage.value)
        }
    }

    mutating func nestedContainer<NestedKey>(
        keyedBy _: NestedKey.Type
    ) -> KeyedEncodingContainer<NestedKey> where NestedKey: CodingKey {
        let nested = encoder.nestedEncoder(with: _JSCodingKey(index: count))
        let container = nested.container(keyedBy: NestedKey.self)
        _append(nested.storage.value)
        return container
    }

    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        let nested = encoder.nestedEncoder(with: _JSCodingKey(index: count))
        let container = nested.unkeyedContainer()
        _append(nested.storage.value)
        return container
    }

    mutating func superEncoder() -> Encoder {
        let nested = encoder.nestedEncoder(with: _JSCodingKey(index: count))
        _append(nested.storage.value)
        return nested
    }
}

extension _Encoder: SingleValueEncodingContainer {
    func encodeNil() throws {
        storage.value = .null
    }

    func encode<T>(_ value: T) throws where T: Encodable {
        if let convertible = value as? ConvertibleToJSValue {
            storage.value = convertible.jsValue
        } else {
            try value.encode(to: self)
        }
    }
}

private struct _JSCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = "\(intValue)"
        self.intValue = intValue
    }

    init(index: Int) {
        stringValue = "Index \(index)"
        intValue = index
    }
}
