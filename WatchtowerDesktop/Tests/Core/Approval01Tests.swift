import GRDB
import XCTest
import WatchtowerTestSupport
@testable import WatchtowerCore

/// APPROVAL-01 — an open approval is always on screen, a closed one never
/// (`docs/inventory/inbox-folders.md`): Needs approval draws the native card
/// whenever the recipe's card is off, stopped, failed, missing or behind,
/// and draws only the approvals open in the same read as the folder.
@MainActor
final class Approval01Tests: XCTestCase {
    private var path = ""
    private let suite = "Approval01Tests.\(UUID().uuidString)"

    override func tearDown() {
        if !path.isEmpty { TestDatabase.cleanup(path: path) }
        UserDefaults.standard.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private struct Seed {
        let pool: DatabasePool
        let folders: InboxFolderFixtures.Seed
        let builtin: Int64
        let run: Int64
    }

    /// The folders, the Needs approval built-in with one succeeded run.
    private func seed(disabledReason: String = "", runStatus: String = "succeeded") throws -> Seed {
        let (pool, path) = try TestDatabase.createPool()
        self.path = path
        return try pool.write { db in
            let folders = try InboxFolderFixtures.seed(db)
            let builtin = try NeedsApprovalFixtures.builtin(
                db, id: "needs-approval", name: "Needs approval", disabledReason: disabledReason)
            let run = try NeedsApprovalFixtures.run(db, builtin, status: runStatus)
            return Seed(pool: pool, folders: folders, builtin: builtin, run: run)
        }
    }

    /// Needs approval's entries after a read, as the Inbox draws them.
    private func approvals(_ seed: Seed, disabled: Set<String> = []) async -> [InboxFolderEntry] {
        let vm = NeedsApprovalFixtures.viewModel(seed.pool, suite: suite)
        vm.disabledFeatures = disabled
        await vm.refresh()
        vm.selectFolder(seed.folders.approvals)
        return vm.folderEntries
    }

    private func picks(_ entries: [InboxFolderEntry]) -> [String: Bool] {
        var out: [String: Bool] = [:]
        for case let .approval(item) in entries { out[item.key] = item.recipe != nil }
        return out
    }

    func test_APPROVAL_01_native_card_when_recipe_off() async throws {
        let seed = try seed()
        try await seed.pool.write { db in
            _ = try TestDatabase.insertAgentAction(db, createdAt: "2026-11-06T09:00:00Z")
            try NeedsApprovalFixtures.card(db, seed.builtin, run: seed.run, key: "action:1", written: "2026-11-06T09:01:00Z")
        }
        let on = await approvals(seed)
        XCTAssertEqual(picks(on), ["action:1": true], "control: on, current → the recipe's card")

        let off = await approvals(seed, disabled: [ActionStripViewModel.approvalsFeatureID])
        XCTAssertEqual(picks(off), ["action:1": false], "the feature off → the native card")

        let stopped = try self.seed(disabledReason: "the run would not end")
        try await stopped.pool.write { db in
            _ = try TestDatabase.insertAgentAction(db, createdAt: "2026-11-06T09:00:00Z")
            try NeedsApprovalFixtures.card(
                db, stopped.builtin, run: stopped.run, key: "action:1", written: "2026-11-06T09:01:00Z")
        }
        let stoppedEntries = await approvals(stopped)
        XCTAssertEqual(picks(stoppedEntries), ["action:1": false], "stopped by the daemon → native")
    }

    func test_APPROVAL_01_native_card_when_behind() async throws {
        let seed = try seed()
        try await seed.pool.write { db in
            // Failed after its card was written: the card is behind.
            _ = try TestDatabase.insertAgentAction(
                db, status: "failed", error: "the team was archived", createdAt: "2026-11-06T09:00:00Z",
                decidedAt: "2026-11-06T09:05:00Z", appliedAt: "2026-11-06T09:06:00Z")
            try NeedsApprovalFixtures.card(db, seed.builtin, run: seed.run, key: "action:1", written: "2026-11-06T09:01:00Z")
            // New since the last run: no card yet.
            _ = try TestDatabase.insertAgentAction(db, turnID: "turn-2", createdAt: "2026-11-06T09:30:00Z")
            // A due reminder whose card predates its due time.
            try db.execute(sql: """
                INSERT INTO reminders (message_ref, note, remind_at, status, created_at)
                VALUES ('C1@1', 'call back', '2026-11-06T09:50:00Z', 'pending', '2026-11-06T08:00:00Z')
                """)
            try NeedsApprovalFixtures.card(
                db, seed.builtin, run: seed.run, key: "reminder:1", written: "2026-11-06T08:01:00Z")
        }
        let behind = await approvals(seed)
        XCTAssertEqual(picks(behind), ["action:1": false, "action:2": false, "reminder:1": false])

        let failed = try self.seed(runStatus: "failed")
        try await failed.pool.write { db in
            _ = try TestDatabase.insertAgentAction(db, createdAt: "2026-11-06T09:00:00Z")
            try NeedsApprovalFixtures.card(
                db, failed.builtin, run: failed.run, key: "action:1", written: "2026-11-06T09:01:00Z")
        }
        let failedEntries = await approvals(failed)
        XCTAssertEqual(picks(failedEntries), ["action:1": false], "the last run failed → native")
    }

    func test_APPROVAL_01_closed_never_drawn() async throws {
        let seed = try seed()
        try await seed.pool.write { db in
            _ = try TestDatabase.insertAgentAction(db, status: "applied", createdAt: "2026-11-06T09:00:00Z",
                                                   decidedAt: "2026-11-06T09:02:00Z", appliedAt: "2026-11-06T09:03:00Z")
            try NeedsApprovalFixtures.card(db, seed.builtin, run: seed.run, key: "action:1", written: "2026-11-06T09:04:00Z")
            try db.execute(sql: """
                INSERT INTO reminders (message_ref, note, remind_at, status, created_at)
                VALUES ('C1@1', 'call back', '2026-11-06T09:00:00Z', 'done', '2026-11-06T08:00:00Z')
                """)
            try NeedsApprovalFixtures.card(db, seed.builtin, run: seed.run, key: "reminder:1", written: "2026-11-06T09:04:00Z")
        }
        let vm = NeedsApprovalFixtures.viewModel(seed.pool, suite: suite)
        await vm.refresh()
        vm.selectFolder(seed.folders.approvals)
        XCTAssertEqual(vm.folderEntries, [], "closed approvals: nothing in Needs approval")
        vm.selectFolder(seed.folders.root)
        XCTAssertEqual(vm.folderEntries, [], "and their live cards are drawn nowhere else")
        XCTAssertEqual(vm.folderMenu.snapshot.counts.values.reduce(0, +), 0, "nor counted")
    }
}
