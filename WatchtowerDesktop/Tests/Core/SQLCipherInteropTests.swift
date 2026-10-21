import Foundation
import GRDB
import XCTest
@testable import WatchtowerCore

/// Board #603: the Go engine (`internal/sqlcipher`) and GRDB on the fork's
/// SQLCipher.swift read and write the same files, keyed and plaintext. The
/// Go half is `internal/sqlcipher/cmd/interop`, built from this checkout once
/// per class. Without a Go toolchain the class skips, except under
/// `WATCHTOWER_REQUIRE_GO=1` (the CI Swift Test job), where it fails.
final class SQLCipherInteropTests: XCTestCase {

    /// The fixed test key x'00…01' (31 zero bytes, then 0x01), the same
    /// literal as `internal/sqlcipher/wt_engine_test.go`. Never a real key.
    static let testKeyHex = String(repeating: "0", count: 62) + "01"

    nonisolated(unsafe) private static var helper: Result<URL, Error>?

    private var tempDir: URL!
    /// Helper processes still running; tearDown kills and reaps them.
    private var running: [Process] = []

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent()
    }

    private static func goTool() -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let dirs = path.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/go/bin", "/usr/local/bin"]
        return dirs.map { $0 + "/go" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Builds the helper once per run of the class. The first build after a
    /// clean Go cache compiles the amalgamation, hence the long timeout.
    private static func builtHelper() throws -> URL {
        if let helper { return try helper.get() }
        let result = Result { () throws -> URL in
            guard let go = goTool() else {
                if ProcessInfo.processInfo.environment["WATCHTOWER_REQUIRE_GO"] == "1" {
                    throw InteropError("WATCHTOWER_REQUIRE_GO=1 but no Go toolchain is on PATH")
                }
                throw XCTSkip("no Go toolchain to build internal/sqlcipher/cmd/interop")
            }
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("sqlcipher-interop-\(UUID().uuidString)/interop")
            var env = ProcessInfo.processInfo.environment
            env["CGO_ENABLED"] = "1"
            let build = try runProcess(
                URL(fileURLWithPath: go), ["build", "-o", out.path, "./internal/sqlcipher/cmd/interop"],
                cwd: repoRoot, env: env, timeout: 600, track: nil)
            guard build.status == 0 else {
                throw InteropError("go build failed (\(build.status)): \(build.stderr)\(build.stdout)")
            }
            return out
        }
        helper = result
        return try result.get()
    }

    override static func tearDown() {
        if case let .success(binary)? = helper {
            try? FileManager.default.removeItem(at: binary.deletingLastPathComponent())
        }
        helper = nil
        super.tearDown()
    }

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLCipherInteropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for process in running where process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        running.removeAll()
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // MARK: - Cases

    /// Go's `versions` equals GRDB's `cipher_version` and `sqlite_version()`.
    func testEnginesReportTheSameVersions() throws {
        try assertVersionsMatch()
    }

    func testKeyedFileRoundTrips() throws {
        try roundTrip(keyHex: Self.testKeyHex)
    }

    func testPlaintextFileRoundTrips() throws {
        try roundTrip(keyHex: nil)
    }

    /// Go writes, GRDB searches and writes, Go reads GRDB's table back.
    private func roundTrip(keyHex: String?, file: StaticString = #filePath, line: UInt = #line) throws {
        try assertVersionsMatch()
        let path = tempDir.appendingPathComponent(keyHex == nil ? "plain.db" : "keyed.db").path
        let keyArgs = keyHex.map { ["--key-hex", $0] } ?? []

        let written = try helperJSON(["write", "--path", path] + keyArgs)
        XCTAssertEqual(written["journal_mode"] as? String, "wal", file: file, line: line)
        let keyword = try XCTUnwrap(written["keyword"] as? String, file: file, line: line)

        let header = try Data(contentsOf: URL(fileURLWithPath: path)).prefix(16)
        if keyHex == nil {
            XCTAssertEqual(header, Data("SQLite format 3\0".utf8), "plaintext file", file: file, line: line)
        } else {
            XCTAssertNotEqual(header, Data("SQLite format 3\0".utf8), "keyed file has a plaintext header", file: file, line: line)
        }

        var config = Configuration()
        if let keyHex {
            config.prepareDatabase { db in
                try db.execute(sql: "PRAGMA key = \"x'\(keyHex)'\"")
                try db.execute(sql: "PRAGMA cipher_compatibility = 4")
            }
        }
        do {
            let pool = try DatabasePool(path: path, configuration: config)
            let hits = try pool.read { db in
                try String.fetchAll(db, sql: """
                    SELECT kb_chunks.title FROM kb_fts JOIN kb_chunks ON kb_chunks.id = kb_fts.rowid
                    WHERE kb_fts MATCH ? ORDER BY bm25(kb_fts) LIMIT 5
                    """, arguments: [keyword])
            }
            XCTAssertEqual(hits.count, 5, "FTS5 hits from the Go-written index", file: file, line: line)
            try pool.write { db in
                try db.execute(sql: "CREATE TABLE swift_side (id INTEGER PRIMARY KEY, note TEXT NOT NULL)")
                try db.execute(sql: "INSERT INTO swift_side(note) VALUES ('written by GRDB')")
            }
            try pool.close()
        }

        let read = try helperJSON(["read", "--path", path, "--expect-table", "swift_side"] + keyArgs)
        XCTAssertEqual(read["rows"] as? Int, 1, file: file, line: line)
        XCTAssertEqual(read["integrity"] as? String, "ok", file: file, line: line)
        XCTAssertEqual(read["fts_hits"] as? Int, 200, file: file, line: line)

        if keyHex != nil {
            // Without the key the Go side cannot open the file at all.
            let unkeyed = try runHelper(["read", "--path", path, "--expect-table", "swift_side"])
            XCTAssertNotEqual(unkeyed.status, 0, file: file, line: line)
            XCTAssertTrue(unkeyed.stdout.contains("file is not a database"), unkeyed.stdout, file: file, line: line)
        }
    }

    // MARK: - Helpers

    private func assertVersionsMatch() throws {
        let go = try helperJSON(["versions"])
        let queue = try DatabaseQueue()
        let (cipher, sqlite) = try queue.read { db in
            (try String.fetchOne(db, sql: "PRAGMA cipher_version") ?? "",
             try String.fetchOne(db, sql: "SELECT sqlite_version()") ?? "")
        }
        let goCipher = go["cipher_version"] as? String ?? ""
        let goSQLite = go["sqlite_version"] as? String ?? ""
        guard goCipher == cipher, goSQLite == sqlite else {
            throw InteropError(Self.driftMessage(goCipher: goCipher, goSQLite: goSQLite, cipher: cipher, sqlite: sqlite))
        }
    }

    private static func driftMessage(goCipher: String, goSQLite: String, cipher: String, sqlite: String) -> String {
        "engine drift: Go internal/sqlcipher is SQLCipher \(goCipher) / SQLite \(goSQLite), "
            + "Swift GRDB fork is SQLCipher \(cipher) / SQLite \(sqlite). Upgrade both in lockstep "
            + "(docs/features/db-encryption.md, \"Upgrading the engine\")."
    }

    private func helperJSON(_ args: [String]) throws -> [String: Any] {
        let result = try runHelper(args)
        guard result.status == 0 else {
            throw InteropError("interop \(args.first ?? "") exited \(result.status): \(result.stdout)\(result.stderr)")
        }
        let object = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8))
        return try XCTUnwrap(object as? [String: Any], "interop printed \(result.stdout)")
    }

    private func runHelper(_ args: [String]) throws -> ProcessResult {
        try Self.runProcess(try Self.builtHelper(), args, cwd: tempDir, env: nil, timeout: 120) { [weak self] in
            self?.running.append($0)
        }
    }

    struct ProcessResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Runs one process to completion with a timeout. Output goes to files,
    /// so a full pipe never blocks the child; on timeout it is killed and
    /// reaped before the error is thrown.
    private static func runProcess(
        _ executable: URL,
        _ args: [String],
        cwd: URL,
        env: [String: String]?,
        timeout: TimeInterval,
        track: ((Process) -> Void)?
    ) throws -> ProcessResult {
        let logs = FileManager.default.temporaryDirectory.appendingPathComponent("interop-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: logs) }
        let outURL = logs.appendingPathComponent("out")
        let errURL = logs.appendingPathComponent("err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)
        defer {
            try? outHandle.close()
            try? errHandle.close()
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.currentDirectoryURL = cwd
        if let env { process.environment = env }
        process.standardOutput = outHandle
        process.standardError = errHandle
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        track?(process)
        if done.wait(timeout: .now() + timeout) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            throw InteropError("\(executable.lastPathComponent) \(args.joined(separator: " ")) timed out after \(Int(timeout)) s")
        }
        process.waitUntilExit()
        let stdout = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        let stderr = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        return ProcessResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    struct InteropError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
