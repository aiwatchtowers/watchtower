import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop

/// The hub's work-alert ledger (mobile workbench remote spec §5.2): each alert key is remembered as seen
/// (the owner was at the Mac) or pushed, so one stop of work never pushes twice.
final class HubSyncStateWorkAlertsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testFirstSeenWins() throws {
        let sidecar = try HubSyncState.inMemory()
        _ = try sidecar.noteWorkAlerts(["ask-7"], at: t0)
        let result = try sidecar.noteWorkAlerts(["ask-7", "stop-3"], at: t0.addingTimeInterval(60))

        XCTAssertEqual(result.generation, 0)
        XCTAssertEqual(result.marks["ask-7"], HubSyncState.WorkAlertMark(seenAt: t0, pushedAt: nil, generation: 0))
        XCTAssertEqual(result.marks["stop-3"]?.seenAt, t0.addingTimeInterval(60))
    }

    func testPushedAtIsSetOnce() throws {
        let sidecar = try HubSyncState.inMemory()
        _ = try sidecar.noteWorkAlerts(["ask-7"], at: t0)
        try sidecar.markWorkAlertsPushed(["ask-7", "unknown"], at: t0.addingTimeInterval(10))
        try sidecar.markWorkAlertsPushed(["ask-7"], at: t0.addingTimeInterval(99))

        let marks = try sidecar.noteWorkAlerts([], at: t0).marks
        XCTAssertEqual(marks["ask-7"]?.pushedAt, t0.addingTimeInterval(10))
        XCTAssertNil(marks["unknown"], "pushing a key never noted creates no row")
    }

    func testPruneKeepsOpenKeys() throws {
        let sidecar = try HubSyncState.inMemory()
        _ = try sidecar.noteWorkAlerts(["ask-1", "ask-2", "stop-9"], at: t0)
        _ = try sidecar.noteWorkAlerts(["ask-3"], at: t0.addingTimeInterval(1000))

        try sidecar.pruneWorkAlerts(olderThan: t0.addingTimeInterval(500), keeping: ["ask-2"])

        XCTAssertEqual(Set(try sidecar.noteWorkAlerts([], at: t0).marks.keys), ["ask-2", "ask-3"])
    }

    func testOldAlertedAsksRowsMigrateAsPushed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("hub.sqlite").path
        let legacy = try DatabaseQueue(path: path)
        try legacy.write { db in
            try db.execute(sql: "CREATE TABLE alerted_asks (ask_id INTEGER PRIMARY KEY, at REAL NOT NULL, generation INTEGER NOT NULL)")
            try db.execute(sql: "INSERT INTO alerted_asks VALUES (7, ?, 2)", arguments: [t0.timeIntervalSince1970])
        }
        try legacy.close()

        let sidecar = try HubSyncState(path: path)
        let marks = try sidecar.noteWorkAlerts([], at: t0).marks

        XCTAssertEqual(marks["ask-7"], HubSyncState.WorkAlertMark(seenAt: t0, pushedAt: t0, generation: 2))
        let left = try DatabaseQueue(path: path).read { try $0.tableExists("alerted_asks") }
        XCTAssertFalse(left, "the old table is dropped")
    }

    func testWipeBumpsGenerationAndKeepsPublishedRows() throws {
        let sidecar = try HubSyncState.inMemory()
        _ = try sidecar.noteWorkAlerts(["ask-1", "ask-2"], at: t0)
        try sidecar.setHash("h", for: "ask_alert-ask-1")

        try sidecar.wipeSyncState(now: t0.addingTimeInterval(60))

        XCTAssertEqual(try sidecar.generation(), 1)
        let marks = try sidecar.noteWorkAlerts([], at: t0).marks
        XCTAssertEqual(marks["ask-1"]?.generation, 0, "a published row keeps its old generation")
        XCTAssertNil(marks["ask-2"], "an unconfirmed row of the wiped generation is forgotten")
    }
}
