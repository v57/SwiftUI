import Foundation

#if os(Windows)
import WinSDK
#elseif os(Linux)
internal import SecretService
#endif

/// Device-bound keys, standing in for the Secure Enclave. A key's `dataRepresentation` is its private key sealed
/// to this device's user (DPAPI on Windows; on Linux AES-GCM under a key kept in the user's Secret Service): it
/// opens only on this machine, for this account, which is what code that stores a Secure Enclave key blob relies
/// on. Unlike the Secure Enclave the private key is in memory while the key is used.
public enum SecureEnclave {
    /// Whether keys can be sealed to the device (Windows: DPAPI; Linux: a Secret Service answers).
    public static var isAvailable: Bool {
        #if os(Windows)
        true
        #elseif os(Linux)
        DeviceSeal.linuxKey != nil
        #else
        false
        #endif
    }

    public enum Error: Swift.Error, Sendable {
        case unavailable
        case sealFailed
        case unsealFailed
    }

    public enum P256 {
        public enum Signing {
            public struct PrivateKey: @unchecked Sendable {
                let key: Crypto.P256.Signing.PrivateKey

                public init(compactRepresentable: Bool = true, accessControl: SecAccessControl = .default, authenticationContext: Any? = nil) throws {
                    guard SecureEnclave.isAvailable else { throw Error.unavailable }
                    key = Crypto.P256.Signing.PrivateKey(compactRepresentable: compactRepresentable)
                }

                public init(dataRepresentation: Data, authenticationContext: Any? = nil) throws {
                    key = try Crypto.P256.Signing.PrivateKey(rawRepresentation: DeviceSeal.open(dataRepresentation))
                }

                public var dataRepresentation: Data { (try? DeviceSeal.seal(key.rawRepresentation)) ?? Data() }
                public var publicKey: Crypto.P256.Signing.PublicKey { key.publicKey }

                public func signature<D: DataProtocol>(for data: D) throws -> Crypto.P256.Signing.ECDSASignature {
                    try key.signature(for: data)
                }

                public func signature<D: Digest>(for digest: D) throws -> Crypto.P256.Signing.ECDSASignature {
                    try key.signature(for: digest)
                }
            }
        }

        public enum KeyAgreement {
            public struct PrivateKey: @unchecked Sendable {
                let key: Crypto.P256.KeyAgreement.PrivateKey

                public init(compactRepresentable: Bool = true, accessControl: SecAccessControl = .default, authenticationContext: Any? = nil) throws {
                    guard SecureEnclave.isAvailable else { throw Error.unavailable }
                    key = Crypto.P256.KeyAgreement.PrivateKey(compactRepresentable: compactRepresentable)
                }

                public init(dataRepresentation: Data, authenticationContext: Any? = nil) throws {
                    key = try Crypto.P256.KeyAgreement.PrivateKey(rawRepresentation: DeviceSeal.open(dataRepresentation))
                }

                public var dataRepresentation: Data { (try? DeviceSeal.seal(key.rawRepresentation)) ?? Data() }
                public var publicKey: Crypto.P256.KeyAgreement.PublicKey { key.publicKey }

                public func sharedSecretFromKeyAgreement(with publicKeyShare: Crypto.P256.KeyAgreement.PublicKey) throws -> SharedSecret {
                    try key.sharedSecretFromKeyAgreement(with: publicKeyShare)
                }
            }
        }
    }
}

/// Access control for a device key (Apple's `SecAccessControl`). Keys here have no user-presence gating; the
/// value is accepted and ignored.
public struct SecAccessControl: Sendable {
    public static let `default` = SecAccessControl()
    public init() {}
}

/// Seals bytes to this device's user.
enum DeviceSeal {
    static func seal(_ data: Data) throws -> Data {
        #if os(Windows)
        return try crypt(data, protect: true)
        #elseif os(Linux)
        guard let key = linuxKey else { throw SecureEnclave.Error.unavailable }
        guard let sealed = try? AES.GCM.seal(data, using: key).combined else { throw SecureEnclave.Error.sealFailed }
        return Data([linuxVersion]) + sealed
        #else
        throw SecureEnclave.Error.unavailable
        #endif
    }

    static func open(_ data: Data) throws -> Data {
        #if os(Windows)
        return try crypt(data, protect: false)
        #elseif os(Linux)
        guard let key = linuxKey else { throw SecureEnclave.Error.unavailable }
        guard data.first == linuxVersion, let box = try? AES.GCM.SealedBox(combined: data.dropFirst()),
              let opened = try? AES.GCM.open(box, using: key)
        else { throw SecureEnclave.Error.unsealFailed }
        return opened
        #else
        throw SecureEnclave.Error.unavailable
        #endif
    }

    #if os(Windows)
    private static func crypt(_ data: Data, protect: Bool) throws -> Data {
        var bytes = [UInt8](data)
        return try bytes.withUnsafeMutableBufferPointer { buffer -> Data in
            var input = DATA_BLOB(cbData: DWORD(buffer.count), pbData: buffer.baseAddress)
            var output = DATA_BLOB()
            let ok = protect
                ? CryptProtectData(&input, nil, nil, nil, nil, DWORD(CRYPTPROTECT_UI_FORBIDDEN), &output)
                : CryptUnprotectData(&input, nil, nil, nil, nil, DWORD(CRYPTPROTECT_UI_FORBIDDEN), &output)
            guard ok, let pointer = output.pbData else { throw protect ? SecureEnclave.Error.sealFailed : SecureEnclave.Error.unsealFailed }
            defer { LocalFree(pointer) }
            return Data(bytes: pointer, count: Int(output.cbData))
        }
    }
    #endif

    #if os(Linux)
    /// The first byte of a Linux seal: AES-GCM (nonce, ciphertext, tag) under `linuxKey`.
    private static let linuxVersion: UInt8 = 1
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedKey: SymmetricKey?

    /// This user's sealing key: 256 random bits kept in the Secret Service's login collection, made on first use;
    /// nil when no Secret Service answers.
    static var linuxKey: SymmetricKey? {
        lock.lock()
        defer { lock.unlock() }
        if let cachedKey { return cachedKey }
        let service = "dev.v57.device-seal", account = "key"
        do {
            if let stored = try SecretService.read(service: service, account: account), stored.count == 32 {
                cachedKey = SymmetricKey(data: stored)
            } else {
                let key = SymmetricKey(size: .bits256)
                let bytes = key.withUnsafeBytes { Data($0) }
                try SecretService.write(bytes, service: service, account: account, label: "v57 device key")
                cachedKey = key
            }
        } catch {
            return nil
        }
        return cachedKey
    }
    #endif
}
