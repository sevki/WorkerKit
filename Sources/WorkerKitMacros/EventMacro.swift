import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxMacros

/// Expands `@Event(.fetch)` on a top-level function into the `workers_js_main`
/// Wasm export, which the JavaScript shim calls once per isolate to register
/// the function as the worker's fetch handler.
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
        guard parameters.count == 3, signature.returnClause != nil else {
            throw MacroExpansionErrorMessage(
                "@Event(.fetch) requires a function of type (Request, Env, Context) async throws -> Response"
            )
        }

        let arguments = zip(parameters, ["request", "env", "context"]).map { parameter, value in
            parameter.firstName.tokenKind == .wildcard ? value : "\(parameter.firstName.text): \(value)"
        }
        let effects = signature.effectSpecifiers
        let call = (effects?.throwsClause != nil ? "try " : "")
            + (effects?.asyncSpecifier != nil ? "await " : "")
            + "\(function.name.text)(\(arguments.joined(separator: ", ")))"

        return [
            """
            #if arch(wasm32)
            @_expose(wasm, "workers_js_main")
            #endif
            @_cdecl("workers_js_main")
            public func __workerKit_main() {
                WorkersRuntime.registerFetch { request, env, context in
                    \(raw: call)
                }
            }
            """,
        ]
    }
}

@main
struct WorkerKitMacrosPlugin: CompilerPlugin {
    let providingMacros: [any Macro.Type] = [EventMacro.self, DurableObjectMacro.self, RPCMacro.self]
}
