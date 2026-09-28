import XCTest
@testable import WatchtowerCore

final class ChatCommandTests: XCTestCase {
    func testTurnLineIsOneLineOfSortedJSON() throws {
        let command = ChatCommand.turn(ChatTurnCommand(
            turnID: "t1", text: "line1\nline2",
            attachments: [ChatCommandAttachment(path: "/a/x.png", mime: "image/png", name: "x.png")],
            replay: false))
        let line = try command.jsonLine()
        XCTAssertFalse(line.contains("\n"), "a newline in the text is escaped, never breaks the JSONL frame")
        XCTAssertEqual(line, #"{"attachments":[{"mime":"image/png","name":"x.png","path":"/a/x.png"}],"#
                       + #""replay":false,"text":"line1\nline2","turn_id":"t1","type":"turn"}"#)
    }

    /// Wire shape: no attachments is `[]`, never `null` (review-rules wire rule).
    func testEmptyAttachmentsEncodeAsEmptyArray() throws {
        let line = try ChatCommand.turn(ChatTurnCommand(turnID: "t", text: "x", attachments: [], replay: true)).jsonLine()
        XCTAssertTrue(line.contains(#""attachments":[]"#))
        XCTAssertTrue(line.contains(#""replay":true"#))
    }

    func testControlCommands() throws {
        XCTAssertEqual(try ChatCommand.cancel.jsonLine(), #"{"type":"cancel"}"#)
        XCTAssertEqual(try ChatCommand.close.jsonLine(), #"{"type":"close"}"#)
    }

    func testContinuity() {
        XCTAssertNil(ChatContinuity.initialLeaf(resumeSessionID: nil, activeLeafID: 5))
        XCTAssertNil(ChatContinuity.initialLeaf(resumeSessionID: "", activeLeafID: 5))
        XCTAssertEqual(ChatContinuity.initialLeaf(resumeSessionID: "s", activeLeafID: 5), 5)
        XCTAssertFalse(ChatContinuity.replayNeeded(historyTipID: nil, continuousLeafID: nil), "a brand-new chat")
        XCTAssertFalse(ChatContinuity.replayNeeded(historyTipID: 5, continuousLeafID: 5))
        XCTAssertTrue(ChatContinuity.replayNeeded(historyTipID: 3, continuousLeafID: 5), "regenerate/edit/branch")
        XCTAssertTrue(ChatContinuity.replayNeeded(historyTipID: 5, continuousLeafID: nil), "history the session never saw")
    }

    /// Preflight ruling 12 (A31): the REFERENCED block is part of the stored
    /// user text (Task 25's composer); only the ACTIONS block is prefixed at
    /// send time.
    func testTurnTextComposition() {
        XCTAssertEqual(ChatTurnText.compose(userText: "hi", outcomes: nil), "hi")
        XCTAssertEqual(ChatTurnText.compose(userText: "hi", outcomes: ""), "hi")
        XCTAssertEqual(ChatTurnText.compose(userText: "hi", outcomes: "=== ACTIONS ==="), "=== ACTIONS ===\n\nhi")
    }
}
