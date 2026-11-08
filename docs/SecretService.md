# SecretService

`SecretService` keeps secrets in the freedesktop Secret Service (GNOME Keyring, KWallet, KeePassXC) through
libsecret, for Linux code that keeps secrets where Apple platforms use the keychain. The [CryptoKit](CryptoKit.md)
stand-in's `SecureEnclave` keeps its sealing key here.

Items are generic passwords named by a service and an account, kept in the user's default (login) collection, which
the desktop unlocks at login; a locked collection asks the user to unlock it. It is not a keychain API: there are no
access groups, no synchronization and no attributes beyond the label.

## Getting started

Linux only (see [SwiftUI](SwiftUI.md#adding-the-package) for a conditional dependency; the product is only defined
on Linux). Building it needs `libsecret-1-dev`.

```swift
.package(url: "https://github.com/v57/SwiftUI.git", branch: "main")
// in the target:
.product(name: "SecretService", package: "SwiftUI")
```

```swift
import Foundation
import SecretService

let service = "com.example.myapp"
try SecretService.write(Data("token".utf8), service: service, account: "user", label: "My App token")
let token = try SecretService.read(service: service, account: "user")   // nil if there is none
try SecretService.delete(service: service, account: "user")
```

## Main API

- `SecretService.read(service:account:)`: the item's bytes, nil if there is none.
- `SecretService.write(_:service:account:label:)`: adds the item or replaces its bytes.
- `SecretService.delete(service:account:)`: removes the item; no error if there was none.
- `SecretService.all(service:)`: every item of a service, as `(account, data)` pairs.
- `SecretService.Failure`: thrown when the Secret Service refuses or isn't running (no D-Bus session, no keyring
  daemon); `message` says why.

## Platform notes

- **Linux**: needs a running Secret Service in the user's D-Bus session.
- **macOS, iOS, Windows, Android**: not built. Use the keychain on Apple platforms.

## Testing

`StandInFrameworkTests` in `CompatTests` write, read, list and delete items; the test runs only where a Secret
Service answers:

```bash
swift test --filter StandInFrameworkTests
```
