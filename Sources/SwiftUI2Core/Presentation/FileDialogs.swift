import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Environment hook to the backend's native file panels.
public struct FileDialogPresenter: @unchecked Sendable {
    let present: @MainActor (FileDialogRequest, @escaping @MainActor ([URL]?) -> Void) -> Void
}

private struct FileDialogsKey: EnvironmentKey {
    static let defaultValue = FileDialogPresenter { _, completion in completion(nil) }
}

extension EnvironmentValues {
    public var _fileDialogs: FileDialogPresenter {
        get { self[FileDialogsKey.self] }
        set { self[FileDialogsKey.self] = newValue }
    }
}

/// Shows the panel whenever `isPresented` turns true and resets it when the panel closes.
struct _FileDialogModifier: ViewModifier {
    @Binding var isPresented: Bool
    let request: FileDialogRequest
    let completion: @MainActor ([URL]?) -> Void
    @Environment(\._fileDialogs) private var dialogs
    @Environment(\.fileDialogOptions) private var options

    func body(content: Content) -> some View {
        content.onChange(of: isPresented, initial: true) { _, presented in
            guard presented else { return }
            let binding = $isPresented
            var request = self.request
            request.options = options
            dialogs.present(request) { urls in
                binding.wrappedValue = false
                completion(urls)
            }
        }
    }
}

#if canImport(UniformTypeIdentifiers)
extension View {
    public func fileImporter(isPresented: Binding<Bool>, allowedContentTypes: [UTType], onCompletion: @escaping @MainActor (Result<URL, any Error>) -> Void) -> some View {
        modifier(_FileDialogModifier(isPresented: isPresented, request: Self.openRequest(allowedContentTypes, multiple: false)) { urls in
            if let url = urls?.first { onCompletion(.success(url)) }
        })
    }

    public func fileImporter(isPresented: Binding<Bool>, allowedContentTypes: [UTType], allowsMultipleSelection: Bool, onCompletion: @escaping @MainActor (Result<[URL], any Error>) -> Void) -> some View {
        modifier(_FileDialogModifier(isPresented: isPresented, request: Self.openRequest(allowedContentTypes, multiple: allowsMultipleSelection)) { urls in
            if let urls { onCompletion(.success(urls)) }
        })
    }

    /// Save panel; `write` gets the chosen destination (the `FileDocument` variants are not supported).
    public func fileExporter(isPresented: Binding<Bool>, contentType: UTType, defaultFilename: String? = nil, write: @escaping @MainActor (URL) throws -> Void, onCompletion: @escaping @MainActor (Result<URL, any Error>) -> Void) -> some View {
        let request = FileDialogRequest(kind: .save, contentTypes: [contentType.identifier], defaultFilename: defaultFilename)
        return modifier(_FileDialogModifier(isPresented: isPresented, request: request) { urls in
            guard let url = urls?.first else { return }
            do {
                try write(url)
                onCompletion(.success(url))
            } catch {
                onCompletion(.failure(error))
            }
        })
    }

    private static func openRequest(_ types: [UTType], multiple: Bool) -> FileDialogRequest {
        FileDialogRequest(kind: .open, contentTypes: types.map(\.identifier), allowsMultipleSelection: multiple, canChooseDirectories: types.contains { $0.conforms(to: .directory) || $0 == .folder })
    }
}
#endif

// MARK: - Panel options

struct FileDialogOptionsKey: EnvironmentKey { static let defaultValue = FileDialogOptions() }

extension EnvironmentValues {
    var fileDialogOptions: FileDialogOptions {
        get { self[FileDialogOptionsKey.self] }
        set { self[FileDialogOptionsKey.self] = newValue }
    }
}

public struct FileDialogBrowserOptions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let enumeratePackages = FileDialogBrowserOptions(rawValue: 1)
    public static let includeHiddenFiles = FileDialogBrowserOptions(rawValue: 2)
    public static let displayFileExtensions = FileDialogBrowserOptions(rawValue: 4)
}

extension View {
    func _fileDialogOptions(_ edit: @escaping (inout FileDialogOptions) -> Void) -> some View {
        transformEnvironment(\.fileDialogOptions, transform: edit)
    }

