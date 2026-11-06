import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

/// The menu's numbers and the sidebar badge (spec "Unread counts and the
/// sidebar badge"): pure cases on hand-built trees, then the badge read end
/// to end.
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

    func testPlainArtifactCountsOneWhileUnread() {
        let state = InboxRefState()
        XCTAssertEqual(InboxFolderCounts.artifactCount(card(1), refState: state), 1)
        XCTAssertEqual(InboxFolderCounts.artifactCount(card(2, read: true), refState: state), 0)
    }

    func testRefArtifactCountsItsWaitingRowsWhateverItsReadState() {
        let waiting = InboxRef(kind: .inboxItem, id: 10)
        let shownOnly = InboxRef(kind: .idea, id: 11)
        let state = InboxRefState(shown: [waiting, shownOnly], waiting: [waiting])
        let refs = [("inbox_item", Int64(10)), ("idea", 11), ("track", 12)]

        XCTAssertEqual(InboxFolderCounts.artifactCount(card(1, refs: refs), refState: state), 1,
                       "a shown row that does not wait and a closed row are not counted")
        XCTAssertEqual(InboxFolderCounts.artifactCount(card(2, read: true, refs: refs), refState: state), 1)
        XCTAssertEqual(InboxFolderCounts.artifactCount(card(3, refs: [("track", 12)]), refState: state), 0,
                       "every row closed: 0 even unread")
    }

    func testFolderCountsItsOwnArtifactsNotItsChildrens() {
        let counts = InboxFolderCounts.counts(
            tree: tree, artifacts: [3: [card(1), card(2)], 4: [card(3)]], refState: InboxRefState(), legacy: [:])

        XCTAssertEqual(counts[3], 2)
        XCTAssertEqual(counts[4], 1)
        XCTAssertEqual(counts[1], 0)
        XCTAssertEqual(counts.count, tree.folders.count, "every folder has a number")
    }

    func testNeedsApprovalCountsTheApprovalsItShowsNotItsArtifactRows() {
        let action = InboxRef(kind: .action, id: 7)
        let state = InboxRefState(shown: [action], waiting: [action])
        let counts = InboxFolderCounts.counts(
            tree: tree, artifacts: [2: [card(1, refs: [("action", 7)]), card(2)]], refState: state,
            legacy: [2: 3, 1: 2])

        XCTAssertEqual(counts[2], 3, "the recipe card's row is one of those three approvals")
        XCTAssertEqual(counts[1], 2, "legacy terms add to the root")
    }

    func testBadgeLeavesHiddenFoldersOut() {
        let counts: [Int64: Int] = [1: 1, 2: 2, 3: 3, 4: 4, 5: 50, 6: 60]
        XCTAssertEqual(InboxFolderCounts.badge(counts: counts, tree: tree), 10,
                       "the hidden folder and its child are out")
    }

    // MARK: - The badge, read end to end

    func testBadgeIsTheVisibleFolderSumAndKeepsTheOldTerms() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let now = "2026-10-16T12:00:00Z"
        try await pool.write { db in
            let seed = try InboxFolderFixtures.seed(db)
            let hidden = try InboxFolderFixtures.folder(db, parent: seed.root, slug: "h", position: 1, hidden: true)
            // Needs approval: one proposal + one due reminder.
            try TestDatabase.insertAgentAction(db, status: "pending")
            try db.execute(sql: """
                INSERT INTO reminders (message_ref, note, remind_at, status) VALUES ('C1@1', 'n', '2000-01-01T00:00:00Z', 'pending')
                """)
            // Root legacy: one idea to judge, one unread open message.
            _ = try TestDatabase.insertIdea(db, status: "proposed")
            let item = try TestDatabase.insertInboxItem(db)
            // Root artifacts: one unread plain, one read plain (0), one read
            // with a waiting row and a closed row (1).
            let automation = try TestDatabase.insertAutomation(db, slug: "root-one")
            let run = try TestDatabase.insertAutomationRun(db, automationID: automation)
            try TestDatabase.insertAutomationOutput(db, automationID: automation, runID: run)
            try TestDatabase.insertAutomationOutput(db, automationID: automation, runID: run, readAt: now)
            try TestDatabase.insertAutomationOutput(
                db, automationID: automation, runID: run, readAt: now,
                blocksJSON: InboxFolderFixtures.listDocument([("inbox_item", item), ("track", 999)]))
            // A hidden folder's artifact leaves the badge.
            let hiddenAutomation = try TestDatabase.insertAutomation(db, slug: "hidden-one")
            try InboxFolderFixtures.route(db, automation: hiddenAutomation, folder: hidden)
            let hiddenRun = try TestDatabase.insertAutomationRun(db, automationID: hiddenAutomation)
            try TestDatabase.insertAutomationOutput(db, automationID: hiddenAutomation, runID: hiddenRun)
        }

        let badge = try await pool.read { try ActionStripViewModel.badgeCount($0, nowUTC: now) }

        // 2 (Needs approval) + 2 (root legacy) + 2 (root artifacts).
        XCTAssertEqual(badge, 6)
    }

    func testUnreadMessagesLeaveTheRootOnceWaitingForMeSucceeded() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let now = "2026-10-16T12:00:00Z"
        let item = try await pool.write { db -> Int64 in
            try InboxFolderFixtures.seed(db)
            return try TestDatabase.insertInboxItem(db)
        }
        let before = try await pool.read { try ActionStripViewModel.badgeCount($0, nowUTC: now) }
        XCTAssertEqual(before, 1, "the Messages entry stands in before the first run")

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
        let after = try await pool.read { try ActionStripViewModel.badgeCount($0, nowUTC: now) }
        XCTAssertEqual(after, 1, "the message counts once, as Waiting for me's waiting row")
    }

    /// The stand-in rule: after a failed run the Messages entry is back and
    /// the stale Waiting for me list of the earlier success leaves the root,
    /// so each open message counts once.
    func testStaleWaitingForMeListLeavesTheBadgeAfterAFailedRun() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let now = "2026-10-16T12:00:00Z"
        try await pool.write { db in
            try InboxFolderFixtures.seed(db)
            let first = try TestDatabase.insertInboxItem(db, messageTS: "1")
            let second = try TestDatabase.insertInboxItem(db, messageTS: "2")
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

        let badge = try await pool.read { try ActionStripViewModel.badgeCount($0, nowUTC: now) }

        XCTAssertEqual(badge, 2, "two open messages, counted once by the Messages entry")
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
        XCTAssertEqual(badge, 2, "the proposal and the unread artifact, both in the root-only tree")
    }
}
