// Minimal Combine subset for platforms without Combine (Linux, Windows, Android).
// Provides exactly what `ObservableObject` / `@Published` / `objectWillChange.sink` need so the same
// app source compiles everywhere. On Apple platforms the real Combine is re-exported instead.
//
// Build with `-Xswiftc -DSWIFTUI2_COMBINE_SHIM` on macOS to exercise this implementation.

#if !canImport(Combine) || SWIFTUI2_COMBINE_SHIM
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public protocol Cancellable {
    func cancel()
}

public final class AnyCancellable: Cancellable, Hashable {
    private var cancelAction: (() -> Void)?

    public init(_ cancel: @escaping () -> Void) { cancelAction = cancel }
    deinit { cancelAction?() }

    public func cancel() {
        cancelAction?()
        cancelAction = nil
    }

    public func store(in set: inout Set<AnyCancellable>) { set.insert(self) }

    public static func == (lhs: AnyCancellable, rhs: AnyCancellable) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

public protocol Publisher<Output, Failure> {
    associatedtype Output
    associatedtype Failure: Error
    func sink(receiveValue: @escaping (Output) -> Void) -> AnyCancellable
}

public final class ObservableObjectPublisher: Publisher {
    public typealias Output = Void
    public typealias Failure = Never

    private var subscribers: [UInt64: (Void) -> Void] = [:]
    private var nextID: UInt64 = 0
    private let lock = NSLock()

    public init() {}

    public func send() {
        lock.lock()
        let current = Array(subscribers.values)
        lock.unlock()
        for subscriber in current { subscriber(()) }
    }

    public func sink(receiveValue: @escaping (Void) -> Void) -> AnyCancellable {
        lock.lock()
        nextID += 1
        let id = nextID
        subscribers[id] = receiveValue
        lock.unlock()
        return AnyCancellable { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.subscribers[id] = nil
            self.lock.unlock()
        }
    }
}

public protocol ObservableObject: AnyObject {
    associatedtype ObjectWillChangePublisher: Publisher = ObservableObjectPublisher where ObjectWillChangePublisher.Failure == Never
    var objectWillChange: ObjectWillChangePublisher { get }
}

private nonisolated(unsafe) var publisherKey: UInt8 = 0
private let publisherTableLock = NSLock()
private nonisolated(unsafe) var publisherTable: [ObjectIdentifier: ObservableObjectPublisher] = [:]

extension ObservableObject where ObjectWillChangePublisher == ObservableObjectPublisher {
    public var objectWillChange: ObservableObjectPublisher {
        publisherTableLock.lock()
        defer { publisherTableLock.unlock() }
        let key = ObjectIdentifier(self)
        if let existing = publisherTable[key] { return existing }
        let publisher = ObservableObjectPublisher()
        publisherTable[key] = publisher
        return publisher
    }
}

@propertyWrapper
public struct Published<Value> {
    private var value: Value

    public init(wrappedValue: Value) { value = wrappedValue }
    public init(initialValue: Value) { value = initialValue }

    @available(*, unavailable, message: "@Published is only available on properties of classes")
    public var wrappedValue: Value {
        get { fatalError() }
        set { fatalError() }
    }

    public static subscript<EnclosingSelf: ObservableObject>(
        _enclosingInstance object: EnclosingSelf,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<EnclosingSelf, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<EnclosingSelf, Published<Value>>
    ) -> Value {
        get { object[keyPath: storageKeyPath].value }
        set {
            if let publisher = object.objectWillChange as? ObservableObjectPublisher {
                publisher.send()
            }
            object[keyPath: storageKeyPath].value = newValue
        }
    }
}
#endif
