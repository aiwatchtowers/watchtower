import XCTest
import SwiftUI
import GRDB
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class TargetChatViewTests: XCTestCase {
    func testActionCardViewDescribesAction() throws {
        let action = ProposedAction(type: .updateStatus, reason: "all merged", status: "done")
        let card = TargetActionCard(messageID: UUID(), action: action, state: .pending)
        // Card description is the single source of truth for the card body.
        XCTAssertTrue(card.action.cardDescription.contains("done"))
        XCTAssertTrue(card.action.cardDescription.contains("all merged"))
        // View constructs without crashing.
        _ = TargetActionCardView(card: card, currentTargetID: 1, onApprove: { _ in }, onReject: {})
    }

    /// An action addressing another task in the tree surfaces that address on
    /// the card; an un-addressed action (and link_target's endpoint id) do not.
    func testActionCardViewFlagsAddressedTarget() throws {
        let addressed = ProposedAction(type: .addSubItem, reason: "fill", text: "x", targetId: 41)
        let own = ProposedAction(type: .addSubItem, reason: "fill", text: "x")
        let link = ProposedAction(type: .linkTarget, reason: "dep", targetId: 41, relation: "blocks")

        func makeView(_ a: ProposedAction) -> TargetActionCardView {
            TargetActionCardView(card: TargetActionCard(messageID: UUID(), action: a, state: .pending),
                                 currentTargetID: 39, onApprove: { _ in }, onReject: {})
        }
        XCTAssertEqual(makeView(addressed).addressedTargetID, 41)
        XCTAssertNil(makeView(own).addressedTargetID)
        XCTAssertNil(makeView(link).addressedTargetID)
        // Addressing the chat's own task explicitly is not "another task".
        let selfAddressed = ProposedAction(type: .addSubItem, reason: "fill", text: "x", targetId: 39)
        XCTAssertNil(makeView(selfAddressed).addressedTargetID)
    }

    /// The section is now the tab bar plus the active tab's pane; both must
    /// construct from a real container.
    func testChatSectionConstructsFromAnAssistantContainer() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let id = try manager.dbPool.write { db in
            try TargetQueries.create(db, text: "ship feature", intent: "x",
                                     periodStart: "2026-06-01", periodEnd: "2026-06-30")
        }
        let target = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: id) })
        let targets = TargetsViewModel(dbManager: manager)
        let assistant = TargetAssistantViewModel(
            target: target, viewModel: targets, dbManager: manager
        ) { conversationID in
            TargetChatViewModel(target: target, viewModel: targets, dbManager: manager,
                                conversationID: conversationID,
                                aiService: MockClaudeService())
        }

        XCTAssertEqual(assistant.conversations.count, 1)
        _ = TargetChatSection(assistant: assistant)
        _ = TargetChatPane(chatVM: try XCTUnwrap(assistant.activeChat))
    }

    // MARK: - Proposals under a reply

    private func chatWithReply(cards count: Int) throws -> (TargetChatViewModel, ChatThreadItem, () -> Void) {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        let id = try manager.dbPool.write { db in
            try TargetQueries.create(db, text: "ship feature", intent: "x",
                                     periodStart: "2026-06-01", periodEnd: "2026-06-30")
        }
        let target = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: id) })
        let conv = try manager.dbPool.write { db in
            try ChatConversationQueries.create(db, title: "Task", contextType: "target", contextID: String(id)).id
        }
        let replyID = try manager.dbPool.write { db in
            try ChatMessageQueries.insert(db, conversationID: conv, role: "assistant", text: "(proposed)", turnID: "t1")
        }
        let chat = TargetChatViewModel(target: target, viewModel: TargetsViewModel(dbManager: manager),
                                       dbManager: manager, conversationID: conv, aiService: MockClaudeService())
        chat.actionCards = (0..<count).map { index in
            TargetActionCard(messageID: UUID(chatRowID: replyID),
                             action: ProposedAction(type: .addSubItem, reason: "r", text: "step \(index)"),
                             state: .pending)
        }
        let item = try XCTUnwrap(chat.engine.messages.first { $0.id == replyID })
        return (chat, item, {
            chat.stop()
            TestDatabase.cleanup(path: path)
        })
    }

    func testTwoPendingCardsUnderAReplyOfferApproveAll() throws {
        let (chat, item, cleanup) = try chatWithReply(cards: 2)
        defer { cleanup() }
        let view = TargetChatProposals(chatVM: chat, item: item)
        XCTAssertNoThrow(try view.inspect().find(text: "2 proposals"))
        try view.inspect().find(ViewType.Button.self) { try $0.accessibilityIdentifier() == "chat.approveAll" }.tap()
        XCTAssertEqual(chat.pendingActionCount, 0, "Approve all applied the reply's batch")
    }

    func testABigBatchCollapsesIntoOneBlock() throws {
        let (chat, item, cleanup) = try chatWithReply(cards: 5)
        defer { cleanup() }
        let view = TargetChatProposals(chatVM: chat, item: item)
        XCTAssertNoThrow(try view.inspect().find(text: "5 proposed changes"))
        XCTAssertNoThrow(try view.inspect().find(ViewType.Button.self) {
            try $0.accessibilityIdentifier() == "chat.batchReview"
        })
    }

    func testOneCardHasNoApproveAll() throws {
        let (chat, item, cleanup) = try chatWithReply(cards: 1)
        defer { cleanup() }
        XCTAssertThrowsError(try TargetChatProposals(chatVM: chat, item: item).inspect().find(ViewType.Button.self) {
            try $0.accessibilityIdentifier() == "chat.approveAll"
        })
    }

    /// Registry proposals of a turn render under its reply only, never a
    /// second time under the owner's row of the same turn.
    func testRegistryProposalsRenderOnceUnderTheReply() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let id = try manager.dbPool.write { db in
            try TargetQueries.create(db, text: "ship feature", intent: "x",
                                     periodStart: "2026-06-01", periodEnd: "2026-06-30")
        }
        let target = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: id) })
        let conv = try manager.dbPool.write { db in
            try ChatConversationQueries.create(db, title: "Task", contextType: "target", contextID: String(id)).id
        }
        try manager.dbPool.write { db in
            _ = try ChatMessageQueries.beginEmbeddedTurn(db, conversationID: conv, ownerText: "file it", turnID: "t9",
                                                         provider: nil, now: Date().timeIntervalSince1970)
        }
        try TestDatabase.insertAgentActionSync(manager.dbPool, conversationID: conv, turnID: "t9")
        let chat = TargetChatViewModel(target: target, viewModel: TargetsViewModel(dbManager: manager),
                                       dbManager: manager, conversationID: conv, aiService: MockClaudeService())
        defer { chat.stop() }
        chat.actionFeed.refresh()
        let owner = try XCTUnwrap(chat.engine.messages.first { $0.message.isUser })
        let reply = try XCTUnwrap(chat.engine.messages.first { $0.message.isAssistant })
        XCTAssertEqual(try TargetChatProposals(chatVM: chat, item: owner).inspect().findAll(AgentActionCardView.self).count, 0)
        XCTAssertEqual(try TargetChatProposals(chatVM: chat, item: reply).inspect().findAll(AgentActionCardView.self).count, 1)
    }
}
