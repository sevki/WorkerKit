// Embedded Swift ships Synchronization without Mutex; its Wasm target is
// single-threaded, so ABIState falls back to unguarded storage there.
#if canImport(Synchronization) && !hasFeature(Embedded)
import Synchronization
#endif

public struct WorkerRequest: Sendable, Equatable {
    public let method: String
    public let path: String

    public init(method: String, path: String) {
        self.method = method
        self.path = path
    }
}

public struct WorkerResponse: Sendable, Equatable {
    public let status: Int
    public let headers: [String: String]
    public let body: String

    public init(status: Int, headers: [String: String] = ["content-type": "text/plain; charset=utf-8"], body: String) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// The events a worker can handle.
public enum WorkerEvent {
    /// An HTTP request, delivered through the Worker `fetch` handler.
    case fetch
}

/// Marks a top-level function as the worker's handler for `event`.
///
///     @Event(.fetch)
///     func fetch(_ request: WorkerRequest) -> WorkerResponse {
///         WorkerResponse(status: 200, body: "Hello")
///     }
///
/// The function may be `throws`; an error becomes a 500 response. The macro
/// generates the `workers_handle_request` Wasm export, so a module can have
/// only one `@Event(.fetch)` function.
@attached(peer, names: named(__workersSwift_fetch))
public macro Event(_ event: WorkerEvent) = #externalMacro(module: "WorkersSwiftMacros", type: "EventMacro")

/// The ABI entry points that `@Event` expansions call.
public enum WorkersRuntime {
    /// Decodes a request passed through the Wasm ABI, runs `handler`, and
    /// stores its response. Returns the response handle, or 0 when the
    /// method or path is malformed.
    public static func handleRequest(
        _ methodPointer: UnsafePointer<UInt8>?,
        _ methodLength: Int32,
        _ pathPointer: UnsafePointer<UInt8>?,
        _ pathLength: Int32,
        handler: (WorkerRequest) -> WorkerResponse
    ) -> Int32 {
        guard methodLength >= 0, pathLength >= 0,
              hasValidABIString(methodPointer, methodLength),
              hasValidABIString(pathPointer, pathLength),
              let method = decodeUTF8(methodPointer, methodLength),
              let path = decodeUTF8(pathPointer, pathLength) else {
            return 0
        }

        let response = handler(WorkerRequest(method: method, path: path))
        return WasmResponseStore.store(response)
    }
}

private struct StoredWasmResponse: Sendable {
    let status: Int32
    /// Header pairs encoded as `name\0value\0`; NUL cannot appear in a
    /// valid header name or value.
    let headers: [UInt8]
    let body: [UInt8]

