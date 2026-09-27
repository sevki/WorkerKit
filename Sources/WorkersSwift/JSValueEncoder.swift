import JavaScriptBigIntSupport
import JavaScriptKit

/// Encodes an `Encodable` Swift value into a `JSValue` tree: an `Encodable`
/// counterpart to JavaScriptKit's `JSValueDecoder`. A keyed container becomes
/// a JS object, an unkeyed container becomes a JS array, and a value that is
/// itself `ConvertibleToJSValue` (`String`, `Int`, `Bool`, ...) is encoded
/// directly rather than through its `Codable` conformance.
///
/// `Int64`/`UInt64` are encoded as a JS `BigInt`, not the `ConvertibleToJSValue`
/// default of a `Double`-backed JS number: a `Double` can't represent every
/// `Int64`/`UInt64` value exactly (anything outside ±2^53), which would
/// silently corrupt an id, counter, or timestamp near the top of that range.
/// `JSValueDecoder` already reads a `BigInt` back losslessly.
public final class JSValueEncoder {
    public init() {}

    public func encode<T: Encodable>(_ value: T) throws -> JSValue {
        if let big = _bigIntJSValue(for: value) {
            return big
        }
        if _takesConvertibleShortcut(value), let convertible = value as? ConvertibleToJSValue {
            return convertible.jsValue
        }
        let encoder = _Encoder(userInfo: [:])
        try value.encode(to: encoder)
        return encoder.storage.value
    }
}

/// `Int64`/`UInt64` as a lossless `JSValue`, or `nil` for any other type
/// (including `Int`/`UInt`, which are 32-bit — and so `Double`-safe — on
/// this package's wasm32 target).
private func _bigIntJSValue(for value: some Encodable) -> JSValue? {
    switch value {
    case let v as Int64: return JSBigInt(v).jsValue
    case let v as UInt64: return JSBigInt(unsigned: v).jsValue
    default: return nil
    }
}

/// `Array`, `Dictionary`, and `Optional` all have their own conditional
/// `ConvertibleToJSValue` conformance (forwarding to each element's/each
/// wrapped value's own `.jsValue`), which would bypass `_bigIntJSValue`
/// entirely for, say, `[Int64]` or `Int64?` — converting their elements
/// through JavaScriptKit's default `Double`-backed path instead. Excluding
/// them from the shortcut sends them through this encoder's own container
/// machinery, which checks `_bigIntJSValue` at every element/wrapped value.
private protocol _JSValueEncoderRecursesInto {}
extension Array: _JSValueEncoderRecursesInto {}
extension Dictionary: _JSValueEncoderRecursesInto {}
extension Optional: _JSValueEncoderRecursesInto {}

private func _takesConvertibleShortcut(_ value: some Encodable) -> Bool {
    !(value is _JSValueEncoderRecursesInto)
}

/// `_EncodingStorage.value`'s setter also runs `onSet`, so a nested encoder
/// created to back `superEncoder()`/`superEncoder(forKey:)` writes straight
/// through to its parent container the moment something is actually encoded
/// into it — the parent can't take a one-time snapshot at creation time, the
/// way a container's own `nestedContainer`/plain `encode<T>` can, because it
/// hands the encoder back to the caller instead of driving it directly.
private final class _EncodingStorage {
    var onSet: ((JSValue) -> Void)?

    var value: JSValue = .undefined {
        didSet { onSet?(value) }
    }
}

private struct _Encoder: Swift.Encoder {
    let storage: _EncodingStorage
    let codingPath: [CodingKey]
    let userInfo: [CodingUserInfoKey: Any]

    init(
        storage: _EncodingStorage = _EncodingStorage(),
        codingPath: [CodingKey] = [],
        userInfo: [CodingUserInfoKey: Any]
    ) {
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

    /// A fresh encoder whose eventual value — however it's set, including
    /// through a container obtained later on — is reported to `onSet`.
    func nestedEncoder(with key: CodingKey, onSet: @escaping (JSValue) -> Void) -> _Encoder {
        let nested = _Encoder(codingPath: codingPath + [key], userInfo: userInfo)
        nested.storage.onSet = onSet
        return nested
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
        if let big = _bigIntJSValue(for: value) {
            _encode(big, forKey: key)
        } else if _takesConvertibleShortcut(value), let convertible = value as? ConvertibleToJSValue {
            _encode(convertible.jsValue, forKey: key)
        } else {
            let nested = encoder.nestedEncoder(with: key) { [object] value in object[key.stringValue] = value }
            try value.encode(to: nested)
        }
    }

    mutating func nestedContainer<NestedKey>(
        keyedBy _: NestedKey.Type,
        forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> where NestedKey: CodingKey {
        let nested = encoder.nestedEncoder(with: key) { [object] value in object[key.stringValue] = value }
        return nested.container(keyedBy: NestedKey.self)
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        let nested = encoder.nestedEncoder(with: key) { [object] value in object[key.stringValue] = value }
        return nested.unkeyedContainer()
    }

    mutating func superEncoder() -> Encoder {
        let key = _JSCodingKey(stringValue: "super")!
        return encoder.nestedEncoder(with: key) { [object] value in object[key.stringValue] = value }
    }

    mutating func superEncoder(forKey key: Key) -> Encoder {
        encoder.nestedEncoder(with: key) { [object] value in object[key.stringValue] = value }
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

    /// Reserves the next index for a nested encoder that will fill it in
    /// later, rather than appending its value now: `nested.storage.onSet`
    /// writes through to this exact index whenever it fires.
    private mutating func _reserveNext() -> Int {
        let index = count
        _ = array.push!(JSValue.undefined)
        count += 1
        return index
    }

    mutating func encodeNil() throws {
        _append(.null)
    }

    mutating func encode<T>(_ value: T) throws where T: Encodable {
        if let big = _bigIntJSValue(for: value) {
            _append(big)
        } else if _takesConvertibleShortcut(value), let convertible = value as? ConvertibleToJSValue {
            _append(convertible.jsValue)
        } else {
            let index = _reserveNext()
            let nested = encoder.nestedEncoder(with: _JSCodingKey(index: index)) { [array] value in array[index] = value }
            try value.encode(to: nested)
        }
    }

    mutating func nestedContainer<NestedKey>(
        keyedBy _: NestedKey.Type
    ) -> KeyedEncodingContainer<NestedKey> where NestedKey: CodingKey {
        let index = _reserveNext()
        let nested = encoder.nestedEncoder(with: _JSCodingKey(index: index)) { [array] value in array[index] = value }
        return nested.container(keyedBy: NestedKey.self)
    }

    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        let index = _reserveNext()
        let nested = encoder.nestedEncoder(with: _JSCodingKey(index: index)) { [array] value in array[index] = value }
        return nested.unkeyedContainer()
    }

    mutating func superEncoder() -> Encoder {
        let index = _reserveNext()
        return encoder.nestedEncoder(with: _JSCodingKey(index: index)) { [array] value in array[index] = value }
    }
}

extension _Encoder: SingleValueEncodingContainer {
    func encodeNil() throws {
        storage.value = .null
    }

    func encode<T>(_ value: T) throws where T: Encodable {
        if let big = _bigIntJSValue(for: value) {
            storage.value = big
        } else if _takesConvertibleShortcut(value), let convertible = value as? ConvertibleToJSValue {
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
