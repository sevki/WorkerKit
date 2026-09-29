import SwiftSyntax
import SwiftSyntaxMacros

/// Expands `@DurableObject` on a top-level class into:
///
/// - a conformance to `DurableObject`, if the class does not declare one;
/// - the `workers_do:<Class>[:<rpc>,<rpc>…]` Wasm export. The shim calls it
///   to register the class, and `worker-build` reads its name to generate
///   the exported JavaScript class and its RPC methods;
/// - if the class declares exactly one property of type `WorkersActorSystem`
///   and does not already declare `__workerKitDistributedCall` itself,
///   the `@RPC` forwarder that hosts a distributed actor through it — see
///   `distributedHostPropertyName(in:)`.
public struct DurableObjectMacro: PeerMacro, MemberMacro, ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let classDecl = declaration.as(ClassDeclSyntax.self) else {
            throw MacroExpansionErrorMessage("@DurableObject can only be attached to a class")
        }
        guard context.lexicalContext.isEmpty else {
            throw MacroExpansionErrorMessage("@DurableObject must be attached to a top-level class")
        }

        let name = classDecl.name.text
        guard isJavaScriptIdentifier(name), !javaScriptReservedWords.contains(name) else {
            throw MacroExpansionErrorMessage(
                "@DurableObject class name \(name) must also be a JavaScript class name (ASCII letters, digits, _ and $)"
            )
        }
        var rpcMethods = classDecl.memberBlock.members
            .compactMap { $0.decl.as(FunctionDeclSyntax.self) }
            .filter { $0.attributes.contains(where: isRPCAttribute) }
        if let synthesized = synthesizedDistributedCallMethod(in: classDecl) {
            rpcMethods.append(synthesized)
        }
        if let invalid = rpcMethods.first(where: { !isJavaScriptIdentifier($0.name.text) }) {
            throw MacroExpansionErrorMessage(
                "@RPC method name \(invalid.name.text) must also be a JavaScript method name (ASCII letters, digits, _ and $)"
            )
        }
        if let message = rpcMethods.lazy.compactMap(unsupportedRPCParameter).first {
            throw MacroExpansionErrorMessage(message)
        }
        // RPC dispatches by name alone, so overloads cannot be told apart
        // (and would be duplicate keys in the generated table).
        var seen = Set<String>()
        if let duplicate = rpcMethods.first(where: { !seen.insert($0.name.text).inserted }) {
            throw MacroExpansionErrorMessage(
                "@RPC method \(duplicate.name.text) is overloaded; RPC methods are called by name, so each needs a unique name"
            )
        }
        // The generated JavaScript class defines these methods itself, and
        // its DurableObject base class sets `ctx` and `env` as instance
        // fields, which would hide methods of the same name.
        let reservedNames = [
            "constructor", "fetch", "alarm", "webSocketMessage", "webSocketClose", "webSocketError", "ctx", "env",
        ]
        if let reserved = rpcMethods.first(where: { reservedNames.contains($0.name.text) }) {
            throw MacroExpansionErrorMessage("@RPC method \(reserved.name.text) clashes with the Durable Object class's own \(reserved.name.text)")
        }

        let entries = rpcMethods.map { method in
            "\"\(method.name.text)\": { object, arguments in \(rpcCallBody(method, receiver: "object.")) },"
        }

        let exportName = rpcMethods.isEmpty
            ? "workers_do:\(name)"
            : "workers_do:\(name):\(rpcMethods.map(\.name.text).joined(separator: ","))"
        let table = entries.isEmpty ? "[:]" : "[\n        \(entries.joined(separator: "\n        "))\n    ]"

        return [
            """
            #if arch(wasm32)
            @_expose(wasm, "\(raw: exportName)")
            #endif
            @_cdecl("__workerKit_do_\(raw: name)")
            public func __workerKit_do_\(raw: name)() {
                WorkersRuntime.registerDurableObject(\(raw: name).self, name: "\(raw: name)", rpc: \(raw: table))
            }
            """,
        ]
    }

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard declaration.is(ClassDeclSyntax.self), !protocols.isEmpty else {
            return []
        }
        let conformances = protocols.map(\.trimmedDescription).joined(separator: ", ")
        return [try ExtensionDeclSyntax("extension \(type.trimmed): \(raw: conformances) {}")]
    }

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let classDecl = declaration.as(ClassDeclSyntax.self),
              let method = synthesizedDistributedCallMethod(in: classDecl) else {
            return []
        }
        return [DeclSyntax(method)]
    }
}

