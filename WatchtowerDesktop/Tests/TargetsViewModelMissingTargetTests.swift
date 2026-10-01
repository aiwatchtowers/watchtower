import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// A target deleted in another process after the screen loaded it: the edit
/// must fail visibly and the vanished row must leave the list, not linger to
/// fail again on every retry.
@MainActor
final class TargetsViewModelMissingTargetTests: XCTestCase {

    func testEditOfATargetDeletedElsewhere_ReportsIt_AndDropsTheRow() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let id = try manager.dbPool.write { db in
            try TargetQueries.create(db, text: "gone soon", periodStart: "2026-09-01", periodEnd: "2026-09-30")
        }
        let vm = TargetsViewModel(dbManager: manager)
        vm.load()
        let stale = try XCTUnwrap((vm.todayTargets + vm.allTargets).first { $0.id == id })

        // No `load()` after this delete: the VM's observation never sees
        // another process's write, which is exactly the case under test.
        try manager.dbPool.write { db in try db.execute(sql: "DELETE FROM targets WHERE id = ?", arguments: [id]) }

        vm.updatePriority(stale, to: "high")

        XCTAssertEqual(
            vm.errorMessage,
            "Failed to update priority: \(TargetNotFoundError(id: id).localizedDescription)"
        )
        XCTAssertFalse((vm.todayTargets + vm.allTargets).contains { $0.id == id })
    }

    // MARK: - Missing parent / link endpoint (#145)

    func testCreateChildUnderAParentDeletedElsewhere_NamesTheParent() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let parent = try makeStaleTarget(manager, text: "parent")
        let vm = TargetsViewModel(dbManager: manager)

        XCTAssertNil(vm.createChild(parent, text: "child", intent: "", priority: "medium"))

        XCTAssertEqual(
            vm.errorMessage,
            "Failed to create child target: \(TargetNotFoundError(id: parent.id).localizedDescription)"
        )
    }

    func testLinkFromATargetDeletedElsewhere_NamesTheSource() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let other = try manager.dbPool.write { db in
            try TargetQueries.create(db, text: "other", periodStart: "2026-09-01", periodEnd: "2026-09-30")
        }
        let source = try makeStaleTarget(manager, text: "source")
        let vm = TargetsViewModel(dbManager: manager)

        vm.createLink(from: source.id, to: other, relation: "blocks")

        XCTAssertEqual(
            vm.errorMessage,
            "Failed to link target: \(TargetNotFoundError(id: source.id).localizedDescription)"
        )
    }

    /// The executor's no-op short-circuits ("already done") used to answer
    /// from the caller's stale snapshot and report success for a deleted row.
    func testExecutorNoOpOnATargetDeletedElsewhere_Fails() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let stale = try makeStaleTarget(manager, text: "gone", subItems: #"[{"text":"a","done":true}]"#)
        let vm = TargetsViewModel(dbManager: manager)
        let action = ProposedAction(type: .toggleSubItem, reason: "r", index: 0, match: "a", done: true)

        XCTAssertThrowsError(try TargetActionExecutor.apply(action, target: stale, viewModel: vm)) {
            XCTAssertEqual($0.localizedDescription, TargetNotFoundError(id: stale.id).localizedDescription)
        }
    }

    func testTargetChat_OnATargetDeletedElsewhere_FailsTheCard_AndStartsNoTurn() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let live = try manager.dbPool.write { db in
            try TargetQueries.create(
                db, text: "task", periodStart: "2026-09-01", periodEnd: "2026-09-30",
                subItems: #"[{"text":"a","done":true}]"#
            )
        }
        let target = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: live) })
        let mock = MockClaudeService()
        let conversationID = try manager.dbPool.write { db -> Int64 in
            try ChatConversationQueries.create(
                db, title: "Task", contextType: "target", contextID: String(target.id)
            ).id
        }
        let chat = TargetChatViewModel(
            target: target, viewModel: TargetsViewModel(dbManager: manager), dbManager: manager,
            conversationID: conversationID, aiService: mock, toolsAvailable: true
        )
        try manager.dbPool.write { db in try db.execute(sql: "DELETE FROM targets WHERE id = ?", arguments: [live]) }

        let card = TargetActionCard(
            messageID: UUID(),
            action: ProposedAction(type: .toggleSubItem, reason: "r", index: 0, match: "a", done: true),
            state: .pending
        )
        chat.actionCards = [card]
        chat.approve(card)

        XCTAssertEqual(chat.actionCards.first?.state, .failed(TargetNotFoundError(id: live).localizedDescription))
        XCTAssertTrue(chat.targetGone)
        XCTAssertEqual(chat.errorMessage, "This task no longer exists — it may have been deleted.")
        XCTAssertFalse(chat.isStreaming, "no follow-up turn about a deleted task")

        chat.inputText = "still there?"
        chat.send()
        XCTAssertFalse(chat.isStreaming)
        XCTAssertEqual(chat.inputText, "still there?", "nothing was sent, so the text stays")
        XCTAssertTrue(mock.prompts.isEmpty)
    }

    /// Loads a target, then deletes its row behind the caller's back and
    /// returns the stale snapshot.
    private func makeStaleTarget(_ manager: DatabaseManager, text: String, subItems: String = "[]") throws -> Target {
        let id = try manager.dbPool.write { db in
            try TargetQueries.create(db, text: text, periodStart: "2026-09-01", periodEnd: "2026-09-30", subItems: subItems)
        }
        let snapshot = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: id) })
        try manager.dbPool.write { db in try db.execute(sql: "DELETE FROM targets WHERE id = ?", arguments: [id]) }
        return snapshot
    }
}
