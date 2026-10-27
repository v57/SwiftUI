// The freedesktop Secret Service (GNOME Keyring, KWallet, KeePassXC) through libsecret, for Linux code that keeps
// secrets where Apple platforms use the keychain: VaultKit's keychain and CryptoKit's SecureEnclave stand-in.
// Items are generic passwords named by a service and an account, kept in the user's default (login) collection,
// which the desktop unlocks at login; a locked one asks the user to unlock it.
import Foundation

// CSecretService's functions, declared here rather than imported: a C module in this module's interface would be
// needed by every module that sees it, and the CryptoKit stand-in (which uses this) is imported by packages that
// don't depend on it (HubService checks `canImport(CryptoKit)`).
@_extern(c, "v57_secret_store")
private func v57_secret_store(
    _ service: UnsafePointer<CChar>, _ account: UnsafePointer<CChar>, _ label: UnsafePointer<CChar>,
    _ data: UnsafePointer<UInt8>?, _ length: Int, _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32
@_extern(c, "v57_secret_lookup")
private func v57_secret_lookup(
    _ service: UnsafePointer<CChar>, _ account: UnsafePointer<CChar>,
    _ data: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, _ length: UnsafeMutablePointer<Int>,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32
@_extern(c, "v57_secret_clear")
private func v57_secret_clear(
    _ service: UnsafePointer<CChar>, _ account: UnsafePointer<CChar>,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32
@_extern(c, "v57_secret_search")
private func v57_secret_search(
    _ service: UnsafePointer<CChar>, _ context: UnsafeMutableRawPointer?,
    _ callback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<UInt8>?, Int) -> Void,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32
@_extern(c, "v57_secret_free")
private func v57_secret_free(_ pointer: UnsafeMutableRawPointer?)

public enum SecretService {
    /// The Secret Service refused or isn't running (no D-Bus session, no keyring daemon).
    public struct Failure: Error, LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { "Secret Service: \(message)" }
    }

    /// The item's bytes, nil if there's none.
    public static func read(service: String, account: String) throws(Failure) -> Data? {
        var bytes: UnsafeMutablePointer<UInt8>?
        var length = 0
        var error: UnsafeMutablePointer<CChar>?
        let result = v57_secret_lookup(service, account, &bytes, &length, &error)
        try check(result, error)
        guard result == 0, let bytes else { return nil }
        defer { v57_secret_free(bytes) }
        return Data(bytes: bytes, count: length)
    }

    /// Adds the item or replaces its bytes.
    public static func write(_ data: Data, service: String, account: String, label: String? = nil) throws(Failure) {
        var error: UnsafeMutablePointer<CChar>?
        let result = data.withUnsafeBytes { buffer in
            v57_secret_store(
                service, account, label ?? "\(service) (\(account))",
                buffer.baseAddress?.assumingMemoryBound(to: UInt8.self), buffer.count, &error)
        }
        try check(result, error)
    }

    /// Removes the item; no error if there was none.
    public static func delete(service: String, account: String) throws(Failure) {
        var error: UnsafeMutablePointer<CChar>?
        try check(v57_secret_clear(service, account, &error), error)
    }

    /// Every item of `service`.
    public static func all(service: String) throws(Failure) -> [(account: String, data: Data)] {
        final class Box { var items: [(account: String, data: Data)] = [] }
        let box = Box()
        var error: UnsafeMutablePointer<CChar>?
        let result = withExtendedLifetime(box) {
            v57_secret_search(service, Unmanaged.passUnretained(box).toOpaque(), { context, account, bytes, length in
                guard let context, let account else { return }
                let box = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
                let data = bytes.map { Data(bytes: $0, count: length) } ?? Data()
                box.items.append((String(cString: account), data))
            }, &error)
        }
        try check(result, error)
        return box.items
    }

    private static func check(_ result: Int32, _ error: UnsafeMutablePointer<CChar>?) throws(Failure) {
        guard result < 0 else { return }
        let message = error.map { String(cString: $0) } ?? "error"
        if let error { v57_secret_free(error) }
        throw Failure(message: message)
    }
}
