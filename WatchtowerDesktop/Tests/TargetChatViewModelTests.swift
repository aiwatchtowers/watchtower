import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

private struct StubStreamError: LocalizedError {
    var errorDescription: String? { "CLI exploded" }
}

@MainActor
final class TargetChatViewModelTests: XCTestCase {
    private func makeTarget(_ manager: DatabaseManager, intent: String) throws -> Target {
        let id = try manager.dbPool.write { db in
            try TargetQueries.create(db, text: "ship feature", intent: intent,
                                     periodStart: "2026-06-01", periodEnd: "2026-06-30")
        }
        return try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: id) })
    }

    /// A chat VM wired to a real conversation row. The VM adopts a conversation
    /// the container resolved for it, so the tab has to exist first — and the
    /// chat tables are Desktop-owned (created at runtime by `DatabaseManager`),
    /// so the shared test schema does not carry them.
    private func makeChat(
        target: Target,
        vm: TargetsViewModel,
        manager: DatabaseManager,
        aiService: any AIServiceProtocol = MockClaudeService()
    ) throws -> TargetChatViewModel {
        let conversationID = try manager.dbPool.write { db -> Int64 in
            try ChatConversationQueries.ensureTable(db)
            try ChatMessageQueries.ensureTable(db)
            return try ChatConversationQueries.create(
                db, title: "Task", contextType: "target", contextID: String(target.id)
            ).id
        }
        return TargetChatViewModel(target: target, viewModel: vm, dbManager: manager,
                                   conversationID: conversationID,
                                   aiService: aiService)
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
        XCTAssertTrue(try XCTUnwrap(summaries.first).text.contains("set status to done"))
        // NO extra AI invocation (unlike approve's follow-up turn).
        XCTAssertEqual(mock.prompts.count, 1)
        // The summary is persisted through the same path as other system messages,
        // AFTER the assistant turn — the reloaded transcript keeps run order.
        let persisted = try fetchPersistedMessages(manager, targetID: target.id)
        XCTAssertEqual(persisted.filter { $0.role == "system" && $0.text.contains("Applied:") }.count, 1)
        let assistantIdx = try XCTUnwrap(persisted.firstIndex { $0.role == "assistant" })
        let summaryIdx = try XCTUnwrap(persisted.firstIndex { $0.role == "system" && $0.text.contains("Applied:") })
        XCTAssertLessThan(assistantIdx, summaryIdx)
    }

    /// Two execute-mode actions in one reply where one succeeds and one fails
    /// at apply time (self-link passes validate() but the executor rejects it):
    /// ONE summary system message reports both outcomes, and the successful
    /// write actually landed in the DB.
    func testExecuteMixedSuccessAndFailureReportsBothInOneSummary() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try ensureChatTables(manager)
        let target = try makeTarget(manager, intent: "x")
        let vm = TargetsViewModel(dbManager: manager)
        let reply = """
        Doing both.
        ```watchtower-action
        { "type": "add_sub_item", "text": "draft reply", "mode": "execute", "reason": "owner instructed" }
        ```
        ```watchtower-action
        { "type": "link_target", "target_id": \(target.id), "relation": "blocks", "mode": "execute", "reason": "owner instructed" }
        ```
        """
        let mock = MockClaudeService(events: [.sessionID("s1"), .text(reply), .done])
        let chat = TargetChatViewModel(target: target, viewModel: vm, dbManager: manager,
                                       aiService: mock)

        chat.inputText = "add the step and link it"
        chat.send()
        try await waitForStreamEnd(chat)

        // The successful action landed in the DB.
        let after = try XCTUnwrap(fetchTargetRow(manager, id: target.id))
        XCTAssertTrue(after.decodedSubItems.contains { $0.text == "draft reply" })
        // One card applied, one failed.
        XCTAssertEqual(chat.actionCards.count, 2)
        XCTAssertEqual(chat.actionCards[0].state, .applied("added sub-item \"draft reply\""))
        if case .failed = chat.actionCards[1].state {} else {
            XCTFail("expected .failed, got \(String(describing: chat.actionCards[1].state))")
        }
        // A single summary message carries BOTH the applied and the failed part.
        let summaries = chat.messages.filter {
            $0.role == .system && ($0.text.contains("Applied:") || $0.text.contains("Failed:"))
        }
        XCTAssertEqual(summaries.count, 1)
        let summary = try XCTUnwrap(summaries.first)
        XCTAssertTrue(summary.text.contains("Applied:"))
        XCTAssertTrue(summary.text.contains("added sub-item"))
        XCTAssertTrue(summary.text.contains("Failed:"))
        XCTAssertTrue(summary.text.contains("link_target"))
    }

    /// A stream failure that is NOT a user cancellation must land in the
    /// persisted transcript (spec §7) — a reloaded conversation shows the run
    /// died instead of silently ending after the owner's message.
    func testStreamFailurePersistsFailureIntoTranscript() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try ensureChatTables(manager)
        let target = try makeTarget(manager, intent: "x")
        let vm = TargetsViewModel(dbManager: manager)
        let mock = MockClaudeService(error: StubStreamError())
        let chat = TargetChatViewModel(target: target, viewModel: vm, dbManager: manager,
                                       aiService: mock)

        chat.inputText = "do the thing"
        chat.send()
        try await waitForStreamEnd(chat)

        XCTAssertEqual(chat.errorMessage, "CLI exploded")
        XCTAssertTrue(chat.messages.contains {
            $0.role == .system && $0.text.contains("The secretary run failed: CLI exploded")
        })
        let persisted = try fetchPersistedMessages(manager, targetID: target.id)
        XCTAssertTrue(persisted.contains {
            $0.role == "system" && $0.text.contains("The secretary run failed: CLI exploded")
        })
        // No assistant turn is persisted for a failed stream.
        XCTAssertFalse(persisted.contains { $0.role == "assistant" })
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
        try ensureChatTables(manager)
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
        // The warning is persisted AFTER the assistant turn (transcript order).
        let persisted = try fetchPersistedMessages(manager, targetID: target.id)
        let assistantIdx = try XCTUnwrap(persisted.firstIndex { $0.role == "assistant" })
        let warningIdx = try XCTUnwrap(persisted.firstIndex {
            $0.role == "system" && $0.text.contains("Invalid action proposal")
        })
        XCTAssertLessThan(assistantIdx, warningIdx)
    }

    /// The prompt must brief the model on its real toolset: MCP tools over the
    /// local database, nothing else. SQL recipes and the database path sent the
    /// model looking for shell/SQL tools it does not have — it then wasted the
    /// turn asking the user to "approve tool permissions".
    func testSystemPromptBriefsToolsAndBansLiveSources() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try manager.dbPool.write { db in try TestDatabase.insertWorkspace(db) }
        let target = try makeTarget(manager, intent: "x")

        let prompt = TargetChatViewModel.buildSystemPrompt(target: target, dbPool: manager.dbPool)
        XCTAssertTrue(prompt.contains("list_messages"))
        XCTAssertTrue(prompt.contains("list_targets"))
        XCTAssertTrue(prompt.contains("never ask the user to approve tool permissions"))
        XCTAssertTrue(prompt.contains("NO live access to Slack, Jira"))
        XCTAssertFalse(prompt.contains("SELECT "), "SQL recipes imply a SQL tool that does not exist")
        XCTAssertFalse(prompt.contains(manager.dbPool.path), "the database path must stay out of the prompt")
    }

    func testApproveAppliesActionAndAppendsFollowUp() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager, intent: "x")
        let vm = TargetsViewModel(dbManager: manager)
        let chat = try makeChat(target: target, vm: vm, manager: manager,
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
        let chat = try makeChat(target: target, vm: vm, manager: manager,
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
        let chat = try makeChat(target: target, vm: vm, manager: manager,
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
        let chat = try makeChat(target: target, vm: vm, manager: manager,
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

    // MARK: - Approve all

    func testApproveAllAppliesEveryPendingCardInOneFollowUp() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager, intent: "x")
        let vm = TargetsViewModel(dbManager: manager)
        let chat = try makeChat(target: target, vm: vm, manager: manager,
                                aiService: MockClaudeService())

        let msgID = UUID()
        chat.actionCards = [
            TargetActionCard(messageID: msgID,
                             action: ProposedAction(type: .updateStatus, reason: "r", status: "done"),
                             state: .pending),
            TargetActionCard(messageID: msgID,
                             action: ProposedAction(type: .addSubItem, reason: "r", text: "Ping Bob"),
                             state: .pending),
            TargetActionCard(messageID: msgID,
                             action: ProposedAction(type: .updateProgress, reason: "r", progress: 40),
                             state: .pending)
        ]
        XCTAssertEqual(chat.pendingActionCount, 3)

        chat.approveAll()

        XCTAssertTrue(chat.actionCards.allSatisfy {
            if case .applied = $0.state { return true } else { return false }
        }, "every card must end up applied, got \(chat.actionCards.map(\.state))")
        XCTAssertEqual(chat.pendingActionCount, 0)

        let after = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: target.id) })
        XCTAssertEqual(after.status, "done")
        XCTAssertTrue(after.decodedSubItems.contains { $0.text == "Ping Bob" })

        // ONE follow-up turn for the whole batch, not one per card.
        let followUps = chat.messages.filter { $0.role == .system && $0.text.contains("Actions applied") }
        XCTAssertEqual(followUps.count, 1)
        XCTAssertTrue(try XCTUnwrap(followUps.first).text.contains("(3)"))
    }

    /// Sub-items live in one JSON column rewritten wholesale, so a batch must
    /// read the target back between writes — otherwise each card overwrites the
    /// previous one's sub-item and only the last survives.
    func testApproveAllKeepsEverySubItemFromTheBatch() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager, intent: "x")
        let vm = TargetsViewModel(dbManager: manager)
        let chat = try makeChat(target: target, vm: vm, manager: manager,
                                aiService: MockClaudeService())

        let msgID = UUID()
        chat.actionCards = ["Ping Bob", "Ping Ann", "Ping Joe"].map {
            TargetActionCard(messageID: msgID,
                             action: ProposedAction(type: .addSubItem, reason: "r", text: $0),
                             state: .pending)
        }

        chat.approveAll()

        let after = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: target.id) })
        let texts = after.decodedSubItems.map(\.text)
        XCTAssertEqual(texts.count, 3, "every sub-item must survive the batch, got \(texts)")
        for expected in ["Ping Bob", "Ping Ann", "Ping Joe"] {
            XCTAssertTrue(texts.contains(expected), "missing \(expected) in \(texts)")
        }
    }

    func testApproveAllLeavesAlreadyDecidedCardsUntouched() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager, intent: "x")
        let vm = TargetsViewModel(dbManager: manager)
        let chat = try makeChat(target: target, vm: vm, manager: manager,
                                aiService: MockClaudeService())

        let msgID = UUID()
        chat.actionCards = [
            TargetActionCard(messageID: msgID,
                             action: ProposedAction(type: .updateStatus, reason: "r", status: "done"),
                             state: .rejected),
            TargetActionCard(messageID: msgID,
                             action: ProposedAction(type: .addSubItem, reason: "r", text: "Ping Bob"),
                             state: .pending)
        ]

        chat.approveAll()

        XCTAssertEqual(chat.actionCards[0].state, .rejected)
        let after = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: target.id) })
        XCTAssertEqual(after.status, "todo", "a rejected card must not be applied by Approve all")
        XCTAssertTrue(after.decodedSubItems.contains { $0.text == "Ping Bob" })
    }

    func testApproveAllReportsFailuresWithoutClaimingSuccess() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager, intent: "x")
        let vm = TargetsViewModel(dbManager: manager)
        let chat = try makeChat(target: target, vm: vm, manager: manager,
                                aiService: MockClaudeService())

        let msgID = UUID()
        chat.actionCards = [
            TargetActionCard(messageID: msgID,
                             action: ProposedAction(type: .addSubItem, reason: "r", text: "Ping Bob"),
                             state: .pending),
            // missing `status` — cannot be applied
            TargetActionCard(messageID: msgID,
                             action: ProposedAction(type: .updateStatus, reason: "r", status: nil),
                             state: .pending)
        ]

        chat.approveAll()

        if case .applied = chat.actionCards[0].state {} else {
            XCTFail("valid card must still apply, got \(chat.actionCards[0].state)")
        }
        if case .failed = chat.actionCards[1].state {} else {
            XCTFail("invalid card must fail, got \(chat.actionCards[1].state)")
        }
        let followUp = try XCTUnwrap(chat.messages.last { $0.role == .system })
        XCTAssertTrue(followUp.text.contains("Actions applied (1)"))
        XCTAssertTrue(followUp.text.contains("FAILED (1)"))
        XCTAssertTrue(followUp.text.contains("Do NOT assume"))
    }

    /// A big batch's follow-up is rendered in the transcript and sent to the AI
    /// verbatim — it must be a count, not a wall of 39 full item summaries.
    func testApproveAllBigBatchSendsCompactFollowUp() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager, intent: "x")
        let vm = TargetsViewModel(dbManager: manager)
        let chat = try makeChat(target: target, vm: vm, manager: manager,
                                aiService: MockClaudeService())

        let msgID = UUID()
        chat.actionCards = (0..<10).map { i in
            TargetActionCard(messageID: msgID,
                             action: ProposedAction(type: .addSubItem, reason: "r", text: "Ping colleague number \(i)"),
                             state: .pending)
        }

        chat.approveAll()

        let followUp = try XCTUnwrap(chat.messages.last { $0.role == .system })
        XCTAssertTrue(followUp.text.contains("Actions applied (10 of 10)"),
                      "big batch must report a count, got: \(followUp.text)")
        XCTAssertFalse(followUp.text.contains("Ping colleague number"),
                       "big batch must not echo per-item texts, got: \(followUp.text)")
    }

    /// Even when the big batch goes compact, failures stay itemized — the user
    /// and the AI both need to know exactly what did not land.
    func testApproveAllBigBatchStillItemizesFailures() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager, intent: "x")
        let vm = TargetsViewModel(dbManager: manager)
        let chat = try makeChat(target: target, vm: vm, manager: manager,
                                aiService: MockClaudeService())

        let msgID = UUID()
        var cards = (0..<9).map { i in
            TargetActionCard(messageID: msgID,
                             action: ProposedAction(type: .addSubItem, reason: "r", text: "item \(i)"),
                             state: .pending)
        }
        // missing `status` — cannot be applied
        cards.append(TargetActionCard(messageID: msgID,
                                      action: ProposedAction(type: .updateStatus, reason: "r", status: nil),
                                      state: .pending))
        chat.actionCards = cards

        chat.approveAll()

        let followUp = try XCTUnwrap(chat.messages.last { $0.role == .system })
        XCTAssertTrue(followUp.text.contains("Actions applied (9 of 10)"), "got: \(followUp.text)")
        XCTAssertTrue(followUp.text.contains("FAILED (1)"))
        XCTAssertTrue(followUp.text.contains("missing status"))
        XCTAssertTrue(followUp.text.contains("Do NOT assume"))
    }

    // MARK: - Batch summary helpers

    func testBatchBreakdownGroupsByKindInFirstAppearanceOrder() {
        let msgID = UUID()
        let cards = [
            TargetActionCard(messageID: msgID,
                             action: ProposedAction(type: .toggleSubItem, reason: "r", index: 0, match: "a", done: true),
                             state: .pending),
            TargetActionCard(messageID: msgID,
                             action: ProposedAction(type: .editSubItem, reason: "r", text: "b", index: 1, match: "b"),
                             state: .pending),
            TargetActionCard(messageID: msgID,
                             action: ProposedAction(type: .toggleSubItem, reason: "r", index: 2, match: "c", done: true),
                             state: .pending)
        ]
        XCTAssertEqual(cards.batchBreakdown, "2× check off · 1× edit")
    }

    func testBatchStateSummaryShowsOnlyNonZeroStates() {
        let msgID = UUID()
        let action = ProposedAction(type: .addSubItem, reason: "r", text: "x")
        let cards = [
            TargetActionCard(messageID: msgID, action: action, state: .applied("ok")),
            TargetActionCard(messageID: msgID, action: action, state: .applied("ok")),
            TargetActionCard(messageID: msgID, action: action, state: .failed("boom")),
            TargetActionCard(messageID: msgID, action: action, state: .pending)
        ]
        XCTAssertEqual(cards.batchStateSummary, "1 pending · 2 applied · 1 failed")
        // All-pending is the default state of a fresh batch — no summary line.
        let fresh = [TargetActionCard(messageID: msgID, action: action, state: .pending)]
        XCTAssertNil(fresh.batchStateSummary)
    }

    // MARK: - Deciding mid-stream

    /// A decision taken while a turn is streaming used to be impossible (the cards
    /// were disabled) because `sendFollowUp` dropped the message. The write must
    /// apply immediately and its follow-up must reach the assistant once the
    /// running turn ends — never be silently lost.
    func testApproveDuringStreamAppliesNowAndSendsFollowUpAfterTurnEnds() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager, intent: "x")
        let vm = TargetsViewModel(dbManager: manager)
        let mock = MockClaudeService(eventSequence: [
            [.sessionID("s1"), .text("first reply"), .done],
            [.text("second reply"), .done]
        ])
        let chat = try makeChat(target: target, vm: vm, manager: manager,
                                aiService: mock)

        let action = ProposedAction(type: .updateStatus, reason: "r", status: "done")
        let card = TargetActionCard(messageID: UUID(), action: action, state: .pending)
        chat.actionCards = [card]

        chat.inputText = "hello"
        chat.send()
        XCTAssertTrue(chat.isStreaming)

        chat.approve(card)

        // Applied straight away — the DB write does not wait for the turn.
        XCTAssertEqual(chat.actionCards.first?.state, .applied("set status to done"))
        // A nested sync function keeps the read off GRDB's async overload.
        func storedStatus() throws -> String? {
            try manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: target.id) }?.status
        }
        XCTAssertEqual(try storedStatus(), "done")

        try await waitForStreamEnd(chat)

        // The queued follow-up went out as its own turn after the first finished.
        XCTAssertEqual(mock.prompts.count, 2)
        XCTAssertTrue(mock.prompts[1].contains("Action applied"))
    }

    /// Cancelling the turn must not lose a queued decision: it rides along with
    /// the user's next message instead.
    func testFollowUpQueuedDuringCancelledStreamRidesNextUserMessage() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager, intent: "x")
        let vm = TargetsViewModel(dbManager: manager)
        let mock = MockClaudeService(eventSequence: [
            [.sessionID("s1"), .text("first reply"), .done],
            [.text("second reply"), .done]
        ])
        let chat = try makeChat(target: target, vm: vm, manager: manager,
                                aiService: mock)

        let action = ProposedAction(type: .updateStatus, reason: "r", status: "done")
        let card = TargetActionCard(messageID: UUID(), action: action, state: .pending)
        chat.actionCards = [card]

        chat.inputText = "hello"
        chat.send()
        chat.approve(card)
        chat.cancelStream()
        // Cancelling must not auto-start another turn to drain the queue.
        XCTAssertFalse(chat.isStreaming)

        chat.inputText = "what now?"
        chat.send()
        try await waitForStreamEnd(chat)

        // The user's message carries the queued decision with it. (The cancelled
        // turn may or may not have reached the service, so match by content.)
        let sent = try XCTUnwrap(mock.prompts.first { $0.hasSuffix("what now?") })
        XCTAssertTrue(sent.contains("Action applied"), "queued decision must ride the next message")
    }

    func testRejectMarksCardRejected() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager, intent: "x")
        let vm = TargetsViewModel(dbManager: manager)
        let chat = try makeChat(target: target, vm: vm, manager: manager,
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

    // MARK: - Target-activity callback

    /// The host screen re-derives its next-step staleness badge from this hook;
    /// an approved action is target activity even before the follow-up turn runs.
    func testApproveNotifiesTargetActivity() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager, intent: "x")
        let vm = TargetsViewModel(dbManager: manager)
        let chat = try makeChat(target: target, vm: vm, manager: manager,
                                aiService: MockClaudeService())
        var notifications = 0
        chat.onTargetActivity = { notifications += 1 }

        let action = ProposedAction(type: .updateStatus, reason: "done", status: "done")
        let card = TargetActionCard(messageID: UUID(), action: action, state: .pending)
        chat.actionCards = [card]
        chat.approve(card)

        XCTAssertEqual(notifications, 1)
    }

    /// A failed action is activity too — the screen must not keep showing a step
    /// derived from a state the chat has since tried to change.
    func testApproveNotifiesTargetActivityEvenWhenTheActionFails() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager, intent: "x")
        let vm = TargetsViewModel(dbManager: manager)
        let chat = try makeChat(target: target, vm: vm, manager: manager,
                                aiService: MockClaudeService())
        var notifications = 0
        chat.onTargetActivity = { notifications += 1 }

        // No status at all — the executor rejects it.
        let action = ProposedAction(type: .updateStatus, reason: "r", status: nil)
        let card = TargetActionCard(messageID: UUID(), action: action, state: .pending)
        chat.actionCards = [card]
        chat.approve(card)

        if case .failed = chat.actionCards.first?.state {} else {
            XCTFail("expected .failed, got \(String(describing: chat.actionCards.first?.state))")
        }
        XCTAssertEqual(notifications, 1)
    }

    /// Approve-all applies a batch in one pass, so it notifies once, not per card.
    func testApproveAllNotifiesTargetActivityOnce() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager, intent: "x")
        let vm = TargetsViewModel(dbManager: manager)
        let chat = try makeChat(target: target, vm: vm, manager: manager,
                                aiService: MockClaudeService())
        var notifications = 0
        chat.onTargetActivity = { notifications += 1 }

        chat.actionCards = [
            TargetActionCard(messageID: UUID(),
                             action: ProposedAction(type: .addSubItem, reason: "r", text: "one"),
                             state: .pending),
            TargetActionCard(messageID: UUID(),
                             action: ProposedAction(type: .addSubItem, reason: "r", text: "two"),
                             state: .pending)
        ]
        chat.approveAll()

        XCTAssertEqual(notifications, 1)
    }

    /// A plain chat turn mutates nothing, but it is still work on the target —
    /// the badge is derived from conversation activity, so the hook must fire.
    func testFinishedTurnNotifiesTargetActivity() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager, intent: "x")
        let vm = TargetsViewModel(dbManager: manager)
        let mock = MockClaudeService(eventSequence: [[.sessionID("s1"), .text("reply"), .done]])
        let chat = try makeChat(target: target, vm: vm, manager: manager,
                                aiService: mock)
        var notifications = 0
        chat.onTargetActivity = { notifications += 1 }

        chat.inputText = "what now?"
        chat.send()
        try await waitForStreamEnd(chat)

        XCTAssertEqual(notifications, 1)
    }

    // MARK: - target_id addressing (act on the task's tree, not just the task)

    private func makeChild(
        _ manager: DatabaseManager, parent: Target, text: String = "child task"
    ) throws -> Target {
        let id = try manager.dbPool.write { db in
            try TargetQueries.create(db, text: text,
                                     periodStart: parent.periodStart, periodEnd: parent.periodEnd,
                                     parentId: parent.id)
        }
        return try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: id) })
    }

    func testApproveAppliesAddressedActionToChild() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager, intent: "x")
        let child = try makeChild(manager, parent: target)
        let vm = TargetsViewModel(dbManager: manager)
        let chat = try makeChat(target: target, vm: vm, manager: manager)

        let action = ProposedAction(type: .addSubItem, reason: "fill checklist",
                                    text: "step 1", targetId: child.id)
        let card = TargetActionCard(messageID: UUID(), action: action, state: .pending)
        chat.actionCards = [card]
        chat.approve(card)

        let childAfter = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: child.id) })
        XCTAssertTrue(childAfter.decodedSubItems.contains { $0.text == "step 1" })
        let currentAfter = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: target.id) })
        XCTAssertTrue(currentAfter.decodedSubItems.isEmpty)
        // The applied summary (echoed into the follow-up) names the addressed task.
        guard case .applied(let summary) = chat.actionCards.first?.state else {
            return XCTFail("expected .applied, got \(String(describing: chat.actionCards.first?.state))")
        }
        XCTAssertTrue(summary.contains("#\(child.id)"), "summary should name the addressed task: \(summary)")
    }

    func testApproveAppliesAddressedActionToAncestor() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let root = try makeTarget(manager, intent: "x")
        let current = try makeChild(manager, parent: root)
        let vm = TargetsViewModel(dbManager: manager)
        let chat = try makeChat(target: current, vm: vm, manager: manager)

        let action = ProposedAction(type: .updateStatus, reason: "parent done",
                                    status: "done", targetId: root.id)
        let card = TargetActionCard(messageID: UUID(), action: action, state: .pending)
        chat.actionCards = [card]
        chat.approve(card)

        let rootAfter = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: root.id) })
        XCTAssertEqual(rootAfter.status, "done")
    }

    func testApproveRejectsSiblingAddress() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let root = try makeTarget(manager, intent: "x")
        let current = try makeChild(manager, parent: root)
        let sibling = try makeChild(manager, parent: root, text: "sibling task")
        let vm = TargetsViewModel(dbManager: manager)
        let chat = try makeChat(target: current, vm: vm, manager: manager)

        let action = ProposedAction(type: .addSubItem, reason: "sneak",
                                    text: "nope", targetId: sibling.id)
        let card = TargetActionCard(messageID: UUID(), action: action, state: .pending)
        chat.actionCards = [card]
        chat.approve(card)

        if case .failed = chat.actionCards.first?.state {} else {
            XCTFail("expected .failed, got \(String(describing: chat.actionCards.first?.state))")
        }
        let siblingAfter = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: sibling.id) })
        XCTAssertTrue(siblingAfter.decodedSubItems.isEmpty)
        XCTAssertTrue(chat.messages.contains { $0.role == .system && $0.text.contains("Action FAILED") })
    }

    func testApproveRejectsUnknownAddress() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager, intent: "x")
        let vm = TargetsViewModel(dbManager: manager)
        let chat = try makeChat(target: target, vm: vm, manager: manager)

        let action = ProposedAction(type: .updateStatus, reason: "ghost",
                                    status: "done", targetId: 9999)
        let card = TargetActionCard(messageID: UUID(), action: action, state: .pending)
        chat.actionCards = [card]
        chat.approve(card)

        if case .failed = chat.actionCards.first?.state {} else {
            XCTFail("expected .failed, got \(String(describing: chat.actionCards.first?.state))")
        }
    }

    func testCreateChildUnderAddressedChildMakesGrandchild() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager, intent: "x")
        let child = try makeChild(manager, parent: target)
        let vm = TargetsViewModel(dbManager: manager)
        let chat = try makeChat(target: target, vm: vm, manager: manager)

        let action = ProposedAction(type: .createChildTarget, reason: "deeper",
                                    text: "grandchild", targetId: child.id)
        let card = TargetActionCard(messageID: UUID(), action: action, state: .pending)
        chat.actionCards = [card]
        chat.approve(card)

        let grandchildren = try manager.dbPool.read { db in
            try Target.fetchAll(db, sql: "SELECT * FROM targets WHERE parent_id = ?", arguments: [child.id])
        }
        XCTAssertEqual(grandchildren.count, 1)
        XCTAssertEqual(grandchildren.first?.text, "grandchild")
    }

    func testApproveAllAppliesAddressedBatchAcrossChildren() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager, intent: "x")
        let childA = try makeChild(manager, parent: target, text: "child A")
        let childB = try makeChild(manager, parent: target, text: "child B")
        let vm = TargetsViewModel(dbManager: manager)
        let chat = try makeChat(target: target, vm: vm, manager: manager)

        let msgID = UUID()
        chat.actionCards = [
            TargetActionCard(messageID: msgID,
                             action: ProposedAction(type: .addSubItem, reason: "r",
                                                    text: "A step", targetId: childA.id),
                             state: .pending),
            TargetActionCard(messageID: msgID,
                             action: ProposedAction(type: .addSubItem, reason: "r",
                                                    text: "B step", targetId: childB.id),
                             state: .pending)
        ]
        chat.approveAll()

        let aAfter = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: childA.id) })
        let bAfter = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: childB.id) })
        XCTAssertTrue(aAfter.decodedSubItems.contains { $0.text == "A step" })
        XCTAssertTrue(bAfter.decodedSubItems.contains { $0.text == "B step" })
    }

    func testSystemPromptIncludesTaskTreeAndAddressingContract() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try manager.dbPool.write { db in try TestDatabase.insertWorkspace(db) }
        let root = try makeTarget(manager, intent: "big goal")
        let current = try makeChild(manager, parent: root, text: "current task")
        let child = try makeChild(manager, parent: current, text: "leaf task")
        let vm = TargetsViewModel(dbManager: manager)
        vm.addSubItem(child, text: "leaf item")

        let prompt = TargetChatViewModel.buildSystemPrompt(target: current, dbPool: manager.dbPool)
        XCTAssertTrue(prompt.contains("=== TASK TREE ==="))
        XCTAssertTrue(prompt.contains("#\(root.id)"))
        XCTAssertTrue(prompt.contains("#\(child.id)"))
        XCTAssertTrue(prompt.contains("leaf item"))
        XCTAssertTrue(prompt.contains("target_id"))
    }

    func testSystemPromptOmitsTaskTreeForLoneTask() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try manager.dbPool.write { db in try TestDatabase.insertWorkspace(db) }
        let target = try makeTarget(manager, intent: "x")

        let prompt = TargetChatViewModel.buildSystemPrompt(target: target, dbPool: manager.dbPool)
        XCTAssertFalse(prompt.contains("=== TASK TREE ==="))

    // MARK: - Persona skills (assistant surface)

    /// Writes the given skill files into a fresh temp dir and returns the dir.
    private func makeSkillsDir(_ files: [String: String]) throws -> String {
        let dir = NSTemporaryDirectory() + "skills_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (name, content) in files {
            try Data(content.utf8).write(to: URL(fileURLWithPath: dir + "/" + name))
        }
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        return dir
    }

    func testSkillsBlockListsAssistantSkillsOnly() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager, intent: "ship it")
        let dir = try makeSkillsDir([
            "target-breakdown.md": """
                ---
                description: Decompose a target into sub-targets.
                persona: assistant
                ---
                Body.
                """,
            "thread-untangle.md": """
                ---
                description: Reconstruct who asked what in a tangled thread.
                persona: secretary
                ---
                Body.
                """
        ])

        let prompt = TargetChatViewModel.buildSystemPrompt(
            target: target, dbPool: manager.dbPool, skillsDir: dir)

        XCTAssertTrue(prompt.contains("=== AVAILABLE SKILLS ==="))
        XCTAssertTrue(prompt.contains("target-breakdown — Decompose a target into sub-targets."))
        XCTAssertTrue(prompt.contains("load_skill"))
        XCTAssertFalse(prompt.contains("thread-untangle"), "secretary skills must not reach the assistant")
    }

    func testSkillsBlockAbsentWhenNoSkillsExist() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager, intent: "ship it")
        let empty = try makeSkillsDir([:])

        let withEmptyDir = TargetChatViewModel.buildSystemPrompt(
            target: target, dbPool: manager.dbPool, skillsDir: empty)
        let withNoDir = TargetChatViewModel.buildSystemPrompt(
            target: target, dbPool: manager.dbPool, skillsDir: nil)

        XCTAssertFalse(withEmptyDir.contains("AVAILABLE SKILLS"))
        XCTAssertEqual(withEmptyDir, withNoDir, "no skills must leave the prompt byte-identical")
    }
}
