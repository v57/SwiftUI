# CryptoKit

Off Apple platforms the `CryptoKit` product stands in for Apple's CryptoKit, so code that writes `import CryptoKit`
builds unchanged on Linux, Windows and Android. It re-exports swift-crypto's `Crypto` module, which has CryptoKit's
API (hashes, HMAC, AES-GCM, ChaChaPoly, HKDF, P256 / P384 / P521, Curve25519), and adds `SecureEnclave` keys sealed
to the device's user.

It is not a Secure Enclave. The stand-in's keys are ordinary software keys: the private key is in memory while it is
used, and the stored blob is protected by the operating system's per-user encryption, not by hardware.

## Getting started

Add it only for builds off Apple platforms, where Apple's CryptoKit doesn't exist (see
[SwiftUI](SwiftUI.md#adding-the-package) for the conditional dependency; the product is only defined there):

```swift
.package(url: "https://github.com/v57/SwiftUI.git", branch: "main")
// in the target:
.product(name: "CryptoKit", package: "SwiftUI")
```

```swift
import CryptoKit
import Foundation

let digest = SHA256.hash(data: Data("hello".utf8))

if SecureEnclave.isAvailable {
    let key = try SecureEnclave.P256.Signing.PrivateKey()
    let blob = key.dataRepresentation        // store this; it opens only for this user on this machine
    let reopened = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob)
    let signature = try reopened.signature(for: Data("message".utf8))
    let valid = key.publicKey.isValidSignature(signature, for: Data("message".utf8))
}
```

## Main API

Everything in swift-crypto's `Crypto` (see its documentation), plus:

- `SecureEnclave.isAvailable`: whether keys can be sealed to the device (always on Windows; on Linux when a Secret
  Service answers; never on Android).
- `SecureEnclave.P256.Signing.PrivateKey`: `init(compactRepresentable:accessControl:authenticationContext:)` makes a
  key, `init(dataRepresentation:authenticationContext:)` reopens one from its blob; `dataRepresentation`,
  `publicKey`, `signature(for:)` (data or a digest).
- `SecureEnclave.P256.KeyAgreement.PrivateKey`: the same initializers, `dataRepresentation`, `publicKey`,
  `sharedSecretFromKeyAgreement(with:)`.
- `SecureEnclave.Error`: `unavailable`, `sealFailed`, `unsealFailed`.
- `SecAccessControl`: accepted and ignored (`.default`). Keys have no user-presence check.

A key's `dataRepresentation` is its private key sealed to this device's user: DPAPI on Windows; on Linux AES-GCM
under a 256-bit key kept in the user's Secret Service login collection (made on first use, see
[SecretService](SecretService.md)). The blob opens only on the same machine for the same account.

## Platform notes

- **macOS, iOS**: not built. Use Apple's CryptoKit.
- **Linux**: needs `libsecret-1-dev` to build. `SecureEnclave` needs a running Secret Service (GNOME Keyring,
  KWallet, KeePassXC); without one `isAvailable` is false and the initializers throw `unavailable`.
- **Windows**: `SecureEnclave` seals with DPAPI.
- **Android**: swift-crypto works; `SecureEnclave` is unavailable.

## Testing

`CompatTests` (built on Linux and Windows) cover hashing, sealing and reopening a `SecureEnclave` key from its blob;
the key tests run only where `SecureEnclave.isAvailable`:

```bash
swift test --filter StandInFrameworkTests
```
