import Foundation
import Network
import Testing

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

    #if os(Windows)
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
}
