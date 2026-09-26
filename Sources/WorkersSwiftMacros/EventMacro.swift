import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxMacros

/// Expands `@Event(.fetch)` on a top-level function into the
/// `workers_handle_request` Wasm export that worker.mjs calls for each request.
public struct EventMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let function = declaration.as(FunctionDeclSyntax.self) else {
            throw MacroExpansionErrorMessage("@Event can only be attached to a function")
        }
        guard context.lexicalContext.isEmpty else {
            throw MacroExpansionErrorMessage("@Event must be attached to a top-level function")
        }

        let event = node.arguments?.as(LabeledExprListSyntax.self)?.first?
            .expression.as(MemberAccessExprSyntax.self)?.declName.baseName.text
        guard event == "fetch" else {
            throw MacroExpansionErrorMessage("@Event supports only .fetch")
        }

        let signature = function.signature
        let parameters = Array(signature.parameterClause.parameters)
        guard parameters.count == 1, let parameter = parameters.first, signature.returnClause != nil else {
            throw MacroExpansionErrorMessage(
                "@Event(.fetch) requires a function of type (WorkerRequest) -> WorkerResponse"
            )
        }
        if signature.effectSpecifiers?.asyncSpecifier != nil {
            throw MacroExpansionErrorMessage("@Event(.fetch) does not support async functions yet")
        }

        let label = parameter.firstName.tokenKind == .wildcard ? "" : "\(parameter.firstName.text): "
        let call = "\(function.name.text)(\(label)request)"
        let handler = signature.effectSpecifiers?.throwsClause == nil
            ? call
            : "do { return try \(call) } catch { return WorkerResponse(status: 500, body: \"Internal Server Error\") }"

        return [
            """
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
                    \(raw: handler)
                }
            }
            """,
        ]
    }
}

@main
struct WorkersSwiftMacrosPlugin: CompilerPlugin {
    let providingMacros: [any Macro.Type] = [EventMacro.self]
}
