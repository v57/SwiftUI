import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
#if canImport(CoreTransferable)
import CoreTransferable
#endif

// MARK: - Default labels

/// "Settings…" with a gear.
public struct DefaultSettingsLinkLabel: View {
    public var body: some View { Label("Settings…", systemImage: "gearshape") }
}

public struct DefaultShareLinkLabel: View {
    public var body: some View { Label("Share", systemImage: "square.and.arrow.up") }
}

public struct DefaultButtonLabel: View {
    let title: String
    let systemImage: String?
    public var body: some View {
        if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
    }
}

public struct DefaultTabLabel: View {
    let title: String
    let systemImage: String?
    public var body: some View {
        if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
    }
}

public struct DefaultWindowVisibilityToggleLabel: View {
    let title: String
    public var body: some View { Text(title) }
}

public struct DefaultNewDocumentButtonLabel: View {
    public var body: some View { Label("New Document", systemImage: "doc.badge.plus") }
}

/// The time remaining or elapsed for `ProgressView(timerInterval:)`.
public struct DefaultDateProgressLabel: View {
    let interval: ClosedRange<Date>
    let countsDown: Bool
    public var body: some View {
        TimelineView(.periodic(from: interval.lowerBound, by: 1)) { context in
            let seconds = countsDown ? interval.upperBound.timeIntervalSince(context.date) : context.date.timeIntervalSince(interval.lowerBound)
            Text(Duration.seconds(max(0, seconds.rounded(.down))).formatted(.time(pattern: .minuteSecond)))
                .monospacedDigit()
        }
    }
}

extension ProgressView where Label == EmptyView, CurrentValueLabel == DefaultDateProgressLabel {
    /// Progress through a time interval, updated every second.
    public init(timerInterval: ClosedRange<Date>, countsDown: Bool = true) {
        self.init(timerInterval: timerInterval, countsDown: countsDown, label: { EmptyView() })
    }
}

extension ProgressView where CurrentValueLabel == DefaultDateProgressLabel {
    public init(timerInterval: ClosedRange<Date>, countsDown: Bool = true, @ViewBuilder label: () -> Label) {
        let total = timerInterval.upperBound.timeIntervalSince(timerInterval.lowerBound)
        let elapsed = Date().timeIntervalSince(timerInterval.lowerBound)
        let fraction = total > 0 ? min(1, max(0, elapsed / total)) : 1
        self.init(fraction: countsDown ? 1 - fraction : fraction, label: label(), currentValueLabel: DefaultDateProgressLabel(interval: timerInterval, countsDown: countsDown))
    }
}

// MARK: - Settings / windows / documents

/// Opens the app's Settings window.
public struct SettingsLink<Label: View>: View {
    let label: Label

    public init(@ViewBuilder label: () -> Label) { self.label = label() }

    public var body: some View {
        Button { AppRuntime.openSettings?() } label: { label }
    }
}

extension SettingsLink where Label == DefaultSettingsLinkLabel {
    public init() { self.init { DefaultSettingsLinkLabel() } }
}

/// Opens the Settings window (`@Environment(\.openSettings)`).
public struct OpenSettingsAction: Sendable {
    @MainActor public func callAsFunction() { AppRuntime.openSettings?() }
}

extension EnvironmentValues {
    public var openSettings: OpenSettingsAction { OpenSettingsAction() }
}

/// Shows or hides a window (`Window` / `UtilityWindow` id).
public struct WindowVisibilityToggle<Label: View>: View {
    let windowID: String
    let label: Label

    public init(windowID: String, @ViewBuilder label: () -> Label) {
        self.windowID = windowID
        self.label = label()
    }

    public var body: some View {
        let id = windowID
        Button {
            if AppRuntime.isWindowOpen?(id) == true { AppRuntime.dismissWindow?(id, nil) } else { AppRuntime.openWindow?(id, nil) }
        } label: { label }
    }
}

extension WindowVisibilityToggle where Label == DefaultWindowVisibilityToggleLabel {
    public init(windowID: String) { self.init(windowID: windowID) { DefaultWindowVisibilityToggleLabel(title: "Show \(windowID)") } }
}

/// Creates a new document (document-based apps).
public struct NewDocumentButton<Label: View>: View {
    let label: Label

    public var body: some View {
        Button { AppRuntime.newDocument?() } label: { label }
    }
}