/// The name of the class's stored property of type `WorkersActorSystem`,
/// if it declares exactly one — the convention `@DurableObject` looks for
/// to auto-generate the `__workerKitDistributedCall` RPC forwarder that
/// hosts a distributed actor through it (see `WorkersActorSystem`'s
/// per-Durable-Object-id hosting). Ambiguous (zero or more than one match)
/// falls back to requiring the forwarder be written by hand, same as
/// before this convention existed.
private func distributedHostPropertyName(in classDecl: ClassDeclSyntax) -> String? {
    let candidates = classDecl.memberBlock.members.compactMap { member -> String? in
        guard let variable = member.decl.as(VariableDeclSyntax.self) else { return nil }
        for binding in variable.bindings {
            guard let type = binding.typeAnnotation?.type, type.trimmedDescription == "WorkersActorSystem",
                  let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
            return identifier.identifier.text
        }
        return nil
    }
    return candidates.count == 1 ? candidates[0] : nil
}

/// The `__workerKitDistributedCall` RPC forwarder for `classDecl`'s
/// `WorkersActorSystem` property (see `distributedHostPropertyName(in:)`),
/// or `nil` if the class doesn't have exactly one such property or already
/// declares the method itself.
///
/// Deliberately has no `@RPC` attribute of its own: the peer macro
/// expansion below adds it to `rpcMethods` directly, and a member macro's
/// synthesized declaration doesn't get the right `lexicalContext` if one of
/// its own attributes is itself a macro — the compiler re-expands `@RPC` on
/// it as if it were a top-level function (wrong `@_cdecl` target, spurious
/// Sendable/capture errors), not as a method of the class it's actually a
/// member of.
private func synthesizedDistributedCallMethod(in classDecl: ClassDeclSyntax) -> FunctionDeclSyntax? {
    let alreadyDeclared = classDecl.memberBlock.members.contains {
        $0.decl.as(FunctionDeclSyntax.self)?.name.text == WorkersActorSystemEntryPointName
    }
    guard !alreadyDeclared, let hostProperty = distributedHostPropertyName(in: classDecl) else {
        return nil
    }
    let source: DeclSyntax = """
        func \(raw: WorkersActorSystemEntryPointName)(
            _ identifier: String, _ arguments: JSValue, _ genericSubstitutions: [String]
        ) async throws -> JSValue {
            try await \(raw: hostProperty).receive(
                identifier: identifier, arguments: arguments, genericSubstitutions: genericSubstitutions
            )
        }
        """
    return source.as(FunctionDeclSyntax.self)
}

/// `WorkersActorSystem.entryPointName`'s value, duplicated here since the
/// macro target cannot import `WorkerKit` (that would be circular — this
/// package is what `WorkerKit` depends on for macro expansion).
private let WorkersActorSystemEntryPointName = "__workerKitDistributedCall"

/// `@RPC` marks a method callable by other workers:
///
/// - on a method of a `@DurableObject` class, through `DurableObjectStub.call`
///   (`@DurableObject` collects these methods);
/// - on a top-level function, through a service binding's `Fetcher.call`. It
///   then generates a `workers_rpc:<name>` export, and `worker-build` adds the
///   method to the worker's default `WorkerEntrypoint` class.
public struct RPCMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let function = declaration.as(FunctionDeclSyntax.self) else {
            throw MacroExpansionErrorMessage("@RPC can only be attached to a method")
        }
        if function.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class) }) {
            throw MacroExpansionErrorMessage("@RPC methods must be instance methods")
        }
        guard context.lexicalContext.isEmpty else {
            // A Durable Object method: @DurableObject registers it, but only
            // from the class body it is attached to.
            guard let enclosing = context.lexicalContext.first?.as(ClassDeclSyntax.self),
                  enclosing.attributes.contains(where: { isAttribute($0, named: "DurableObject") }) else {
                throw MacroExpansionErrorMessage("@RPC methods must be declared in the body of a @DurableObject class")
            }
            return []
        }

        let name = function.name.text
        guard isJavaScriptIdentifier(name) else {
            throw MacroExpansionErrorMessage(
                "@RPC function name \(name) must also be a JavaScript method name (ASCII letters, digits, _ and $)"
            )
        }
        if let message = unsupportedRPCParameter(function) {
            throw MacroExpansionErrorMessage(message)
        }
        // The generated WorkerEntrypoint class defines these itself.
        guard !["constructor", "fetch", "env", "ctx"].contains(name) else {
            throw MacroExpansionErrorMessage("@RPC function \(name) clashes with the WorkerEntrypoint class's own \(name)")
        }

        return [
            """
            #if arch(wasm32)
            @_expose(wasm, "workers_rpc:\(raw: name)")
            #endif
            @_cdecl("__workerKit_rpc_\(raw: name)")
            public func __workerKit_rpc_\(raw: name)() {
                WorkersRuntime.registerRPC(name: "\(raw: name)") { arguments in
                    \(raw: rpcCallBody(function, receiver: ""))
                }
            }
            """,
        ]
    }
}

