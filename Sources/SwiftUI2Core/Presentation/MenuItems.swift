import Foundation

// Menu content (menu bar commands, Menu, context menus) described as native menu items: backends
// build NSMenu / GMenu / ... from these. Content is read statically from the view values (Button,
// Toggle, Picker, Menu, Divider, Section, ForEach, conditionals, shortcut/disabled modifiers).

public indirect enum MenuItem {
    case button(title: String, systemImage: String?, shortcut: KeyboardShortcut?, isEnabled: Bool, isDestructive: Bool, action: @MainActor () -> Void)
    case toggle(title: String, isOn: Bool, shortcut: KeyboardShortcut?, isEnabled: Bool, set: @MainActor (Bool) -> Void)
    case submenu(title: String, systemImage: String?, items: [MenuItem])
    case section(title: String?, items: [MenuItem])
    case divider
    /// Text in a menu (a disabled item).
    case label(String)
}

@MainActor
protocol _MenuItemsConvertible {
    func _menuItems(environment: EnvironmentValues, into items: inout [MenuItem])
}

@MainActor
public enum MenuItems {
    /// Menu items for menu content.
    public static func items<V: View>(_ view: V, environment: EnvironmentValues = EnvironmentValues()) -> [MenuItem] {
        var result: [MenuItem] = []
        collect(view, environment: environment, into: &result)
        return result
    }

    static func collect(_ view: any View, environment: EnvironmentValues, into items: inout [MenuItem]) {
        if let convertible = view as? _MenuItemsConvertible {
            convertible._menuItems(environment: environment, into: &items)
        } else if view is EmptyView {
        } else if let text = view as? Text {
            items.append(.label(text.plainString))
        } else if let any = view as? AnyView {
            collect(any.storage.anyView, environment: environment, into: &items)
        } else if view is Divider {
            items.append(.divider)
        } else {
            // Composite content (a custom View struct): use its body.
            if !_isPrimitive(view) {
                collect(view._anyBody, environment: environment, into: &items)
            }
        }
    }

    /// Title and SF Symbol of a label view (Text, Label, Image, HStack of them).
    static func title(of label: any View) -> (String, String?) {
        if let text = label as? Text { return (text.plainString, nil) }
        if let both = label as? Label<Text, Image> {
            if case .system(let name) = both.icon.source { return (both.title.plainString, name) }
            return (both.title.plainString, nil)
        }
        if let image = label as? Image, case .system(let name) = image.source { return ("", name) }
        if let any = label as? AnyView { return title(of: any.storage.anyView) }
        if let convertible = label as? _MenuLabelConvertible { return convertible._menuLabel }
        // Stacks and tuples: the first child that has a title (like a pull-down button's label).
        if let stack = label as? _StackContentReadable { return title(of: stack._stackContent) }
        if let tuple = label as? _ChildrenReadable {
            for child in tuple._children {
                let found = title(of: child)
                if !found.0.isEmpty || found.1 != nil { return found }
            }
        }
        return ("", nil)
    }
}

@MainActor
protocol _MenuLabelConvertible {
    var _menuLabel: (String, String?) { get }
}

extension View {
    @MainActor var _anyBody: any View { body }
}

@MainActor
func _isPrimitive<V: View>(_ view: V) -> Bool { V.Body.self == Never.self }

extension Button: _MenuItemsConvertible {
    func _menuItems(environment: EnvironmentValues, into items: inout [MenuItem]) {
        let (title, image) = MenuItems.title(of: label)
        items.append(.button(title: title, systemImage: image, shortcut: environment.keyboardShortcut, isEnabled: environment.isEnabled, isDestructive: role == .destructive, action: action))
    }
}

extension Toggle: _MenuItemsConvertible {
    func _menuItems(environment: EnvironmentValues, into items: inout [MenuItem]) {
        let (title, _) = MenuItems.title(of: label)
        let binding = isOn
        items.append(.toggle(title: title, isOn: binding.wrappedValue, shortcut: environment.keyboardShortcut, isEnabled: environment.isEnabled, set: { binding.wrappedValue = $0 }))
    }
}

extension Menu: _MenuItemsConvertible {
    func _menuItems(environment: EnvironmentValues, into items: inout [MenuItem]) {
        let (title, image) = MenuItems.title(of: label)
        items.append(.submenu(title: title, systemImage: image, items: MenuItems.items(content, environment: environment)))
    }
}

extension Section: _MenuItemsConvertible {
    func _menuItems(environment: EnvironmentValues, into items: inout [MenuItem]) {
        let title = header.map { MenuItems.title(of: $0).0 }
        items.append(.section(title: title, items: MenuItems.items(content, environment: environment)))
    }
}

