import GRDB
import XCTest
import WatchtowerTestSupport
@testable import WatchtowerCore

/// The thread briefs of the `:brief:` reaction in the Inbox root (ask #609),
/// drawn on their agent-action card. Which briefs are listed, where and that
/// they never count is Go's (`TestLegacy_*`, the parity cases); these tests
/// hand the view model a canned feed. Times are seeded from `Date()`.
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

    // MARK: - The root

    // MARK: - Selection and routes

    func testSelectingABriefShowsItsAgentActionCard() async throws {
        let pool = try pool()
        let now = now
        let ids = try await pool.write { db in
            let folders = try InboxFolderFixtures.seed(db)
            return (root: folders.root, brief: try Self.brief(db, now: now, hoursAgo: 1))
        }
        let vm = viewModel(pool)
        await vm.showFeed(try TestInboxFeeds.feed(pool, root: [.brief(ids.brief)]))
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
        await vm.showFeed(try TestInboxFeeds.feed(pool, root: [.brief(ids.brief)]))
        vm.selectFolder(ids.approvals)
        await vm.open(folder: nil, select: .card(.proposal(ids.brief)))

        XCTAssertEqual(vm.folderMenu.selectedFolderID, ids.root)
        XCTAssertEqual(vm.selectedEntry?.id, "brief:\(ids.brief)")
        XCTAssertEqual(vm.selection, .proposal(ids.brief))
    }
}
