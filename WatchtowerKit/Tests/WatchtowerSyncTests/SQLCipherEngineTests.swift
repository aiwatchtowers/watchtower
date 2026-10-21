import Foundation
import GRDB
import WatchtowerE2ETesting
import XCTest
@testable import WatchtowerSync

/// Board #603 Stage 1: the Kit's GRDB is the SQLCipher fork
/// (`aiwatchtowers/GRDB.swift`), so the replica `DatabasePool` runs on
/// SQLCipher.swift and never on the system `libsqlite3`. The phone opens
/// its files with no key (spec §4.3), which stays a plain SQLite file.
final class SQLCipherEngineTests: XCTestCase {

    /// Same pins as the Desktop's `SQLCipherEngineTests`; they move in
    /// lockstep with `internal/sqlcipher/VERSION`.
    static let pinnedCipherVersion = "4.19.0"
    static let pinnedSQLiteVersion = "3.53.4"

    func testReplicaPoolRunsOnSQLCipher() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("KitSQLCipherEngine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("replica.sqlite").path

        let store = try ReplicaStore(path: path, opener: TestE2E.opener())
        try store.writer.read { db in
            let cipher = try String.fetchOne(db, sql: "PRAGMA cipher_version") ?? ""
            XCTAssertTrue(cipher.hasPrefix(Self.pinnedCipherVersion),
                          "cipher_version \(cipher.isEmpty ? "<empty: not SQLCipher>" : cipher)")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT sqlite_version()"), Self.pinnedSQLiteVersion)
            let options = try String.fetchAll(db, sql: "PRAGMA compile_options")
            XCTAssertTrue(options.contains("ENABLE_FTS5"), "compile_options: \(options)")
        }
        let header = try Data(contentsOf: URL(fileURLWithPath: path)).prefix(16)
        XCTAssertEqual(header, Data("SQLite format 3\0".utf8), "no key: the replica stays plain SQLite")
    }
}
