// NSItemProvider + Transferable (Apple's CoreTransferable additions), for platforms where both
// come from SwiftUI2's stand-ins.
#if !canImport(ObjectiveC) && canImport(CoreTransferable)
import Foundation
import CoreTransferable
import UniformTypeIdentifiers

extension NSItemProvider {
    /// Registers every exportable representation of `transferable`.
    public func register<T: Transferable>(_ transferable: @autoclosure @escaping @Sendable () -> T) {
        for entry in T._transferEntries where entry.exportData != nil || entry.exportFile != nil {
            let box = TransferableBox(entry: entry, make: transferable)
            if suggestedName == nil { suggestedName = entry.suggestedFileName?(transferable()) }
            registerDataRepresentation(forTypeIdentifier: entry.contentType.identifier, visibility: .all) { completion in
                Task {
                    do { completion(try await box.export(), nil) } catch { completion(nil, error) }
                }
                return nil
            }
        }
    }

    public func canLoadObject<T: Transferable>(ofClass: T.Type) -> Bool {
        let types = T._importedContentTypes
        return registeredTypeIdentifiers.contains { id in types.contains { UTType(id)?.conforms(to: $0) ?? ($0.identifier == id) } }
    }

    /// Loads the first registered representation `T` can import.
    @discardableResult
    public func loadTransferable<T: Transferable>(type: T.Type, completionHandler: @escaping @Sendable (Result<T, any Error>) -> Void) -> Progress {
        let imported = T._importedContentTypes
        let identifiers = registeredTypeIdentifiers
        let match = identifiers.first { id in imported.contains { UTType(id)?.conforms(to: $0) ?? ($0.identifier == id) } }
            ?? identifiers.first
        guard let match else {
            completionHandler(.failure(CocoaError(.fileReadUnknown)))
            return Progress(totalUnitCount: 0)
        }
        return loadDataRepresentation(forTypeIdentifier: match) { data, error in
            guard let data else { return completionHandler(.failure(error ?? CocoaError(.fileReadUnknown))) }
            Task {
                do {
                    if let item = try await T._imported(from: data, contentType: UTType(match)) { completionHandler(.success(item)) }
                    else { completionHandler(.failure(CocoaError(.fileReadCorruptFile))) }
                } catch {
                    completionHandler(.failure(error))
                }
            }
        }
    }
}

private struct TransferableBox<T: Transferable>: @unchecked Sendable {
    let entry: _TransferEntry<T>
    let make: @Sendable () -> T

    func export() async throws -> Data {
        let item = make()
        if let exportData = entry.exportData { return try await exportData(item) }
        if let exportFile = entry.exportFile { return try Data(contentsOf: try await exportFile(item).file) }
        throw CocoaError(.featureUnsupported)
    }
}
#endif
