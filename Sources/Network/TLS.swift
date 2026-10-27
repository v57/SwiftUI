import CNetworkSupport
import Foundation

#if os(Windows)
import WinSDK

/// TLS over a byte stream with SChannel, the system's TLS: it checks the server's certificate and name against the
/// system's roots, unless a verify block decides. `read` and `write` move the encrypted bytes, so the session works
/// over any stream (a socket, an SSH channel).
public final class TLSSession: @unchecked Sendable {
    private var credentials = CredHandle()
    private var context = CtxtHandle()
    private var hasContext = false
    private var sizes = SecPkgContext_StreamSizes()
    /// Encrypted bytes received and not yet decrypted.
    private var pending: [UInt8] = []
    private let lock = NSLock()
    private var closed = false
    /// The protocol the server picked with ALPN.
    public private(set) var negotiatedProtocol: String?

    // SSPI's status codes and flags (macros Swift can't import).
    static let ok: Int32 = 0
    static let continueNeeded = Int32(bitPattern: 0x0009_0312)
    static let incompleteMessage = Int32(bitPattern: 0x8009_0318)
    static let contextExpired = Int32(bitPattern: 0x0009_0317)
    static let renegotiate = Int32(bitPattern: 0x0009_0321)
    static let bufferEmpty: UInt32 = 0, bufferData: UInt32 = 1, bufferToken: UInt32 = 2, bufferExtra: UInt32 = 5
    static let bufferTrailer: UInt32 = 6, bufferHeader: UInt32 = 7, bufferAlert: UInt32 = 17, bufferProtocols: UInt32 = 18
    static let requests: UInt32 = 0x8 | 0x4 | 0x10 | 0x100 | 0x4000 | 0x8000  // sequence, replay, confidentiality, allocate, extended error, stream

    /// Connects TLS over a socket.
    static func connect(socket: Socket, serverName: String, options: sec_protocol_options_t) throws -> TLSSession {
        let session = TLSSession()
        try session.handshake(
            serverName: serverName, alpn: options.applicationProtocols, verify: options.verify,
            write: { try socket.send($0) }, read: { try socket.receive(maximum: 65_536) })
        return session
    }

    /// Connects TLS over any stream: `write` sends bytes, `read` returns the next ones (empty at the end).
    public static func connect(
        serverName: String, alpn: [String] = [], allowUntrusted: Bool = false,
        write: (Data) throws -> Void, read: () throws -> Data
    ) throws -> TLSSession {
        let session = TLSSession()
        try session.handshake(
            serverName: serverName, alpn: alpn, verify: allowUntrusted ? { _, _, complete in complete(true) } : nil,
            write: write, read: read)
        return session
    }

    private init() {}

    deinit {
        if hasContext { DeleteSecurityContext(&context) }
        FreeCredentialsHandle(&credentials)
    }

