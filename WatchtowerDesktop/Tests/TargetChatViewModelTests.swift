import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class TargetChatViewModelTests: XCTestCase {
    private func makeTarget(_ manager: DatabaseManager, intent: String) throws -> Target {
        let id = try manager.dbPool.write { db in
            try TargetQueries.create(db, text: "ship feature", intent: intent,
                                     periodStart: "2026-06-01", periodEnd: "2026-06-30")
        }
        return try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: id) })
    }

    /// Synchronous DB helpers — inside an `async` test the trailing-closure
    /// `dbPool.read` resolves to GRDB's async overload, which XCTUnwrap's
    /// autoclosure cannot await; a sync function pins the sync overload.
    private func fetchTargetRow(_ manager: DatabaseManager, id: Int) throws -> Target? {
        try manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: id) }
    }

    private func ensureChatTables(_ manager: DatabaseManager) throws {
        try manager.dbPool.write { db in
            try ChatConversationQueries.ensureTable(db)
            try ChatMessageQueries.ensureTable(db)
        }
    }

    private func fetchPersistedMessages(_ manager: DatabaseManager, targetID: Int) throws -> [ChatMessageRecord] {
        try manager.dbPool.read { db in
            guard let conv = try ChatConversationQueries.fetchByContext(
                db, type: "target", id: String(targetID)
            ) else { return [] }
            return try ChatMessageQueries.fetchByConversation(db, conversationID: conv.id)
        }
    }

    func testSystemPromptIncludesIntentAndContract() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try manager.dbPool.write { db in try TestDatabase.insertWorkspace(db) }
        let target = try makeTarget(manager, intent: "get sign-off from design")

        let prompt = TargetChatViewModel.buildSystemPrompt(target: target, dbPool: manager.dbPool)
        XCTAssertTrue(prompt.contains("get sign-off from design"))
        XCTAssertTrue(prompt.contains("=== TASK ACTIONS ==="))
        XCTAssertTrue(prompt.contains("watchtower-action"))
        XCTAssertTrue(prompt.contains("create_child_target"))
        // The four newer kinds are documented.
        XCTAssertTrue(prompt.contains("update_title"))
        XCTAssertTrue(prompt.contains("update_priority"))
        XCTAssertTrue(prompt.contains("update_due"))
        XCTAssertTrue(prompt.contains("update_intent"))
        // Mode grammar: propose default, execute for directives, ambiguity → propose.
        XCTAssertTrue(prompt.contains("MODE — propose vs execute"))
        XCTAssertTrue(prompt.contains("\"mode\":\"execute\""))
        XCTAssertTrue(prompt.contains("\"mode\":\"propose\""))
        XCTAssertTrue(prompt.contains("When the message is ambiguous, propose"))
        // Mandate rule wording.
        XCTAssertTrue(prompt.contains("broad powers, narrow mandate"))
        XCTAssertTrue(prompt.contains("task's subtree"))
        XCTAssertTrue(prompt.contains("NEVER into actions"))
    }

    /// A reply carrying an execute-mode action block is applied immediately —
    /// no Approve gate, no per-action follow-up AI turn — and exactly one
    /// persisted system message summarizes what was done.
    func testExecuteModeActionAutoAppliesWithOneSummaryMessage() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try ensureChatTables(manager)
        let target = try makeTarget(manager, intent: "x")
        let vm = TargetsViewModel(dbManager: manager)
        let reply = """
        Done — marked it done.
        ```watchtower-action
        { "type": "update_status", "status": "done", "mode": "execute", "reason": "owner instructed" }
        ```
        """
        let mock = MockClaudeService(events: [.sessionID("s1"), .text(reply), .done])
        let chat = TargetChatViewModel(target: target, viewModel: vm, dbManager: manager,
                                       aiService: mock)

        chat.inputText = "mark this done"
        chat.send()
        try await waitForStreamEnd(chat)

        // The DB row actually changed, without any user approval.
        let after = try XCTUnwrap(fetchTargetRow(manager, id: target.id))
        XCTAssertEqual(after.status, "done")
        XCTAssertEqual(chat.actionCards.count, 1)
        XCTAssertEqual(chat.actionCards.first?.state, .applied("set status to done"))
        // Exactly ONE system summary message in the transcript.
        let summaries = chat.messages.filter { $0.role == .system && $0.text.contains("Applied:") }
        XCTAssertEqual(summaries.count, 1)
        XCTAssertTrue(summaries[0].text.contains("set status to done"))
        // NO extra AI invocation (unlike approve's follow-up turn).
        XCTAssertEqual(mock.prompts.count, 1)
        // The summary is persisted through the same path as other system messages.
        let persisted = try fetchPersistedMessages(manager, targetID: target.id)
        XCTAssertEqual(persisted.filter { $0.role == "system" && $0.text.contains("Applied:") }.count, 1)
    }

    /// Regression pin: an action block with NO mode field keeps today's
    /// behavior exactly — a pending card, nothing applied, no summary message.
    func testNoModeActionStaysPendingAndUnapplied() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager, intent: "x")
        let vm = TargetsViewModel(dbManager: manager)
        let reply = """
        I suggest we mark it done.
        ```watchtower-action
        { "type": "update_status", "status": "done", "reason": "looks finished" }
        ```
        """
        let mock = MockClaudeService(events: [.sessionID("s1"), .text(reply), .done])
        let chat = TargetChatViewModel(target: target, viewModel: vm, dbManager: manager,
                                       aiService: mock)

        chat.inputText = "what do you think?"
        chat.send()
        try await waitForStreamEnd(chat)

        XCTAssertEqual(chat.actionCards.count, 1)
        XCTAssertEqual(chat.actionCards.first?.state, .pending)
        let after = try XCTUnwrap(fetchTargetRow(manager, id: target.id))
        XCTAssertEqual(after.status, "todo") // unchanged
        XCTAssertFalse(chat.messages.contains { $0.role == .system && $0.text.contains("Applied:") })
        XCTAssertEqual(mock.prompts.count, 1)
    }

    /// A malformed execute-mode block (missing its required field) is never
    /// applied — it surfaces as the existing invalid-action warning instead.
    func testMalformedExecuteModeBlockNotApplied() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager, intent: "x")
        let vm = TargetsViewModel(dbManager: manager)
        let reply = """
        Doing it.
        ```watchtower-action
        { "type": "update_status", "mode": "execute", "reason": "owner instructed" }
        ```
        """
        let mock = MockClaudeService(events: [.sessionID("s1"), .text(reply), .done])
        let chat = TargetChatViewModel(target: target, viewModel: vm, dbManager: manager,
                                       aiService: mock)

        chat.inputText = "mark this done"
        chat.send()
        try await waitForStreamEnd(chat)

        XCTAssertTrue(chat.actionCards.isEmpty)
        let after = try XCTUnwrap(fetchTargetRow(manager, id: target.id))
        XCTAssertEqual(after.status, "todo") // unchanged
        XCTAssertTrue(chat.messages.contains {
            $0.role == .system && $0.text.contains("Invalid action proposal")
        })
        XCTAssertFalse(chat.messages.contains { $0.role == .system && $0.text.contains("Applied:") })
    }

    func testApproveAppliesActionAndAppendsFollowUp() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager, intent: "x")
        let vm = TargetsViewModel(dbManager: manager)
        let chat = TargetChatViewModel(target: target, viewModel: vm, dbManager: manager,
                                       aiService: MockClaudeService())

        let action = ProposedAction(type: .updateStatus, reason: "done", status: "done")
        let card = TargetActionCard(messageID: UUID(), action: action, state: .pending)
        chat.actionCards = [card]
        chat.approve(card)

        let after = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: target.id) })
        XCTAssertEqual(after.status, "done")
        // card transitions to applied
        XCTAssertEqual(chat.actionCards.first?.state, .applied("set status to done"))
        // a follow-up turn is fed back into the conversation so the AI continues
        XCTAssertTrue(chat.messages.contains {
            $0.role == .system && $0.text.contains("Action applied")
        })
    }

    func testApproveOverridesCreateKind() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager, intent: "x")
        let vm = TargetsViewModel(dbManager: manager)
        let chat = TargetChatViewModel(target: target, viewModel: vm, dbManager: manager,
                                       aiService: MockClaudeService())

        // AI proposed a checkpoint (sub-item); user overrides to a full sub-task.
        let action = ProposedAction(type: .addSubItem, reason: "spin off", text: "Ping Bob")
        let card = TargetActionCard(messageID: UUID(), action: action, state: .pending)
        chat.actionCards = [card]
        chat.approve(card, as: .createChildTarget)

        let children = try manager.dbPool.read { db in
            try Target.fetchAll(db, sql: "SELECT * FROM targets WHERE parent_id = ?", arguments: [target.id])
        }
        XCTAssertEqual(children.count, 1)
        XCTAssertEqual(children.first?.text, "Ping Bob")
        // and it did NOT become a sub-item
        let after = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: target.id) })
        XCTAssertFalse(after.decodedSubItems.contains { $0.text == "Ping Bob" })
    }

    func testApproveWithFailedWriteMarksCardFailed() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager, intent: "x")
        let vm = TargetsViewModel(dbManager: manager)
        let chat = TargetChatViewModel(target: target, viewModel: vm, dbManager: manager,
                                       aiService: MockClaudeService())

        // An action missing its required field cannot be applied — the card must
        // surface .failed and the follow-up must NOT claim success.
        let action = ProposedAction(type: .updateStatus, reason: "x", status: nil)
        let card = TargetActionCard(messageID: UUID(), action: action, state: .pending)
        chat.actionCards = [card]
        chat.approve(card)

        if case .failed = chat.actionCards.first?.state {} else {
            XCTFail("expected .failed, got \(String(describing: chat.actionCards.first?.state))")
        }
        XCTAssertTrue(chat.messages.contains {
            $0.role == .system && $0.text.contains("Action FAILED")
        })
        XCTAssertFalse(chat.messages.contains {
            $0.role == .system && $0.text.contains("Action applied")
        })
    }

    /// A resumed turn drops the system prompt (the CLI uses --resume), so the
    /// per-turn prompt must carry BOTH the live task context and the action
    /// grammar — otherwise a post-restart expired session can no longer emit
    /// valid watchtower-action blocks.
    func testResumedTurnCarriesTaskContextAndActionContract() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager, intent: "x")
        let vm = TargetsViewModel(dbManager: manager)
        let mock = MockClaudeService(eventSequence: [
            [.sessionID("s1"), .text("first reply"), .done],
            [.text("second reply"), .done]
        ])
        let chat = TargetChatViewModel(target: target, viewModel: vm, dbManager: manager,
                                       aiService: mock)

        chat.inputText = "hello"
        chat.send()
        try await waitForStreamEnd(chat)

        chat.inputText = "again"
        chat.send()
        try await waitForStreamEnd(chat)

        XCTAssertEqual(mock.prompts.count, 2)
        // First turn: context + contract live in the system prompt, not the message.
        XCTAssertEqual(mock.prompts[0], "hello")
        // Resumed turn: the message itself must carry context AND the contract.
        XCTAssertTrue(mock.prompts[1].contains("=== CURRENT TASK ==="))
        XCTAssertTrue(mock.prompts[1].contains("=== TASK ACTIONS ==="))
        XCTAssertTrue(mock.prompts[1].hasSuffix("again"))
    }

    private func waitForStreamEnd(_ chat: TargetChatViewModel, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while chat.isStreaming {
            if Date() > deadline {
                XCTFail("stream did not finish within \(timeout)s")
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testRejectMarksCardRejected() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager, intent: "x")
        let vm = TargetsViewModel(dbManager: manager)
        let chat = TargetChatViewModel(target: target, viewModel: vm, dbManager: manager,
                                       aiService: MockClaudeService())

        let action = ProposedAction(type: .updateStatus, reason: "done", status: "done")
        let card = TargetActionCard(messageID: UUID(), action: action, state: .pending)
        chat.actionCards = [card]
        chat.reject(card)

        XCTAssertEqual(chat.actionCards.first?.state, .rejected)
        XCTAssertTrue(chat.messages.contains {
            $0.role == .system && $0.text.contains("rejected")
        })
        let after = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: target.id) })
        XCTAssertEqual(after.status, "todo") // unchanged
    }
}
