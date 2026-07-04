import XCTest
import GRDB
@testable import WatchtowerDesktop

@MainActor
final class TargetChatViewModelTests: XCTestCase {
    private func makeTarget(_ manager: DatabaseManager, intent: String) throws -> Target {
        let id = try manager.dbPool.write { db in
            try TargetQueries.create(db, text: "ship feature", intent: intent,
                                     periodStart: "2026-06-01", periodEnd: "2026-06-30")
        }
        return try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: id) })
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
    }

    func testDefaultModelMatchesProvider() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager, intent: "x")
        let vm = TargetsViewModel(dbManager: manager)

        let claude = TargetChatViewModel(target: target, viewModel: vm, dbManager: manager,
                                         aiService: MockClaudeService(), provider: .claude)
        XCTAssertEqual(claude.provider, .claude)
        XCTAssertEqual(claude.selectedModel, ChatModel.defaultModel(for: .claude))
        XCTAssertTrue(ChatModel.models(for: .claude).contains(claude.selectedModel))

        let codex = TargetChatViewModel(target: target, viewModel: vm, dbManager: manager,
                                        aiService: MockClaudeService(), provider: .codex)
        XCTAssertEqual(codex.selectedModel, ChatModel.defaultModel(for: .codex))
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
                                       aiService: mock, provider: .claude)

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
