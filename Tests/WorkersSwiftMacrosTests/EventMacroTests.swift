import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import WorkersSwiftMacros
import XCTest

private let macros: [String: any Macro.Type] = ["Event": EventMacro.self]

final class EventMacroTests: XCTestCase {
    func testAsyncThrowingFetchRegistersHandler() {
        assertMacroExpansion(
            """
            @Event(.fetch)
            func fetch(req: Request, env: Env, ctx: Context) async throws -> Response {
                .ok("hi")
            }
            """,
            expandedSource: """
            func fetch(req: Request, env: Env, ctx: Context) async throws -> Response {
                .ok("hi")
            }

            #if arch(wasm32)
            @_expose(wasm, "workers_js_main")
            #endif
            @_cdecl("workers_js_main")
            public func __workersSwift_main() {
                WorkersRuntime.registerFetch { request, env, context in
                    try await fetch(req: request, env: env, ctx: context)
                }
            }
            """,
            macros: macros
        )
    }

    func testSynchronousUnlabeledHandler() {
        assertMacroExpansion(
            """
            @Event(.fetch)
            func handle(_ request: Request, _ env: Env, _ context: Context) -> Response {
                .ok("hi")
            }
            """,
            expandedSource: """
            func handle(_ request: Request, _ env: Env, _ context: Context) -> Response {
                .ok("hi")
            }

            #if arch(wasm32)
            @_expose(wasm, "workers_js_main")
            #endif
            @_cdecl("workers_js_main")
            public func __workersSwift_main() {
                WorkersRuntime.registerFetch { request, env, context in
                    handle(request, env, context)
                }
            }
            """,
            macros: macros
        )
    }

    func testRejectsWrongArity() {
        assertMacroExpansion(
            """
            @Event(.fetch)
            func fetch(req: Request) -> Response {
                .ok("hi")
            }
            """,
            expandedSource: """
            func fetch(req: Request) -> Response {
                .ok("hi")
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Event(.fetch) requires a function of type (Request, Env, Context) async throws -> Response",
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
                func fetch(req: Request, env: Env, ctx: Context) -> Response {
                    .ok("hi")
                }
            }
            """,
            expandedSource: """
            struct Worker {
                func fetch(req: Request, env: Env, ctx: Context) -> Response {
                    .ok("hi")
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