    static func error(_ message: String) -> StoredWasmResponse {
        StoredWasmResponse(
            status: 500,
            headers: encodeHeaders(["content-type": "text/plain; charset=utf-8"]),
            body: Array(message.utf8)
        )
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

func encodeHeaders(_ headers: [String: String]) -> [UInt8] {
    var bytes: [UInt8] = []
    for (name, value) in headers {
        bytes += name.utf8
        bytes.append(0)
        bytes += value.utf8
        bytes.append(0)
    }
    return bytes
}

private struct WasmAllocation: Sendable {
    let size: Int32
    let alignment: Int32
}

/// Guards the ABI's global state. Native `swift test` runs tests in parallel,
/// so it needs a real lock; a Wasm module in workerd/celld is single-threaded.
private final class ABIState<Value: Sendable>: @unchecked Sendable {
    #if canImport(Synchronization) && !hasFeature(Embedded)
    private let mutex: Mutex<Value>

    init(_ value: Value) {
        mutex = Mutex(value)
    }

    func withLock<Result: Sendable>(_ body: (inout Value) -> Result) -> Result {
        mutex.withLock { value in body(&value) }
    }
    #else
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result: Sendable>(_ body: (inout Value) -> Result) -> Result {
        body(&value)
    }
    #endif
}

enum WasmResponseStore {
    private struct State: Sendable {
        var nextHandle: Int32 = 1
        var responses: [Int32: StoredWasmResponse] = [:]
    }

    private static let state = ABIState(State())

    static func nextValidHandle(after handle: Int32) -> Int32 {
        let next = handle &+ 1
        return next > 0 ? next : 1
    }

    /// The statuses the Fetch `Response` constructor accepts.
    static let validStatuses: ClosedRange<Int> = 200...599

    static func store(_ response: WorkerResponse) -> Int32 {
        let body = Array(response.body.utf8)
        let headers = encodeHeaders(response.headers)
        let storedResponse: StoredWasmResponse

        if body.count > Int(Int32.max) || headers.count > Int(Int32.max) {
            storedResponse = .error("Response too large for ABI")
        } else if !validStatuses.contains(response.status) {
            storedResponse = .error("Response status out of range for ABI")
        } else if !response.headers.allSatisfy({ isValidHeaderName($0.key) && isValidHeaderValue($0.value) }) {
            storedResponse = .error("Response header is not a valid HTTP header")
        } else {
            storedResponse = StoredWasmResponse(status: Int32(response.status), headers: headers, body: body)
        }

        return state.withLock { state in
            let handle = state.nextHandle > 0 ? state.nextHandle : 1
            state.nextHandle = nextValidHandle(after: handle)
            state.responses[handle] = storedResponse
            return handle
        }
    }

    static func status(for handle: Int32) -> Int32 {
        state.withLock { $0.responses[handle]?.status ?? 500 }
    }

    static func bodyLength(for handle: Int32) -> Int32 {
        let count = state.withLock { $0.responses[handle]?.body.count ?? 0 }
        return Int32(exactly: count) ?? Int32.max
    }

    static func copyBody(for handle: Int32, to destination: UnsafeMutableRawPointer?) {
        copy(state.withLock { $0.responses[handle]?.body ?? [] }, to: destination)
    }

    static func headersLength(for handle: Int32) -> Int32 {
        let count = state.withLock { $0.responses[handle]?.headers.count ?? 0 }
        return Int32(exactly: count) ?? Int32.max
    }

    static func copyHeaders(for handle: Int32, to destination: UnsafeMutableRawPointer?) {
        copy(state.withLock { $0.responses[handle]?.headers ?? [] }, to: destination)
    }

    private static func copy(_ bytes: [UInt8], to destination: UnsafeMutableRawPointer?) {
        guard let destination, !bytes.isEmpty else {
            return
        }

        bytes.withUnsafeBytes { buffer in
            destination.copyMemory(from: buffer.baseAddress!, byteCount: bytes.count)
        }
    }

    static func release(_ handle: Int32) {
        state.withLock { _ = $0.responses.removeValue(forKey: handle) }
    }
}

enum WasmAllocationStore {
    private static let allocations = ABIState([UInt: WasmAllocation]())

    static func record(pointer: UnsafeMutableRawPointer, size: Int32, alignment: Int32) {
        allocations.withLock { $0[UInt(bitPattern: pointer)] = WasmAllocation(size: size, alignment: alignment) }
    }

    static func take(pointer: UnsafeMutableRawPointer, size: Int32, alignment: Int32) -> Bool {
        allocations.withLock { allocations in
            let key = UInt(bitPattern: pointer)
            guard let allocation = allocations[key] else {
                return false
            }
            guard allocation.size == size, allocation.alignment == alignment else {
                return false
            }

            allocations.removeValue(forKey: key)
            return true
        }
    }
}

func hasValidABIString(_ pointer: UnsafePointer<UInt8>?, _ length: Int32) -> Bool {
    length == 0 || pointer != nil
}

func decodeUTF8(_ pointer: UnsafePointer<UInt8>?, _ length: Int32) -> String? {
    guard let pointer, length > 0 else {
        return ""
    }

    let buffer = UnsafeBufferPointer(start: pointer, count: Int(length))
    return String(validating: buffer, as: UTF8.self)
}

#if arch(wasm32)
@_expose(wasm, "workers_alloc")
#endif
@_cdecl("workers_alloc")
public func workers_alloc(_ size: Int32, _ alignment: Int32) -> UnsafeMutableRawPointer? {
    guard size >= 0, alignment == 1,
          let byteCount = Int(exactly: size),
          let byteAlignment = Int(exactly: alignment) else {
        return nil
    }

    let pointer = UnsafeMutableRawPointer.allocate(byteCount: max(byteCount, 1), alignment: byteAlignment)
    WasmAllocationStore.record(pointer: pointer, size: size, alignment: alignment)
    return pointer
}

#if arch(wasm32)
@_expose(wasm, "workers_free")
#endif
@_cdecl("workers_free")
public func workers_free(_ pointer: UnsafeMutableRawPointer?, _ size: Int32, _ alignment: Int32) {
    guard let pointer, size >= 0, alignment == 1 else {
        return
    }
    guard WasmAllocationStore.take(pointer: pointer, size: size, alignment: alignment) else {
        return
    }

    pointer.deallocate()
}

#if arch(wasm32)
@_expose(wasm, "workers_response_status")
#endif
@_cdecl("workers_response_status")
public func workers_response_status(_ handle: Int32) -> Int32 {
    WasmResponseStore.status(for: handle)
}

#if arch(wasm32)
@_expose(wasm, "workers_response_body_len")
#endif
@_cdecl("workers_response_body_len")
public func workers_response_body_len(_ handle: Int32) -> Int32 {
    WasmResponseStore.bodyLength(for: handle)
}

#if arch(wasm32)
@_expose(wasm, "workers_response_body_copy")
#endif
@_cdecl("workers_response_body_copy")
public func workers_response_body_copy(_ handle: Int32, _ destination: UnsafeMutableRawPointer?) {
    WasmResponseStore.copyBody(for: handle, to: destination)
}

#if arch(wasm32)
@_expose(wasm, "workers_response_headers_len")
#endif
@_cdecl("workers_response_headers_len")
public func workers_response_headers_len(_ handle: Int32) -> Int32 {
    WasmResponseStore.headersLength(for: handle)
}

#if arch(wasm32)
@_expose(wasm, "workers_response_headers_copy")
#endif
@_cdecl("workers_response_headers_copy")
public func workers_response_headers_copy(_ handle: Int32, _ destination: UnsafeMutableRawPointer?) {
    WasmResponseStore.copyHeaders(for: handle, to: destination)
}

#if arch(wasm32)
@_expose(wasm, "workers_response_release")
#endif
@_cdecl("workers_response_release")
public func workers_response_release(_ handle: Int32) {
    WasmResponseStore.release(handle)
}
