import Foundation
import GRDB
import XCTest
@testable import WatchtowerCore

/// Board #603 Stage 1: GRDB runs on the SQLCipher engine of our GRDB fork
/// (`aiwatchtowers/GRDB.swift`), never on the system `libsqlite3`. A pool
/// and a queue configured the way `DatabaseManager` configures the app's
/// handle report the pinned SQLCipher build, its SQLite version and FTS5.
final class SQLCipherEngineTests: XCTestCase {

    /// The SQLCipher.swift pin in the GRDB fork. It moves in lockstep with
    /// `internal/sqlcipher/VERSION`; see the fork's README for the upgrade.
    static let pinnedCipherVersion = "4.19.0"
    static let pinnedSQLiteVersion = "3.53.4"

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLCipherEngineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    /// The app's configuration (`DatabaseManager.init(path:)`): the Go
    /// CLI's pragmas plus the dblock busy handling, with no sink.
    private func appConfiguration() -> Configuration {
        var config = Configuration()
        config.label = "watchtower"
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        DBLockInstrumentation.install(on: &config, sink: nil)
        return config
    }

    func testInMemoryQueueRunsOnSQLCipher() throws {
        let queue = try DatabaseQueue(configuration: appConfiguration())
        try queue.read { try Self.assertSQLCipherEngine($0) }
    }

    func testFilePoolRunsOnSQLCipher() throws {
        let path = tempDir.appendingPathComponent("engine.db").path
        let pool = try DatabasePool(path: path, configuration: appConfiguration())
        try pool.write { db in
            try db.execute(sql: "CREATE VIRTUAL TABLE docs USING fts5(body)")
            try db.execute(sql: "INSERT INTO docs(body) VALUES ('hello cipher world')")
        }
        // Both the writer and a reader connection are SQLCipher's.
        try pool.write { try Self.assertSQLCipherEngine($0) }
        try pool.read { db in
            try Self.assertSQLCipherEngine(db)
            let hits = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM docs WHERE docs MATCH 'cipher' ORDER BY bm25(docs)")
            XCTAssertEqual(hits, 1)
        }
        // A plaintext file with no key, as everywhere in Stage 1.
        let header = try Data(contentsOf: URL(fileURLWithPath: path)).prefix(16)
        XCTAssertEqual(header, Data("SQLite format 3\0".utf8))
    }

    /// The Go engine's `internal/sqlcipher/VERSION` names the same SQLCipher
    /// and the same SQLite as the Swift side.
    func testSwiftEngineMatchesGoAmalgamationVersion() throws {
        let versionURL = URL(fileURLWithPath: #filePath)   // …/WatchtowerDesktop/Tests/Core/<this file>
            .deletingLastPathComponent()                    // Tests/Core
            .deletingLastPathComponent()                    // Tests
            .deletingLastPathComponent()                    // WatchtowerDesktop
            .deletingLastPathComponent()                    // repo root
            .appendingPathComponent("internal/sqlcipher/VERSION")
        let text = try String(contentsOf: versionURL, encoding: .utf8)
        let pinned = Self.parseVersionFile(text)
        XCTAssertEqual(pinned.cipher, Self.pinnedCipherVersion,
                       "internal/sqlcipher/VERSION and the GRDB fork's SQLCipher.swift pin drifted; "
                       + "upgrade both together (aiwatchtowers/GRDB.swift README)")
        XCTAssertEqual(pinned.sqlite, Self.pinnedSQLiteVersion,
                       "internal/sqlcipher/VERSION names another SQLite than SQLCipher.swift")
    }

    /// Pulls the SQLCipher and SQLite versions out of `VERSION`: the first
    /// `x.y.z` on a line naming SQLCipher, and on a line naming SQLite but
    /// neither SQLCipher nor the Go driver (`mattn/go-sqlite3`).
    static func parseVersionFile(_ text: String) -> (cipher: String?, sqlite: String?) {
        var cipher: String?
        var sqlite: String?
        for line in text.split(whereSeparator: \.isNewline) {
            let lower = line.lowercased()
            if lower.contains("go-sqlite3") || lower.contains("mattn") { continue }
            guard let range = lower.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else { continue }
            let version = String(lower[range])
            if lower.contains("sqlcipher") {
                if cipher == nil { cipher = version }
            } else if lower.contains("sqlite"), sqlite == nil {
                sqlite = version
            }
        }
        return (cipher, sqlite)
    }

    func testParseVersionFile() {
        let parsed = Self.parseVersionFile("""
        mattn/go-sqlite3 v1.14.52
        sqlcipher v4.19.0
        sqlite 3.53.4
        amalgamation sha256 0123abcd
        """)
        XCTAssertEqual(parsed.cipher, "4.19.0")
        XCTAssertEqual(parsed.sqlite, "3.53.4")
    }

    static func assertSQLCipherEngine(_ db: Database, file: StaticString = #filePath, line: UInt = #line) throws {
        let cipher = try String.fetchOne(db, sql: "PRAGMA cipher_version") ?? ""
        XCTAssertTrue(cipher.hasPrefix(pinnedCipherVersion),
                      "cipher_version \(cipher.isEmpty ? "<empty: not SQLCipher>" : cipher)", file: file, line: line)
        let sqlite = try String.fetchOne(db, sql: "SELECT sqlite_version()")
        XCTAssertEqual(sqlite, pinnedSQLiteVersion, file: file, line: line)
        let options = try String.fetchAll(db, sql: "PRAGMA compile_options")
        XCTAssertTrue(options.contains("ENABLE_FTS5"), "compile_options: \(options)", file: file, line: line)
        XCTAssertTrue(options.contains("HAS_CODEC"), "compile_options: \(options)", file: file, line: line)
    }
}
