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
                                  controls: RecipeCustomTrackControls(cli: cli, direct: direct))
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
        XCTAssertEqual(watch.track.automationID, 42)
        XCTAssertEqual(runner.invocations, [["tracks", "start", "\(track.id)", "--json"],
                                            ["automations", "show", "42", "--json"]])
        XCTAssertEqual(watch.instructionDraft, "watch the refund owner")
        XCTAssertNil(watch.error)
    }
}
