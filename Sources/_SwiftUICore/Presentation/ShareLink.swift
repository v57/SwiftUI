import Foundation
#if canImport(CoreTransferable)
import CoreTransferable
#endif

/// Environment hook to the backend's share sheet.
public struct ShareAction: @unchecked Sendable {
    let share: @MainActor ([Any]) -> Void
}

private struct ShareActionKey: EnvironmentKey {
    static let defaultValue = ShareAction { _ in }
}

extension EnvironmentValues {
    public var _share: ShareAction {
        get { self[ShareActionKey.self] }
        set { self[ShareActionKey.self] = newValue }
    }
}

/// Title and images for the share sheet's preview (the AppKit picker shows the items themselves).
public struct SharePreview<Image, Icon> {
    public let title: String
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, image: Image, icon: Icon) { self.title = String(title) }
}

extension SharePreview where Image == Never, Icon == Never {
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S) { self.title = String(title) }
}

extension SharePreview where Icon == Never {
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, image: Image) { self.title = String(title) }
}

extension SharePreview where Image == Never {
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, icon: Icon) { self.title = String(title) }
}

/// URLs and strings are shared as-is; other `Transferable` values through an item provider.
func _shareItem(_ item: Any) -> Any {
    switch item {
    case is URL, is String, is NSAttributedString: return item
    default:
        #if canImport(CoreTransferable) && canImport(ObjectiveC)
        if let transferable = item as? any Transferable {
            let provider = NSItemProvider()
            func register<T: Transferable>(_ value: T) { provider.register(value) }
            register(transferable)
            return provider
        }
        #endif
        return item
    }
}

/// A button that presents the platform share sheet for its items. Items are shared as their
/// platform representation: URLs, strings and attributed strings are passed through.
public struct ShareLink<Label: View>: View {
    let items: [Any]
    let label: Label
    @Environment(\._share) private var share

    public var body: some View {
        let items = self.items
        let share = self.share
        Button { share.share(items.map(_shareItem)) } label: { label }
    }
}

extension ShareLink {
    public init<Data: RandomAccessCollection>(items: Data, subject: Text? = nil, message: Text? = nil, @ViewBuilder label: () -> Label) {
        self.items = items.map { $0 as Any }
        self.label = label()
    }

    public init<Item>(item: Item, subject: Text? = nil, message: Text? = nil, @ViewBuilder label: () -> Label) {
        self.items = [item]
        self.label = label()
    }

    public init<Item, I, C>(item: Item, subject: Text? = nil, message: Text? = nil, preview: SharePreview<I, C>, @ViewBuilder label: () -> Label) {
        self.items = [item]
        self.label = label()
    }

    public init<Data: RandomAccessCollection, I, C>(items: Data, subject: Text? = nil, message: Text? = nil, preview: (Data.Element) -> SharePreview<I, C>, @ViewBuilder label: () -> Label) {
        self.items = items.map { $0 as Any }
        self.label = label()
    }
}

extension ShareLink where Label == _SwiftUICore.Label<Text, Image> {
    public init<Data: RandomAccessCollection>(items: Data, subject: Text? = nil, message: Text? = nil) {
        self.init(items: items, subject: subject, message: message) { _SwiftUICore.Label("Share", systemImage: "square.and.arrow.up") }
    }

    public init<Item>(item: Item, subject: Text? = nil, message: Text? = nil) {
        self.init(item: item, subject: subject, message: message) { _SwiftUICore.Label("Share", systemImage: "square.and.arrow.up") }
    }

    @_disfavoredOverload public init<S: StringProtocol, Item>(_ title: S, item: Item, subject: Text? = nil, message: Text? = nil) {
        self.init(item: item, subject: subject, message: message) { _SwiftUICore.Label(title, systemImage: "square.and.arrow.up") }
    }

    public init<Item>(_ titleKey: LocalizedStringKey, item: Item, subject: Text? = nil, message: Text? = nil) {
        self.init(item: item, subject: subject, message: message) { _SwiftUICore.Label(titleKey, systemImage: "square.and.arrow.up") }
    }
}
