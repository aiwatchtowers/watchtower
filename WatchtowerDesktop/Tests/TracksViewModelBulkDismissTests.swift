import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class TracksViewModelBulkDismissTests: XCTestCase {
    private func makeVM() throws -> (TracksViewModel, DatabasePool) {
        let (manager, _) = try TestDatabase.createDatabaseManager()
        return (TracksViewModel(dbManager: manager), manager.dbPool)
    }

    private func activeIDs(_ pool: DatabasePool) throws -> Set<Int> {
        Set(try pool.read { try Int.fetchAll($0, sql: "SELECT id FROM tracks WHERE dismissed_at = ''") })
    }

    func testDismissSelectedDismissesExactlyTheSelectionAndEndsSelecting() throws {
        let (vm, pool) = try makeVM()
        let ids = try pool.write { db in try (0..<3).map { _ in Int(try TestDatabase.insertTrack(db)) } }
        vm.showRead = true
        vm.load()
        vm.isSelecting = true
        vm.toggleSelection(ids[0])
        vm.toggleSelection(ids[1])
        vm.toggleSelection(ids[1])
        XCTAssertEqual(vm.selectedIDs, [ids[0]])

        vm.dismissTracks(ids: vm.selectedIDs.sorted())

        XCTAssertEqual(try activeIDs(pool), [ids[1], ids[2]])
        XCTAssertFalse(vm.isSelecting)
        XCTAssertTrue(vm.selectedIDs.isEmpty)
        XCTAssertNil(vm.errorMessage)
    }

    func testSelectAllVisibleAndAutoIDsForConfirmation() throws {
        let (vm, pool) = try makeVM()
        let ids = try pool.write { db in
            // The test schema predates tracks.origin.
            try db.execute(sql: "ALTER TABLE tracks ADD COLUMN origin TEXT NOT NULL DEFAULT 'auto'")
            let ids = try (0..<3).map { _ in Int(try TestDatabase.insertTrack(db)) }
            try db.execute(sql: "UPDATE tracks SET origin = 'custom' WHERE id = ?", arguments: [ids[2]])
            return ids
        }
        vm.showRead = true
        vm.load()
        vm.selectAllVisible()
        XCTAssertEqual(vm.selectedIDs, Set(ids))

        let auto = try XCTUnwrap(vm.activeAutoTrackIDs())
        XCTAssertEqual(auto, [ids[0], ids[1]], "the confirmation counts auto tracks only")
        // A track the daemon adds after the dialog opened is not swept up.
        let late = try pool.write { db in Int(try TestDatabase.insertTrack(db)) }
        vm.dismissTracks(ids: auto)
        XCTAssertEqual(try activeIDs(pool), [ids[2], late])
    }

    func testNoAutoTracksAndPartialDismissAreReported() throws {
        let (vm, pool) = try makeVM()
        try pool.write { db in try db.execute(sql: "ALTER TABLE tracks ADD COLUMN origin TEXT NOT NULL DEFAULT 'auto'") }
        XCTAssertNil(vm.activeAutoTrackIDs())
        XCTAssertEqual(vm.notice, "No active auto tracks to dismiss.")

        let ids = try pool.write { db in try (0..<2).map { _ in Int(try TestDatabase.insertTrack(db)) } }
        try pool.write { db in try TrackQueries.dismiss(db, id: ids[0]) }
        vm.notice = nil
        vm.dismissTracks(ids: ids)
        XCTAssertEqual(vm.notice, "Dismissed 1 of 2; the rest were already dismissed or gone.")
    }

    func testDismissFailureIsReported() throws {
        let (vm, pool) = try makeVM()
        try pool.write { db in try db.execute(sql: "DROP TABLE tracks") }
        vm.isSelecting = true
        vm.dismissTracks(ids: [1])
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(vm.isSelecting, "a failed write keeps the selection")
    }

    func testLoadDropsSelectionHiddenByAFilter() throws {
        let (vm, pool) = try makeVM()
        let high = try pool.write { db in Int(try TestDatabase.insertTrack(db, priority: "high")) }
        let low = try pool.write { db in Int(try TestDatabase.insertTrack(db, priority: "low")) }
        vm.showRead = true
        vm.load()
        vm.selectedIDs = [high, low]
        vm.priorityFilter = "high"
        vm.load()
        XCTAssertEqual(vm.selectedIDs, [high])
    }
}
