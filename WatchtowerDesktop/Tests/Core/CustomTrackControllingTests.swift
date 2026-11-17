import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerInterface
import WatchtowerTestSupport

/// The seam for a custom track's card controls and Stop watching (C1
/// Task 9, R4): the direct implementation sends the `tracks.*` tower
/// commands and runs the scan CLI; C3's drives a bound track's recipe.
@MainActor
final class CustomTrackControllingTests: XCTestCase {
    private var pool: DatabasePool!
    private var path = ""

    override func setUp() async throws {
        (pool, path) = try TestDatabase.createPool()
    }

    override func tearDown() async throws {
        pool = nil
        TestDatabase.cleanup(path: path)
    }

    private func customTrack() throws -> Track {
        let id = try pool.write { db -> Int in
            let id = try TestDatabase.insertTrack(db, text: "Watch the launch")
            try db.execute(sql: "UPDATE tracks SET origin = 'custom', enabled = 1, instruction = 'old' WHERE id = ?",
                           arguments: [id])
            return Int(id)
        }
        return try XCTUnwrap(pool.read { db in try TrackQueries.fetchByID(db, id: id) })
    }

    private func track(_ id: Int) throws -> Track {
        try XCTUnwrap(pool.read { db in try TrackQueries.fetchByID(db, id: id) })
    }

    private func row(_ id: Int) throws -> Row {
        try XCTUnwrap(pool.read { db in try Row.fetchOne(db, sql: "SELECT * FROM tracks WHERE id = ?", arguments: [id]) })
    }

    /// The calls `tower` got, as "command id[:value]".
    private func sent(_ tower: FakeScreenTower) -> [String] {
        tower.calls.map { call in
            let id = (call.params["id"] as? Int).map(String.init)
                ?? (call.params["ids"] as? [Int]).map { $0.map(String.init).joined(separator: ",") } ?? ""
            let value = call.params["instruction"] ?? call.params["enabled"]
            return "\(call.command.rawValue) \(id)" + (value.map { ":\($0)" } ?? "")
        }
    }

    /// The unbound controls send the `tracks.*` commands (Go writes the row,
    /// #1170 Task 12) and run the scan CLI; Swift writes nothing.
    func testDirectControlsSendTheTrackCommands() async throws {
        let track = try customTrack()
        let before = try row(track.id)
        let runner = FakeCLIRunner(stdout: Data("[]".utf8))
        let tower = FakeScreenTower()
        let controls = DirectCustomTrackControls(tower: tower, scanService: TrackScanService(runner: runner))

        try await controls.saveInstruction(track, text: "watch the refund owner")
        try await controls.setCollecting(track, on: false)
        try await controls.setCollecting(track, on: true)
        let from = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z"))
        try await controls.scan(track, from: from)
        try await controls.scan(track, from: nil)
        try await controls.stopWatching(track)
        try await controls.resumeWatching(track)
        try await controls.delete(track)

        XCTAssertEqual(sent(tower), [
            "tracks.instruction \(track.id):watch the refund owner",
            "tracks.enabled \(track.id):0",
            "tracks.enabled \(track.id):1",
            "tracks.stop \(track.id)",
            "tracks.restore \(track.id)",
            "tracks.delete \(track.id)"
        ])
        XCTAssertEqual(runner.invocations, [
            ["tracks", "scan", "\(track.id)", "--since", "2026-10-01T00:00:00Z"],
            ["tracks", "scan", "\(track.id)"]
        ])
        XCTAssertEqual(try row(track.id), before, "the Mac wrote nothing itself")
    }

