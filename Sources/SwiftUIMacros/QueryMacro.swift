import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@Query(…) var items: [Item]`, as SwiftData's macro: a computed property over a generated `_items` holding the
/// `Query<Item, [Item]>(…)`. The backing value has its type spelled out, so a bare `@Query` needs no inference and
/// the property never appears in a memberwise initializer.
public struct QueryMacro: AccessorMacro, PeerMacro {
    static func binding(_ declaration: some DeclSyntaxProtocol) -> (name: String, type: TypeSyntax)? {
        guard let variable = declaration.as(VariableDeclSyntax.self), let binding = variable.bindings.first,
              let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
              let type = binding.typeAnnotation?.type else { return nil }
        return (pattern.identifier.text, type)
    }

    /// `[Item]` or `Array<Item>` → `Item`.
    static func element(of type: TypeSyntax) -> String? {
        if let array = type.as(ArrayTypeSyntax.self) { return array.element.trimmedDescription }
        if let generic = type.as(IdentifierTypeSyntax.self), generic.name.text == "Array",
           let argument = generic.genericArgumentClause?.arguments.first {
            return argument.argument.trimmedDescription
        }
        return nil
    }

    public static func expansion(of node: AttributeSyntax, providingAccessorsOf declaration: some DeclSyntaxProtocol, in context: some MacroExpansionContext) throws -> [AccessorDeclSyntax] {
        guard let (name, _) = binding(declaration) else { return [] }
        return ["get { _\(raw: name).wrappedValue }"]
    }

    public static func expansion(of node: AttributeSyntax, providingPeersOf declaration: some DeclSyntaxProtocol, in context: some MacroExpansionContext) throws -> [DeclSyntax] {
        guard let (name, type) = binding(declaration), let element = element(of: type) else { return [] }
        let arguments = node.arguments?.trimmedDescription ?? ""
        return ["private let _\(raw: name) = Query<\(raw: element), \(raw: type.trimmedDescription)>(\(raw: arguments))"]
    }
}