extension Picker: _MenuItemsConvertible {
    func _menuItems(environment: EnvironmentValues, into items: inout [MenuItem]) {
        let (title, image) = MenuItems.title(of: label)
        // Options: tagged content views.
        var options: [MenuItem] = []
        let binding = selection
        for (tag, view) in _taggedViews(content) {
            let (optionTitle, _) = MenuItems.title(of: view)
            let value = tag.base as? SelectionValue
            options.append(.toggle(title: optionTitle, isOn: value.map { $0 == binding.wrappedValue } ?? false, shortcut: nil, isEnabled: environment.isEnabled, set: { _ in if let value { binding.wrappedValue = value } }))
        }
        items.append(.submenu(title: title, systemImage: image, items: options))
    }
}

extension TupleView: _MenuItemsConvertible {
    func _menuItems(environment: EnvironmentValues, into items: inout [MenuItem]) {
        for child in Mirror(reflecting: value).children {
            if let view = child.value as? any View { MenuItems.collect(view, environment: environment, into: &items) }
        }
    }
}

extension Optional: _MenuItemsConvertible where Wrapped: View {
    func _menuItems(environment: EnvironmentValues, into items: inout [MenuItem]) {
        if let self { MenuItems.collect(self, environment: environment, into: &items) }
    }
}

extension _ConditionalContent: _MenuItemsConvertible where TrueContent: View, FalseContent: View {
    func _menuItems(environment: EnvironmentValues, into items: inout [MenuItem]) {
        switch storage {
        case .trueContent(let view): MenuItems.collect(view, environment: environment, into: &items)
        case .falseContent(let view): MenuItems.collect(view, environment: environment, into: &items)
        }
    }
}

extension Group: _MenuItemsConvertible where Content: View {
    func _menuItems(environment: EnvironmentValues, into items: inout [MenuItem]) {
        MenuItems.collect(content, environment: environment, into: &items)
    }
}

extension ForEach: _MenuItemsConvertible where Content: View {
    func _menuItems(environment: EnvironmentValues, into items: inout [MenuItem]) {
        for element in data { MenuItems.collect(content(element), environment: environment, into: &items) }
    }
}

extension ModifiedContent: _MenuItemsConvertible where Content: View, Modifier: ViewModifier {
    func _menuItems(environment: EnvironmentValues, into items: inout [MenuItem]) {
        var environment = environment
        if let writer = modifier as? _EnvironmentApplying { writer._apply(to: &environment) }
        MenuItems.collect(content, environment: environment, into: &items)
    }
}

extension ModifiedContent: _MenuLabelConvertible where Content: View, Modifier: ViewModifier {
    var _menuLabel: (String, String?) { MenuItems.title(of: content) }
}

extension _EnvironmentTransformModifier: _EnvironmentApplying {
    func _apply(to environment: inout EnvironmentValues) { transform(&environment[keyPath: keyPath]) }
}

/// Tagged elements of picker content (`Text("A").tag(1)`, ForEach with tags).
@MainActor
func _taggedViews(_ view: any View) -> [(AnyHashable, any View)] {
    var result: [(AnyHashable, any View)] = []
    func visit(_ view: any View) {
        if let tagged = view as? _TagReadable {
            if let tag = tagged._tag { result.append((tag, tagged._untagged)) }
            return
        }
        if let tuple = view as? _ChildrenReadable { tuple._children.forEach(visit) }
    }
    visit(view)
    return result
}

@MainActor protocol _TagReadable { var _tag: AnyHashable? { get }; var _untagged: any View { get } }
@MainActor protocol _ChildrenReadable { var _children: [any View] { get } }
@MainActor protocol _StackContentReadable { var _stackContent: any View { get } }

extension HStack: _StackContentReadable { var _stackContent: any View { content } }
extension VStack: _StackContentReadable { var _stackContent: any View { content } }
extension ZStack: _StackContentReadable { var _stackContent: any View { content } }

extension ModifiedContent: _TagReadable where Content: View, Modifier: ViewModifier {
    var _tag: AnyHashable? { (modifier as? _TraitWritingModifier<TagTraitKey>)?.value }
    var _untagged: any View { content }
}

extension TupleView: _ChildrenReadable {
    var _children: [any View] { Mirror(reflecting: value).children.compactMap { $0.value as? any View } }
}

extension ForEach: _ChildrenReadable where Content: View {
    var _children: [any View] { data.map { content($0) } }
}