    /// C3's controls: a bound track drives its watch recipe through the CLI
    /// (instruction, collecting, scans, the recipe's delete); Stop watching,
    /// its undo and the track's delete are the tower's, which turns the
    /// recipe off and on in the same write. An unbound track goes through the
    /// direct controls throughout.
    func testRecipeControlsDriveTheRecipe() async throws {
        let track = try customTrack()
        try await pool.write { db in
            try db.execute(sql: "UPDATE tracks SET automation_id = 42 WHERE id = ?", arguments: [track.id])
        }
        let fetched = try await pool.read { db in try TrackQueries.fetchByID(db, id: track.id) }
        let bound = try XCTUnwrap(fetched)
        XCTAssertEqual(bound.automationID, 42)
        let runner = FakeCLIRunner(stdout: Data(#"{"run_id":3,"coalesced":false,"daemon_running":true}"#.utf8))
        let tower = FakeScreenTower()
        let direct = DirectCustomTrackControls(tower: tower, scanService: TrackScanService(runner: runner))
        let controls = RecipeCustomTrackControls(cli: AutomationsCLI(runner: runner), direct: direct)

        try await controls.saveInstruction(bound, text: "watch the refund owner")
        try await controls.setCollecting(bound, on: false)
        try await controls.setCollecting(bound, on: true)
        let from = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z"))
        try await controls.scan(bound, from: from)
        try await controls.scan(bound, from: nil)
        try await controls.stopWatching(bound)
        try await controls.resumeWatching(bound)
        try await controls.delete(bound)

        let calls = runner.invocations
        XCTAssertEqual(calls.count, 6)
        XCTAssertEqual(Array(calls[0].prefix(4)), ["tracks", "instruction", "\(track.id)", "--text-file"])
        XCTAssertEqual(runner.textFileContents, ["watch the refund owner"])
        XCTAssertEqual(Array(calls.dropFirst()), [
            ["automations", "disable", "42"],
            ["automations", "enable", "42"],
            ["automations", "run", "42", "--since", "2026-10-01T00:00:00Z", "--json"],
            ["automations", "run", "42", "--json"],
            ["automations", "delete", "42"]
        ])
        XCTAssertEqual(sent(tower), ["tracks.stop \(track.id)", "tracks.restore \(track.id)", "tracks.delete \(track.id)"])

        // Unbound (a legacy custom track before its move): the direct controls throughout.
        let unbound = try customTrack()
        XCTAssertNil(unbound.automationID)
        let scans = FakeCLIRunner(stdout: Data("[]".utf8))
        let legacyTower = FakeScreenTower()
        let legacy = RecipeCustomTrackControls(
            cli: AutomationsCLI(runner: runner),
            direct: DirectCustomTrackControls(tower: legacyTower, scanService: TrackScanService(runner: scans)))
        let before = runner.invocations.count
        try await legacy.saveInstruction(unbound, text: "watch the refund window")
        try await legacy.setCollecting(unbound, on: false)
        try await legacy.scan(unbound, from: nil)
        try await legacy.stopWatching(unbound)
        XCTAssertEqual(sent(legacyTower), [
            "tracks.instruction \(unbound.id):watch the refund window",
            "tracks.enabled \(unbound.id):0",
            "tracks.stop \(unbound.id)"
        ])
        XCTAssertEqual(scans.invocations, [["tracks", "scan", "\(unbound.id)"]])
        XCTAssertEqual(runner.invocations.count, before, "no recipe verb for an unbound track")
    }

    /// A recipe deleted elsewhere since the track was read (Go
    /// `db.ErrAutomationNotFound`) counts as deleted: the track still goes.
    /// Any other refusal stops before the track is touched.
    func testRecipeDeleteOfAGoneRecipeStillDeletesTheTrack() async throws {
        let track = try customTrack()
        try await pool.write { db in
            try db.execute(sql: "UPDATE tracks SET automation_id = 42 WHERE id = ?", arguments: [track.id])
        }
        let fetched = try await pool.read { db in try TrackQueries.fetchByID(db, id: track.id) }
        let bound = try XCTUnwrap(fetched)
        let busy = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "automation 42 is running\n"))
        let busyTower = FakeScreenTower()
        let refused = RecipeCustomTrackControls(
            cli: AutomationsCLI(runner: busy),
            direct: DirectCustomTrackControls(tower: busyTower, scanService: TrackScanService(runner: busy)))
        do {
            try await refused.delete(bound)
            XCTFail("another refusal is thrown")
        } catch {}
        XCTAssertTrue(busyTower.calls.isEmpty, "the track is not touched")

        let gone = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(
            code: 1, stderr: "automation 42: automation not found\n"))
        let tower = FakeScreenTower()
        let controls = RecipeCustomTrackControls(
            cli: AutomationsCLI(runner: gone),
            direct: DirectCustomTrackControls(tower: tower, scanService: TrackScanService(runner: gone)))
        try await controls.delete(bound)
        XCTAssertEqual(gone.invocations, [["automations", "delete", "42"]])
        XCTAssertEqual(sent(tower), ["tracks.delete \(track.id)"])
    }

    /// A track deleted elsewhere is Go's `not_found`, which the card treats
    /// as "the watch is gone" (`TowerWriteError.isGone`); the daemon down is
    /// its sentence, not gone.
    func testDirectControlsOnADeletedTrackSayItIsGone() async throws {
        let track = try customTrack()
        let tower = FakeScreenTower()
        tower.next(.tracksInstruction, .refused("Couldn't save the instruction: it's no longer on the Mac."))
        tower.next(.tracksInstruction, .failed(TowerText.daemonDown))
        let controls = DirectCustomTrackControls(tower: tower, scanService: TrackScanService(runner: FakeCLIRunner()))

        do {
            try await controls.saveInstruction(track, text: "x")
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual((error as? TowerWriteError)?.isGone, true, "\(error)")
        }
        do {
            try await controls.saveInstruction(track, text: "x")
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? TowerWriteError, TowerWriteError(TowerText.daemonDown))
            XCTAssertEqual((error as? TowerWriteError)?.isGone, false)
        }
    }

    /// Made without the app's tower, every write fails with the daemon's
    /// sentence and writes nothing.
    func testDirectControlsWithoutATowerFailWithTheDaemonsSentence() async throws {
        let track = try customTrack()
        let before = try row(track.id)
        let controls = DirectCustomTrackControls(tower: nil, scanService: TrackScanService(runner: FakeCLIRunner()))
        do {
            try await controls.stopWatching(track)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? TowerWriteError, TowerWriteError(TowerText.daemonDown))
        }
        XCTAssertEqual(try row(track.id), before)
    }
}
