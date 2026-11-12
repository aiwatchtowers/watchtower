import GRDB
import XCTest
import WatchtowerTestSupport
@testable import WatchtowerCore

/// **Approve All N…** on a Needs approval group: each row through the
/// per-action path (`AgentActionFeed.approve`, args pinned), rows closed
/// meanwhile skipped, the first failure stops the run on its card, and the
/// press survives leaving the Inbox. The fake CLI runner stands in for
/// `watchtower actions approve` (`ActionStripViewModelTests`' precedent).
@MainActor
final class ActionStripApproveAllTests: XCTestCase {
    private struct Boom: LocalizedError {
        var errorDescription: String? { "boom" }
    }

    private var paths: [String] = []
    private let suite = "ActionStripApproveAllTests.\(UUID().uuidString)"

    override func tearDown() {
        paths.forEach { TestDatabase.cleanup(path: $0) }
        paths = []
        UserDefaults.standard.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private static let ok = Data(#"{"ok":true,"applied_ok":true,"error":""}"#.utf8)

    private func pool() throws -> DatabasePool {
        let (pool, path) = try TestDatabase.createPool()
        paths.append(path)
        return pool
    }

    /// The folders and `count` pending rows of `tool`, oldest first.
    private func seed(_ pool: DatabasePool, tool: String, count: Int) async throws -> (InboxFolderFixtures.Seed, [Int64]) {
        try await pool.write { db in
            let folders = try InboxFolderFixtures.seed(db)
            let ids = try (0..<count).map { index in
                try TestDatabase.insertAgentAction(
                    db, tool: tool, argsJSON: #"{"title":"Task \#(index)"}"#, createdAt: "2026-11-06T09:0\(index):00Z")
            }
            return (folders, ids)
        }
    }

    private func viewModel(_ pool: DatabasePool, runner: FakeCLIRunner) -> ActionStripViewModel {
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        let now = NeedsApprovalFixtures.now
        return ActionStripViewModel(dbPool: pool, cliRunner: runner, defaults: defaults, clock: { now },
                                    dayChangeSignals: [])
    }

    private func approveCall(_ id: Int64, _ args: String) -> [String] {
        ["actions", "approve", String(id), "--args-sha256", AgentActionFeed.argsSHA256(args), "--json"]
    }

    func testApproveAllApprovesEachThroughTheFeed() async throws {
        let pool = try pool()
        let (_, ids) = try await seed(pool, tool: "create_targets", count: 3)
        let runner = FakeCLIRunner(stdout: Self.ok)
        let vm = viewModel(pool, runner: runner)
        await vm.refresh()

        let plan = vm.approveAllPlan(.targets)
        XCTAssertEqual(plan, InboxBulkPlan(ids: ids.map(String.init), count: 3))
        let result = await vm.approveAll(ids: plan.ids)

        XCTAssertEqual(result, .done(count: 3, skipped: 0))
        XCTAssertEqual(runner.invocations, ids.enumerated().map { approveCall($1, #"{"title":"Task \#($0)"}"#) })
    }

    func testApproveAllSkipsRowsClosedMeanwhile() async throws {
        let pool = try pool()
        let (_, ids) = try await seed(pool, tool: "create_track", count: 3)
        let runner = FakeCLIRunner(stdout: Self.ok)
        let vm = viewModel(pool, runner: runner)
        await vm.refresh()
        let plan = vm.approveAllPlan(.tracksToCreate)
        XCTAssertEqual(plan.count, 3)

        // Rejected elsewhere (the phone, the CLI) after the plan was read.
        let otherPool = try DatabasePool(path: pool.path)
        try await otherPool.write { db in
            try db.execute(sql: "UPDATE agent_actions SET status = 'rejected' WHERE id = ?", arguments: [ids[1]])
        }
        let result = await vm.approveAll(ids: plan.ids)

        XCTAssertEqual(result, .done(count: 2, skipped: 1))
        let approved = runner.invocations.filter { $0.prefix(2) == ["actions", "approve"] }.map { $0[2] }
        XCTAssertEqual(approved, [String(ids[0]), String(ids[2])])
    }

    func testApproveAllStopsAtFirstFailureAndSelectsThatCard() async throws {
        let pool = try pool()
        let (folders, ids) = try await seed(pool, tool: "update_target", count: 3)
        let runner = FakeCLIRunner(stdout: Self.ok)
        let second = String(ids[1])
        runner.onRun = { [runner] args in
            if args.contains(second) { runner.shouldThrow = Boom() }
        }
        let vm = viewModel(pool, runner: runner)
        await vm.refresh()
        vm.selectFolder(folders.approvals)

        let result = await vm.approveAll(ids: vm.approveAllPlan(.targets).ids)

        XCTAssertEqual(result, .partial(done: 1, of: 3, error: "boom"))
        XCTAssertEqual(runner.invocations.map { $0[2] }, [String(ids[0]), second], "the third is never approved")
        XCTAssertEqual(vm.entrySelection, "approval:action:\(ids[1])")
        XCTAssertEqual(vm.actionFeed.rowErrors[ids[1]]?.message, "boom", "the error shows on that card")
    }

    /// APPROVAL-01 (supporting): grouping never hides an open approval —
    /// every entry of `InboxFolderEntries.build` is a row of its own or
    /// inside its group's Approve All row, and nothing else is listed.
    func testEveryOpenApprovalStaysListed() async throws {
        let pool = try pool()
        let folders = try await pool.write { db in
            let folders = try InboxFolderFixtures.seed(db)
            for (index, tool) in ["create_track", "send_slack_message", "create_track", "a_tool_added_later",
                                  "send_slack_message", "create_track", "update_target"].enumerated() {
                _ = try TestDatabase.insertAgentAction(db, tool: tool, createdAt: "2026-11-06T09:0\(index):00Z")
            }
            _ = try TestDatabase.insertAgentAction(
                db, status: "executing", createdAt: "2026-11-06T09:08:00Z", decidedAt: "2026-11-06T09:09:00Z")
            try db.execute(sql: """
                INSERT INTO reminders (message_ref, note, remind_at, status, created_at)
                VALUES ('C1@1', 'call back', '2000-01-01T00:00:00Z', 'pending', '2026-11-06T08:00:00Z')
                """)
            return folders
        }
        let vm = viewModel(pool, runner: FakeCLIRunner(stdout: Self.ok))
        await vm.refresh()
        vm.selectFolder(folders.approvals)

        let list = vm.folderList
        XCTAssertEqual(list.sections.map(\.id), ["reminders", "tracksToCreate", "messages", "other", "targets",
                                                 NeedsApprovalGroups.inFlightSectionID])
        XCTAssertEqual(list.sections.map(\.count), [1, 3, 2, 1, 1, nil])
        let open = vm.folderEntries.compactMap { entry -> NeedsApprovalItem? in
            guard case let .approval(item) = entry,
                  NeedsApprovalGroups.isOpen(item, openActions: vm.folderMenu.snapshot.openActions) else { return nil }
            return item
        }
        let groups = Dictionary(uniqueKeysWithValues: NeedsApprovalGroups.build(open)
            .map { (NeedsApprovalGroups.rowID($0.0), $0.1) })
        let listed = list.rows.flatMap { row -> [String] in
            guard let items = groups[row.id] else { return [row.id] }
            return items.map { InboxFolderEntry.approval($0).id }
        }
        XCTAssertEqual(listed.count, Set(listed).count, "each approval listed once")
        XCTAssertEqual(Set(listed), Set(vm.folderEntries.map(\.id)))
        XCTAssertEqual(list.sections.first { $0.id == "tracksToCreate" }?.rows.map(\.id), ["group:tracksToCreate"])
    }

    func testApproveAllModelSurvivesLeavingTheInbox() async throws {
        let pool = try pool()
        _ = try await seed(pool, tool: "create_targets", count: 3)
        let runner = FakeCLIRunner(stdout: Self.ok)
        let vm = viewModel(pool, runner: runner)
        vm.setOnScreen(true)
        await vm.refresh()
        let model = vm.approveAllModel(.targets)
        XCTAssertTrue(model === vm.approveAllModel(.targets), "one model per group")

        model.begin()
        await waitUntil(model) { if case .confirming = $0 { true } else { false } }
        XCTAssertEqual(model.state, .confirming(vm.approveAllPlan(.targets)))
        model.confirm()
        vm.setOnScreen(false)
        await waitUntil(model) { if case .finished = $0 { true } else { false } }

        XCTAssertTrue(model === vm.approveAllModel(.targets))
        XCTAssertEqual(model.state, .finished(.done(count: 3, skipped: 0)))
        XCTAssertEqual(runner.invocations.filter { $0.prefix(2) == ["actions", "approve"] }.count, 3)
    }

    /// Yields until `model` reaches a state `done` accepts, failing after 10 s.
    private func waitUntil(
        _ model: InboxBulkPressModel, _ done: (InboxBulkPressModel.State) -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(10)
        while !done(model.state) {
            guard Date() < deadline else { return XCTFail("still \(model.state)") }
            await Task.yield()
        }
    }
}