    private func handshake(
        serverName: String, alpn: [String], verify: sec_protocol_verify_t?, write: (Data) throws -> Void, read: () throws -> Data
    ) throws {
        var schannel = SCH_CREDENTIALS()
        schannel.dwVersion = DWORD(SCH_CREDENTIALS_VERSION)
        // Manual validation lets the verify block decide; otherwise SChannel checks the chain and the name.
        schannel.dwFlags = DWORD(0x0040_0000 | 0x10 | (verify == nil ? 0x20 : 0x8))
        var expiry = TimeStamp()
        let acquired = withUnsafeMutablePointer(to: &schannel) { auth in
            AcquireCredentialsHandleW(nil, UnsafeMutablePointer(mutating: cns_unisp_name()), ULONG(SECPKG_CRED_OUTBOUND), nil, auth, nil, nil, &credentials, &expiry)
        }
        guard acquired == Self.ok else { throw NWError.tls(acquired) }

        let target = Array(serverName.utf16) + [0]
        var input: [UInt8] = []
        var first = true
        let flags = Self.requests | (verify == nil ? 0 : 0x0008_0000)
        while true {
            var attributes: ULONG = 0
            var outBuffers = [SecBuffer(cbBuffer: 0, BufferType: ULONG(Self.bufferToken), pvBuffer: nil),
                              SecBuffer(cbBuffer: 0, BufferType: ULONG(Self.bufferAlert), pvBuffer: nil)]
            var status: Int32 = 0
            var extra = 0
            var protocols = first ? Self.alpnBuffer(alpn) : []
            target.withUnsafeBufferPointer { name in
                input.withUnsafeMutableBytes { inputBytes in
                    protocols.withUnsafeMutableBytes { protocolBytes in
                        outBuffers.withUnsafeMutableBufferPointer { outs in
                            var outDesc = SecBufferDesc(ulVersion: ULONG(SECBUFFER_VERSION), cBuffers: 2, pBuffers: outs.baseAddress)
                            var inBuffers: [SecBuffer]
                            if first {
                                inBuffers = protocolBytes.isEmpty ? [] : [SecBuffer(cbBuffer: ULONG(protocolBytes.count), BufferType: ULONG(Self.bufferProtocols), pvBuffer: protocolBytes.baseAddress)]
                            } else {
                                inBuffers = [SecBuffer(cbBuffer: ULONG(inputBytes.count), BufferType: ULONG(Self.bufferToken), pvBuffer: inputBytes.baseAddress),
                                             SecBuffer(cbBuffer: 0, BufferType: ULONG(Self.bufferEmpty), pvBuffer: nil)]
                            }
                            inBuffers.withUnsafeMutableBufferPointer { ins in
                                var inDesc = SecBufferDesc(ulVersion: ULONG(SECBUFFER_VERSION), cBuffers: ULONG(ins.count), pBuffers: ins.baseAddress)
                                let name = UnsafeMutablePointer(mutating: name.baseAddress!)
                                let hasInput = !ins.isEmpty
                                status = withUnsafeMutablePointer(to: &context) { newContext in
                                    withUnsafeMutablePointer(to: &inDesc) { inDesc in
                                        InitializeSecurityContextW(
                                            &credentials, hasContext ? newContext : nil, name, ULONG(flags), 0, 0,
                                            hasInput ? inDesc : nil, 0, newContext, &outDesc, &attributes, nil)
                                    }
                                }
                                if !first, ins.count > 1, ins[1].BufferType == ULONG(Self.bufferExtra) { extra = Int(ins[1].cbBuffer) }
                            }
                        }
                    }
                }
            }
            first = false
            if status == Self.ok || status == Self.continueNeeded || status == Self.incompleteMessage { hasContext = true }
            if let token = outBuffers[0].pvBuffer {
                let data = Data(bytes: token, count: Int(outBuffers[0].cbBuffer))
                FreeContextBuffer(token)
                if !data.isEmpty { try write(data) }
            }
            if let alert = outBuffers[1].pvBuffer { FreeContextBuffer(alert) }
            switch status {
            case Self.ok:
                pending = extra > 0 ? Array(input.suffix(extra)) : []
                QueryContextAttributesW(&context, ULONG(SECPKG_ATTR_STREAM_SIZES), &sizes)
                negotiatedProtocol = queryALPN()
                if let verify { try Self.decide(verify) }
                return
            case Self.continueNeeded:
                input = extra > 0 ? Array(input.suffix(extra)) : []
                if input.isEmpty {
                    let chunk = try read()
                    guard !chunk.isEmpty else { throw NWError.posix(.ECONNRESET) }
                    input += chunk
                }
            case Self.incompleteMessage:
                let chunk = try read()
                guard !chunk.isEmpty else { throw NWError.posix(.ECONNRESET) }
                input += chunk
            default:
                throw NWError.tls(status)
            }
        }
    }

    /// Asks the verify block, waiting for its answer.
    private static func decide(_ verify: sec_protocol_verify_t) throws {
        let answer = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var trusted = false
        verify(sec_protocol_metadata_t(), sec_trust_t()) { ok in
            trusted = ok
            answer.signal()
        }
        answer.wait()
        guard trusted else { throw NWError.tls(-9808) }
    }

