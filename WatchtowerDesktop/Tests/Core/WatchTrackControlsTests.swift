import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

/// A custom track card's watch controls over its watch recipe (C3 Task 14):
/// the instruction, Collecting and Scan from go through C1's seam
/// (`RecipeCustomTrackControls` here), never a `tracks` write; Start
/// Watching binds an unbound track through `tracks start`.
@MainActor
final class WatchTrackControlsTests: XCTestCase {
    private var pool: DatabasePool!
    private var path = ""

    /// One stdout every decoder reads: `show` (`watch`), `run` and `tracks start`.
    private static let stdout = Data(#"""
        {"watch":{"track_id":7,"instruction":"watch the refund owner","template_shaped":true},
         "run_id":3,"coalesced":false,"daemon_running":true,"at_next_sync":true,"track_id":7,"automation_id":42}
        """#.utf8)

    private static let refusal = "This watch was changed in the chat — change it there."

    override func setUp() async throws {
        (pool, path) = try TestDatabase.createPool()
    }

    override func tearDown() async throws {
        pool = nil
        TestDatabase.cleanup(path: path)
    }

    private func track(automationID: Int64?) throws -> Track {
        let id = try pool.write { db -> Int in
            let id = Int(try TestDatabase.insertTrack(db, text: "Watch the launch"))
            try db.execute(sql: """
                UPDATE tracks SET origin = 'custom', enabled = 1, instruction = 'old', automation_id = ? WHERE id = ?
                """, arguments: [automationID, id])
            return id
        }
        return try XCTUnwrap(pool.read { db in try TrackQueries.fetchByID(db, id: id) })
    }

    private func controls(_ track: Track, runner: FakeCLIRunner) -> WatchTrackControls {
        let cli = AutomationsCLI(runner: runner)
        let direct = DirectCustomTrackControls(dbPool: pool, scanService: TrackScanService(runner: runner))
        return WatchTrackControls(track: track, cli: cli,
                                  controls: RecipeCustomTrackControls(cli: cli, direct: direct), reader: pool)
    }

    func testWatchControlsCallTheCLI() async throws {
        let track = try track(automationID: 42)
        let runner = FakeCLIRunner(stdout: Self.stdout)
        let watch = controls(track, runner: runner)
        XCTAssertTrue(watch.isBound)

        await watch.load()
        XCTAssertEqual(watch.instructionDraft, "watch the refund owner")
        XCTAssertTrue(watch.templateShaped)

        watch.instructionDraft = "  watch the refund window \n"
        await watch.saveInstruction()
        XCTAssertEqual(watch.note, "Saved")

        await watch.setCollecting(false)
        XCTAssertFalse(watch.collecting)

        watch.scanFrom = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z"))
        await watch.scan()
        XCTAssertNil(watch.error)

        let calls = runner.invocations
        XCTAssertEqual(calls.count, 4)
        XCTAssertEqual(calls[0], ["automations", "show", "42", "--json"])
        XCTAssertEqual(Array(calls[1].prefix(4)), ["tracks", "instruction", "\(track.id)", "--text-file"])
        XCTAssertEqual(calls[1].count, 5)
        XCTAssertEqual(runner.textFileContents, ["watch the refund window"])
        XCTAssertEqual(calls[2], ["automations", "disable", "42"])
        XCTAssertEqual(calls[3], ["automations", "run", "42", "--since", "2026-10-01T00:00:00Z", "--json"])

        // Nothing wrote the track row from Swift.
        let row = try XCTUnwrap(pool.read { db in
            try Row.fetchOne(db, sql: "SELECT enabled, instruction FROM tracks WHERE id = ?", arguments: [track.id])
        })
        XCTAssertEqual(row["enabled"] as Int?, 1)
        XCTAssertEqual(row["instruction"] as String?, "old")
    }

    func testCLIArgsForTheWatchOps() {
        let since = ISO8601DateFormatter().date(from: "2026-10-01T08:30:00Z")
        XCTAssertEqual(AutomationsCLI.args(.runSince(5, since: since)),
                       ["automations", "run", "5", "--since", "2026-10-01T08:30:00Z", "--json"])
        XCTAssertEqual(AutomationsCLI.args(.runSince(5, since: nil)), ["automations", "run", "5", "--json"])
        XCTAssertEqual(AutomationsCLI.args(.showWatch(5)), ["automations", "show", "5", "--json"])
        XCTAssertEqual(AutomationsCLI.args(.trackStart(7)), ["tracks", "start", "7", "--json"])
        XCTAssertEqual(AutomationsCLI.args(.trackInstruction(7, file: "/tmp/acme.txt")),
                       ["tracks", "instruction", "7", "--text-file", "/tmp/acme.txt"])
    }

    func testDecodesTheWatchBlockAndAtNextSync() async throws {
        let shown = try await AutomationsCLI(runner: FakeCLIRunner(stdout: Self.stdout)).showWatch(42)
        XCTAssertEqual(shown?.trackID, 7)
        XCTAssertEqual(shown?.instruction, "watch the refund owner")
        XCTAssertEqual(shown?.templateShaped, true)
        let none = FakeCLIRunner(stdout: Data(#"{"id":4,"watch":null}"#.utf8))
        let nothing = try await AutomationsCLI(runner: none).showWatch(4)
        XCTAssertNil(nothing)
        let run = try await AutomationsCLI(runner: FakeCLIRunner(stdout: Self.stdout)).runSince(42, since: nil)
        XCTAssertTrue(run.atNextSync)
        let plain = Data(#"{"run_id":1,"coalesced":false,"daemon_running":true}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(AutomationsCLI.RunResult.self, from: plain).atNextSync)
    }

    func testSaveInstructionShowsRefusalText() async throws {
        let track = try track(automationID: 42)
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: Self.refusal + "\n"))
        let watch = controls(track, runner: runner)
        watch.instructionDraft = "watch the refund window"

        await watch.saveInstruction()

        XCTAssertEqual(watch.error, Self.refusal)
        XCTAssertNil(watch.note)
        XCTAssertEqual(watch.instructionDraft, "watch the refund window", "the owner's draft is kept")
        XCTAssertFalse(watch.isWorking)
    }

    func testEmptyDraftSaysWhy() async throws {
        let runner = FakeCLIRunner(stdout: Self.stdout)
        let watch = controls(try track(automationID: 42), runner: runner)
        watch.instructionDraft = "  \n "

        await watch.saveInstruction()

        XCTAssertEqual(watch.error, "Say what to watch for first.")
        XCTAssertNil(watch.note)
        XCTAssertEqual(runner.invocations, [])
    }

    /// All history is the epoch (the legacy `RunForTrackSince` meaning);
    /// Since last check is nil, the recipe's own watermark.
    func testAllHistoryScansFromTheEpoch() async throws {
        let runner = FakeCLIRunner(stdout: Self.stdout)
        let watch = controls(try track(automationID: 42), runner: runner)
        watch.scanFrom = WatchTrackControls.allHistory
        await watch.scan()
        watch.scanFrom = nil
        await watch.scan()
        XCTAssertEqual(runner.invocations, [
            ["automations", "run", "42", "--since", "1970-01-01T00:00:00Z", "--json"],
            ["automations", "run", "42", "--json"]
        ])
    }

    func testScanShowsNextSyncNote() async throws {
        let track = try track(automationID: 42)
        let runner = FakeCLIRunner(stdout: Self.stdout)
        let watch = controls(track, runner: runner)

        await watch.scan()

        XCTAssertEqual(watch.note, "Runs at the next sync")
        XCTAssertEqual(runner.invocations, [["automations", "run", "42", "--json"]], "nil = since the last check")
    }

    func testUnboundTrackOffersStart() async throws {
        let track = try track(automationID: nil)
        let runner = FakeCLIRunner(stdout: Self.stdout)
        // `tracks start` binds the row in the CLI's own process.
        let pool = try XCTUnwrap(pool)
        runner.onRun = { args in
            guard args.prefix(2) == ["tracks", "start"] else { return }
            try? await pool.write { db in
                try db.execute(sql: "UPDATE tracks SET automation_id = 42 WHERE id = ?", arguments: [track.id])
            }
        }
        let watch = controls(track, runner: runner)
        XCTAssertFalse(watch.isBound)

        // The controls do nothing for an unbound track: the card shows Start Watching.
        await watch.load()
        await watch.saveInstruction()
        await watch.setCollecting(false)
        await watch.scan()
        XCTAssertEqual(runner.invocations, [])

        await watch.startWatching()

        XCTAssertTrue(watch.isBound)
        XCTAssertEqual(watch.track.automationID, 42, "the track row is read again")
        XCTAssertEqual(runner.invocations, [["tracks", "start", "\(track.id)", "--json"],
                                            ["automations", "show", "42", "--json"]])
        XCTAssertEqual(watch.instructionDraft, "watch the refund owner")
        XCTAssertNil(watch.error)
    }

    /// AGENT-07: the Desktop's own `tracks start`, `tracks instruction` and
    /// `automations enable` launches carry an `OwnerConfirmGrants` entry for
    /// their exact argv and pid while they run (the CLI's `confirmWithOwner`
    /// sends `os.Args[1:]`), so the owner's press opens no confirm window.
    func testOwnerLaunchesOfTheWatchVerbsAreGranted() async throws {
        let granted = try await grantedArgs { try await $0.trackStart(7) }
        XCTAssertEqual(granted, ["tracks", "start", "7", "--json"])
        let instruction = try await grantedArgs { try await $0.trackInstruction(7, text: "watch refunds") }
        XCTAssertEqual(Array(instruction.prefix(4)), ["tracks", "instruction", "7", "--text-file"])
        let enable = try await grantedArgs { try await $0.setEnabled(42, true) }
        XCTAssertEqual(enable, ["automations", "enable", "42"])
    }

    /// Runs `op` against a stub binary that records its argv and pid, and
    /// returns the argv once a live grant for it was consumed while it ran.
    private func grantedArgs(_ op: @escaping @Sendable (AutomationsCLI) async throws -> Void) async throws -> [String] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("watch-grant-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = dir.appendingPathComponent("watchtower")
        try """
            #!/bin/sh
            d="\(dir.path)"
            printf '%s\\n' "$@" > "$d/args.tmp" && mv "$d/args.tmp" "$d/args"
            echo $$ > "$d/pid.tmp" && mv "$d/pid.tmp" "$d/pid"
            sleep 1
            echo '{"track_id":7,"automation_id":42}'
            """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
        let cli = AutomationsCLI(runner: ProcessCLIRunner(binaryPath: stub.path))
        let run = Task { try await op(cli) }
        var pid: Int32?
        for _ in 0..<150 where pid == nil {
            try await Task.sleep(for: .milliseconds(20))
            pid = (try? String(contentsOf: dir.appendingPathComponent("pid"), encoding: .utf8))
                .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        let child = try XCTUnwrap(pid)
        let args = try String(contentsOf: dir.appendingPathComponent("args"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertTrue(OwnerConfirmGrants.shared.consume(args, pid: child), "\(args)")
        try await run.value
        return args
    }
}
