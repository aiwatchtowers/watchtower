import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

/// The menu's numbers and the sidebar badge (spec "Counts"): pure cases on
/// hand-built trees, then the counts and the badge read end to end.
final class InboxFolderCountsTests: XCTestCase {
    // root 1 ▸ approvals 2, a 3 ▸ a1 4, hidden 5 ▸ under-hidden 6
    private let tree = InboxFolderTree(revision: 1, folders: [
        InboxFolder(id: 1, kind: .root, parentID: nil, slug: "inbox", title: "Inbox"),
        InboxFolder(id: 2, kind: .approvals, parentID: 1, slug: "needs-approval", title: "Needs approval"),
        InboxFolder(id: 3, kind: .owner, parentID: 1, slug: "a", title: "A", position: 1),
        InboxFolder(id: 4, kind: .owner, parentID: 3, slug: "a1", title: "A1"),
        InboxFolder(id: 5, kind: .owner, parentID: 1, slug: "h", title: "H", position: 2, hidden: true),
        InboxFolder(id: 6, kind: .owner, parentID: 5, slug: "h1", title: "H1")
    ])

    private func card(_ id: Int64, read: Bool = false, refs: [(String, Int64)] = []) -> AutomationOutputCard {
        AutomationOutputCard(
            id: id, automationID: 1, automationName: "A", runID: 1, title: "t", body: "b", priority: "medium",
            createdAt: Date(timeIntervalSince1970: 0), readAt: read ? Date(timeIntervalSince1970: 1) : nil,
            blocksJSON: refs.isEmpty ? "" : InboxFolderFixtures.listDocument(refs.map { (kind: $0.0, id: $0.1) })
        )
    }

    private func count(_ card: AutomationOutputCard, _ state: InboxRefState) -> Int {
        InboxFolderCounts.artifactCount(card, refs: InboxRef.refs(blocksJSON: card.blocksJSON), refState: state)
    }

    func testPlainArtifactCountsOneWhileUnread() {
        let state = InboxRefState()
        XCTAssertEqual(count(card(1), state), 1)
        XCTAssertEqual(count(card(2, read: true), state), 0)
    }

    func testRefArtifactCountsItsWaitingRowsWhateverItsReadState() {
        let waiting = InboxRef(kind: .inboxItem, id: 10)
        let shownOnly = InboxRef(kind: .idea, id: 11)
        let state = InboxRefState(shown: [waiting, shownOnly], waiting: [waiting])
        let refs = [("inbox_item", Int64(10)), ("idea", 11), ("track", 12)]

        XCTAssertEqual(count(card(1, refs: refs), state), 1,
                       "a shown row that does not wait and a closed row are not counted")
        XCTAssertEqual(count(card(2, read: true, refs: refs), state), 1)
        XCTAssertEqual(count(card(3, refs: [("track", 12)]), state), 0,
                       "every row closed: 0 even unread")
    }

    func testFolderCountsItsOwnArtifactsNotItsChildrens() {
        let artifacts = [Int64(3): [card(1), card(2)], 4: [card(3)]]
        let counts = InboxFolderCounts.counts(
            tree: tree, artifacts: artifacts, refs: InboxFolderCounts.refs(of: artifacts), refState: InboxRefState(),
            legacy: [:])

        XCTAssertEqual(counts[3], 2)
        XCTAssertEqual(counts[4], 1)
        XCTAssertEqual(counts[1], 0)
        XCTAssertEqual(counts.count, tree.folders.count, "every folder has a number")
    }

    func testNeedsApprovalCountsTheApprovalsItShowsNotItsArtifactRows() {
        let action = InboxRef(kind: .action, id: 7)
        let state = InboxRefState(shown: [action], waiting: [action])
        let artifacts = [Int64(2): [card(1, refs: [("action", 7)]), card(2)]]
        let counts = InboxFolderCounts.counts(
            tree: tree, artifacts: artifacts, refs: InboxFolderCounts.refs(of: artifacts), refState: state,
            legacy: [2: 3, 1: 2])

        XCTAssertEqual(counts[2], 3, "the recipe card's row is one of those three approvals")
        XCTAssertEqual(counts[1], 2, "legacy terms add to the root")
    }

    func testRefsOfParsesEachCardOnceByID() {
        let artifacts = [Int64(1): [card(10, refs: [("track", 1)]), card(11)], 3: [card(12, refs: [("idea", 2), ("idea", 3)])]]
        let refs = InboxFolderCounts.refs(of: artifacts)
        XCTAssertEqual(refs[10], [InboxRef(kind: .track, id: 1)])
        XCTAssertEqual(refs[11], [])
        XCTAssertEqual(refs[12], [InboxRef(kind: .idea, id: 2), InboxRef(kind: .idea, id: 3)])
    }