extension NewDocumentButton where Label == DefaultNewDocumentButtonLabel {
    public init() { label = DefaultNewDocumentButtonLabel() }
    public init<D>(for documentType: D.Type) { label = DefaultNewDocumentButtonLabel() }
}

extension NewDocumentButton where Label == Text {
    public init<S: StringProtocol>(_ title: S) { label = Text(title) }
    public init<S: StringProtocol, D>(_ title: S, for documentType: D.Type) { label = Text(title) }
}

// MARK: - Rename

/// Starts renaming (`renameAction`), used by `RenameButton`.
public struct RenameAction: @unchecked Sendable {
    let action: @MainActor () -> Void
    @MainActor public func callAsFunction() { action() }
}

struct RenameActionKey: EnvironmentKey { static let defaultValue: RenameAction? = nil }

extension EnvironmentValues {
    public var rename: RenameAction? {
        get { self[RenameActionKey.self] }
        set { self[RenameActionKey.self] = newValue }
    }
}

extension View {
    public func renameAction(_ action: @escaping @MainActor () -> Void) -> some View {
        environment(\.rename, RenameAction(action: action))
    }

    /// Renaming focuses the field bound to `isFocused`.
    public func renameAction(_ isFocused: FocusState<Bool>.Binding) -> some View {
        environment(\.rename, RenameAction(action: { isFocused.wrappedValue = true }))
    }
}

/// "Rename" — triggers the environment's rename action.
public struct RenameButton<Label: View>: View {
    let label: Label
    @Environment(\.rename) private var rename

    public var body: some View {
        let rename = self.rename
        Button { rename?() } label: { label }
            .disabled(rename == nil)
    }
}

extension RenameButton where Label == SwiftUI2Core.Label<Text, Image> {
    public init() { label = SwiftUI2Core.Label("Rename", systemImage: "pencil") }
}

// MARK: - Help

/// The round "?" help button.
public struct HelpLink: View {
    let action: @MainActor () -> Void

    public init(action: @escaping @MainActor () -> Void) { self.action = action }

    public init(destination: URL) {
        self.action = { AppRuntime.environment.openURL(destination) }
    }

    public init(anchor: String) {
        self.action = { AppRuntime.environment.openURL(URL(string: "help:anchor=\(anchor)")!) }
    }

    public var body: some View {
        Button(action: action) {
            Text("?")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 21, height: 21)
                .background(Circle().fill(Color.gray.opacity(0.18)))
                .overlay(Circle().strokeBorder(Color.gray.opacity(0.35), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Help")
    }
}

// MARK: - Paste

#if canImport(UniformTypeIdentifiers)
/// Environment hook to read the platform pasteboard.
public struct PasteboardReader: @unchecked Sendable {
    let read: @MainActor () -> [NSItemProvider]
}

struct PasteboardReaderKey: EnvironmentKey { static let defaultValue = PasteboardReader { [] } }

extension EnvironmentValues {
    public var _pasteboardReader: PasteboardReader {
        get { self[PasteboardReaderKey.self] }
        set { self[PasteboardReaderKey.self] = newValue }
    }
}

/// "Paste": delivers the pasteboard's items.
public struct PasteButton: View {
    let deliver: @MainActor ([NSItemProvider]) -> Void
    @Environment(\._pasteboardReader) private var reader

    public init(supportedContentTypes: [UTType], payloadAction: @escaping @MainActor ([NSItemProvider]) -> Void) {
        deliver = { providers in
            let identifiers = supportedContentTypes.map(\.identifier)
            payloadAction(providers.filter { provider in identifiers.contains { provider.hasItemConformingToTypeIdentifier($0) } })
        }
    }

    #if canImport(CoreTransferable)
    public init<T: Transferable>(payloadType: T.Type, onPaste: @escaping @MainActor ([T]) -> Void) {
        deliver = { providers in
            guard !providers.isEmpty else { return }
            let collector = _PasteCollector<T>(count: providers.count) { items in if !items.isEmpty { onPaste(items) } }
            for (index, provider) in providers.enumerated() {
                _ = provider.loadTransferable(type: T.self) { result in
                    let item = UncheckedSendable(try? result.get())
                    DispatchQueue.main.async { MainActor.assumeIsolated { collector.deliver(item.value, at: index) } }
                }
            }
        }
    }
    #endif

    public var body: some View {
        let reader = self.reader
        let deliver = self.deliver
        Button { deliver(reader.read()) } label: { Label("Paste", systemImage: "doc.on.clipboard") }
    }
}
#endif
