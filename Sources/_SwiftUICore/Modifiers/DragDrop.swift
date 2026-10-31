import Foundation
import CoreTransferable
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

// Drag & drop. The core only routes events: backends hand dropped items over as platform item
// providers (`NSItemProvider` on Apple platforms) and ask drag sources for one.

struct _DropModifier: PlatformEffectModifier {
    static var hasActions: Bool { true }
    let types: [String]
    let isTargeted: Binding<Bool>?
    let delegate: (any _DropHandler)

    static var pathComponent: String { "onDrop" }
    func effect(size: CGSize) -> DisplayEffect { .opacity(1) }

    func actions(modifier: Attribute<Self>) -> RenderActions {
        var actions = RenderActions()
        actions.dropTypes = types
        actions.dropTargeted = { [weak modifier] targeted in
            guard let modifier else { return }
            AnyAttribute.withoutDependencies {
                let value = modifier.value
                if let isTargeted = value.isTargeted, isTargeted.wrappedValue != targeted {
                    isTargeted.wrappedValue = targeted
                }
                value.delegate.targeted(targeted)
            }
        }
        actions.dropUpdated = { [weak modifier] location in
            guard let modifier else { return }
            AnyAttribute.withoutDependencies { modifier.value.delegate.updated(location: location) }
        }
        actions.drop = { [weak modifier] providers, location in
            guard let modifier else { return false }
            return AnyAttribute.withoutDependencies {
                modifier.value.delegate.perform(providers: providers, location: location, types: modifier.value.types)
            }
        }
        return actions
    }
}

@MainActor
protocol _DropHandler {
    func targeted(_ value: Bool)
    func updated(location: CGPoint)
    func perform(providers: [AnyObject], location: CGPoint, types: [String]) -> Bool
}

struct _DragModifier: PlatformEffectModifier {
    static var hasActions: Bool { true }
    let makeItem: @MainActor () -> AnyObject?
    static var pathComponent: String { "onDrag" }
    func effect(size: CGSize) -> DisplayEffect { .opacity(1) }

    func actions(modifier: Attribute<Self>) -> RenderActions {
        var actions = RenderActions()
        actions.dragItem = { [weak modifier] in
            guard let modifier else { return nil }
            return AnyAttribute.withoutDependencies { modifier.value.makeItem() }
        }
        return actions
    }
}

#if canImport(UniformTypeIdentifiers)
/// Mirrors `SwiftUI.DropInfo`.
@MainActor
public struct DropInfo {
    public let location: CGPoint
    let providers: [NSItemProvider]

    public func hasItemsConforming(to contentTypes: [UTType]) -> Bool {
        providers.contains { provider in
            contentTypes.contains { type in provider.hasItemConformingToTypeIdentifier(type.identifier) }
        }
    }

    public func itemProviders(for contentTypes: [UTType]) -> [NSItemProvider] {
        providers.filter { provider in
            contentTypes.contains { type in provider.hasItemConformingToTypeIdentifier(type.identifier) }
        }
    }
}

public enum DropOperation: Sendable { case cancel, forbidden, copy, move }

public struct DropProposal: Sendable {
    public let operation: DropOperation
    public init(operation: DropOperation) { self.operation = operation }
}

/// Mirrors `SwiftUI.DropDelegate`.
@MainActor @preconcurrency
public protocol DropDelegate {
    func validateDrop(info: DropInfo) -> Bool
    func performDrop(info: DropInfo) -> Bool
    func dropEntered(info: DropInfo)
    func dropUpdated(info: DropInfo) -> DropProposal?
    func dropExited(info: DropInfo)
}

extension DropDelegate {
    public func validateDrop(info: DropInfo) -> Bool { true }
    public func dropEntered(info: DropInfo) {}
    public func dropUpdated(info: DropInfo) -> DropProposal? { nil }
    public func dropExited(info: DropInfo) {}
}

private struct ClosureDropHandler: _DropHandler {
    let action: @MainActor ([NSItemProvider], CGPoint) -> Bool
    func targeted(_ value: Bool) {}
    func updated(location: CGPoint) {}
    func perform(providers: [AnyObject], location: CGPoint, types: [String]) -> Bool {
        let matching = providers.compactMap { $0 as? NSItemProvider }.filter { provider in
            types.contains { provider.hasItemConformingToTypeIdentifier($0) }
        }
        guard !matching.isEmpty else { return false }
        return action(matching, location)
    }
}

private struct DelegateDropHandler: _DropHandler {
    let delegate: any DropDelegate
    func targeted(_ value: Bool) {
        let info = DropInfo(location: .zero, providers: [])
        if value { delegate.dropEntered(info: info) } else { delegate.dropExited(info: info) }
    }
    func updated(location: CGPoint) { _ = delegate.dropUpdated(info: DropInfo(location: location, providers: [])) }
    func perform(providers: [AnyObject], location: CGPoint, types: [String]) -> Bool {
        let info = DropInfo(location: location, providers: providers.compactMap { $0 as? NSItemProvider })
        guard delegate.validateDrop(info: info) else { return false }
        return delegate.performDrop(info: info)
    }
}