    func testUncountedAutomationsArtifactsAddNothing() {
        let artifacts = [Int64(1): [card(1), card(2)]]
        let counts = InboxFolderCounts.counts(
            tree: tree, artifacts: artifacts, refs: InboxFolderCounts.refs(of: artifacts), refState: InboxRefState(),
            legacy: [1: 2], uncounted: [1])
        XCTAssertEqual(counts[1], 2, "only the legacy terms")
    }

    // MARK: - The badge, read end to end

    private let now = "2026-10-16T12:00:00Z"
    private let today = "2026-10-16T09:00:00Z"

    private func utc() throws -> Calendar {
        try InboxTodayFixture.calendar("UTC")
    }

    /// An open message, created at `createdAt`.
    @discardableResult
    private static func message(_ db: Database, _ ts: String = "1", createdAt: String) throws -> Int64 {
        let id = try TestDatabase.insertInboxItem(db, messageTS: ts)
        try db.execute(sql: "UPDATE inbox_items SET created_at = ? WHERE id = ?", arguments: [createdAt, id])
        return id
    }

    private func snapshot(_ pool: DatabasePool) async throws -> InboxFolderMenuSnapshot {
        let now = now
        let calendar = try utc()
        return try await pool.read { try InboxFolderMenuSnapshot.read($0, nowUTC: now, calendar: calendar) }
    }

    func testRootCountsPeopleTodayBriefAndArtifacts() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let today = today
        let root = try await pool.write { db -> Int64 in
            let seed = try InboxFolderFixtures.seed(db)
            try Self.message(db, "1", createdAt: today)
            try Self.message(db, "2", createdAt: "2026-10-15T09:00:00Z")
            // Today's unread brief counts; an unread past brief does not.
            try TestDatabase.insertBriefing(db, date: "2026-10-16")
            try TestDatabase.insertBriefing(db, date: "2026-10-15")
            try db.execute(sql: "UPDATE briefings SET created_at = date || 'T05:00:00Z'")
            _ = try TestDatabase.insertIdea(db, status: "proposed")
            let automation = try TestDatabase.insertAutomation(db, slug: "root-one")
            let run = try TestDatabase.insertAutomationRun(db, automationID: automation)
            try TestDatabase.insertAutomationOutput(db, automationID: automation, runID: run)
            return seed.root
        }

        let read = try await snapshot(pool)

