import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

/// The seam for a custom track's card controls and Stop watching (C1
/// Task 9, R4): C1's direct implementation writes the `tracks` row and runs
/// the scan CLI; the Inbox view model sends a custom track's Stop watching
/// through whatever implementation it was given.
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

    private func row(_ id: Int) throws -> Row {
        try XCTUnwrap(pool.read { db in try Row.fetchOne(db, sql: "SELECT * FROM tracks WHERE id = ?", arguments: [id]) })
    }

    func testDirectControlsWriteTheTrackRow() async throws {
        let track = try customTrack()
        let runner = FakeCLIRunner(stdout: Data("[]".utf8))
        let controls = DirectCustomTrackControls(dbPool: pool, scanService: TrackScanService(runner: runner))

        try await controls.saveInstruction(track, text: "watch the refund owner")
        XCTAssertEqual(try row(track.id)["instruction"] as String?, "watch the refund owner")

        try await controls.setCollecting(track, on: false)
        XCTAssertEqual(try row(track.id)["enabled"] as Int?, 0)
        try await controls.setCollecting(track, on: true)
        XCTAssertEqual(try row(track.id)["enabled"] as Int?, 1)

        let from = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z"))
        try await controls.scan(track, from: from)
        XCTAssertEqual(runner.invocations, [["tracks", "scan", "\(track.id)", "--since", "2026-10-01T00:00:00Z"]])

        try await controls.stopWatching(track)
        let stopped = try row(track.id)
        XCTAssertFalse(((stopped["dismissed_at"] as String?) ?? "").isEmpty)
        XCTAssertEqual(stopped["enabled"] as Int?, 0)
    }

    /// A row deleted elsewhere is a `RowNotFoundError`, which the card and
    /// the view model treat as "the watch is gone".
    func testDirectControlsOnADeletedTrackSayItIsGone() async throws {
        let track = try customTrack()
        try await pool.write { db in try db.execute(sql: "DELETE FROM tracks") }
        let controls = DirectCustomTrackControls(dbPool: pool, scanService: TrackScanService(runner: FakeCLIRunner()))

        do {
            try await controls.saveInstruction(track, text: "x")
            XCTFail("expected RowNotFoundError")
        } catch {
            XCTAssertTrue(error is RowNotFoundError, "\(error)")
        }
    }

    /// The Inbox view model's Stop watching: a custom track goes through the
    /// seam once and nothing else writes it; an auto track is dismissed
    /// directly and never reaches the seam.
    func testStopWatchingSendsOnlyACustomTrackThroughTheSeam() async throws {
        let custom = try customTrack()
        let auto = try await pool.write { db in Int(try TestDatabase.insertTrack(db, text: "Extracted")) }
        let suite = "CustomTrackControllingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fake = RecordingCustomTrackControls()
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner(), customTrackControls: fake,
                                      defaults: defaults)
        await vm.refresh()
        let autoTrack = try XCTUnwrap(vm.feed.tracks.map(\.track).first { $0.id == auto })

        await vm.stopWatching(custom)
        await vm.stopWatching(autoTrack)

        XCTAssertEqual(fake.calls, [.stopWatching(trackID: custom.id)])
        // The fake wrote nothing: the custom row is untouched.
        XCTAssertEqual(try row(custom.id)["enabled"] as Int?, 1)
        XCTAssertFalse(((try row(auto)["dismissed_at"] as String?) ?? "").isEmpty)
        XCTAssertNil(vm.lastError)
    }
}
