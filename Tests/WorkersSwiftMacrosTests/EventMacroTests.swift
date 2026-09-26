import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import WorkersSwiftMacros
import XCTest

private let macros: [String: any Macro.Type] = ["Event": EventMacro.self]

final class EventMacroTests: XCTestCase {
    func testFetchGeneratesRequestExport() {
        assertMacroExpansion(
            """
            @Event(.fetch)
            func fetch(_ request: WorkerRequest) -> WorkerResponse {
                WorkerResponse(status: 200, body: "ok")
            }
            """,
            expandedSource: """
            func fetch(_ request: WorkerRequest) -> WorkerResponse {
                WorkerResponse(status: 200, body: "ok")
            }

            #if arch(wasm32)
            @_expose(wasm, "workers_handle_request")
            #endif
            @_cdecl("workers_handle_request")
            public func __workersSwift_fetch(
                _ methodPointer: UnsafePointer<UInt8>?,
                _ methodLength: Int32,
                _ pathPointer: UnsafePointer<UInt8>?,
                _ pathLength: Int32
            ) -> Int32 {
                WorkersRuntime.handleRequest(methodPointer, methodLength, pathPointer, pathLength) { request in
                    fetch(request)
                }
            }
            """,
            macros: macros
        )
    }

    func testThrowingHandlerMapsErrorsTo500() {
        assertMacroExpansion(
            """
            @Event(.fetch)
            func handle(request: WorkerRequest) throws -> WorkerResponse {
                throw Failure()
            }
            """,
            expandedSource: """
            func handle(request: WorkerRequest) throws -> WorkerResponse {
                throw Failure()
            }

            #if arch(wasm32)
            @_expose(wasm, "workers_handle_request")
            #endif
            @_cdecl("workers_handle_request")
            public func __workersSwift_fetch(
                _ methodPointer: UnsafePointer<UInt8>?,
                _ methodLength: Int32,
                _ pathPointer: UnsafePointer<UInt8>?,
                _ pathLength: Int32
            ) -> Int32 {
                WorkersRuntime.handleRequest(methodPointer, methodLength, pathPointer, pathLength) { request in
                    do {
                        return try handle(request: request)
                    } catch {
                        return WorkerResponse(status: 500, body: "Internal Server Error")
                    }
                }
            }
            """,
            macros: macros
        )
    }

    func testRejectsAsyncHandler() {
        assertMacroExpansion(
            """
            @Event(.fetch)
            func fetch(_ request: WorkerRequest) async -> WorkerResponse {
                WorkerResponse(status: 200, body: "ok")
            }
            """,
            expandedSource: """
            func fetch(_ request: WorkerRequest) async -> WorkerResponse {
                WorkerResponse(status: 200, body: "ok")
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Event(.fetch) does not support async functions yet", line: 1, column: 1),
            ],
            macros: macros
        )
    }

    func testRejectsWrongArity() {
        assertMacroExpansion(
            """
            @Event(.fetch)
            func fetch() -> WorkerResponse {
                WorkerResponse(status: 200, body: "ok")
            }
            """,
            expandedSource: """
            func fetch() -> WorkerResponse {
                WorkerResponse(status: 200, body: "ok")
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Event(.fetch) requires a function of type (WorkerRequest) -> WorkerResponse",
                    line: 1,
                    column: 1
                ),
            ],
            macros: macros
        )
    }

    func testRejectsMethods() {
        assertMacroExpansion(
            """
            struct Worker {
                @Event(.fetch)
                func fetch(_ request: WorkerRequest) -> WorkerResponse {
                    WorkerResponse(status: 200, body: "ok")
                }
            }
            """,
            expandedSource: """
            struct Worker {
                func fetch(_ request: WorkerRequest) -> WorkerResponse {
                    WorkerResponse(status: 200, body: "ok")
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Event must be attached to a top-level function", line: 2, column: 5),
            ],
            macros: macros
        )
    }

    func testRejectsNonFunctions() {
        assertMacroExpansion(
            """
            @Event(.fetch)
            var handler = 1
            """,
            expandedSource: """
            var handler = 1
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Event can only be attached to a function", line: 1, column: 1),
            ],
            macros: macros
        )
    }
}
