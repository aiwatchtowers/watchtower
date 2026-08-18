import XCTest
import SwiftUI
import GRDB
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
        _ = TargetActionCardView(card: card, onApprove: { _ in }, onReject: {})
    }

    /// The section is now the tab bar plus the active tab's pane; both must
    /// construct from a real container.
    func testChatSectionConstructsFromAnAssistantContainer() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try manager.dbPool.write { db in
            try ChatConversationQueries.ensureTable(db)
            try ChatMessageQueries.ensureTable(db)
        }
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
                                aiService: MockClaudeService(), provider: .claude)
        }

        XCTAssertEqual(assistant.conversations.count, 1)
        _ = TargetChatSection(assistant: assistant)
        _ = TargetChatPane(chatVM: try XCTUnwrap(assistant.activeChat))
    }
}
