import XCTest
import SwiftUI
import GRDB
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class ChatMessageRowTests: XCTestCase {
    private func item(role: String, status: String, errorCode: String? = nil, siblings: Int = 1) throws -> ChatThreadItem {
        let db = try TestDatabase.create()
        let message = try db.write { d -> ChatMessageRecord in
            let conv = try TestDatabase.insertChatConversation(d)
            let id = try TestDatabase.insertChatMessage(d, conversationID: conv, role: role, text: "body", status: status)
            try d.execute(sql: "UPDATE chat_messages SET error_code = ? WHERE id = ?", arguments: [errorCode, id])
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
}