    public func fileDialogMessage(_ message: Text?) -> some View { _fileDialogOptions { $0.message = message?.plainString } }
    public func fileDialogMessage<S: StringProtocol>(_ message: S) -> some View { _fileDialogOptions { $0.message = String(message) } }
    public func fileDialogConfirmationLabel(_ label: Text?) -> some View { _fileDialogOptions { $0.confirmationLabel = label?.plainString } }
    public func fileDialogConfirmationLabel<S: StringProtocol>(_ label: S) -> some View { _fileDialogOptions { $0.confirmationLabel = String(label) } }
    public func fileDialogDefaultDirectory(_ url: URL?) -> some View { _fileDialogOptions { $0.defaultDirectory = url } }
    public func fileDialogBrowserOptions(_ options: FileDialogBrowserOptions) -> some View {
        _fileDialogOptions {
            $0.treatsPackagesAsDirectories = options.contains(.enumeratePackages)
            $0.showsHiddenFiles = options.contains(.includeHiddenFiles)
            if options.contains(.displayFileExtensions) { $0.showsFileExtensions = true }
        }
    }
    /// Panels with the same id remember their size and location.
    public func fileDialogCustomizationID(_ id: String) -> some View { _fileDialogOptions { $0.customizationID = id } }
    public func fileDialogImportsUnresolvedAliases(_ imports: Bool) -> some View { _fileDialogOptions { $0.importsUnresolvedAliases = imports } }
    public func fileDialogURLEnabled(_ predicate: Predicate<URL>) -> some View {
        let box = UncheckedSendable(predicate)
        return _fileDialogOptions { $0.isURLEnabled = { (try? box.value.evaluate($0)) ?? true } }
    }
    public func fileExporterFilenameLabel(_ label: Text?) -> some View { _fileDialogOptions { $0.filenameLabel = label?.plainString } }
    public func fileExporterFilenameLabel<S: StringProtocol>(_ label: S) -> some View { _fileDialogOptions { $0.filenameLabel = String(label) } }
}

#if canImport(UniformTypeIdentifiers)
extension View {
    /// Exports a document with a save panel.
    public func fileExporter<D: FileDocument>(isPresented: Binding<Bool>, document: D?, contentType: UTType, defaultFilename: String? = nil, onCompletion: @escaping @MainActor (Result<URL, any Error>) -> Void) -> some View {
        fileExporter(isPresented: isPresented, contentType: contentType, defaultFilename: defaultFilename, write: { url in
            guard let document else { return }
            try document.fileWrapper(configuration: FileDocumentWriteConfiguration(contentType: contentType, existingFile: nil)).write(to: url, options: .atomic, originalContentsURL: nil)
        }, onCompletion: onCompletion)
    }

    /// Exports several documents into a chosen folder.
    public func fileExporter<C: Collection>(isPresented: Binding<Bool>, documents: C, contentType: UTType, onCompletion: @escaping @MainActor (Result<[URL], any Error>) -> Void) -> some View where C.Element: FileDocument {
        let documents = Array(documents)
        var request = FileDialogRequest(kind: .open, contentTypes: [UTType.folder.identifier], canChooseDirectories: true)
        request.options.confirmationLabel = "Export"
        return modifier(_FileDialogModifier(isPresented: isPresented, request: request) { urls in
            guard let folder = urls?.first else { return }
            do {
                var written: [URL] = []
                for (index, document) in documents.enumerated() {
                    let url = folder.appendingPathComponent("Untitled \(index + 1)").appendingPathExtension(contentType.preferredFilenameExtension ?? "")
                    try document.fileWrapper(configuration: FileDocumentWriteConfiguration(contentType: contentType, existingFile: nil)).write(to: url, options: .atomic, originalContentsURL: nil)
                    written.append(url)
                }
                onCompletion(.success(written))
            } catch {
                onCompletion(.failure(error))
            }
        })
    }

    /// Imports with a cancellation callback.
    public func fileImporter(isPresented: Binding<Bool>, allowedContentTypes: [UTType], allowsMultipleSelection: Bool, onCompletion: @escaping @MainActor (Result<[URL], any Error>) -> Void, onCancellation: @escaping @MainActor () -> Void) -> some View {
        modifier(_FileDialogModifier(isPresented: isPresented, request: FileDialogRequest(kind: .open, contentTypes: allowedContentTypes.map(\.identifier), allowsMultipleSelection: allowsMultipleSelection)) { urls in
            if let urls { onCompletion(.success(urls)) } else { onCancellation() }
        })
    }

    /// Moves a file to a folder the user chooses.
    public func fileMover(isPresented: Binding<Bool>, file: URL?, onCompletion: @escaping @MainActor (Result<URL, any Error>) -> Void) -> some View {
        fileMover(isPresented: isPresented, files: file.map { [$0] } ?? []) { result in onCompletion(result.map { $0.first ?? URL(fileURLWithPath: "/") }) }
    }

    public func fileMover<C: Collection>(isPresented: Binding<Bool>, files: C, onCompletion: @escaping @MainActor (Result<[URL], any Error>) -> Void) -> some View where C.Element == URL {
        let files = Array(files)
        var request = FileDialogRequest(kind: .open, contentTypes: [UTType.folder.identifier], canChooseDirectories: true)
        request.options.confirmationLabel = "Move"
        return modifier(_FileDialogModifier(isPresented: isPresented, request: request) { urls in
            guard let folder = urls?.first else { return }
            do {
                var moved: [URL] = []
                for file in files {
                    let destination = folder.appendingPathComponent(file.lastPathComponent)
                    try FileManager.default.moveItem(at: file, to: destination)
                    moved.append(destination)
                }
                onCompletion(.success(moved))
            } catch {
                onCompletion(.failure(error))
            }
        })
    }
}
#endif
