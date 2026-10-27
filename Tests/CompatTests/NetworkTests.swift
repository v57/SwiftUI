import Foundation
import Network
import Testing
#if os(Linux)
import SwiftUIPortability
#endif

/// The Network stand-in: TCP through a listener, connected UDP, and TLS to a public server.
struct NetworkTests {
    @Test func tcpRoundTripsThroughAListener() async throws {
        let queue = DispatchQueue(label: "test")
        let listener = try NWListener(using: .tcp, on: .any)
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error): continuation.resume(throwing: error)
                default: break
                }
            }
            // Echo the first message back, upper-cased.
            listener.newConnectionHandler = { connection in
                connection.start(queue: queue)
                connection.receive(minimumIncompleteLength: 5, maximumLength: 100) { data, _, _, _ in
                    let reply = Data(String(decoding: data ?? Data(), as: UTF8.self).uppercased().utf8)
                    connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            listener.start(queue: queue)
        }
        defer { listener.cancel() }
        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let reply: String = try await withCheckedThrowingContinuation { continuation in
            client.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    client.send(content: Data("hello".utf8), completion: .contentProcessed { _ in })
                    client.receive(minimumIncompleteLength: 5, maximumLength: 100) { data, _, _, error in
                        if let error { continuation.resume(throwing: error) } else {
                            continuation.resume(returning: String(decoding: data ?? Data(), as: UTF8.self))
                        }
                    }
                case .failed(let error): continuation.resume(throwing: error)
                default: break
                }
            }
            client.start(queue: queue)
        }
        client.cancel()
        #expect(reply == "HELLO")
    }

    #if os(Windows) || os(Linux)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETWORK_TESTS_ONLINE"] != nil))
    func tlsFetchesAPage() async throws {
        let queue = DispatchQueue(label: "tls")
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        let connection = NWConnection(host: "example.com", port: .https, using: NWParameters(tls: tls))
        let head: String = try await withCheckedThrowingContinuation { continuation in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: Data("GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                    connection.receive(minimumIncompleteLength: 12, maximumLength: 4096) { data, _, _, error in
                        if let error { continuation.resume(throwing: error) } else {
                            continuation.resume(returning: String(decoding: data ?? Data(), as: UTF8.self))
                        }
                    }
                case .failed(let error): continuation.resume(throwing: error)
                default: break
                }
            }
            connection.start(queue: queue)
        }
        connection.cancel()
        #expect(head.hasPrefix("HTTP/1.1 "))
    }
    #endif

    #if os(Linux)
    /// TLS against a local `openssl s_server` with a self-signed certificate: trusted through a verify block, and
    /// refused without one.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/openssl")))
    func tlsTalksToALocalServer() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let openssl = URL(fileURLWithPath: "/usr/bin/openssl")
        let request = try ChildProcess(
            executable: openssl,
            arguments: ["req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes", "-keyout", "key.pem",
                        "-out", "cert.pem", "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost"],
            directory: folder, environment: [:])
        #expect(request.waitUntilExit() == 0)
        let port = UInt16.random(in: 20_000..<40_000)
        let server = try ChildProcess(
            executable: openssl,
            arguments: ["s_server", "-accept", "127.0.0.1:\(port)", "-cert", "cert.pem", "-key", "key.pem", "-www", "-alpn", "http/1.1", "-quiet"],
            directory: folder, environment: [:])
        defer {
            server.terminate()
            _ = server.waitUntilExit()
        }

        func fetch(trusting: Bool) async throws -> String {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, "localhost")
            sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
            if trusting {
                sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, .global())
            }
            let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: NWParameters(tls: tls))
            defer { connection.cancel() }
            return try await withCheckedThrowingContinuation { continuation in
                nonisolated(unsafe) var resumed = false
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.send(content: Data("GET / HTTP/1.0\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                        connection.receive(minimumIncompleteLength: 12, maximumLength: 4096) { data, _, _, error in
                            guard !resumed else { return }
                            resumed = true
                            if let error { continuation.resume(throwing: error) } else {
                                continuation.resume(returning: String(decoding: data ?? Data(), as: UTF8.self))
                            }
                        }
                    case .failed(let error), .waiting(let error):
                        guard !resumed else { return }
                        resumed = true
                        continuation.resume(throwing: error)
                    default: break
                    }
                }
                connection.start(queue: DispatchQueue(label: "tls"))
            }
        }

        // The server takes a moment to listen.
        var head = ""
        for _ in 0..<50 {
            do {
                head = try await fetch(trusting: true)
                break
            } catch NWError.posix(.ECONNREFUSED) {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        #expect(head.hasPrefix("HTTP/1.0 200"))
        await #expect(throws: NWError.tls(-9807)) { try await fetch(trusting: false) }
    }
    #endif
}