/// The body of a closure `{ arguments in … }` that calls `method` on
/// `receiver` (for example `"object."`, or `""` for a free function) with
/// the JavaScript `arguments` converted to its parameter types, and returns
/// its result as a `JSValue`.
func rpcCallBody(_ method: FunctionDeclSyntax, receiver: String) -> String {
    let arguments = method.signature.parameterClause.parameters.enumerated().map { index, parameter in
        let value = "WorkersRuntime.rpcArgument(arguments, \(index), as: \(parameter.type.trimmedDescription).self)"
        return parameter.firstName.tokenKind == .wildcard ? value : "\(parameter.firstName.text): \(value)"
    }
    let effects = method.signature.effectSpecifiers
    // Converting arguments can throw, so a call with arguments needs `try`
    // even when the method does not throw.
    let needsTry = effects?.throwsClause != nil || !arguments.isEmpty
    let call = (needsTry ? "try " : "")
        + (effects?.asyncSpecifier != nil ? "await " : "")
        + "\(receiver)\(method.name.text)(\(arguments.joined(separator: ", ")))"
    let returnType = method.signature.returnClause?.type.trimmedDescription
    return returnType == nil || returnType == "Void" || returnType == "()"
        ? "\(call); return .undefined"
        : "return \(call).jsValue"
}

/// Why `method` cannot be called over RPC, if it cannot: the generated call
/// passes one JavaScript argument per parameter, by value.
func unsupportedRPCParameter(_ method: FunctionDeclSyntax) -> String? {
    for parameter in method.signature.parameterClause.parameters {
        if parameter.ellipsis != nil {
            return "@RPC method \(method.name.text) has a variadic parameter; take an array instead"
        }
        if parameter.defaultValue != nil {
            return "@RPC method \(method.name.text) has a default argument, which RPC cannot apply to an omitted argument; declare the parameter as an optional instead"
        }
        if let attributed = parameter.type.as(AttributedTypeSyntax.self),
           attributed.specifiers.contains(where: { $0.trimmedDescription == "inout" }) {
            return "@RPC method \(method.name.text) has an inout parameter, which RPC cannot pass back"
        }
    }
    return nil
}

/// Whether `element` is `@RPC`, including the qualified `@WorkerKit.RPC`.
private func isRPCAttribute(_ element: AttributeListSyntax.Element) -> Bool {
    isAttribute(element, named: "RPC")
}

/// Whether `element` is the attribute `@name`, qualified or not.
private func isAttribute(_ element: AttributeListSyntax.Element, named name: String) -> Bool {
    guard let attributeName = element.as(AttributeSyntax.self)?.attributeName else {
        return false
    }
    let lastComponent = attributeName.as(MemberTypeSyntax.self)?.name.text
        ?? attributeName.as(IdentifierTypeSyntax.self)?.name.text
    return lastComponent == name
}

/// Whether `name` is an ASCII JavaScript identifier, as `worker-build` needs
/// for the generated class and method names.
func isJavaScriptIdentifier(_ name: String) -> Bool {
    guard let first = name.utf8.first else {
        return false
    }
    func isLetter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "$")
    }
    return isLetter(first) && name.utf8.allSatisfy { isLetter($0) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
}

/// Words JavaScript does not allow as a class name.
let javaScriptReservedWords: Set<String> = [
    "arguments", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default",
    "delete", "do", "else", "enum", "eval", "export", "extends", "false", "finally", "for", "function",
    "if", "implements", "import", "in", "instanceof", "interface", "let", "new", "null", "package",
    "private", "protected", "public", "return", "static", "super", "switch", "this", "throw", "true",
    "try", "typeof", "var", "void", "while", "with", "yield",
]
