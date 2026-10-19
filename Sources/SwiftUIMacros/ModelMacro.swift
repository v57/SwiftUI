import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// The SwiftData stand-in's `@Model`: makes a class observable the way `@Observable` does (stored properties go
/// through `@ObservationTracked`) and persistable: it writes its stored properties into a row and reads them back
/// (`_$encode()`, `init(_$row:)`). `@Transient` properties stay out of the row; `@Attribute(.unique)` ones are the
/// keys an insert replaces an existing model by.
public struct ModelMacro: MemberMacro, MemberAttributeMacro, ExtensionMacro {
    struct Property {
        let name: String
        let type: String?
        let initializer: String?
        let isTransient: Bool
        let isUnique: Bool
        var isOptional: Bool {
            guard let type else { return initializer == "nil" }
            return type.hasSuffix("?") || type.hasSuffix("!") || type.hasPrefix("Optional<")
        }
    }

    /// Stored instance `var`s (no accessors, not static, not ignored).
    static func properties(of declaration: some DeclGroupSyntax) -> [Property] {
        declaration.memberBlock.members.compactMap { member -> Property? in
            guard let variable = member.decl.as(VariableDeclSyntax.self), isTracked(variable),
                  let binding = variable.bindings.first, variable.bindings.count == 1,
                  let pattern = binding.pattern.as(IdentifierPatternSyntax.self)
            else { return nil }
            let attributes = variable.attributes.compactMap { $0.as(AttributeSyntax.self) }
            let names = attributes.map { $0.attributeName.trimmedDescription }
            let isUnique = attributes.contains { attribute in
                attribute.attributeName.trimmedDescription.hasSuffix("Attribute")
                    && (attribute.arguments?.trimmedDescription.contains(".unique") ?? false)
            }
            return Property(
                name: pattern.identifier.text, type: binding.typeAnnotation?.type.trimmedDescription,
                initializer: binding.initializer?.value.trimmedDescription,
                isTransient: names.contains { $0.hasSuffix("Transient") }, isUnique: isUnique)
        }
    }

    static func isTracked(_ variable: VariableDeclSyntax) -> Bool {
        guard variable.bindingSpecifier.tokenKind == .keyword(.var) else { return false }
        if variable.modifiers.contains(where: { ["static", "class", "lazy"].contains($0.name.text) }) { return false }
        let names = variable.attributes.compactMap { $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription }
        if names.contains(where: { $0.hasSuffix("ObservationIgnored") || $0.hasSuffix("ObservationTracked") }) { return false }
        guard let binding = variable.bindings.first else { return false }
        if let accessors = binding.accessorBlock {
            // willSet/didSet observers keep the property stored; get/set make it computed.
            if case .accessors(let list) = accessors.accessors {
                return list.allSatisfy { ["willSet", "didSet"].contains($0.accessorSpecifier.text) }
            }
            return false
        }
        return true
    }

    public static func expansion(
        of node: AttributeSyntax, providingMembersOf declaration: some DeclGroupSyntax, conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let type = declaration.as(ClassDeclSyntax.self)?.name.text else { return [] }
        let properties = properties(of: declaration)
        let persisted = properties.filter { !$0.isTransient }
        let encode = persisted.map { "row.set(\"\($0.name)\", self.\($0.name))" }.joined(separator: "\n")
        let decode = persisted.map { property -> String in
            if let initializer = property.initializer { return "self.\(property.name) = row.get(\"\(property.name)\") ?? (\(initializer))" }
            if property.isOptional { return "self.\(property.name) = row.get(\"\(property.name)\") ?? nil" }
            return "self.\(property.name) = row.require(\"\(property.name)\")"
        }.joined(separator: "\n")
        let unique = persisted.filter(\.isUnique).map { "\"\($0.name)\"" }.joined(separator: ", ")
        return [
            "@ObservationIgnored private let _$observationRegistrar = Observation.ObservationRegistrar()",
            """
            internal nonisolated func access<_Member>(keyPath: KeyPath<\(raw: type), _Member>) {
                _$observationRegistrar.access(self, keyPath: keyPath)
            }
            """,
            """
            internal nonisolated func withMutation<_Member, _MutationResult>(
                keyPath: KeyPath<\(raw: type), _Member>, _ mutation: () throws -> _MutationResult
            ) rethrows -> _MutationResult {
                _$backing.didChange()
                return try _$observationRegistrar.withMutation(of: self, keyPath: keyPath, mutation)
            }
            """,
            "private nonisolated func shouldNotifyObservers<_Member>(_ lhs: _Member, _ rhs: _Member) -> Bool { true }",
            "private nonisolated func shouldNotifyObservers<_Member: Equatable>(_ lhs: _Member, _ rhs: _Member) -> Bool { lhs != rhs }",
            "private nonisolated func shouldNotifyObservers<_Member: AnyObject>(_ lhs: _Member, _ rhs: _Member) -> Bool { lhs !== rhs }",
            "private nonisolated func shouldNotifyObservers<_Member: Equatable & AnyObject>(_ lhs: _Member, _ rhs: _Member) -> Bool { lhs != rhs }",
            "@ObservationIgnored public nonisolated let _$backing = SwiftData._ModelBacking()",
            "public nonisolated static var _$entityName: String { \"\(raw: type)\" }",
            "public nonisolated static var _$uniqueKeys: [String] { [\(raw: unique)] }",
            """
            public func _$encode() -> SwiftData._ModelRow {
                var row = SwiftData._ModelRow()
                \(raw: encode)
                return row
            }
            """,
            """
            public required init(_$row row: SwiftData._ModelRow) {
                \(raw: decode)
            }
            """,
        ]
    }

    public static func expansion(
        of node: AttributeSyntax, attachedTo declaration: some DeclGroupSyntax, providingAttributesFor member: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AttributeSyntax] {
        guard let variable = member.as(VariableDeclSyntax.self), isTracked(variable) else { return [] }
        return ["@ObservationTracked"]
    }

    public static func expansion(
        of node: AttributeSyntax, attachedTo declaration: some DeclGroupSyntax, providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax], in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        [
            try ExtensionDeclSyntax("extension \(type.trimmed): nonisolated Observation.Observable {}"),
            try ExtensionDeclSyntax("extension \(type.trimmed): SwiftData.PersistentModel {}"),
        ]
    }
}

/// `@Attribute`, `@Relationship`, `@Transient`: markers `@Model` reads; they add nothing themselves.
public struct ModelMarkerMacro: PeerMacro {
    public static func expansion(of node: AttributeSyntax, providingPeersOf declaration: some DeclSyntaxProtocol, in context: some MacroExpansionContext) throws -> [DeclSyntax] { [] }
}
