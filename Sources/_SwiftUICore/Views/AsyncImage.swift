import Foundation
import Observation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Decoding hook

/// Environment hook to the backend's image decoder (data → platform image).
public struct ImageDecoder: @unchecked Sendable {
    let decode: @MainActor (Data, CGFloat) -> Image?
}

extension ImageDecoder {
    /// The backend of the newest window (set when its view graph is made), for decoding outside a view's environment.
    @MainActor weak static var backend: (any RenderBackend)?
}

extension Image {
    /// Not Apple API: an image decoded from PNG, JPEG or other image file bytes by the backend (GdkPixbuf on GTK, the
    /// host on Android and Windows, NSImage under AppKit), each `scale` pixels a point; nil when the bytes aren't an
    /// image, or before a window is up. Apple platforms decode with `NSImage(data:)` / `UIImage(data:)` instead.
    @MainActor
    public init?(_platformData data: Data, scale: CGFloat = 1) {
        guard let image = ImageDecoder.backend?.decodeImage(data, scale: scale) else { return nil }
        self.init(_platformImage: image)
    }
}

struct ImageDecoderKey: EnvironmentKey { static let defaultValue = ImageDecoder { _, _ in nil } }
struct AsyncImageSessionKey: EnvironmentKey { static let defaultValue: URLSession? = nil }

extension EnvironmentValues {
    public var _imageDecoder: ImageDecoder {
        get { self[ImageDecoderKey.self] }
        set { self[ImageDecoderKey.self] = newValue }
    }

    var asyncImageURLSession: URLSession? {
        get { self[AsyncImageSessionKey.self] }
        set { self[AsyncImageSessionKey.self] = newValue }
    }
}

extension View {
    /// The session `AsyncImage` loads with.
    public func asyncImageURLSession(_ session: URLSession) -> some View { environment(\.asyncImageURLSession, session) }
}

// MARK: - AsyncImage

public enum AsyncImagePhase: @unchecked Sendable {
    case empty
    case success(Image)
    case failure(any Error)

    public var image: Image? {
        if case .success(let image) = self { return image }
        return nil
    }

    public var error: (any Error)? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

public struct AsyncImageDecodingError: Error, Sendable {}

/// Loads and displays an image from a URL (`AsyncImage(url:) { phase in ... }`).
public struct AsyncImage<Content: View>: View {
    let url: URL?
    let scale: CGFloat
    let transaction: Transaction
    let content: (AsyncImagePhase) -> Content
    @State private var loaded = _AsyncImageState()
    @Environment(\._imageDecoder) private var decoder
    @Environment(\.asyncImageURLSession) private var session

    public init(url: URL?, scale: CGFloat = 1, transaction: Transaction = Transaction(), @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.url = url
        self.scale = scale
        self.transaction = transaction
        self.content = content
    }

    public var body: some View {
        let state = loaded
        let decoder = self.decoder
        let session = self.session ?? .shared
        let scale = self.scale
        let transaction = self.transaction
        let url = self.url
        content(state.url == url ? state.phase : .empty)
            .task(id: url) {
                guard let url else {
                    state.update(url: nil, phase: .empty, transaction: transaction)
                    return
                }
                do {
                    let data = try await _AsyncImageLoader.load(url, session: session)
                    if Task.isCancelled { return }
                    if let image = decoder.decode(data, scale) {
                        state.update(url: url, phase: .success(image), transaction: transaction)
                    } else {
                        state.update(url: url, phase: .failure(AsyncImageDecodingError()), transaction: transaction)
                    }
                } catch {
                    if Task.isCancelled { return }
                    state.update(url: url, phase: .failure(error), transaction: transaction)
                }
            }
    }
}

/// The loaded phase, observed by the view.
@Observable
@MainActor
final class _AsyncImageState {
    var url: URL?
    var phase = AsyncImagePhase.empty

    func update(url: URL?, phase: AsyncImagePhase, transaction: Transaction) {
        withTransaction(transaction) {
            self.url = url
            self.phase = phase
        }
    }
}

enum _AsyncImageLoader {
    static func load(_ url: URL, session: URLSession) async throws -> Data {
        if url.isFileURL { return try Data(contentsOf: url) }
        return try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: url) { data, response, error in
                if let error { return continuation.resume(throwing: error) }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    return continuation.resume(throwing: URLError(.badServerResponse))
                }
                continuation.resume(returning: data ?? Data())
            }
            task.resume()
        }
    }
}

extension AsyncImage {
    /// The image at its intrinsic size, or a gray placeholder while loading (or on failure).
    public init(url: URL?, scale: CGFloat = 1) where Content == _AsyncImageDefaultContent {
        self.init(url: url, scale: scale) { _AsyncImageDefaultContent(phase: $0) }
    }

    public init<I: View, P: View>(url: URL?, scale: CGFloat = 1, @ViewBuilder content: @escaping (Image) -> I, @ViewBuilder placeholder: @escaping () -> P) where Content == _ConditionalContent<I, P> {
        self.init(url: url, scale: scale) { phase in
            if let image = phase.image { content(image) } else { placeholder() }
        }
    }
}

public struct _AsyncImageDefaultContent: View {
    let phase: AsyncImagePhase
    public var body: some View {
        if let image = phase.image {
            image
        } else {
            Color.gray.opacity(0.2)
        }
    }
}