    /// SEC_APPLICATION_PROTOCOLS for ALPN: the list size, then one ALPN list of length-prefixed names.
    private static func alpnBuffer(_ names: [String]) -> [UInt8] {
        guard !names.isEmpty else { return [] }
        var list: [UInt8] = []
        for name in names { list.append(UInt8(name.utf8.count)); list += name.utf8 }
        var buffer: [UInt8] = []
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { buffer += $0 } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { buffer += $0 } }
        append32(UInt32(4 + 2 + list.count))  // ProtocolListsSize
        append32(2)  // SecApplicationProtocolNegotiationExt_ALPN
        append16(UInt16(list.count))
        return buffer + list
    }

    private func queryALPN() -> String? {
        var result = SecPkgContext_ApplicationProtocol()
        guard QueryContextAttributesW(&context, ULONG(SECPKG_ATTR_APPLICATION_PROTOCOL), &result) == Self.ok,
              result.ProtoNegoStatus == SecApplicationProtocolNegotiationStatus_Success
        else { return nil }
        let count = Int(result.ProtocolIdSize)
        return withUnsafeBytes(of: result.ProtocolId) { String(decoding: $0.prefix(count), as: UTF8.self) }
    }

    /// Encrypts application data into TLS records.
    public func encrypt(_ data: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        var output = Data()
        let header = Int(sizes.cbHeader), trailer = Int(sizes.cbTrailer), maximum = max(1, Int(sizes.cbMaximumMessage))
        var offset = 0
        while offset < data.count {
            let count = min(maximum, data.count - offset)
            var record = [UInt8](repeating: 0, count: header + count + trailer)
            data.copyBytes(to: &record[header], from: offset..<offset + count)
            var status: Int32 = 0
            var sizesOut = (0, 0, 0)
            record.withUnsafeMutableBytes { raw in
                let base = raw.baseAddress!
                var buffers = [SecBuffer(cbBuffer: ULONG(header), BufferType: ULONG(Self.bufferHeader), pvBuffer: base),
                               SecBuffer(cbBuffer: ULONG(count), BufferType: ULONG(Self.bufferData), pvBuffer: base + header),
                               SecBuffer(cbBuffer: ULONG(trailer), BufferType: ULONG(Self.bufferTrailer), pvBuffer: base + header + count),
                               SecBuffer(cbBuffer: 0, BufferType: ULONG(Self.bufferEmpty), pvBuffer: nil)]
                buffers.withUnsafeMutableBufferPointer { pointer in
                    var desc = SecBufferDesc(ulVersion: ULONG(SECBUFFER_VERSION), cBuffers: 4, pBuffers: pointer.baseAddress)
                    status = EncryptMessage(&context, 0, &desc, 0)
                    sizesOut = (Int(pointer[0].cbBuffer), Int(pointer[1].cbBuffer), Int(pointer[2].cbBuffer))
                }
            }
            guard status == Self.ok else { throw NWError.tls(status) }
            output.append(contentsOf: record[0..<(sizesOut.0 + sizesOut.1 + sizesOut.2)])
            offset += count
        }
        return output
    }

    /// The next application data: reads and decrypts records until one carries data. Empty at the end.
    public func decrypt(read: () throws -> Data) throws -> Data {
        while true {
            if closed { return Data() }
            var status: Int32 = 0
            var plaintext = Data()
            var extra: [UInt8] = []
            if !pending.isEmpty {
                lock.lock()
                pending.withUnsafeMutableBytes { raw in
                    var buffers = [SecBuffer(cbBuffer: ULONG(raw.count), BufferType: ULONG(Self.bufferData), pvBuffer: raw.baseAddress),
                                   SecBuffer(cbBuffer: 0, BufferType: ULONG(Self.bufferEmpty), pvBuffer: nil),
                                   SecBuffer(cbBuffer: 0, BufferType: ULONG(Self.bufferEmpty), pvBuffer: nil),
                                   SecBuffer(cbBuffer: 0, BufferType: ULONG(Self.bufferEmpty), pvBuffer: nil)]
                    buffers.withUnsafeMutableBufferPointer { pointer in
                        var desc = SecBufferDesc(ulVersion: ULONG(SECBUFFER_VERSION), cBuffers: 4, pBuffers: pointer.baseAddress)
                        status = DecryptMessage(&context, &desc, 0, nil)
                        for buffer in pointer {
                            if buffer.BufferType == ULONG(Self.bufferData), let bytes = buffer.pvBuffer {
                                plaintext.append(bytes.assumingMemoryBound(to: UInt8.self), count: Int(buffer.cbBuffer))
                            } else if buffer.BufferType == ULONG(Self.bufferExtra), let bytes = buffer.pvBuffer {
                                extra = Array(UnsafeBufferPointer(start: bytes.assumingMemoryBound(to: UInt8.self), count: Int(buffer.cbBuffer)))
                            }
                        }
                    }
                }
                lock.unlock()
            } else {
                status = Self.incompleteMessage
            }
            switch status {
            case Self.incompleteMessage:
                let chunk = try read()
                guard !chunk.isEmpty else { return Data() }
                pending += chunk
                continue
            case Self.ok:
                pending = extra
            case Self.contextExpired:
                // close_notify.
                pending = []
                closed = true
            case Self.renegotiate:
                // TLS 1.3 post-handshake messages (session tickets): SChannel takes them through the handshake call.
                pending = []
                try continueHandshake(with: extra)
            default:
                throw NWError.tls(status)
            }
            if !plaintext.isEmpty { return plaintext }
        }
    }

    /// Feeds post-handshake records to SChannel.
    private func continueHandshake(with data: [UInt8]) throws {
        var input = data
        var status: Int32 = 0
        var attributes: ULONG = 0
        var extra = 0
        lock.lock()
        defer { lock.unlock() }
        var outBuffers = [SecBuffer(cbBuffer: 0, BufferType: ULONG(Self.bufferToken), pvBuffer: nil)]
        input.withUnsafeMutableBytes { raw in
            outBuffers.withUnsafeMutableBufferPointer { outs in
                var outDesc = SecBufferDesc(ulVersion: ULONG(SECBUFFER_VERSION), cBuffers: 1, pBuffers: outs.baseAddress)
                var inBuffers = [SecBuffer(cbBuffer: ULONG(raw.count), BufferType: ULONG(Self.bufferToken), pvBuffer: raw.baseAddress),
                                 SecBuffer(cbBuffer: 0, BufferType: ULONG(Self.bufferEmpty), pvBuffer: nil)]
                inBuffers.withUnsafeMutableBufferPointer { ins in
                    var inDesc = SecBufferDesc(ulVersion: ULONG(SECBUFFER_VERSION), cBuffers: 2, pBuffers: ins.baseAddress)
                    status = withUnsafeMutablePointer(to: &context) { ctx in
                        InitializeSecurityContextW(&credentials, ctx, nil, ULONG(Self.requests), 0, 0, &inDesc, 0, ctx, &outDesc, &attributes, nil)
                    }
                    if ins[1].BufferType == ULONG(Self.bufferExtra) { extra = Int(ins[1].cbBuffer) }
                }
            }
        }
        if let token = outBuffers[0].pvBuffer { FreeContextBuffer(token) }
        guard status == Self.ok || status == Self.continueNeeded else { throw NWError.tls(status) }
        if extra > 0 { pending = Array(input.suffix(extra)) }
    }
}
#elseif os(Linux)
/// TLS over a byte stream with OpenSSL: it checks the server's certificate and name against the system's roots
/// (`/etc/ssl/certs`), unless a verify block decides. `read` and `write` move the encrypted bytes, so the session
/// works over any stream (a socket, an SSH channel).
public final class TLSSession: @unchecked Sendable {
    private let tls: OpaquePointer
    /// Guards `tls`: OpenSSL's connections aren't thread-safe, and sending and receiving run on different threads.
    private let lock = NSLock()
    private var closed = false
    /// The protocol the server picked with ALPN.
    public private(set) var negotiatedProtocol: String?

