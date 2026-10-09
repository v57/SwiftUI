import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@Entry var name: Type = default` inside `extension EnvironmentValues` (or `Transaction`,
/// `FocusedValues`, `ContainerValues`): a computed property backed by a generated key.
public struct EntryMacro: AccessorMacro, PeerMacro {
    static func names(_ declaration: some DeclSyntaxProtocol) -> (name: String, type: String?, value: String?)? {
        guard let variable = declaration.as(VariableDeclSyntax.self), let binding = variable.bindings.first,
              let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { return nil }
        return (pattern.identifier.text, binding.typeAnnotation?.type.trimmedDescription, binding.initializer?.value.trimmedDescription)
    }

    static func keyProtocol(in context: some MacroExpansionContext) -> String {
        for node in context.lexicalContext {
            if let ext = node.as(ExtensionDeclSyntax.self) {
                switch ext.extendedType.trimmedDescription.split(separator: ".").last.map(String.init) {
                case "Transaction": return "TransactionKey"
                case "FocusedValues": return "FocusedValueKey"
                case "ContainerValues": return "ContainerValueKey"
                default: return "EnvironmentKey"
                }
            }
        }
        return "EnvironmentKey"
    }

    public static func expansion(of node: AttributeSyntax, providingAccessorsOf declaration: some DeclSyntaxProtocol, in context: some MacroExpansionContext) throws -> [AccessorDeclSyntax] {
        guard let (name, _, _) = names(declaration) else { return [] }
        return [
            "get { self[__Key_\(raw: name).self] }",
            "set { self[__Key_\(raw: name).self] = newValue }",
        ]
    }

    public static func expansion(of node: AttributeSyntax, providingPeersOf declaration: some DeclSyntaxProtocol, in context: some MacroExpansionContext) throws -> [DeclSyntax] {
        guard let (name, type, value) = names(declaration) else { return [] }
        let keyProtocol = keyProtocol(in: context)
        let valueType = type ?? "_"
        let defaultValue = value ?? "nil"
        if keyProtocol == "FocusedValueKey" {
            return ["private struct __Key_\(raw: name): \(raw: keyProtocol) { typealias Value = \(raw: valueType.hasSuffix("?") ? String(valueType.dropLast()) : valueType) }"]
        }
        if type == nil {
            // Type inferred from the default value.
            return ["private struct __Key_\(raw: name): \(raw: keyProtocol) { nonisolated(unsafe) static let defaultValue = \(raw: defaultValue) }"]
        }
        return ["private struct __Key_\(raw: name): \(raw: keyProtocol) { static var defaultValue: \(raw: valueType) { \(raw: defaultValue) } }"]
    }
}

/// `#Preview { ... }` compiles to nothing (previews are an Xcode feature).
public struct PreviewMacro: DeclarationMacro {
    public static func expansion(of node: some FreestandingMacroExpansionSyntax, in context: some MacroExpansionContext) throws -> [DeclSyntax] { [] }
}

@main
struct SwiftUI2MacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [EntryMacro.self, PreviewMacro.self]
}
