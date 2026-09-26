import Testing
@testable import WorkersSwift
@testable import WorkersSwiftWasm

@Test func rootRequestReturnsHelloMessage() async throws {
    let response = fetch(.init(method: "GET", path: "/"))

    #expect(response.status == 200)
    #expect(response.body == "Hello from Swift on workerd/celld")
    #expect(response.headers["content-type"] == "text/plain; charset=utf-8")
}

@Test func healthRequestReturnsOk() async throws {
    let response = fetch(.init(method: "GET", path: "/health"))

    #expect(response.status == 200)
    #expect(response.body == "ok")
}

@Test func unknownRouteReturnsNotFound() async throws {
    let response = fetch(.init(method: "POST", path: "/missing"))

    #expect(response.status == 404)
    #expect(response.body == "Not Found")
}

@Test func lowercaseMethodStillMatchesRoute() async throws {
    let response = fetch(.init(method: "get", path: "/health"))

    #expect(response.status == 200)
    #expect(response.body == "ok")
}

@Test func mixedCaseNonGetMethodStillMissesGetRoute() async throws {
    let response = fetch(.init(method: "PoSt", path: "/health"))

    #expect(response.status == 404)
    #expect(response.body == "Not Found")
}

@Test func wasmRequestExportsRoundTripResponseBody() async throws {
    let method = Array("GET".utf8)
    let path = Array("/".utf8)

    let handle = method.withUnsafeBufferPointer { methodBuffer in
        path.withUnsafeBufferPointer { pathBuffer in
            __workersSwift_fetch(
                methodBuffer.baseAddress,
                Int32(methodBuffer.count),
                pathBuffer.baseAddress,
                Int32(pathBuffer.count)
            )
        }
    }

    #expect(workers_response_status(handle) == 200)
    let bodyLength = workers_response_body_len(handle)
    #expect(bodyLength == Int32("Hello from Swift on workerd/celld".utf8.count))

    let bodyPointer = workers_alloc(bodyLength, 1)
    #expect(bodyPointer != nil)

    workers_response_body_copy(handle, bodyPointer)

    let body = String(
        decoding: UnsafeBufferPointer(
            start: bodyPointer?.assumingMemoryBound(to: UInt8.self),
            count: Int(bodyLength)
        ),
        as: UTF8.self
    )

    #expect(body == "Hello from Swift on workerd/celld")

    workers_free(bodyPointer, bodyLength, 1)
    workers_response_release(handle)
    #expect(workers_response_status(handle) == 500)
}

@Test func wasmAllocatorRejectsNegativeSizesAndSupportsEmptyBuffers() async throws {
    #expect(workers_alloc(-1, 1) == nil)

    let empty = workers_alloc(0, 1)
    #expect(empty != nil)
    workers_free(empty, 0, 1)
}

@Test func wasmAllocatorRejectsInvalidAlignment() async throws {
    #expect(workers_alloc(4, 3) == nil)
}

@Test func wasmRequestRejectsNegativeLengths() async throws {
    let method = Array("GET".utf8)

    let handle = method.withUnsafeBufferPointer { methodBuffer in
        __workersSwift_fetch(methodBuffer.baseAddress, -1, nil, 0)
    }

    #expect(handle == 0)
}

@Test func wasmStoreFallsBackForOutOfRangeStatus() async throws {
    let handle = WasmResponseStore.store(WorkerResponse(status: Int(Int32.max) + 1, body: "boom"))

    #expect(workers_response_status(handle) == 500)
    let bodyLength = workers_response_body_len(handle)
    let bodyPointer = workers_alloc(bodyLength, 1)
    #expect(bodyPointer != nil)

    workers_response_body_copy(handle, bodyPointer)

    let body = String(
        decoding: UnsafeBufferPointer(
            start: bodyPointer?.assumingMemoryBound(to: UInt8.self),
            count: Int(bodyLength)
        ),
        as: UTF8.self
    )

    #expect(body == "Response status out of range for ABI")

    workers_free(bodyPointer, bodyLength, 1)
    workers_response_release(handle)
}

@Test func wasmHandleGenerationSkipsZeroOnWraparound() async throws {
    #expect(WasmResponseStore.nextValidHandle(after: .max) == 1)
}

@Test func wasmRequestRejectsMissingPointerForPositiveLength() async throws {
    #expect(__workersSwift_fetch(nil, 1, nil, 0) == 0)
}

@Test func wasmRequestRejectsInvalidUtf8() async throws {
    let invalidMethod: [UInt8] = [0xFF]

    let handle = invalidMethod.withUnsafeBufferPointer { methodBuffer in
        __workersSwift_fetch(methodBuffer.baseAddress, Int32(methodBuffer.count), nil, 0)
    }

    #expect(handle == 0)
}

@Test func wasmRequestAllowsMissingZeroLengthBuffers() async throws {
    let handle = __workersSwift_fetch(nil, 0, nil, 0)

    #expect(handle > 0)
    #expect(workers_response_status(handle) == 404)
    workers_response_release(handle)
}

@Test func runtimePassesDecodedRequestToHandler() async throws {
    let method = Array("PATCH".utf8)
    let path = Array("/caf\u{e9}".utf8)

    let handle = method.withUnsafeBufferPointer { methodBuffer in
        path.withUnsafeBufferPointer { pathBuffer in
            WorkersRuntime.handleRequest(
                methodBuffer.baseAddress,
                Int32(methodBuffer.count),
                pathBuffer.baseAddress,
                Int32(pathBuffer.count)
            ) { request in
                WorkerResponse(status: 201, body: "\(request.method) \(request.path)")
            }
        }
    }

    #expect(workers_response_status(handle) == 201)
    #expect(workers_response_body_len(handle) == Int32("PATCH /caf\u{e9}".utf8.count))
    workers_response_release(handle)
}

private func copiedHeaders(_ handle: Int32) -> [String: String] {
    let length = Int(workers_response_headers_len(handle))
    var bytes = [UInt8](repeating: 0, count: length)
    bytes.withUnsafeMutableBytes { workers_response_headers_copy(handle, $0.baseAddress) }

    let parts = bytes.split(separator: 0, omittingEmptySubsequences: false).map {
        String(decoding: $0, as: UTF8.self)
    }
    var headers: [String: String] = [:]
    for index in stride(from: 0, to: parts.count - 1, by: 2) {
        headers[parts[index]] = parts[index + 1]
    }
    return headers
}

@Test func wasmStoreForwardsResponseHeaders() async throws {
    let handle = WasmResponseStore.store(WorkerResponse(
        status: 302,
        headers: ["location": "/next", "cache-control": "no-store"],
        body: ""
    ))

    #expect(workers_response_status(handle) == 302)
    #expect(copiedHeaders(handle) == ["location": "/next", "cache-control": "no-store"])
    workers_response_release(handle)
}

@Test(arguments: [0, 101, 199, 600, 1000])
func wasmStoreRejectsStatusesResponseCannotRepresent(status: Int) async throws {
    let handle = WasmResponseStore.store(WorkerResponse(status: status, body: "boom"))

    #expect(workers_response_status(handle) == 500)
    #expect(copiedHeaders(handle) == ["content-type": "text/plain; charset=utf-8"])
    workers_response_release(handle)
}

@Test func wasmStoreRejectsHeadersContainingNul() async throws {
    let handle = WasmResponseStore.store(WorkerResponse(status: 200, headers: ["x-bad": "a\u{0}b"], body: "ok"))

    #expect(workers_response_status(handle) == 500)
    workers_response_release(handle)
}
