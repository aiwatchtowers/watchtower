import GRDB
import XCTest
import WatchtowerTestSupport
@testable import WatchtowerCore

/// The thread briefs of the `:brief:` reaction in the Inbox root (ask #609):
/// one entry per `brief_context` row applied in the last 24 hours, by its
/// applied time among the root's entries, drawn on its agent-action card,
/// never counted and never in Needs approval. Times are seeded from `Date()`.
@MainActor
final class InboxBriefEntryTests: XCTestCase {
    private var path = ""
    private let suite = "InboxBriefEntryTests.\(UUID().uuidString)"
    private let now = Date()

    override func tearDown() {
        if !path.isEmpty { TestDatabase.cleanup(path: path) }
        UserDefaults.standard.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func pool() throws -> DatabasePool {
        let (pool, path) = try TestDatabase.createPool()
        self.path = path
        return pool
    }

    /// `hours` before `now`, in the column format.
    nonisolated private static func stamp(_ now: Date, hoursAgo hours: Double) -> String {
        AutomationDates.format(now.addingTimeInterval(-hours * 3600))
    }

    @discardableResult
    nonisolated private static func brief(
        _ db: Database,
        now: Date,
        hoursAgo: Double,
        status: String = "applied",
        tool: String = "brief_context",
        reason: String = "Brief of a thread",
        contextType: String = "slack_message"
    ) throws -> Int64 {
        let at = stamp(now, hoursAgo: hoursAgo)
        return try TestDatabase.insertAgentAction(
            db, tool: tool, argsJSON: #"{"summary":"s","reason":"r"}"#, reason: reason, surface: "reaction",
            contextType: contextType, status: status, resultJSON: #"{"summary":"What the thread is about"}"#,
            createdAt: at, decidedAt: at, appliedAt: status == "applied" ? at : "")
    }

    private func viewModel(_ pool: DatabasePool) -> ActionStripViewModel {
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let now = now
        // Labeled: a trailing closure would bind to `automationsWake`.
        // swiftlint:disable:next trailing_closure
        return ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner(), defaults: defaults, clock: { now })
    }

    // MARK: - The read

    func testReadKeepsOnlyBriefsAppliedInTheLast24HoursNewestFirst() throws {
        let queue = try TestDatabase.create()
        let now = now
        let ids = try queue.write { db in
            let older = try Self.brief(db, now: now, hoursAgo: 23)
            let newer = try Self.brief(db, now: now, hoursAgo: 1)
            try Self.brief(db, now: now, hoursAgo: 25)
            try Self.brief(db, now: now, hoursAgo: 1, tool: "create_target")
            for status in ["pending", "approved", "executing", "failed", "rejected"] {
                try Self.brief(db, now: now, hoursAgo: 1, status: status)
            }
            try Self.brief(db, now: now, hoursAgo: 1, contextType: "project")
            return [newer, older]
        }
        let feed = try queue.read { db in
            try InboxFeedQueries.read(db, nowUTC: AutomationDates.format(now), dayLimit: 30)
        }
        XCTAssertEqual(feed.briefs.map(\.id), ids)
        XCTAssertEqual(feed.briefs.first?.resultString("summary"), "What the thread is about")
    }

    func testReadToleratesAMissingTable() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in try db.execute(sql: "DROP TABLE agent_actions") }
        let feed = try queue.read { db in
            try InboxFeedQueries.read(db, nowUTC: AutomationDates.format(self.now), dayLimit: 30)
        }
        XCTAssertTrue(feed.briefs.isEmpty)
    }

    // MARK: - The root

    func testRootListsBriefsByAppliedTimeAmongItsEntries() async throws {
        let pool = try pool()
        let now = now
        let ids = try await pool.write { db in
            let folders = try InboxFolderFixtures.seed(db)
            let newer = try Self.brief(db, now: now, hoursAgo: 0.25)
            let older = try Self.brief(db, now: now, hoursAgo: 2, reason: "")
            try TestDatabase.insertIdea(db, updatedAt: Self.stamp(now, hoursAgo: 1))
            return (root: folders.root, approvals: folders.approvals, newer: newer, older: older)
        }
        let vm = viewModel(pool)
        await vm.refresh()
        vm.selectFolder(ids.root)

        XCTAssertEqual(vm.folderEntries.map(\.id), ["brief:\(ids.newer)", "ideas", "brief:\(ids.older)"])
        let rows = vm.folderList.rows
        XCTAssertEqual(rows[0].kind, .result)
        XCTAssertEqual(rows[0].title, "Brief of a thread")
        XCTAssertEqual(rows[0].detail, "Thread brief · 15 min ago")
        XCTAssertEqual(rows[2].title, "Thread brief", "an empty reason falls back to the tool's name")
        XCTAssertFalse(rows[0].unread || rows[2].unread, "a result never waits on the owner")

        vm.selectFolder(ids.approvals)
        XCTAssertFalse(vm.folderEntries.contains { $0.id.hasPrefix("brief:") }, "Needs approval is for decisions only")
    }

    func testBriefsNeverCount() async throws {
        let pool = try pool()
        let now = now
        let root = try await pool.write { db in
            let folders = try InboxFolderFixtures.seed(db)
            try Self.brief(db, now: now, hoursAgo: 1)
            return folders.root
        }
        let badge = try await pool.read { db in
            try ActionStripViewModel.badgeCount(db, nowUTC: AutomationDates.format(now))
        }
        XCTAssertEqual(badge, 0)
        let vm = viewModel(pool)
        await vm.refresh()
        vm.selectFolder(root)
        XCTAssertEqual(vm.folderEntries.count, 1)
        XCTAssertTrue(vm.folderMenu.snapshot.counts.values.allSatisfy { $0 == 0 })
    }

    // MARK: - Selection and routes

    func testSelectingABriefShowsItsAgentActionCard() async throws {
        let pool = try pool()
        let now = now
        let ids = try await pool.write { db in
            let folders = try InboxFolderFixtures.seed(db)
            return (root: folders.root, brief: try Self.brief(db, now: now, hoursAgo: 1))
        }
        let vm = viewModel(pool)
        await vm.refresh()
        vm.selectFolder(ids.root)
        await vm.selectEntry("brief:\(ids.brief)")

        XCTAssertEqual(vm.selection, .proposal(ids.brief))
        guard case let .brief(action)? = vm.selectedEntry else { return XCTFail("the brief is not selected") }
        XCTAssertEqual(action.id, ids.brief)

        // A refresh keeps it open while it is listed.
        await vm.refresh()
        XCTAssertEqual(vm.selection, .proposal(ids.brief))
    }

    func testARouteToABriefOpensItsRootEntry() async throws {
        let pool = try pool()
        let now = now
        let ids = try await pool.write { db in
            let folders = try InboxFolderFixtures.seed(db)
            return (root: folders.root, approvals: folders.approvals, brief: try Self.brief(db, now: now, hoursAgo: 1))
        }
        let vm = viewModel(pool)
        await vm.refresh()
        vm.selectFolder(ids.approvals)
        await vm.open(folder: nil, select: .card(.proposal(ids.brief)))

        XCTAssertEqual(vm.folderMenu.selectedFolderID, ids.root)
        XCTAssertEqual(vm.selectedEntry?.id, "brief:\(ids.brief)")
        XCTAssertEqual(vm.selection, .proposal(ids.brief))
    }
}
