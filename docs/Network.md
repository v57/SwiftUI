# Network

Off Apple platforms the `Network` product stands in for the part of Apple's Network framework that apps use for
plain connections: `NWConnection` (TCP with optional TLS, connected UDP), `NWListener` (TCP), endpoints and
parameters. Code that writes `import Network` builds unchanged on Linux and Windows.

It is not the whole framework. There is no Bonjour browsing or advertising, no `NWPathMonitor`, no QUIC or WebSocket
protocols, and connections take host-and-port endpoints only (`.unix`, `.service` and `.url` endpoints fail with
`EAFNOSUPPORT`). `currentPath` is nil and `restart()` does nothing.

## Getting started

Add it only for builds off Apple platforms (see [SwiftUI](SwiftUI.md#adding-the-package); the product is only
defined there):

```swift
.package(url: "https://github.com/v57/SwiftUI.git", branch: "main")
// in the target:
.product(name: "Network", package: "SwiftUI")
```

```swift
import Foundation
import Network

let connection = NWConnection(host: "example.com", port: .https, using: .tls)
connection.stateUpdateHandler = { state in
    switch state {
    case .ready:
        let request = Data("HEAD / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n".utf8)
        connection.send(content: request, completion: .contentProcessed { _ in })
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
            print(String(decoding: data ?? Data(), as: UTF8.self))
            connection.cancel()
        }
    case .failed(let error):
        print("failed: \(error)")
    default:
        break
    }
}
connection.start(queue: .main)
```

## Main API

- `NWConnection(host:port:using:)`, `NWConnection(to:using:)`; `stateUpdateHandler` and `state` (`setup`,
  `preparing`, `ready`, `waiting`, `failed`, `cancelled`), `start(queue:)`, `cancel()`, `forceCancel()`.
- Sending and receiving: `send(content:contentContext:isComplete:completion:)` with `.contentProcessed { error in }`
  or `.idempotent`; `receive(minimumIncompleteLength:maximumLength:completion:)` for streams;
  `receiveMessage(completion:)` for one UDP datagram.
- `NWListener(using:on:)`: `port`, `stateUpdateHandler`, `newConnectionHandler`, `start(queue:)`, `cancel()`.
- `NWParameters`: `.tcp`, `.tls`, `.udp`, `init(tls:tcp:)`, `init(dtls:udp:)`; `allowLocalEndpointReuse`.
  `NWProtocolTCP.Options` has `noDelay`, `connectionTimeout`, `enableKeepalive`, `keepaliveIdle`.
- TLS settings through `NWProtocolTLS.Options().securityProtocolOptions` and the `sec_protocol_options_*` functions:
  `set_tls_server_name`, `add_tls_application_protocol` (ALPN) and `set_verify_block`.
- `NWEndpoint` (`.hostPort`), `NWEndpoint.Host` (a name, `IPv4Address` or `IPv6Address`; string literals work),
  `NWEndpoint.Port` (integer literals, `.any`, `.http`, `.https`), `NWError` (`.posix`, `.dns`, `.tls`) with
  Apple's POSIX code names (`NWPOSIXErrorCode`).
- `TLSSession.connect(serverName:alpn:allowUntrusted:write:read:)` (not Apple API): TLS over any byte stream, such as
  an SSH channel.

Each connection runs on a thread of its own with blocking sockets (Winsock or BSD sockets); handlers are called on
the connection's queue.

TLS checks the server's certificate and name against the system's roots (SChannel on Windows, OpenSSL with
`/etc/ssl/certs` on Linux). A verify block set with `sec_protocol_options_set_verify_block` replaces that check, and
decides alone whether to trust the server.

## Platform notes

- **macOS, iOS**: not built. Use Apple's Network framework.
- **Linux**: TLS on OpenSSL (link `libssl` and `libcrypto`; `libssl-dev` to build).
- **Windows**: TLS on SChannel.
- **Android**: the product is built when cross-compiling, but there is no TLS backend: TLS connections fail. Plain
  TCP and UDP are untested there.

## Testing

`NetworkTests` in `CompatTests` (built on Linux and Windows) round-trip TCP through a listener. On Linux one test runs
TLS against a local `openssl s_server` (when `/usr/bin/openssl` exists); a TLS test against a public server runs
only with `NETWORK_TESTS_ONLINE=1`:

```bash
swift test --filter NetworkTests
NETWORK_TESTS_ONLINE=1 swift test --filter NetworkTests
```
