import XCTest
@testable import WatchtowerCore

/// The earlier turns of a code question, replayed into a turn that resumes
/// no provider session (board #361), worded as the main chat's Go replay.
final class EmbeddedChatReplayTests: XCTestCase {
    private var nextID: Int64 = 0

    private func message(_ role: String, _ text: String, turn: String, status: String = "complete") -> ChatMessageRecord {
        nextID += 1
        return ChatMessageRecord(id: nextID, conversationID: 1, role: role, text: text, createdAt: Double(nextID),
                                 turnID: turn, status: status)
    }

    func testEarlierTurnsAreReplayedWithoutTheCurrentOne() {
        let messages = [
            message("user", "Explain this.", turn: "t1"),
            message("assistant", "It loads the config.", turn: "t1"),
            message("system", "This model cannot read other files.", turn: ""),
            message("user", "And the caller?", turn: "t2"),
            message("assistant", "", turn: "t2", status: "partial")
        ]
        XCTAssertEqual(EmbeddedChatReplay.block(messages: messages, before: "t2"), """
            \(EmbeddedChatReplay.header)
            Owner: Explain this.
            Assistant: It loads the config.
            \(EmbeddedChatReplay.footer)


            """)
    }

    func testTheFirstTurnHasNothingToReplay() {
        let messages = [message("user", "Explain this.", turn: "t1"), message("assistant", "", turn: "t1", status: "partial")]
        XCTAssertNil(EmbeddedChatReplay.block(messages: messages, before: "t1"))
        XCTAssertNil(EmbeddedChatReplay.block(messages: [], before: "t1"))
    }

    /// A failed reply is left out, and so is the question a Retry sends
    /// again; a reply stopped early says so.
    func testFailedRepliesAndTheRetriedQuestionAreLeftOut() throws {
        let messages = [
            message("user", "Explain this.", turn: "t1"),
            message("assistant", "It loads", turn: "t1", status: "partial"),
            message("user", "Why?", turn: "t2"),
            message("assistant", "boom", turn: "t2", status: "error"),
            message("assistant", "", turn: "t3", status: "partial")
        ]
        let block = try XCTUnwrap(EmbeddedChatReplay.block(messages: messages, before: "t3"))
        XCTAssertTrue(block.contains("Assistant (stopped early): It loads\n"), block)
        XCTAssertFalse(block.contains("Why?"), block)
        XCTAssertFalse(block.contains("boom"), block)
    }

    /// Over the cap the oldest messages go and are counted; a newest one
    /// alone over the cap is cut.
    func testTheCapKeepsTheNewestMessages() throws {
        let messages = [
            message("user", String(repeating: "a", count: 30), turn: "t1"),
            message("assistant", String(repeating: "b", count: 30), turn: "t1"),
            message("user", "c", turn: "t2"),
            message("assistant", "d", turn: "t2")
        ]
        let block = try XCTUnwrap(EmbeddedChatReplay.block(messages: messages, before: "t3", capCharacters: 50))
        XCTAssertTrue(block.contains("[2 earlier messages omitted]\nOwner: c\nAssistant: d\n"), block)
        let long = try XCTUnwrap(EmbeddedChatReplay.block(
            messages: [message("user", "q", turn: "t1"), message("assistant", String(repeating: "x", count: 100), turn: "t1")],
            before: "t2", capCharacters: 20))
        XCTAssertTrue(long.contains("[1 earlier messages omitted]\nAssistant: xxxxxxxx"), long)
        XCTAssertFalse(long.contains(String(repeating: "x", count: 20)), long)
    }
}
