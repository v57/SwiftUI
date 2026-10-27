// Network stand-in (Linux, Windows): the part of Network.framework apps use for plain connections:
// NWConnection (TCP with optional TLS, connected UDP), NWListener (TCP), endpoints and parameters. Sockets are
// Winsock or BSD sockets driven by a thread per connection; TLS is SChannel on Windows and OpenSSL on Linux.
import Foundation

/// A POSIX error code with Apple's names (the platform's `POSIXErrorCode` lacks the socket errors on Windows).
public enum NWPOSIXErrorCode: Int32, Sendable, CustomStringConvertible {
    case EPERM = 1, ENOENT = 2, EINTR = 4, EIO = 5, EBADF = 9, EAGAIN = 35, EACCES = 13, EINVAL = 22, EPIPE = 32
    case EINPROGRESS = 36, ENOTSOCK = 38, EMSGSIZE = 40, EPROTONOSUPPORT = 43, EOPNOTSUPP = 45, EAFNOSUPPORT = 47
    case EADDRINUSE = 48, EADDRNOTAVAIL = 49, ENETDOWN = 50, ENETUNREACH = 51, ECONNABORTED = 53, ECONNRESET = 54
    case ENOBUFS = 55, EISCONN = 56, ENOTCONN = 57, ETIMEDOUT = 60, ECONNREFUSED = 61, EHOSTDOWN = 64
    case EHOSTUNREACH = 65, ECANCELED = 89

    public var description: String {
        switch self {
        case .ECONNREFUSED: "Connection refused"
        case .ECONNRESET: "Connection reset by peer"
        case .ECONNABORTED: "Software caused connection abort"
        case .ETIMEDOUT: "Operation timed out"
        case .EHOSTUNREACH: "No route to host"
        case .ENETUNREACH: "Network is unreachable"
        case .ENOTCONN: "Socket is not connected"
        case .ECANCELED: "Operation canceled"
        case .EADDRINUSE: "Address already in use"
        case .EADDRNOTAVAIL: "Can't assign requested address"
        default: "POSIX error \(rawValue)"
        }
    }
}

/// An error from a connection: a POSIX error (connect, send, receive), a DNS lookup failure or a TLS failure.
public enum NWError: Error, Equatable, Sendable, CustomDebugStringConvertible {
    case posix(NWPOSIXErrorCode)
    case dns(Int32)
    case tls(Int32)

    public var debugDescription: String {
        switch self {
        case .posix(let code): "POSIXErrorCode(rawValue: \(code.rawValue)): \(code)"
        case .dns(let code): "DNS error \(code)"
        case .tls(let status): "TLS error \(status)"
        }
    }

    public var errorCode: Int32 {
        switch self {
        case .posix(let code): code.rawValue
        case .dns(let code), .tls(let code): code
        }
    }

    public var localizedDescription: String { debugDescription }
}

public enum NWEndpoint: Hashable, Sendable, CustomDebugStringConvertible {
    case hostPort(host: Host, port: Port)
    case unix(path: String)
    case service(name: String, type: String, domain: String, interface: NWInterface?)
    case url(URL)

    public enum Host: Hashable, Sendable, ExpressibleByStringLiteral, CustomDebugStringConvertible {
        case name(String, NWInterface?)
        case ipv4(IPv4Address)
        case ipv6(IPv6Address)

        public init(_ string: String) {
            if let v4 = IPv4Address(string) { self = .ipv4(v4) } else if let v6 = IPv6Address(string) { self = .ipv6(v6) } else {
                self = .name(string, nil)
            }
        }

        public init(stringLiteral value: String) { self.init(value) }

        public var debugDescription: String {
            switch self {
            case .name(let name, _): name
            case .ipv4(let address): address.debugDescription
            case .ipv6(let address): address.debugDescription
            }
        }
    }

    public struct Port: Hashable, Sendable, ExpressibleByIntegerLiteral, CustomDebugStringConvertible {
        public let rawValue: UInt16
        public init?(rawValue: UInt16) { self.rawValue = rawValue }
        public init?(_ string: String) {
            guard let value = UInt16(string) else { return nil }
            rawValue = value
        }
        public init(integerLiteral value: UInt16) { rawValue = value }
        public static let any = Port(integerLiteral: 0)
        public static let http = Port(integerLiteral: 80)
        public static let https = Port(integerLiteral: 443)
        public var debugDescription: String { String(rawValue) }
    }

