import XCTest
import GRDB
import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerTestSupport

@MainActor
final class SidebarCountsViewModelTests: XCTestCase {

    // MARK: - Catch-Up badge
    //
    // The badge is a single "there is a recap waiting for you" dot: one ready,
    // unacknowledged `catchup_recaps` row, never a count of unread sources.

    nonisolated private static func insertRecap(
        _ db: Database, status: String, acknowledgedAt: String? = nil
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO catchup_recaps (period_from, period_to, status, acknowledged_at)
                VALUES (1000, 2000, ?, ?)
                """,
            arguments: [status, acknowledgedAt]
        )
    }

    func testCatchUpBadgeIsOneWhenReadyUnacknowledgedRecapExists() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }

        try await manager.dbPool.write { db in
            try Self.insertRecap(db, status: "ready")
        }

        let vm = SidebarCountsViewModel(dbPool: manager.dbPool)
        await vm.loadInitial()
        // Unread source counts must not contribute to the Catch-Up badge anymore.
        vm.unreadDigestCount = 99

        XCTAssertEqual(vm.unacknowledgedRecapCount, 1)
        XCTAssertEqual(vm.catchUpTotalCount, 1)
    }

    func testCatchUpBadgeIsZeroWhenAcknowledged() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }

        try await manager.dbPool.write { db in
            try Self.insertRecap(db, status: "ready", acknowledgedAt: "2026-09-04T10:00:00Z")
        }

        let vm = SidebarCountsViewModel(dbPool: manager.dbPool)
        await vm.loadInitial()

        XCTAssertEqual(vm.catchUpTotalCount, 0)
    }

    func testCatchUpBadgeIgnoresBuildingAndFailed() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }

        try await manager.dbPool.write { db in
            try Self.insertRecap(db, status: "building")
            try Self.insertRecap(db, status: "failed")
        }

        let vm = SidebarCountsViewModel(dbPool: manager.dbPool)
        await vm.loadInitial()

        XCTAssertEqual(vm.catchUpTotalCount, 0, "only a finished recap asks to be read")
    }

    /// The Inbox badge counts what the action strip shows — proposals awaiting
    /// the owner (pending + failed) and due reminders — and nothing else. The
    /// frozen situations backlog and the detector's `inbox_items` feed have no
    /// screen of their own since the inbox demolition, so neither may badge the
    /// tab: both are inserted here precisely to prove they contribute zero.
    func testInboxBadgeCountsStripOnly() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }

        try await manager.dbPool.write { db in
            try TestDatabase.insertSituation(db, status: "open")
            try TestDatabase.insertInboxItem(db, channelID: "C001", messageTS: "1700000000.000100")
            _ = try TestDatabase.insertAgentAction(db, turnID: "t1", status: "pending")
            _ = try TestDatabase.insertAgentAction(db, turnID: "t2", status: "failed")
            _ = try TestDatabase.insertAgentAction(db, turnID: "t3", status: "applied")
            try db.execute(sql: """
                INSERT INTO reminders (message_ref, note, remind_at, status)
                VALUES ('C1@1','due','2000-01-01T00:00:00Z','pending')
                """)
            try db.execute(sql: """
                INSERT INTO reminders (message_ref, note, remind_at, status)
                VALUES ('C2@2','x','2999-01-01T00:00:00Z','pending')
                """)
        }

        let vm = SidebarCountsViewModel(dbPool: manager.dbPool)
        await vm.loadInitial()

        XCTAssertEqual(vm.inboxStripCount, 3, "2 proposals awaiting the owner + 1 due reminder")
    }

    func testInboxBadgeIsZeroOnEmptyDB() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }

        let vm = SidebarCountsViewModel(dbPool: manager.dbPool)
        await vm.loadInitial()

        XCTAssertEqual(vm.inboxStripCount, 0)
    }

    /// The Ideas badge is the count of ideas awaiting owner review — matches
    /// `IdeaQueries.countForReview` exactly (proposed OR flagged needs_review).
    func testIdeasCountMatchesCountForReview() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }

        try await manager.dbPool.write { db in
            try TestDatabase.insertIdea(db, status: "proposed")
            try TestDatabase.insertIdea(db, status: "active", needsReview: true)
            try TestDatabase.insertIdea(db, status: "active")
            try TestDatabase.insertIdea(db, status: "dropped")
        }

        let vm = SidebarCountsViewModel(dbPool: manager.dbPool)
        await vm.loadInitial()

        let expected = try await manager.dbPool.read { try IdeaQueries.countForReview($0) }
        XCTAssertEqual(vm.ideasCount, expected)
        XCTAssertEqual(vm.ideasCount, 2)
    }

    func testIdeasCountIsZeroOnEmptyDB() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }

        let vm = SidebarCountsViewModel(dbPool: manager.dbPool)
        await vm.loadInitial()

        XCTAssertEqual(vm.ideasCount, 0)
    }

    /// The Digests sidebar badge sums Slack + stream + decision unread — the
    /// same three sources the Digests screen's tab header shows, not Slack
    /// only (owner reversed the v1 Slack-only scoping).
    func testDigestsBadgeCountIncludesStreamAndDecisionUnread() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }

        try await manager.dbPool.write { db in
            // A workspace user (account #1) so fetch() runs its full path,
            // where unreadDigestCount is computed (the no-uid path leaves it 0).
            _ = try TestDatabase.insertSlackAccount(db, currentUserID: "U042")
            // 2 unread Slack digests (insertDigest leaves read_at NULL);
            // distinct channels to clear the (channel,type,period) UNIQUE key.
            try TestDatabase.insertDigest(db, channelID: "C001")
            try TestDatabase.insertDigest(db, channelID: "C002")
            // Stream digests: 1 unread, 1 read.
            _ = try TestDatabase.insertStreamDigest(db, readAt: nil)
            _ = try TestDatabase.insertStreamDigest(db, readAt: "2026-06-20T00:00:00Z")
            // Decisions: 1 never-seen (unread), 1 seen (read),
            // 1 seen-but-re-flagged (unread).
            _ = try TestDatabase.insertIdea(db, kind: "decision", seenAt: nil)
            _ = try TestDatabase.insertIdea(db, kind: "decision", seenAt: "2026-06-20T00:00:00Z")
            _ = try TestDatabase.insertIdea(
                db, kind: "decision", needsReview: true, seenAt: "2026-06-20T00:00:00Z"
            )
            // A non-decision idea must NOT contribute to the decision unread.
            _ = try TestDatabase.insertIdea(db, kind: "idea", status: "proposed")
        }

        let vm = SidebarCountsViewModel(dbPool: manager.dbPool)
        await vm.loadInitial()

        XCTAssertEqual(vm.unreadDigestCount, 2)
        XCTAssertEqual(vm.unreadStreamCount, 1)
        XCTAssertEqual(vm.unreadDecisionCount, 2)
        XCTAssertEqual(vm.digestsBadgeCount, 2 + 1 + 2)
        XCTAssertEqual(
            vm.digestsBadgeCount,
            vm.unreadDigestCount + vm.unreadStreamCount + vm.unreadDecisionCount
        )
    }

    func testDigestsBadgeCountIsZeroOnEmptyDB() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }

        let vm = SidebarCountsViewModel(dbPool: manager.dbPool)
        await vm.loadInitial()

        XCTAssertEqual(vm.digestsBadgeCount, 0)
    }

    // MARK: - Owner (OWNER-01)

    /// A Google-only install has an owner, so the owner-gated counts (tracks,
    /// targets) are real — before OWNER-01 they zeroed out without Slack.
    func testOwner01GoogleOnlyInstallCountsTracks() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }

        try await manager.dbPool.write { db in
            _ = try TestDatabase.insertGoogleAccount(db, email: "me@x.com")
            try TestDatabase.insertTrack(db, text: "Ship it", hasUpdates: true)
        }

        let vm = SidebarCountsViewModel(dbPool: manager.dbPool)
        await vm.loadInitial()

        XCTAssertEqual(vm.totalTrackCount, 1)
        XCTAssertEqual(vm.updatedTrackCount, 1)
        XCTAssertEqual(vm.recommendationCount, 0, "channel recommendations need a Slack owner")
    }
}