extension View {
    public func onDrop(of supportedContentTypes: [UTType], isTargeted: Binding<Bool>?, perform action: @escaping @MainActor ([NSItemProvider]) -> Bool) -> some View {
        modifier(_DropModifier(types: supportedContentTypes.map(\.identifier), isTargeted: isTargeted, delegate: ClosureDropHandler { providers, _ in action(providers) }))
    }

    public func onDrop(of supportedContentTypes: [UTType], isTargeted: Binding<Bool>?, perform action: @escaping @MainActor ([NSItemProvider], CGPoint) -> Bool) -> some View {
        modifier(_DropModifier(types: supportedContentTypes.map(\.identifier), isTargeted: isTargeted, delegate: ClosureDropHandler(action: action)))
    }

    public func onDrop(of supportedContentTypes: [UTType], delegate: any DropDelegate) -> some View {
        modifier(_DropModifier(types: supportedContentTypes.map(\.identifier), isTargeted: nil, delegate: DelegateDropHandler(delegate: delegate)))
    }

    /// Drag source: `data` builds the item provider when a drag starts.
    public func onDrag(_ data: @escaping @MainActor () -> NSItemProvider) -> some View {
        modifier(_DragModifier(makeItem: data))
    }

    public func onDrag<V: View>(_ data: @escaping @MainActor () -> NSItemProvider, @ViewBuilder preview: () -> V) -> some View {
        modifier(_DragModifier(makeItem: data))
    }
}
#endif

// MARK: - Drag sessions (macOS 26)

/// Which operations a drag started in this view allows.
public struct DragConfiguration: Sendable {
    public var allowMove: Bool
    public var allowCopy: Bool
    public var allowDelete: Bool
    public var allowAlias: Bool

    public init(allowMove: Bool = true, allowCopy: Bool = true, allowDelete: Bool = false, allowAlias: Bool = false) {
        self.allowMove = allowMove
        self.allowCopy = allowCopy
        self.allowDelete = allowDelete
        self.allowAlias = allowAlias
    }
}

/// A drag in progress, as `onDragSessionUpdated` reports it.
public struct DragSession {
    public enum Phase {
        case initial, active
        case ended(DropOperation)
        case dataTransferCompleted
    }

    public var phase: Phase
}

/// Drag sessions started by this app's drag sources; backends report their phases.
@MainActor
public enum DragSessions {
    final class Observer {
        var action: (DragSession) -> Void = { _ in }
    }

    static var observers: [ObjectIdentifier: Observer] = [:]

    /// Called by backends when a drag starts and ends.
    public static func update(_ phase: DragSession.Phase) {
        for observer in observers.values { observer.action(DragSession(phase: phase)) }
    }
}

struct _DragSessionObserverModifier: ViewModifier {
    let action: (DragSession) -> Void
    @State private var observer = DragSessions.Observer()

    func body(content: Content) -> some View {
        observer.action = action
        let observer = self.observer
        return content
            .onAppear { DragSessions.observers[ObjectIdentifier(observer)] = observer }
            .onDisappear { DragSessions.observers[ObjectIdentifier(observer)] = nil }
    }
}

extension View {
    /// Drags are configured by the backend (move and copy within the app).
    public func dragConfiguration(_ configuration: DragConfiguration) -> some View { self }

    /// Calls `action` as a drag started by this app moves through its phases.
    public func onDragSessionUpdated(_ action: @escaping (DragSession) -> Void) -> some View {
        modifier(_DragSessionObserverModifier(action: action))
    }
}

// MARK: - Drag containers (macOS 26, iOS 27)

extension View {
    /// Marks the view as the item `containerItemID` of the drag container around it (`dragContainer`). Backends drag
    /// no containers yet, so the view drags nothing.
    public func draggable<ItemID: Hashable & Sendable>(containerItemID: ItemID, containerNamespace: Namespace.ID? = nil) -> some View { self }

    /// The ids a drag of a selected item in this container drags together. Backends drag no containers yet.
    public func dragContainerSelection<ItemID: Hashable & Sendable>(_ selection: @autoclosure @escaping () -> [ItemID], containerNamespace: Namespace.ID? = nil) -> some View { self }

    /// What the container's items (`draggable(containerItemID:)`) drag: `payload` gets the dragged ids. Backends drag
    /// no containers yet.
    public func dragContainer<ItemID: Hashable & Sendable, Item: Transferable, Data: Collection>(for itemType: Item.Type = Item.self, itemID: KeyPath<Item, ItemID>, in namespace: Namespace.ID? = nil, _ payload: @escaping (_ draggedItemIDs: [ItemID]) -> Data) -> some View where Item == Data.Element { self }
}