    public var debugDescription: String {
        switch self {
        case let .hostPort(host, port): "\(host.debugDescription):\(port.rawValue)"
        case .unix(let path): path
        case .service(let name, let type, let domain, _): "\(name).\(type)\(domain)"
        case .url(let url): url.absoluteString
        }
    }
}

public struct NWInterface: Hashable, Sendable {
    public let name: String
}

public struct IPv4Address: Hashable, Sendable, CustomDebugStringConvertible {
    public let rawValue: Data
    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard let value = UInt8(part) else { return nil }
            bytes.append(value)
        }
        rawValue = Data(bytes)
    }
    public init?(_ rawValue: Data) {
        guard rawValue.count == 4 else { return nil }
        self.rawValue = rawValue
    }
    public static let any = IPv4Address("0.0.0.0")!
    public static let loopback = IPv4Address("127.0.0.1")!
    public var debugDescription: String { rawValue.map(String.init).joined(separator: ".") }
}

public struct IPv6Address: Hashable, Sendable, CustomDebugStringConvertible {
    public let text: String
    public init?(_ string: String) {
        guard string.contains(":"), string.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." || $0 == "%" }) else { return nil }
        text = string
    }
    public static let any = IPv6Address("::")!
    public static let loopback = IPv6Address("::1")!
    public var debugDescription: String { text }
}

/// TCP options.
public final class NWProtocolTCP: @unchecked Sendable {
    public final class Options: @unchecked Sendable {
        public var noDelay = false
        /// Seconds to wait for the connection (0: the system's).
        public var connectionTimeout = 0
        public var enableKeepalive = false
        public var keepaliveIdle = 0
        public init() {}
    }
}

public final class NWProtocolUDP: @unchecked Sendable {
    public final class Options: @unchecked Sendable {
        public init() {}
    }
}

/// TLS options: the server name, ALPN protocols and an optional verification override.
public final class NWProtocolTLS: @unchecked Sendable {
    public final class Options: @unchecked Sendable {
        public let securityProtocolOptions = sec_protocol_options_t()
        public init() {}
    }
}

/// TLS settings (Apple's `sec_protocol_options_t`), set with the `sec_protocol_options_*` functions.
public final class sec_protocol_options_t: @unchecked Sendable {
    var serverName: String?
    var applicationProtocols: [String] = []
    var verify: sec_protocol_verify_t?
}

/// What a verify block gets: the connection's TLS metadata and the peer's trust (opaque here).
public final class sec_protocol_metadata_t: @unchecked Sendable {}
public final class sec_trust_t: @unchecked Sendable {}
public typealias sec_protocol_verify_complete_t = (Bool) -> Void
public typealias sec_protocol_verify_t = (sec_protocol_metadata_t, sec_trust_t, @escaping sec_protocol_verify_complete_t) -> Void

public func sec_protocol_options_set_tls_server_name(_ options: sec_protocol_options_t, _ serverName: String) {
    options.serverName = serverName
}

public func sec_protocol_options_add_tls_application_protocol(_ options: sec_protocol_options_t, _ applicationProtocol: String) {
    options.applicationProtocols.append(applicationProtocol)
}

/// Decides whether to trust the server; without one the system checks the certificate and the server name.
public func sec_protocol_options_set_verify_block(_ options: sec_protocol_options_t, _ verifyBlock: @escaping sec_protocol_verify_t, _ queue: DispatchQueue) {
    options.verify = verifyBlock
}

/// How a connection is made: TCP (optionally under TLS) or UDP.
public final class NWParameters: @unchecked Sendable {
    enum Transport { case tcp(NWProtocolTCP.Options), udp }
    let transport: Transport
    let tls: NWProtocolTLS.Options?
    public var allowLocalEndpointReuse = false
    public var requiredLocalEndpoint: NWEndpoint?
    public var includePeerToPeer = false

    public init(tls: NWProtocolTLS.Options?, tcp: NWProtocolTCP.Options = NWProtocolTCP.Options()) {
        transport = .tcp(tcp)
        self.tls = tls
    }

    public init(dtls: NWProtocolTLS.Options?, udp: NWProtocolUDP.Options = NWProtocolUDP.Options()) {
        transport = .udp
        tls = nil
    }

    public static var tcp: NWParameters { NWParameters(tls: nil) }
    public static var tls: NWParameters { NWParameters(tls: NWProtocolTLS.Options()) }
    public static var udp: NWParameters { NWParameters(dtls: nil) }

    var isUDP: Bool { if case .udp = transport { true } else { false } }
    var tcpOptions: NWProtocolTCP.Options? { if case .tcp(let options) = transport { options } else { nil } }
}
