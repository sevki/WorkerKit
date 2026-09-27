import JavaScriptKit

/// The headers of a `Request`: the runtime's own JavaScript `Headers`.
public final class Headers: @unchecked Sendable {
    /// The underlying JavaScript `Headers`.
    public let jsObject: JSObject

    public init(_ jsObject: JSObject) {
        self.jsObject = jsObject
    }

    /// The value of the header `name`, or `nil` when it is absent. Multiple
    /// values are joined with ", ".
    public func get(_ name: String) -> String? {
        guard isValidHeaderName(name) else {
            return nil
        }
        return jsObject.get!(name).string
    }

    /// Whether the header `name` is present.
    public func has(_ name: String) -> Bool {
        isValidHeaderName(name) && jsObject.has!(name).boolean == true
    }
}

/// A header name must be a non-empty RFC 9110 token, which is what the Fetch
/// `Headers` class accepts.
func isValidHeaderName(_ name: String) -> Bool {
    !name.isEmpty && name.utf8.allSatisfy { byte in
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"):
            return true
        default:
            return "!#$%&'*+-.^_`|~".utf8.contains(byte)
        }
    }
}

/// `Headers` values are JavaScript ByteStrings: every character must be at
/// most U+00FF, and NUL, CR, and LF are rejected.
func isValidHeaderValue(_ value: String) -> Bool {
    value.unicodeScalars.allSatisfy { scalar in
        scalar.value <= 0xFF && scalar != "\0" && scalar != "\n" && scalar != "\r"
    }
}
