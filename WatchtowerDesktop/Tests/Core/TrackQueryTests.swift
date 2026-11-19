import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class TrackQueryTests: XCTestCase {

    // MARK: - Fetch

    func testFetchAllDefaultOrder() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertTrack(db, text: "Low", priority: "low")
            try TestDatabase.insertTrack(db, text: "High", priority: "high", hasUpdates: true)
            try TestDatabase.insertTrack(db, text: "Medium", priority: "medium")
        }
        let tracks = try db.read { try TrackQueries.fetchAll($0) }
        // has_updates DESC, updated_at DESC — "High" has updates so comes first
        XCTAssertEqual(tracks[0].text, "High")
    }

    func testFetchUpdatedTracks() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertTrack(db, text: "Updated", hasUpdates: true)
            try TestDatabase.insertTrack(db, text: "Stable")
        }
        let tracks = try db.read { try TrackQueries.fetchUpdatedTracks($0) }
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks[0].text, "Updated")
    }

    /// `tracks.automation_id` (twin: Go `db.Track.AutomationID`): nil = unbound.
    func testTrackDecodesAutomationID() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            let bound = try TestDatabase.insertTrack(db, text: "Bound")
            try TestDatabase.insertTrack(db, text: "Unbound")
            try db.execute(sql: "UPDATE tracks SET automation_id = 42 WHERE id = ?", arguments: [bound])
        }
        let tracks = try db.read { try TrackQueries.fetchAll($0) }
        XCTAssertEqual(tracks.first { $0.text == "Bound" }?.automationID, 42)
        XCTAssertEqual(tracks.first { $0.text == "Unbound" }.map { $0.automationID == nil }, true)
    }

    func testFetchByID() throws {
        let db = try TestDatabase.create()
        _ = try db.write { try TestDatabase.insertTrack($0, text: "Find me") }
        let track = try db.read { try TrackQueries.fetchByID($0, id: 1) }
        XCTAssertNotNil(track)
        XCTAssertEqual(track?.text, "Find me")
    }

    func testFetchByIDs() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertTrack(db, text: "First")
            try TestDatabase.insertTrack(db, text: "Second")
            try TestDatabase.insertTrack(db, text: "Third")
        }
        let tracks = try db.read { try TrackQueries.fetchByIDs($0, ids: [1, 3]) }
        XCTAssertEqual(tracks.count, 2)
        let texts = Set(tracks.map(\.text))
        XCTAssertTrue(texts.contains("First"))
        XCTAssertTrue(texts.contains("Third"))
    }

    func testFetchByIDsEmpty() throws {
        let db = try TestDatabase.create()
        let tracks = try db.read { try TrackQueries.fetchByIDs($0, ids: []) }
        XCTAssertTrue(tracks.isEmpty)
    }

    // MARK: - Counts

    func testFetchCounts() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertTrack(db, hasUpdates: true)
            try TestDatabase.insertTrack(db, hasUpdates: true)
            try TestDatabase.insertTrack(db)
        }
        let counts = try db.read { try TrackQueries.fetchCounts($0) }
        XCTAssertEqual(counts.total, 3)
        XCTAssertEqual(counts.updated, 2)
    }

    func testFetchOwnershipCounts() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertTrack(db, ownership: "mine")
            try TestDatabase.insertTrack(db, ownership: "mine")
            try TestDatabase.insertTrack(db, ownership: "delegated")
        }
        let counts = try db.read { try TrackQueries.fetchOwnershipCounts($0) }
        XCTAssertEqual(counts["mine"], 2)
        XCTAssertEqual(counts["delegated"], 1)
    }

    // MARK: - Mark read

    // MARK: - Priority

    // MARK: - Ownership

    // MARK: - Sub-items

    // MARK: - fetchLatestCustom (dashboard create-track conversion, DASH-03)

    func testFetchLatestCustomReturnsNewestCustomTrack() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertTrack(db, text: "Auto track")
            try db.execute(sql: "INSERT INTO tracks (text, origin) VALUES ('Older custom', 'custom')")
            try db.execute(sql: "INSERT INTO tracks (text, origin) VALUES ('Newer custom', 'custom')")
        }
        let latest = try db.read { try TrackQueries.fetchLatestCustom($0) }
        XCTAssertEqual(latest?.text, "Newer custom")
    }

    func testFetchLatestCustomReturnsNilWhenNoneCustom() throws {
        let db = try TestDatabase.create()
        _ = try db.write { db in
            try TestDatabase.insertTrack(db, text: "Auto track")
        }
        let latest = try db.read { try TrackQueries.fetchLatestCustom($0) }
        XCTAssertNil(latest)
    }
}
