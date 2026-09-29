import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import WorkerKitMacros
import XCTest

private let macros: [String: any Macro.Type] = [
    "Event": EventMacro.self,
    "DurableObject": DurableObjectMacro.self,
    "RPC": RPCMacro.self,
]

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
            public func __workerKit_main() {
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
            public func __workerKit_main() {
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

    func testDurableObjectWithoutRPCMethods() {
        assertMacroExpansion(
            """
            @DurableObject
            final class Room {
                init(state: DurableObjectState, env: Env) {
                }
            }
            """,
            expandedSource: """
            final class Room {
                init(state: DurableObjectState, env: Env) {
                }
            }

            #if arch(wasm32)
            @_expose(wasm, "workers_do:Room")
            #endif
            @_cdecl("__workerKit_do_Room")
            public func __workerKit_do_Room() {
                WorkersRuntime.registerDurableObject(Room.self, name: "Room", rpc: [:])
            }
            """,
            macros: macros
        )
    }

    func testDurableObjectListsRPCMethodsInExportName() {
        assertMacroExpansion(
            """
            @DurableObject
            final class Counter {
                @RPC func increment(by amount: Int) async throws -> Int {
                    amount
                }

                @RPC func reset() {
                }

                func helper() {
                }
            }
            """,
            expandedSource: """
            final class Counter {
                func increment(by amount: Int) async throws -> Int {
                    amount
                }

                func reset() {
                }

                func helper() {
                }
            }

            #if arch(wasm32)
            @_expose(wasm, "workers_do:Counter:increment,reset")
            #endif
            @_cdecl("__workerKit_do_Counter")
            public func __workerKit_do_Counter() {
                WorkersRuntime.registerDurableObject(Counter.self, name: "Counter", rpc: [
                    "increment": { object, arguments in
                                    return try await object.increment(by: WorkersRuntime.rpcArgument(arguments, 0, as: Int.self)).jsValue
                                },
                    "reset": { object, arguments in
                                    object.reset();
                                    return .undefined
                                },
                ])
            }
            """,
            macros: macros
        )
    }

    func testDurableObjectRejectsNonClasses() {
        assertMacroExpansion(
            """
            @DurableObject
            struct Counter {
            }
            """,
            expandedSource: """
            struct Counter {
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@DurableObject can only be attached to a class", line: 1, column: 1),
            ],
            macros: macros
        )
    }

    func testRPCRejectsStaticMethods() {
        assertMacroExpansion(
            """
            @RPC static func make() {
            }
            """,
            expandedSource: """
            static func make() {
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@RPC methods must be instance methods", line: 1, column: 1),
            ],
            macros: macros
        )
    }

    func testDurableObjectRejectsNamesJavaScriptCannotUse() {
        assertMacroExpansion(
            """
            @DurableObject
            final class Café {
            }
            """,
            expandedSource: """
            final class Café {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@DurableObject class name Café must also be a JavaScript class name (ASCII letters, digits, _ and $)",
                    line: 1,
                    column: 1
                ),
            ],
            macros: macros
        )
    }

    func testTopLevelRPCRegistersEntrypointMethod() {
        assertMacroExpansion(
            """
            @RPC func add(_ a: Int, _ b: Int) -> Int {
                a + b
            }
            """,
            expandedSource: """
            func add(_ a: Int, _ b: Int) -> Int {
                a + b
            }

            #if arch(wasm32)
            @_expose(wasm, "workers_rpc:add")
            #endif
            @_cdecl("__workerKit_rpc_add")
            public func __workerKit_rpc_add() {
                WorkersRuntime.registerRPC(name: "add") { arguments in
                    return try add(WorkersRuntime.rpcArgument(arguments, 0, as: Int.self), WorkersRuntime.rpcArgument(arguments, 1, as: Int.self)).jsValue
                }
            }
            """,
            macros: macros
        )
    }

    func testTopLevelRPCRejectsEntrypointNames() {
        assertMacroExpansion(
            """
            @RPC func fetch() {
            }
            """,
            expandedSource: """
            func fetch() {
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@RPC function fetch clashes with the WorkerEntrypoint class's own fetch", line: 1, column: 1),
            ],
            macros: macros
        )
    }

    func testDurableObjectCollectsQualifiedRPCAttributes() {
        assertMacroExpansion(
            """
            @DurableObject
            final class Room {
                @WorkerKit.RPC func ping() {
                }
            }
            """,
            expandedSource: """
            final class Room {
                @WorkerKit.RPC func ping() {
                }
            }

            #if arch(wasm32)
            @_expose(wasm, "workers_do:Room:ping")
            #endif
            @_cdecl("__workerKit_do_Room")
            public func __workerKit_do_Room() {
                WorkersRuntime.registerDurableObject(Room.self, name: "Room", rpc: [
                    "ping": { object, arguments in
                                    object.ping();
                                    return .undefined
                                },
                ])
            }
            """,
            macros: macros
        )
    }

    func testRPCRejectsMethodsOutsideDurableObjects() {
        assertMacroExpansion(
            """
            final class Plain {
                @RPC func ping() {
                }
            }
            """,
            expandedSource: """
            final class Plain {
                func ping() {
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@RPC methods must be declared in the body of a @DurableObject class", line: 2, column: 5),
            ],
            macros: macros
        )
    }

    func testDurableObjectRejectsInheritedFieldNames() {
        assertMacroExpansion(
            """
            @DurableObject
            final class Room {
                @RPC func env() {
                }
            }
            """,
            expandedSource: """
            final class Room {
                func env() {
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@RPC method env clashes with the Durable Object class's own env", line: 1, column: 1),
            ],
            macros: macros
        )
    }

    func testDurableObjectRejectsOverloadedRPCMethods() {
        assertMacroExpansion(
            """
            @DurableObject
            final class Directory {
                @RPC func lookup(_ id: Int) {
                }

                @RPC func lookup(_ name: String) {
                }
            }
            """,
            expandedSource: """
            final class Directory {
                func lookup(_ id: Int) {
                }

                func lookup(_ name: String) {
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@RPC method lookup is overloaded; RPC methods are called by name, so each needs a unique name",
                    line: 1,
                    column: 1
                ),
            ],
            macros: macros
        )
    }

    func testDurableObjectRejectsVariadicRPCParameters() {
        assertMacroExpansion(
            """
            @DurableObject
            final class Adder {
                @RPC func sum(_ values: Int...) {
                }
            }
            """,
            expandedSource: """
            final class Adder {
                func sum(_ values: Int...) {
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@RPC method sum has a variadic parameter; take an array instead", line: 1, column: 1),
            ],
            macros: macros
        )
    }

    func testTopLevelRPCRejectsInoutParameters() {
        assertMacroExpansion(
            """
            @RPC func bump(_ value: inout Int) {
            }
            """,
            expandedSource: """
            func bump(_ value: inout Int) {
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@RPC method bump has an inout parameter, which RPC cannot pass back", line: 1, column: 1),
            ],
            macros: macros
        )
    }

    func testDurableObjectSynthesizesDistributedCallForwarder() {
        assertMacroExpansion(
            """
            @DurableObject
            final class CounterObject {
                let hostSystem: WorkersActorSystem
                let counter: Counter

                init(state: DurableObjectState, env: Env) {
                    let hostSystem = WorkersActorSystem()
                    self.hostSystem = hostSystem
                    counter = hostSystem.host(state.id) { Counter(actorSystem: $0) }
                }
            }
            """,
            expandedSource: """
            final class CounterObject {
                let hostSystem: WorkersActorSystem
                let counter: Counter

                init(state: DurableObjectState, env: Env) {
                    let hostSystem = WorkersActorSystem()
                    self.hostSystem = hostSystem
                    counter = hostSystem.host(state.id) { Counter(actorSystem: $0) }
                }

                func __workerKitDistributedCall(
                    _ identifier: String, _ arguments: JSValue, _ genericSubstitutions: [String]
                ) async throws -> JSValue {
                    try await hostSystem.receive(
                        identifier: identifier, arguments: arguments, genericSubstitutions: genericSubstitutions
                    )
                }
            }

            #if arch(wasm32)
            @_expose(wasm, "workers_do:CounterObject:__workerKitDistributedCall")
            #endif
            @_cdecl("__workerKit_do_CounterObject")
            public func __workerKit_do_CounterObject() {
                WorkersRuntime.registerDurableObject(CounterObject.self, name: "CounterObject", rpc: [
                    "__workerKitDistributedCall": { object, arguments in
                                    return try await object.__workerKitDistributedCall(WorkersRuntime.rpcArgument(arguments, 0, as: String.self), WorkersRuntime.rpcArgument(arguments, 1, as: JSValue.self), WorkersRuntime.rpcArgument(arguments, 2, as: [String].self)).jsValue
                                },
                ])
            }
            """,
            macros: macros
        )
    }

    func testDurableObjectSkipsForwarderWithoutActorSystemProperty() {
        assertMacroExpansion(
            """
            @DurableObject
            final class Plain {
                init(state: DurableObjectState, env: Env) {
                }
            }
            """,
            expandedSource: """
            final class Plain {
                init(state: DurableObjectState, env: Env) {
                }
            }

            #if arch(wasm32)
            @_expose(wasm, "workers_do:Plain")
            #endif
            @_cdecl("__workerKit_do_Plain")
            public func __workerKit_do_Plain() {
                WorkersRuntime.registerDurableObject(Plain.self, name: "Plain", rpc: [:])
            }
            """,
            macros: macros
        )
    }

    func testDurableObjectSkipsForwarderWithAmbiguousActorSystemProperties() {
        assertMacroExpansion(
            """
            @DurableObject
            final class TwoSystems {
                let hostSystem: WorkersActorSystem
                let otherSystem: WorkersActorSystem
            }
            """,
            expandedSource: """
            final class TwoSystems {
                let hostSystem: WorkersActorSystem
                let otherSystem: WorkersActorSystem
            }

            #if arch(wasm32)
            @_expose(wasm, "workers_do:TwoSystems")
            #endif
            @_cdecl("__workerKit_do_TwoSystems")
            public func __workerKit_do_TwoSystems() {
                WorkersRuntime.registerDurableObject(TwoSystems.self, name: "TwoSystems", rpc: [:])
            }
            """,
            macros: macros
        )
    }

    func testDurableObjectDoesNotDuplicateHandWrittenForwarder() {
        assertMacroExpansion(
            """
            @DurableObject
            final class CounterObject {
                let hostSystem: WorkersActorSystem

                @RPC func __workerKitDistributedCall(
                    _ identifier: String, _ arguments: JSValue, _ genericSubstitutions: [String]
                ) async throws -> JSValue {
                    try await hostSystem.receive(
                        identifier: identifier, arguments: arguments, genericSubstitutions: genericSubstitutions
                    )
                }
            }
            """,
            expandedSource: """
            final class CounterObject {
                let hostSystem: WorkersActorSystem

                func __workerKitDistributedCall(
                    _ identifier: String, _ arguments: JSValue, _ genericSubstitutions: [String]
                ) async throws -> JSValue {
                    try await hostSystem.receive(
                        identifier: identifier, arguments: arguments, genericSubstitutions: genericSubstitutions
                    )
                }
            }

            #if arch(wasm32)
            @_expose(wasm, "workers_do:CounterObject:__workerKitDistributedCall")
            #endif
            @_cdecl("__workerKit_do_CounterObject")
            public func __workerKit_do_CounterObject() {
                WorkersRuntime.registerDurableObject(CounterObject.self, name: "CounterObject", rpc: [
                    "__workerKitDistributedCall": { object, arguments in
                                    return try await object.__workerKitDistributedCall(WorkersRuntime.rpcArgument(arguments, 0, as: String.self), WorkersRuntime.rpcArgument(arguments, 1, as: JSValue.self), WorkersRuntime.rpcArgument(arguments, 2, as: [String].self)).jsValue
                                },
                ])
            }
            """,
            macros: macros
        )
    }

    func testTopLevelRPCRejectsDefaultArguments() {
        assertMacroExpansion(
            """
            @RPC func greet(_ name: String = "world") {
            }
            """,
            expandedSource: """
            func greet(_ name: String = "world") {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@RPC method greet has a default argument, which RPC cannot apply to an omitted argument; declare the parameter as an optional instead",
                    line: 1,
                    column: 1
                ),
            ],
            macros: macros
        )
    }
}
