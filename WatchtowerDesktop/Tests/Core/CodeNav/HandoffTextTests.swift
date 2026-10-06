import XCTest
@testable import WatchtowerCore

/// What "Hand to Claude Code" types into a session (spec 2026-10-02 §9.5):
/// one header line, the question(s), the answer text and `path:line`
/// references — never a file body.
final class HandoffTextTests: XCTestCase {
    private var nextID: Int64 = 0

    private func message(_ role: String, _ text: String, status: String = "complete") -> ChatMessageRecord {
        nextID += 1
        return ChatMessageRecord(id: nextID, conversationID: 1, role: role, text: text,
                                 createdAt: Double(nextID), status: status)
    }

    private let selection = CodeQuestionOrigin(
        path: "Sources/App.swift", line: 12,
        selection: CodeQuestionSelection(startLine: 12, endLine: 14, text: "let secretBody = load()\nrun()\nexit()")
    )

    func testConversationCarriesHeaderQuestionAnswerAndReferences() throws {
        let text = try XCTUnwrap(HandoffText.conversation(origin: selection, messages: [
            message("user", "Explain what this code does."),
            message("assistant", "It loads the config, see `Sources/Config.swift:40` and cmd/run.go:3:7.")
        ]))
        XCTAssertEqual(text, """
            From a Watchtower code question:
            Asked at Sources/App.swift:12-14

            Question: Explain what this code does.

            Answer:
            It loads the config, see `Sources/Config.swift:40` and cmd/run.go:3:7.

            References: Sources/App.swift:12-14, Sources/Config.swift:40, cmd/run.go:3:7
            """)
    }

    /// The selection's source is never appended; a fenced block the answer
    /// itself holds stays as the answer's text.
    func testNeverAppendsTheSelectedSourceButKeepsTheAnswersFence() throws {
        let answer = "Rewrite it:\n```swift\nlet value = load()\n```"
        let text = try XCTUnwrap(HandoffText.conversation(origin: selection, messages: [
            message("user", "Suggest a change to this code."),
            message("assistant", answer)
        ]))
        XCTAssertFalse(text.contains("secretBody"), "the selected code is not handed over")
        XCTAssertTrue(text.contains(answer))
        XCTAssertTrue(text.hasPrefix("From a Watchtower code question:\n"))
    }

    func testFollowUpsAreInOrderAndNoticesStreamingAndFailedRepliesAreLeftOut() throws {
        let text = try XCTUnwrap(HandoffText.conversation(origin: selection, messages: [
            message("user", "Why?"),
            message("system", "This model cannot read other files."),
            message("assistant", "Because."),
            message("user", "And then?"),
            message("assistant", "Half an answ", status: "partial")
        ]))
        XCTAssertEqual(text, """
            From a Watchtower code question:
            Asked at Sources/App.swift:12-14

            Question: Why?

            Answer:
            Because.

            Question: And then?
            """)
        let failed = try XCTUnwrap(HandoffText.conversation(origin: selection, messages: [
            message("user", "Why?"),
            message("assistant", "boom", status: "error")
        ]))
        XCTAssertFalse(failed.contains("boom"))
    }

    func testNoQuestionYetIsNothingToHand() {
        XCTAssertNil(HandoffText.conversation(origin: selection, messages: []))
        XCTAssertNil(HandoffText.conversation(origin: selection, messages: [message("system", "notice")]))
    }

    func testCitationsInsideFencedCodeAreNoReferences() throws {
        let text = try XCTUnwrap(HandoffText.conversation(
            origin: CodeQuestionOrigin(path: "a.go", line: 3, selection: nil),
            messages: [message("user", "q"), message("assistant", "```\nx.swift:3\n```\nsee a.go:3")]
        ))
        XCTAssertTrue(text.hasSuffix("References: a.go:3"), text)
    }

