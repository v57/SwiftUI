#if canImport(Translation)
import Foundation
import SwiftUI2Core
@preconcurrency import Translation

// `translationTask` lives in Apple's SwiftUI overlay of the Translation framework; this provides it
// for SwiftUI2. Sessions are created for installed languages (macOS 26+), as there is no
// system download sheet to present.

@available(macOS 15.0, *)
private struct _TranslationTaskID: Equatable {
    let configuration: TranslationSession.Configuration?
}

extension View {
    @available(macOS 15.0, *)
    public func translationTask(_ configuration: TranslationSession.Configuration?, action: @escaping @MainActor @Sendable (TranslationSession) async -> Void) -> some View {
        task(id: _TranslationTaskID(configuration: configuration)) {
            guard #available(macOS 26.0, *), let configuration else { return }
            let source = configuration.source ?? Locale.current.language
            let session = TranslationSession(installedSource: source, target: configuration.target)
            await action(session)
        }
    }

    @available(macOS 15.0, *)
    public func translationTask(source: Locale.Language? = nil, target: Locale.Language? = nil, action: @escaping @MainActor @Sendable (TranslationSession) async -> Void) -> some View {
        translationTask(TranslationSession.Configuration(source: source, target: target), action: action)
    }
}
#endif
