import CryptoKit
import Foundation
import SQLite3
#if os(Linux)
import SecretService
#endif
import Testing
import os

/// The CryptoKit, SQLite3 and os stand-ins, as code written for Apple's frameworks uses them.
struct StandInFrameworkTests {
    @Test func cryptoKitHashesAndSeals() throws {
        let digest = SHA256.hash(data: Data("abc".utf8))
        #expect(digest.map { String(format: "%02x", $0) }.joined().hasPrefix("ba7816bf"))
        let key = SymmetricKey(size: .bits256)
        let box = try AES.GCM.seal(Data("secret".utf8), using: key)
        #expect(try AES.GCM.open(box, using: key) == Data("secret".utf8))
    }

    #if os(Windows) || os(Linux)
    // Linux needs a Secret Service (a desktop session's keyring) for the sealing key.
    @Test(.enabled(if: SecureEnclave.isAvailable)) func secureEnclaveKeysReopenFromTheirBlob() throws {
        let key = try SecureEnclave.P256.Signing.PrivateKey()
        let blob = key.dataRepresentation
        #expect(!blob.isEmpty)
        let reopened = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob)
        #expect(reopened.publicKey.rawRepresentation == key.publicKey.rawRepresentation)
        let signature = try reopened.signature(for: Data("message".utf8))
        #expect(key.publicKey.isValidSignature(signature, for: Data("message".utf8)))
        #expect(throws: (any Error).self) { try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: Data(blob.reversed())) }
    }
    #endif

    #if os(Linux)
    @Test(.enabled(if: SecureEnclave.isAvailable)) func secretServiceKeepsItems() throws {
        let service = "dev.v57.compat-test.\(UUID().uuidString)"
        defer { try? SecretService.delete(service: service, account: "a") }
        defer { try? SecretService.delete(service: service, account: "b") }
        #expect(try SecretService.read(service: service, account: "a") == nil)
        try SecretService.write(Data([0, 1, 2, 255]), service: service, account: "a")
        try SecretService.write(Data("first".utf8), service: service, account: "b")
        try SecretService.write(Data("second".utf8), service: service, account: "b")
        #expect(try SecretService.read(service: service, account: "a") == Data([0, 1, 2, 255]))
        #expect(try SecretService.read(service: service, account: "b") == Data("second".utf8))
        let all = try SecretService.all(service: service).sorted { $0.account < $1.account }
        #expect(all.map(\.account) == ["a", "b"])
        try SecretService.delete(service: service, account: "a")
        try SecretService.delete(service: service, account: "a")
        #expect(try SecretService.read(service: service, account: "a") == nil)
    }
    #endif

    @Test func sqliteRunsQueries() throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(":memory:", &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "CREATE TABLE t (v INTEGER); INSERT INTO t VALUES (41), (1);", nil, nil, nil) == SQLITE_OK)
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "SELECT SUM(v) FROM t", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(sqlite3_column_int(statement, 0) == 42)
    }

    @Test func loggerAcceptsOSLogInterpolation() {
        let logger = Logger(subsystem: "dev.v57.test", category: "compat")
        let count = 3
        logger.info("Loaded \(count) items from \("a path", privacy: .private) in \(0.5) s, ok: \(true)")
        logger.error("Failed: \(CocoaError(.fileNoSuchFile) as Error, privacy: .public)")
        let lock = OSAllocatedUnfairLock(initialState: 0)
        lock.withLock { $0 += 1 }
        #expect(lock.withLock { $0 } == 1)
    }
}
