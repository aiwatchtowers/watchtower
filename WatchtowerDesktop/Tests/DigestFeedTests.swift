import XCTest
import GRDB
@testable import WatchtowerDesktop

/// VM-level coverage for the Digests segment's cross-source feed
/// (`DigestViewModel.feedEntries`) — the merge of Slack digests, Gmail/Jira
/// stream digests (Task 9), and meeting recordings into one date-sorted list.
/// Day grouping itself is a view-layer concern (`Calendar`-based in
/// `DigestListView`); this file only covers what the VM hands the view.
final class DigestFeedTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        do {
            (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        } catch {
            XCTFail("setUp failed: \(error)")
        }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        super.tearDown()
    }

    // MARK: - Merged order

    @MainActor
    func testFeedEntriesMergesAllThreeSourcesSortedNewestFirst() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertDigest(db, createdAt: "2026-01-01T00:00:00Z")
            try TestDatabase.insertStreamDigest(db, createdAt: "2026-01-03T00:00:00Z")
            try TestDatabase.insertMeetingTranscript(db, createdAt: "2026-01-02T00:00:00Z")
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertEqual(vm.feedEntries.count, 3)
        // Newest first: stream (01-03) > meeting (01-02) > slack (01-01).
        guard case .stream = vm.feedEntries[0] else {
            return XCTFail("expected stream entry first, got \(vm.feedEntries[0])")
        }
        guard case .meeting = vm.feedEntries[1] else {
            return XCTFail("expected meeting entry second, got \(vm.feedEntries[1])")
        }
        guard case .slack = vm.feedEntries[2] else {
            return XCTFail("expected slack entry third, got \(vm.feedEntries[2])")
        }
    }

    @MainActor
    func testOldestFirstSortReversesTheFeed() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertDigest(db, createdAt: "2026-01-01T00:00:00Z")
            try TestDatabase.insertStreamDigest(db, createdAt: "2026-01-03T00:00:00Z")
            try TestDatabase.insertMeetingTranscript(db, createdAt: "2026-01-02T00:00:00Z")
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()
        vm.setSortOrder(.oldestFirst)

        guard case .slack = vm.feedEntries[0] else {
            return XCTFail("expected slack entry first, got \(vm.feedEntries[0])")
        }
        guard case .meeting = vm.feedEntries[1] else {
            return XCTFail("expected meeting entry second, got \(vm.feedEntries[1])")
        }
        guard case .stream = vm.feedEntries[2] else {
            return XCTFail("expected stream entry third, got \(vm.feedEntries[2])")
        }
    }

    // MARK: - Stable ids

    @MainActor
    func testFeedEntryIDsAreNamespacedByRowID() throws {
        var digestID: Int64 = 0
        var streamID: Int64 = 0
        var meetingID: Int64 = 0
        try dbManager.dbPool.write { db in
            try TestDatabase.insertDigest(db)
            digestID = db.lastInsertedRowID
            streamID = try TestDatabase.insertStreamDigest(db)
            try TestDatabase.insertMeetingTranscript(db)
            meetingID = db.lastInsertedRowID
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()

        let ids = Set(vm.feedEntries.map(\.id))
        XCTAssertEqual(ids, [
            "slack-\(digestID)",
            "stream-\(streamID)",
            "meeting-\(meetingID)"
        ])
    }

    // MARK: - Meeting entries always read

    @MainActor
    func testMeetingEntriesAreAlwaysRead() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertMeetingTranscript(db)
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertEqual(vm.feedEntries.count, 1)
        XCTAssertTrue(vm.feedEntries[0].isRead)
    }

    // MARK: - Stream markRead flows through

    @MainActor
    func testMarkStreamReadUpdatesTheFeedEntryAndUnreadCount() throws {
        var streamID = 0
        try dbManager.dbPool.write { db in
            streamID = Int(try TestDatabase.insertStreamDigest(db))
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()
        XCTAssertFalse(vm.feedEntries[0].isRead)
        XCTAssertEqual(vm.unreadStreamCount, 1)

        vm.markStreamRead(id: streamID)

        XCTAssertTrue(vm.feedEntries[0].isRead)
        XCTAssertEqual(vm.unreadStreamCount, 0)
    }

    @MainActor
    func testUnreadStreamCountLoadsFromQuery() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertStreamDigest(db)
            let readID = try TestDatabase.insertStreamDigest(db)
            try StreamDigestQueries.markRead(db, id: Int(readID))
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertEqual(vm.unreadStreamCount, 1)
    }
}
