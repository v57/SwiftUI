import CNetworkSupport
import Foundation

#if os(Windows)
import WinSDK
typealias SocketHandle = SOCKET
let invalidSocket = INVALID_SOCKET
#else
typealias SocketHandle = Int32
let invalidSocket: Int32 = -1
#endif

/// A blocking socket. Closing it from another thread makes a blocked call return with an error.
final class Socket: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: SocketHandle
    private(set) var isClosed = false

    init(handle: SocketHandle) { self.handle = handle }

    static func startup() {
        #if os(Windows)
        _ = winsockStarted
        #endif
    }

    #if os(Windows)
    private static let winsockStarted: Bool = {
        var data = WSADATA()
        return WSAStartup(0x0202, &data) == 0
    }()
    #endif

    /// The last socket error as a POSIX code.
    static func lastError() -> NWError {
        #if os(Windows)
        let code = WSAGetLastError()
        let posix: NWPOSIXErrorCode = switch code {
        case WSAECONNREFUSED: .ECONNREFUSED
        case WSAECONNRESET: .ECONNRESET
        case WSAECONNABORTED: .ECONNABORTED
        case WSAETIMEDOUT: .ETIMEDOUT
        case WSAEHOSTUNREACH: .EHOSTUNREACH
        case WSAENETUNREACH: .ENETUNREACH
        case WSAEADDRINUSE: .EADDRINUSE
        case WSAEADDRNOTAVAIL: .EADDRNOTAVAIL
        case WSAENOTSOCK, WSAEINTR: .ECANCELED
        case WSAEMSGSIZE: .EMSGSIZE
        case WSAEACCES: .EACCES
        default: .EIO
        }
        return .posix(posix)
        #else
        let posix: NWPOSIXErrorCode = switch errno {
        case ECONNREFUSED: .ECONNREFUSED
        case ECONNRESET: .ECONNRESET
        case ECONNABORTED: .ECONNABORTED
        case ETIMEDOUT: .ETIMEDOUT
        case EHOSTUNREACH: .EHOSTUNREACH
        case ENETUNREACH: .ENETUNREACH
        case EADDRINUSE: .EADDRINUSE
        case EADDRNOTAVAIL: .EADDRNOTAVAIL
        case EBADF, EINTR: .ECANCELED
        case EMSGSIZE: .EMSGSIZE
        case EACCES: .EACCES
        case EPIPE: .EPIPE
        default: .EIO
        }
        return .posix(posix)
        #endif
    }

    /// Resolves a host and port to socket addresses (blocking).
    static func resolve(_ host: String, port: UInt16, udp: Bool, passive: Bool = false) throws -> [Data] {
        startup()
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if os(Windows)
        hints.ai_socktype = udp ? Int32(SOCK_DGRAM) : Int32(SOCK_STREAM)
        #else
        hints.ai_socktype = Int32(udp ? SOCK_DGRAM.rawValue : SOCK_STREAM.rawValue)
        #endif
        if passive { hints.ai_flags = AI_PASSIVE }
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(passive && host.isEmpty ? nil : host, String(port), &hints, &result)
        guard status == 0, let first = result else { throw NWError.dns(Int32(status)) }
        defer { freeaddrinfo(first) }
        var addresses: [Data] = []
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let info = current {
            if let address = info.pointee.ai_addr {
                addresses.append(Data(bytes: address, count: Int(info.pointee.ai_addrlen)))
            }
            current = info.pointee.ai_next
        }
        // IPv4 first: many trackers and peers publish AAAA records they don't listen on.
        return addresses.sorted { family($0) == AF_INET && family($1) != AF_INET }
    }

    static func family(_ address: Data) -> Int32 {
        address.withUnsafeBytes { Int32($0.load(as: sockaddr.self).sa_family) }
    }

    /// A socket connected to the first address that answers.
    static func connect(to addresses: [Data], udp: Bool, noDelay: Bool, cancelled: () -> Bool, current: (Socket) -> Void) throws -> Socket {
        var lastError: NWError = .posix(.EHOSTUNREACH)
        for address in addresses {
            if cancelled() { throw NWError.posix(.ECANCELED) }
            #if os(Windows)
            let type = udp ? Int32(SOCK_DGRAM) : Int32(SOCK_STREAM)
            let proto = udp ? Int32(IPPROTO_UDP.rawValue) : Int32(IPPROTO_TCP.rawValue)
            #else
            let type = Int32(udp ? SOCK_DGRAM.rawValue : SOCK_STREAM.rawValue)
            let proto = Int32(udp ? IPPROTO_UDP : IPPROTO_TCP)
            #endif
            let handle = socket(family(address), type, proto)
            guard handle != invalidSocket else { lastError = Socket.lastError(); continue }
            let socket = Socket(handle: handle)
            current(socket)
            if noDelay && !udp { socket.setOption(level: Int32(IPPROTO_TCP_LEVEL), name: TCP_NODELAY, value: 1) }
            let result = address.withUnsafeBytes { raw in
                #if os(Windows)
                WinSDK.connect(handle, raw.baseAddress!.assumingMemoryBound(to: sockaddr.self), Int32(raw.count))
                #else
                Glibc.connect(handle, raw.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(raw.count))
                #endif
            }
            if result == 0 { return socket }
            lastError = Socket.lastError()
            socket.close()
        }
        throw cancelled() ? NWError.posix(.ECANCELED) : lastError
    }

    func setOption(level: Int32, name: Int32, value: Int32) {
        var value = value
        #if os(Windows)
        withUnsafePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 4) { _ = setsockopt(handle, level, name, $0, 4) }
        }
        #else
        _ = setsockopt(handle, level, name, &value, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    /// Sends all of `data`.
    func send(_ data: Data) throws {
        var offset = 0
        while offset < data.count {
            let sent = data.withUnsafeBytes { raw -> Int in
                let base = raw.baseAddress!.advanced(by: offset)
                #if os(Windows)
                return Int(WinSDK.send(handle, base.assumingMemoryBound(to: CChar.self), Int32(min(raw.count - offset, 1 << 20)), 0))
                #else
                return Glibc.send(handle, base, raw.count - offset, Int32(MSG_NOSIGNAL))
                #endif
            }
            guard sent > 0 else { throw isClosed ? NWError.posix(.ECANCELED) : Socket.lastError() }
            offset += sent
        }
    }

    /// Receives up to `maximum` bytes; empty at the end of the stream.
    func receive(maximum: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: max(1, maximum))
        let count = buffer.withUnsafeMutableBytes { raw -> Int in
            #if os(Windows)
            return Int(recv(handle, raw.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(raw.count), 0))
            #else
            return recv(handle, raw.baseAddress!, raw.count, 0)
            #endif
        }
        guard count >= 0 else { throw isClosed ? NWError.posix(.ECANCELED) : Socket.lastError() }
        return Data(buffer[0..<count])
    }

    /// Listens on a port (0: any), on every IPv4 and IPv6 address where possible.
    static func listen(port: UInt16, reuse: Bool) throws -> (Socket, UInt16) {
        startup()
        let addresses = try resolve("", port: port, udp: false, passive: true)
        guard let address = addresses.first(where: { family($0) == AF_INET6 }) ?? addresses.first else { throw NWError.posix(.EADDRNOTAVAIL) }
        #if os(Windows)
        let handle = socket(family(address), Int32(SOCK_STREAM), Int32(IPPROTO_TCP.rawValue))
        #else
        let handle = socket(family(address), Int32(SOCK_STREAM.rawValue), Int32(IPPROTO_TCP))
        #endif
        guard handle != invalidSocket else { throw Socket.lastError() }
        let socket = Socket(handle: handle)
        if family(address) == AF_INET6 { socket.setOption(level: Int32(IPPROTO_IPV6_LEVEL), name: Int32(IPV6_V6ONLY), value: 0) }
        if reuse { socket.setOption(level: Int32(SOL_SOCKET), name: Int32(SO_REUSEADDR), value: 1) }
        let bound = address.withUnsafeBytes { raw in
            #if os(Windows)
            bind(handle, raw.baseAddress!.assumingMemoryBound(to: sockaddr.self), Int32(raw.count))
            #else
            bind(handle, raw.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(raw.count))
            #endif
        }
        #if os(Windows)
        guard bound == 0, WinSDK.listen(handle, SOMAXCONN) == 0 else { let error = Socket.lastError(); socket.close(); throw error }
        #else
        guard bound == 0, Glibc.listen(handle, SOMAXCONN) == 0 else { let error = Socket.lastError(); socket.close(); throw error }
        #endif
        return (socket, socket.localPort() ?? port)
    }

    func localPort() -> UInt16? {
        var storage = sockaddr_storage()
        #if os(Windows)
        var length = Int32(MemoryLayout<sockaddr_storage>.size)
        #else
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        #endif
        let ok = withUnsafeMutablePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(handle, $0, &length) == 0 }
        }
        guard ok else { return nil }
        return withUnsafeBytes(of: &storage) { raw in
            // sin_port and sin6_port sit at the same offset, in network byte order.
            let port = raw.load(fromByteOffset: 2, as: UInt16.self)
            return UInt16(bigEndian: port)
        }
    }

    /// Waits for the next connection.
    func accept() throws -> Socket {
        #if os(Windows)
        let client = WinSDK.accept(handle, nil, nil)
        #else
        let client = Glibc.accept(handle, nil, nil)
        #endif
        guard client != invalidSocket else { throw isClosed ? NWError.posix(.ECANCELED) : Socket.lastError() }
        return Socket(handle: client)
    }

    /// The peer's address (host and port).
    func peer() -> NWEndpoint? {
        var storage = sockaddr_storage()
        #if os(Windows)
        var length = Int32(MemoryLayout<sockaddr_storage>.size)
        #else
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        #endif
        let ok = withUnsafeMutablePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(handle, $0, &length) == 0 }
        }
        guard ok else { return nil }
        var host = [CChar](repeating: 0, count: 64)
        var service = [CChar](repeating: 0, count: 16)
        let status = withUnsafePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, length, &host, 64, &service, 16, Int32(NI_NUMERICHOST | NI_NUMERICSERV))
            }
        }
        guard status == 0, let port = UInt16(String(cString: service)) else { return nil }
        return .hostPort(host: NWEndpoint.Host(String(cString: host)), port: NWEndpoint.Port(integerLiteral: port))
    }

    func close() {
        lock.lock()
        guard !isClosed else { lock.unlock(); return }
        isClosed = true
        lock.unlock()
        #if os(Windows)
        _ = shutdown(handle, Int32(SD_BOTH))
        _ = closesocket(handle)
        #else
        _ = shutdown(handle, Int32(SHUT_RDWR))
        _ = Glibc.close(handle)
        #endif
    }

    deinit { close() }
}

#if os(Windows)
let IPPROTO_TCP_LEVEL = Int32(IPPROTO_TCP.rawValue)
let IPPROTO_IPV6_LEVEL = Int32(IPPROTO_IPV6.rawValue)
#else
let IPPROTO_TCP_LEVEL = Int32(IPPROTO_TCP)
let IPPROTO_IPV6_LEVEL = Int32(IPPROTO_IPV6)
#endif