    /// Connects TLS over a socket.
    static func connect(socket: Socket, serverName: String, options: sec_protocol_options_t) throws -> TLSSession {
        try TLSSession(
            serverName: serverName, alpn: options.applicationProtocols, verify: options.verify,
            write: { try socket.send($0) }, read: { try socket.receive(maximum: 65_536) })
    }

    /// Connects TLS over any stream: `write` sends bytes, `read` returns the next ones (empty at the end).
    public static func connect(
        serverName: String, alpn: [String] = [], allowUntrusted: Bool = false,
        write: (Data) throws -> Void, read: () throws -> Data
    ) throws -> TLSSession {
        try TLSSession(
            serverName: serverName, alpn: alpn, verify: allowUntrusted ? { _, _, complete in complete(true) } : nil,
            write: write, read: read)
    }

    private init(
        serverName: String, alpn: [String], verify: sec_protocol_verify_t?, write: (Data) throws -> Void, read: () throws -> Data
    ) throws {
        var protocols: [UInt8] = []
        for name in alpn where !name.isEmpty && name.utf8.count < 256 {
            protocols.append(UInt8(name.utf8.count))
            protocols += name.utf8
        }
        guard let tls = cns_tls_new(serverName, protocols, UInt32(protocols.count), verify == nil ? 1 : 0) else {
            throw NWError.tls(-1)
        }
        self.tls = tls
        while true {
            let status = cns_tls_handshake(tls)
            try write(takeOutput())
            switch status {
            case CNS_TLS_DONE:
                var length: UInt32 = 0
                if let name = cns_tls_alpn(tls, &length) {
                    negotiatedProtocol = String(decoding: UnsafeBufferPointer(start: name, count: Int(length)), as: UTF8.self)
                }
                if let verify { try Self.decide(verify) }
                return
            case CNS_TLS_WANT_INPUT:
                let chunk = try read()
                guard !chunk.isEmpty else { throw NWError.posix(.ECONNRESET) }
                feed(chunk)
            case CNS_TLS_UNTRUSTED:
                // errSSLXCertChainInvalid, as Apple's TLS reports an untrusted server.
                throw NWError.tls(-9807)
            default:
                throw NWError.tls(Self.lastError)
            }
        }
    }