    /// A markdown link to a workbench path cites the path it opens, not
    /// its text; a link to anything else cites nothing.
    func testALinkCitesTheFileItOpensNotItsText() throws {
        let answer = "See [the plan](docs/plan.md) and `a.go:3`, [file.go:42](internal/x/file.go#L42), [site](https://example.com), [web](www.example.com)."
        let text = try XCTUnwrap(HandoffText.conversation(
            origin: CodeQuestionOrigin(path: "", line: 0, selection: nil),
            messages: [message("user", "q"), message("assistant", answer)]
        ))
        XCTAssertTrue(text.hasSuffix("References: docs/plan.md:1, a.go:3, internal/x/file.go:42"), text)
    }

    func testQuestionWithNoFileOpen() throws {
        let text = try XCTUnwrap(HandoffText.conversation(
            origin: CodeQuestionOrigin(path: "", line: 0, selection: nil),
            messages: [message("user", "Where is the config read?")]
        ))
        XCTAssertEqual(text, """
            From a Watchtower code question:
            Asked with no file open

            Question: Where is the config read?
            """)
    }

    func testOpenQuicklyQueryCarriesTheOpenFilesLine() {
        XCTAssertEqual(HandoffText.query("  why save  ", origin: CodeQuestionOrigin(path: "src/save.swift", line: 7, selection: nil)), """
            From a Watchtower code question:
            Asked at src/save.swift:7

            Question: why save
            """)
        XCTAssertNil(HandoffText.query("  ", origin: CodeQuestionOrigin(path: "", line: 0, selection: nil)))
    }

    /// Ruling R54(c): over 32 KB the earliest turns go, said in one line;
    /// the latest turn stays.
    func testALongConversationDropsItsEarliestTurns() throws {
        let long = String(repeating: "a", count: 12 * 1024)
        var messages: [ChatMessageRecord] = []
        for index in 1...4 {
            messages.append(message("user", "Question \(index)?"))
            messages.append(message("assistant", "Answer \(index) " + long))
        }
        let text = try XCTUnwrap(HandoffText.conversation(origin: selection, messages: messages))
        XCTAssertLessThanOrEqual(text.utf8.count, HandoffText.maxBytes)
        XCTAssertTrue(text.hasPrefix(HandoffText.header + "\nAsked at Sources/App.swift:12-14\n\n… earlier turns omitted\n\n"))
        XCTAssertFalse(text.contains("Question 1?"))
        XCTAssertFalse(text.contains("Question 2?"))
        XCTAssertTrue(text.contains("Question 3?") && text.contains("Question 4?"))
        let short = try XCTUnwrap(HandoffText.conversation(origin: selection, messages: Array(messages.suffix(2))))
        XCTAssertFalse(short.contains(HandoffText.omittedLine))
    }

    func testASingleTurnOverTheCapIsCut() throws {
        let huge = String(repeating: "é", count: 40 * 1024)
        let text = try XCTUnwrap(HandoffText.conversation(origin: selection, messages: [
            message("user", "Why?"), message("assistant", huge)
        ]))
        XCTAssertLessThanOrEqual(text.utf8.count, HandoffText.maxBytes)
        XCTAssertTrue(text.hasSuffix(HandoffText.cutLine))
        XCTAssertTrue(text.contains("Question: Why?"))
        let query = try XCTUnwrap(HandoffText.query(huge, origin: selection))
        XCTAssertLessThanOrEqual(query.utf8.count, HandoffText.maxBytes)
    }

    // MARK: - Delivery

    /// Line breaks survive the paste (a hand-off is several lines); every
    /// other control, ESC included, is dropped so the paste cannot end early.
    func testPayloadKeepsLineBreaksAndDropsEscapes() {
        let payload = WorkbenchCommentPrompt.terminalPayload("a\r\nb\u{1B}[201~c\td", bracketedPaste: true, keepingLineBreaks: true)
        let start: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]
        let end: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
        XCTAssertEqual(payload, .paste(start + Array("a\nb[201~c\td".utf8) + end))
        XCTAssertEqual(WorkbenchCommentPrompt.terminalPayload("a\nb", bracketedPaste: false, keepingLineBreaks: true),
                       .clipboard("a\nb"))
        XCTAssertEqual(WorkbenchCommentPrompt.terminalPayload("a\nb", bracketedPaste: false), .clipboard("ab"),
                       "Send comments still sends one line")
    }
}
