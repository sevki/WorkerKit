import SwiftSyntax
import SwiftSyntaxMacros

/// Expands `@DurableObject` on a top-level class into:
///
/// - a conformance to `DurableObject`, if the class does not declare one;
/// - the `workers_do:<Class>[:<rpc>,<rpc>…]` Wasm export. The shim calls it
///   to register the class, and `worker-build` reads its name to generate
///   the exported JavaScript class and its RPC methods.
public struct DurableObjectMacro: PeerMacro, ExtensionMacro {
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
        let rpcMethods = classDecl.memberBlock.members
            .compactMap { $0.decl.as(FunctionDeclSyntax.self) }
            .filter { $0.attributes.contains(where: isRPCAttribute) }
        if let invalid = rpcMethods.first(where: { !isJavaScriptIdentifier($0.name.text) }) {
            throw MacroExpansionErrorMessage(
                "@RPC method name \(invalid.name.text) must also be a JavaScript method name (ASCII letters, digits, _ and $)"
            )
        }
        // The generated JavaScript class defines these itself.
        if let reserved = rpcMethods.first(where: { ["constructor", "fetch", "alarm"].contains($0.name.text) }) {
            throw MacroExpansionErrorMessage("@RPC method \(reserved.name.text) clashes with the Durable Object class's own \(reserved.name.text)")
        }

        let entries = rpcMethods.map { method in
            let arguments = method.signature.parameterClause.parameters.enumerated().map { index, parameter in
                let value = "WorkersRuntime.rpcArgument(arguments, \(index), as: \(parameter.type.trimmedDescription).self)"
                return parameter.firstName.tokenKind == .wildcard ? value : "\(parameter.firstName.text): \(value)"
            }
            let effects = method.signature.effectSpecifiers
            // Converting arguments can throw, so a call with arguments needs
            // `try` even when the method does not throw.
            let needsTry = effects?.throwsClause != nil || !arguments.isEmpty
            let call = (needsTry ? "try " : "")
                + (effects?.asyncSpecifier != nil ? "await " : "")
                + "object.\(method.name.text)(\(arguments.joined(separator: ", ")))"
            let returnType = method.signature.returnClause?.type.trimmedDescription
            let body = returnType == nil || returnType == "Void" || returnType == "()"
                ? "\(call); return .undefined"
                : "return \(call).jsValue"
            return "\"\(method.name.text)\": { object, arguments in \(body) },"
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
            @_cdecl("__workersSwift_do_\(raw: name)")
            public func __workersSwift_do_\(raw: name)() {
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
}

/// `@RPC` marks a Durable Object method as callable through
/// `DurableObjectStub.call`; `@DurableObject` collects the marked methods.
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
        return []
    }
}

private func isRPCAttribute(_ element: AttributeListSyntax.Element) -> Bool {
    element.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "RPC"
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