    deinit { cns_tls_free(tls) }

    /// OpenSSL's error code, as a negative status that doesn't collide with Apple's.
    private static var lastError: Int32 {
        let code = cns_tls_last_error(nil, 0)
        return code == 0 ? -1 : -Int32(truncatingIfNeeded: code & 0x7fff_ffff)
    }

    /// Asks the verify block, waiting for its answer.
    private static func decide(_ verify: sec_protocol_verify_t) throws {
        let answer = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var trusted = false
        verify(sec_protocol_metadata_t(), sec_trust_t()) { ok in
            trusted = ok
            answer.signal()
        }
        answer.wait()
        guard trusted else { throw NWError.tls(-9808) }
    }

    private func feed(_ data: Data) {
        _ = data.withUnsafeBytes { cns_tls_feed(tls, $0.baseAddress, $0.count) }
    }

    /// The encrypted bytes OpenSSL has written.
    private func takeOutput() -> Data {
        var output = Data()
        while true {
            let count = cns_tls_output_count(tls)
            guard count > 0 else { return output }
            var buffer = [UInt8](repeating: 0, count: count)
            let taken = buffer.withUnsafeMutableBytes { cns_tls_output(tls, $0.baseAddress, $0.count) }
            guard taken > 0 else { return output }
            output.append(contentsOf: buffer[0..<taken])
        }
    }

    /// Encrypts application data into TLS records.
    public func encrypt(_ data: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        let written = data.withUnsafeBytes { cns_tls_write(tls, $0.baseAddress, Int32($0.count)) }
        guard written >= 0 else { throw NWError.tls(Self.lastError) }
        // Also carries anything reading left behind (TLS 1.3 key update replies).
        return takeOutput()
    }

    /// The next application data: reads and decrypts records until one carries data. Empty at the end.
    public func decrypt(read: () throws -> Data) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            lock.lock()
            if closed {
                lock.unlock()
                return Data()
            }
            let count = buffer.withUnsafeMutableBytes { cns_tls_read(tls, $0.baseAddress, Int32($0.count)) }
            if count == CNS_TLS_CLOSED { closed = true }
            lock.unlock()
            switch count {
            case 1...:
                return Data(buffer[0..<Int(count)])
            case CNS_TLS_WANT_INPUT:
                // Read without the lock, so sending isn't blocked while waiting for the peer.
                let chunk = try read()
                guard !chunk.isEmpty else { return Data() }
                lock.withLock { feed(chunk) }
            case CNS_TLS_CLOSED:
                return Data()
            default:
                throw NWError.tls(Self.lastError)
            }
        }
    }
}
#else
/// TLS needs SChannel (Windows) or OpenSSL (Linux) here; elsewhere TLS connections fail.
public final class TLSSession: @unchecked Sendable {
    static func connect(socket: Socket, serverName: String, options: sec_protocol_options_t) throws -> TLSSession {
        throw NWError.tls(-1)
    }
    func encrypt(_ data: Data) throws -> Data { data }
    func decrypt(read: () throws -> Data) throws -> Data { try read() }
}
#endif