        XCTAssertEqual(read.peopleWaitingToday, 1)
        XCTAssertEqual(read.counts[root], 3, "1 person today + today's unread brief + the unread plain artifact")
        XCTAssertEqual(read.badge, 1, "the badge takes the people only")
    }

    /// A succeeded Waiting for me lists today's people, whom the root
    /// already counts through `peopleWaitingToday`: its rows add nothing.
    func testWaitingForMeArtifactIsNotCountedTwice() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let (now, today) = (now, today)
        let root = try await pool.write { db -> Int64 in
            let seed = try InboxFolderFixtures.seed(db)
            let first = try Self.message(db, "1", createdAt: today)
            let second = try Self.message(db, "2", createdAt: today)
            let id = try TestDatabase.insertAutomation(db, slug: "waiting-for-me")
            try db.execute(sql: """
                UPDATE automations SET origin = 'builtin', builtin_id = 'waiting-for-me', path = 'builtin:waiting-for-me'
                WHERE id = ?
                """, arguments: [id])
            let run = try TestDatabase.insertAutomationRun(db, automationID: id, status: "succeeded")
            try TestDatabase.insertAutomationOutput(
                db, automationID: id, runID: run, readAt: now,
                blocksJSON: InboxFolderFixtures.listDocument([("inbox_item", first), ("inbox_item", second)]),
                outputKey: "waiting")
            return seed.root
        }

        let read = try await snapshot(pool)

        XCTAssertFalse(read.waitingForMe.messagesStandIn)
        XCTAssertEqual(read.counts[root], 2, "2 people today, not 4")
        XCTAssertEqual(read.badge, 2)
    }

    /// An owner folder's and a hidden folder's artifacts keep their own
    /// counts on their rail rows; neither reaches the badge, nor does a
    /// root artifact.
    func testOwnerFolderArtifactsNeverReachTheBadge() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let today = today
        let ids = try await pool.write { db -> (owner: Int64, hidden: Int64) in
            let seed = try InboxFolderFixtures.seed(db)
            let owner = try InboxFolderFixtures.folder(db, parent: seed.root, slug: "a", position: 1)
            let hidden = try InboxFolderFixtures.folder(db, parent: seed.root, slug: "h", position: 2, hidden: true)
            // Needs approval: one proposal + one due reminder.
            try TestDatabase.insertAgentAction(db, status: "pending")
            try db.execute(sql: """
                INSERT INTO reminders (message_ref, note, remind_at, status) VALUES ('C1@1', 'n', '2000-01-01T00:00:00Z', 'pending')
                """)
            try Self.message(db, createdAt: today)
            let rootAutomation = try TestDatabase.insertAutomation(db, slug: "root-one")
            let rootRun = try TestDatabase.insertAutomationRun(db, automationID: rootAutomation)
            try TestDatabase.insertAutomationOutput(db, automationID: rootAutomation, runID: rootRun)
            for (slug, folder) in [("owner-one", owner), ("hidden-one", hidden)] {
                let automation = try TestDatabase.insertAutomation(db, slug: slug)
                try InboxFolderFixtures.route(db, automation: automation, folder: folder)
                let run = try TestDatabase.insertAutomationRun(db, automationID: automation)
                try TestDatabase.insertAutomationOutput(db, automationID: automation, runID: run)
            }
            return (owner: owner, hidden: hidden)
        }

        let read = try await snapshot(pool)

        XCTAssertEqual(read.counts[ids.owner], 1)
        XCTAssertEqual(read.counts[ids.hidden], 1)
        XCTAssertEqual(read.approvalsCount, 2)
        XCTAssertEqual(read.badge, 3, "2 approvals + 1 person today; no artifact")
        let calendar = try utc()
        let now = now
        let badge = try await pool.read { try ActionStripViewModel.badgeCount($0, nowUTC: now, calendar: calendar) }
        XCTAssertEqual(badge, read.badge)
    }

    func testUnreadMessagesLeaveTheRootOnceWaitingForMeSucceeded() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let (now, today, calendar) = (now, today, try utc())
        let item = try await pool.write { db -> Int64 in
            try InboxFolderFixtures.seed(db)
            return try Self.message(db, createdAt: today)
        }
        let before = try await pool.read { try ActionStripViewModel.badgeCount($0, nowUTC: now, calendar: calendar) }
        XCTAssertEqual(before, 1, "the Messages entry stands in before the first run: one person today")

        try await pool.write { db in
            let id = try TestDatabase.insertAutomation(db, slug: "waiting-for-me")
            try db.execute(sql: """
                UPDATE automations SET origin = 'builtin', builtin_id = 'waiting-for-me', path = 'builtin:waiting-for-me'
                WHERE id = ?
                """, arguments: [id])
            let run = try TestDatabase.insertAutomationRun(db, automationID: id, status: "succeeded")
            try TestDatabase.insertAutomationOutput(
                db, automationID: id, runID: run, readAt: now,
                blocksJSON: InboxFolderFixtures.listDocument([("inbox_item", item)]), outputKey: "waiting")
        }
        let after = try await pool.read { try ActionStripViewModel.badgeCount($0, nowUTC: now, calendar: calendar) }
        XCTAssertEqual(after, 1, "the person counts once, as people waiting today, not again as Waiting for me's row")
    }

    /// The stand-in rule: after a failed run the Messages entry is back and
    /// the stale Waiting for me list of the earlier success leaves the root,
    /// so each open message counts once.
    func testStaleWaitingForMeListLeavesTheBadgeAfterAFailedRun() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let (now, today, calendar) = (now, today, try utc())
        try await pool.write { db in
            try InboxFolderFixtures.seed(db)
            let first = try Self.message(db, "1", createdAt: today)
            let second = try Self.message(db, "2", createdAt: today)
            let id = try TestDatabase.insertAutomation(db, slug: "waiting-for-me")
            try db.execute(sql: """
                UPDATE automations SET origin = 'builtin', builtin_id = 'waiting-for-me', path = 'builtin:waiting-for-me'
                WHERE id = ?
                """, arguments: [id])
            let run = try TestDatabase.insertAutomationRun(db, automationID: id, status: "succeeded")
            try TestDatabase.insertAutomationOutput(
                db, automationID: id, runID: run,
                blocksJSON: InboxFolderFixtures.listDocument([("inbox_item", first), ("inbox_item", second)]),
                outputKey: "waiting")
            try TestDatabase.insertAutomationRun(db, automationID: id, status: "failed")
        }

        let badge = try await pool.read { try ActionStripViewModel.badgeCount($0, nowUTC: now, calendar: calendar) }

        XCTAssertEqual(badge, 2, "two people waiting today, counted once; the stale list counts nothing")
        let state = try await pool.read { try InboxFolderQueries.waitingForMe($0) }
        XCTAssertTrue(state.messagesStandIn)
    }

    func testBadgeWithoutTheFolderSeedRowsCountsEverythingInTheRoot() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        try await pool.write { db in
            try TestDatabase.insertAgentAction(db, status: "pending")
            let automation = try TestDatabase.insertAutomation(db)
            let run = try TestDatabase.insertAutomationRun(db, automationID: automation)
            try TestDatabase.insertAutomationOutput(db, automationID: automation, runID: run)
        }
        let badge = try await pool.read { try ActionStripViewModel.badgeCount($0, nowUTC: "2026-10-16T12:00:00Z") }
        XCTAssertEqual(badge, 1, "the proposal; the unread artifact is not a badge term")
    }
}
