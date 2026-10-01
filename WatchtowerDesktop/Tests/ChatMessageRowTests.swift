import XCTest
import SwiftUI
import GRDB
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class ChatMessageRowTests: XCTestCase {
    private func item(
        role: String,
        status: String,
        errorCode: String? = nil,
        errorMessage: String? = nil,
        provider: String? = nil,
        siblings: Int = 1
    ) throws -> ChatThreadItem {
        let db = try TestDatabase.create()
        let message = try db.write { d -> ChatMessageRecord in
            let conv = try TestDatabase.insertChatConversation(d)
            let id = try TestDatabase.insertChatMessage(d, conversationID: conv, role: role, text: "body", status: status)
            try d.execute(sql: "UPDATE chat_messages SET error_code = ?, error_message = ?, provider = ? WHERE id = ?",
                          arguments: [errorCode, errorMessage, provider, id])
            return try XCTUnwrap(ChatMessageRecord.fetchOne(d, sql: "SELECT * FROM chat_messages WHERE id = ?", arguments: [id]))
        }
        return ChatThreadItem(message: message, steps: [], siblingIndex: 1, siblingCount: siblings)
    }

    func testRetryableErrorShowsRetry() throws {
        let row = ChatMessageRow(item: try item(role: "assistant", status: "error", errorCode: "rate_limit"),
                                 isLast: true, isEditing: false, actions: ChatRowActions())
        XCTAssertNoThrow(try row.inspect().find(text: "Retry"))
    }

    func testAuthErrorHasNoRetry() throws {
        let row = ChatMessageRow(item: try item(role: "assistant", status: "error", errorCode: "auth"),
                                 isLast: true, isEditing: false, actions: ChatRowActions())
        XCTAssertThrowsError(try row.inspect().find(text: "Retry"))
        XCTAssertNoThrow(try row.inspect().find(text: ChatErrorPresentation.message(for: "auth")))
    }

    /// The card keeps the session's own reason under the generic phrase —
    /// the one fix ("pick one in Settings → AI") is otherwise never shown.
    func testErrorCardShowsTheSessionMessage() throws {
        let reason = "no Ollama model is configured: pick one in Settings → AI"
        let row = ChatMessageRow(item: try item(role: "assistant", status: "error", errorCode: "provider_unavailable",
                                                errorMessage: reason, provider: "ollama"),
                                 isLast: true, isEditing: false, actions: ChatRowActions())
        XCTAssertNoThrow(try row.inspect().find(text: ChatErrorPresentation.message(for: "provider_unavailable")))
        XCTAssertNoThrow(try row.inspect().find(text: reason))
    }

    func testCodexAuthErrorNeverSaysClaudeLogin() throws {
        let row = ChatMessageRow(item: try item(role: "assistant", status: "error", errorCode: "auth", provider: "codex"),
                                 isLast: true, isEditing: false, actions: ChatRowActions())
        XCTAssertNoThrow(try row.inspect().find(text: ChatErrorPresentation.message(for: "auth", provider: "codex")))
        XCTAssertThrowsError(try row.inspect().find(text: ChatErrorPresentation.message(for: "auth")))
    }

    func testStoppedLastMessageOffersContinue() throws {
        let row = ChatMessageRow(item: try item(role: "assistant", status: "partial"),
                                 isLast: true, isEditing: false, actions: ChatRowActions())
        XCTAssertNoThrow(try row.inspect().find(text: "Stopped"))
        XCTAssertNoThrow(try row.inspect().find(text: "Continue"))
    }

    func testVariantCounterShowsWithSiblings() throws {
        let row = ChatMessageRow(item: try item(role: "assistant", status: "complete", siblings: 3),
                                 isLast: true, isEditing: false, actions: ChatRowActions())
        XCTAssertNoThrow(try row.inspect().find(text: "1/3"))
    }

    /// Render isolation: equality ignores the action closures, so SwiftUI
    /// skips an unchanged row even though its closures are rebuilt per render.
    func testRowEqualityIgnoresClosures() throws {
        let base = try item(role: "assistant", status: "complete")
        let a = ChatMessageRow(item: base, isLast: false, isEditing: false, actions: ChatRowActions())
        // swiftlint:disable:next trailing_closure
        let regenerateAction = ChatRowActions(regenerate: { _ in XCTFail("never invoked by ==") })
        let b = ChatMessageRow(item: base, isLast: false, isEditing: false, actions: regenerateAction)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, ChatMessageRow(item: base, isLast: true, isEditing: false, actions: ChatRowActions()))
    }

    func testAFinishedAnswerOffersQuoteInReplyWithItsText() throws {
        var quoted: (Int64, String)?
        let base = try item(role: "assistant", status: "complete")
        let row = ChatMessageRow(item: base, isLast: true, isEditing: false,
                                 actions: ChatRowActions { quoted = ($0, $1) })
        try row.inspect().find(ViewType.Button.self) { try $0.accessibilityLabel().string() == "Quote in reply" }.tap()
        XCTAssertEqual(quoted?.0, base.id)
        XCTAssertEqual(quoted?.1, "body")
    }

    func testOwnerMessagesHaveNoQuoteButton() throws {
        let row = ChatMessageRow(item: try item(role: "user", status: "complete"),
                                 isLast: true, isEditing: false, actions: ChatRowActions())
        XCTAssertThrowsError(try row.inspect().find(ViewType.Button.self) {
            try $0.accessibilityLabel().string() == "Quote in reply"
        })
    }

    // MARK: - Embedded chats (Copy + Retry only)

    func testEmbeddedRowOffersCopyOnly() throws {
        let actions = ChatRowActions.embedded(copy: { _ in }, retry: nil)
        let reply = ChatMessageRow(item: try item(role: "assistant", status: "complete", siblings: 2),
                                   isLast: true, isEditing: false, actions: actions)
        XCTAssertNoThrow(try reply.inspect().find(ViewType.Button.self) {
            try $0.accessibilityLabel().string() == "Copy message"
        })
        for label in ["Quote in reply", "Regenerate", "Previous version", "Next version"] {
            XCTAssertThrowsError(try reply.inspect().find(ViewType.Button.self) {
                try $0.accessibilityLabel().string() == label
            }, label)
        }
        let owner = ChatMessageRow(item: try item(role: "user", status: "complete"),
                                   isLast: true, isEditing: false, actions: actions)
        XCTAssertThrowsError(try owner.inspect().find(ViewType.Button.self) {
            try $0.accessibilityLabel().string() == "Edit"
        })
    }

    func testEmbeddedErrorRowShowsRetryOnlyWhenGivenOne() throws {
        let failed = try item(role: "assistant", status: "error", errorCode: "rate_limit")
        var retried: Int64?
        let withRetry = ChatMessageRow(item: failed, isLast: true, isEditing: false,
                                       actions: .embedded(copy: { _ in }, retry: { retried = $0 }))
        try withRetry.inspect().find(button: "Retry").tap()
        XCTAssertEqual(retried, failed.id)
        let without = ChatMessageRow(item: failed, isLast: false, isEditing: false,
                                     actions: .embedded(copy: { _ in }, retry: nil))
        XCTAssertThrowsError(try without.inspect().find(text: "Retry"))
    }

    func testEmbeddedStoppedRowHasNoContinue() throws {
        let row = ChatMessageRow(item: try item(role: "assistant", status: "partial"), isLast: true, isEditing: false,
                                 actions: .embedded(copy: { _ in }, retry: nil))
        XCTAssertNoThrow(try row.inspect().find(text: "Stopped"))
        XCTAssertThrowsError(try row.inspect().find(text: "Continue"))
    }
}
