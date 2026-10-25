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
    /// The processes this class started (the helper build and every helper
    /// run); tearDown kills and reaps the groups of those still running.
    private static let live = LiveGroups()

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
                cwd: repoRoot, env: env, timeout: 600)
            guard build.status == 0 else {
                throw InteropError("go build failed (\(build.status)): \(build.stderr)\(build.stdout)")
            }
            return out
        }
        helper = result
        return try result.get()
    }

    override static func tearDown() {
        live.reapAll()
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
        Self.live.reapAll()
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

    /// A timed-out process is stopped with its whole group: a child it
    /// started (as `go build` starts compilers) does not outlive it.
    func testTimeoutReapsTheWholeGroup() throws {
        let pidFile = tempDir.appendingPathComponent("child.pid")
        XCTAssertThrowsError(try Self.runProcess(
            URL(fileURLWithPath: "/bin/sh"), ["-c", "sleep 30 & echo $! > \"$0\"; wait", pidFile.path],
            cwd: tempDir, env: nil, timeout: 1))
        let child = try XCTUnwrap(pid_t(String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        let alive = kill(child, 0)
        let err = errno
        XCTAssertEqual(alive, -1, "the grandchild still runs")
        XCTAssertEqual(err, ESRCH)
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
        try Self.runProcess(try Self.builtHelper(), args, cwd: tempDir, env: nil, timeout: 120)
    }

    struct ProcessResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Runs one process to completion with a timeout, in its own process
    /// group. Output goes to files, so a full pipe never blocks the child; on
    /// timeout the whole group is stopped and reaped (`terminateGroup`)
    /// before the error is thrown, so `go build`'s compile and cgo children
    /// never outlive it.
    private static func runProcess(
        _ executable: URL,
        _ args: [String],
        cwd: URL,
        env: [String: String]?,
        timeout: TimeInterval
    ) throws -> ProcessResult {
        let logs = FileManager.default.temporaryDirectory.appendingPathComponent("interop-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: logs) }
        let outURL = logs.appendingPathComponent("out")
        let errURL = logs.appendingPathComponent("err")

        let process = try GroupProcess.spawn(
            executable, args, cwd: cwd, env: env ?? ProcessInfo.processInfo.environment, stdout: outURL, stderr: errURL)
        live.add(process)
        defer { live.remove(process) }
        guard process.wait(timeout: timeout) else {
            process.terminateGroup()
            throw InteropError("\(executable.lastPathComponent) \(args.joined(separator: " ")) timed out after \(Int(timeout)) s")
        }
        return ProcessResult(status: process.exitStatus, stdout: readLog(outURL), stderr: readLog(errURL))
    }

    /// A log file's text, or a visible marker when it cannot be read.
    private static func readLog(_ url: URL) -> String {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            return "<unreadable: \(error)>"
        }
    }

    struct InteropError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

/// A child process spawned as the leader of its own process group, so a
/// timeout or tearDown stops everything it started. One detached thread is
/// its only reaper (`waitpid`); everyone else waits on `exited`.
private final class GroupProcess: @unchecked Sendable {
    let pid: pid_t
    private let exited = DispatchGroup()
    private let lock = NSLock()
    private var status: Int32?

    private init(pid: pid_t) {
        self.pid = pid
        exited.enter()
        Thread.detachNewThread { [self] in
            var raw: Int32 = 0
            while waitpid(pid, &raw, 0) == -1, errno == EINTR {}
            lock.withLock { status = raw }
            exited.leave()
        }
    }

    var isRunning: Bool { lock.withLock { status == nil } }

    /// The exit code, or 128 + the signal that ended the process.
    var exitStatus: Int32 {
        let raw = lock.withLock { status } ?? -1
        let signal = raw & 0x7f
        return signal == 0 ? (raw >> 8) & 0xff : 128 + signal
    }

    func wait(timeout: TimeInterval) -> Bool {
        exited.wait(timeout: .now() + timeout) == .success
    }

    /// SIGINT to the group (go cancels its child processes on an
    /// interrupt), up to `grace` for the leader to exit, then SIGKILL to
    /// whatever is left of the group, and the leader reaped. A process that
    /// already exited is left alone: its group id may be reused.
    func terminateGroup(grace: TimeInterval = 10) {
        guard isRunning else { return }
        _ = killpg(pid, SIGINT)
        _ = wait(timeout: grace)
        _ = killpg(pid, SIGKILL)
        exited.wait()
    }

    /// Spawns `executable args` in `cwd` as a new group leader, with stdin
    /// on /dev/null and stdout and stderr in the given files, default signal
    /// dispositions and only fds 0–2 inherited.
    static func spawn(
        _ executable: URL, _ args: [String], cwd: URL, env: [String: String], stdout: URL, stderr: URL
    ) throws -> GroupProcess {
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw spawnError(errno) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, stdout.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        posix_spawn_file_actions_addopen(&actions, 2, stderr.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        posix_spawn_file_actions_addchdir_np(&actions, cwd.path)

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw spawnError(errno) }
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(
            &attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attributes, &none)
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attributes, &all)

        let argv = ([executable.path] + args).map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp)
        guard rc == 0 else { throw spawnError(rc) }
        return GroupProcess(pid: pid)
    }

    private static func spawnError(_ code: Int32) -> Error {
        SQLCipherInteropTests.InteropError("posix_spawn failed: \(String(cString: strerror(code)))")
    }
}

/// The groups still running, for tearDown to reap.
private final class LiveGroups: @unchecked Sendable {
    private let lock = NSLock()
    private var groups: [ObjectIdentifier: GroupProcess] = [:]

    func add(_ process: GroupProcess) { lock.withLock { groups[ObjectIdentifier(process)] = process } }
    func remove(_ process: GroupProcess) { lock.withLock { _ = groups.removeValue(forKey: ObjectIdentifier(process)) } }

    func reapAll() {
        let running = lock.withLock { Array(groups.values) }
        running.forEach { $0.terminateGroup() }
    }
}
