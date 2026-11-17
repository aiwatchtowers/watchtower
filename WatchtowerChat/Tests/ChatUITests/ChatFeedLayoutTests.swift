import ChatWire
import WatchtowerChatText
import XCTest
@testable import ChatUI

/// Which reply's question card can be answered, and what answered it — over the feed's messages, oldest first (moved
/// from the Mac's `ChatQuestionThread` when every chat came onto ChatUI, unified chat T12).
final class ChatFeedLayoutTests: XCTestCase {
    private func message(_ id: Int64, _ role: String, _ text: String = "x") -> ChatFeed.Message {
        ChatFeed.Message(id: id, role: role, text: text, createdAt: Date(timeIntervalSince1970: Double(id)))
    }

    func testAnswerableOnlyOnTheLatestUnansweredReply() {
        let rows = [message(1, "user"), message(2, "assistant"), message(3, "system")]
        XCTAssertTrue(ChatFeedLayout.isAnswerable(2, in: rows, isTurnRunning: false), "a notice after it does not count")
        XCTAssertFalse(ChatFeedLayout.isAnswerable(2, in: rows, isTurnRunning: true))
        let answered = rows + [message(4, "user", "Answers:")]
        XCTAssertFalse(ChatFeedLayout.isAnswerable(2, in: answered, isTurnRunning: false))
        XCTAssertEqual(ChatFeedLayout.ownerReply(after: 2, in: answered), "Answers:")
        let later = answered + [message(5, "assistant")]
        XCTAssertFalse(ChatFeedLayout.isAnswerable(2, in: later, isTurnRunning: false), "an older reply")
        XCTAssertTrue(ChatFeedLayout.isAnswerable(5, in: later, isTurnRunning: false))
        XCTAssertFalse(ChatFeedLayout.isAnswerable(99, in: later, isTurnRunning: false), "an unknown message")
        XCTAssertNil(ChatFeedLayout.ownerReply(after: 99, in: later))
        XCTAssertNil(ChatFeedLayout.ownerReply(after: 1, in: later), "an owner message is answered by nothing")
    }

    /// VoiceOver reads an option's label without markup; the phone adds its "Recommended" mark (review n2).
    func testAnOptionsAccessibilityLabelNamesTheRecommendedMarkOnThePhone() {
        let option = ChatQuestionOption(label: "**Server** table", recommended: true)
        XCTAssertEqual(QuestionPartView.accessibilityLabel(option, includesRecommended: true), "Server table, Recommended")
        XCTAssertEqual(QuestionPartView.accessibilityLabel(option, includesRecommended: false), "Server table")
        XCTAssertEqual(QuestionPartView.accessibilityLabel(ChatQuestionOption(label: "Cookie"), includesRecommended: true),
                       "Cookie")
    }
}
