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

    func body(content: Content) -> some View {
        content.onChange(of: isPresented, initial: true) { _, presented in
            guard presented else { return }
            let binding = $isPresented
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
