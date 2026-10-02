import XCTest
@testable import WatchtowerCore

final class ChatQuestionCardTests: XCTestCase {
    private func block(_ json: String) -> String {
        "```watchtower-question\n\(json)\n```"
    }

    private let validJSON = """
    {"questions": [
      {"id": "scope", "question": "Which release?", "options": [
        {"label": "v0.11", "description": "Being cut now", "recommended": true},
        {"label": "v0.10", "description": "Last shipped"}]},
      {"question": "Who reads it?", "multi": true, "options": [
        {"label": "Support"}, {"label": "Sales"}, {"label": "Execs"}]}
    ]}
    """

    func testAValidBlockBecomesACardAndLeavesTheText() throws {
        let parsed = ChatQuestionParser.parse("Two readings here.\n" + block(validJSON), final: true)
        XCTAssertEqual(parsed.text, "Two readings here.")
        let card = try XCTUnwrap(parsed.card)
        XCTAssertEqual(card.questions.map(\.id), ["scope", "2"], "a missing id is the position")
        XCTAssertEqual(card.questions[0].options.map(\.label), ["v0.11", "v0.10"])
        XCTAssertTrue(card.questions[0].options[0].recommended)
        XCTAssertFalse(card.questions[0].multi)
        XCTAssertTrue(card.questions[1].multi)
    }

    func testOutOfBoundsOrMalformedBlocksStayPlainText() {
        let cases = [
            "{not json",
            #"{"questions": []}"#,
            #"{"questions": [{"question": "Q", "options": [{"label": "only one"}]}]}"#,
            #"{"questions": [{"question": "Q", "options": [{"label": "a"}, {"label": "b"}, {"label": "c"}, {"label": "d"}, {"label": "e"}]}]}"#,
            #"{"questions": [{"question": "", "options": [{"label": "a"}, {"label": "b"}]}]}"#,
            #"{"questions": [{"question": "Q", "options": [{"label": " "}, {"label": "b"}]}]}"#,
            #"{"questions": [1, 2, 3, 4, 5]}"#
        ]
        for json in cases {
            let reply = "Hmm.\n" + block(json)
            let parsed = ChatQuestionParser.parse(reply, final: true)
            XCTAssertNil(parsed.card, json)
            XCTAssertEqual(parsed.text, reply, "falls back to plain text: \(json)")
        }
    }

    func testTheLastValidBlockWins() throws {
        let first = #"{"questions": [{"question": "First?", "options": [{"label": "a"}, {"label": "b"}]}]}"#
        let second = #"{"questions": [{"question": "Second?", "options": [{"label": "c"}, {"label": "d"}]}]}"#
        let parsed = ChatQuestionParser.parse(block(first) + "\nand\n" + block(second), final: true)
        XCTAssertEqual(try XCTUnwrap(parsed.card).questions.first?.question, "Second?")
        XCTAssertEqual(parsed.text, "and")
    }

    func testAnOpenBlockIsHiddenWhileStreamingAndShownWhenFinal() {
        let partial = "Let me ask.\n```watchtower-question\n{\"questions\": [{\"quest"
        XCTAssertEqual(ChatQuestionParser.parse(partial, final: false).text, "Let me ask.")
        XCTAssertNil(ChatQuestionParser.parse(partial, final: false).card)
        XCTAssertEqual(ChatQuestionParser.parse(partial, final: true).text, partial)
    }

    func testAFenceInsideALineIsNotABlock() {
        let reply = "Use ```watchtower-question blocks like this."
        XCTAssertEqual(ChatQuestionParser.parse(reply, final: true).text, reply)
    }

    func testAnEmptyBlockIsNotACard() {
        let reply = "```watchtower-question\n```"
        let parsed = ChatQuestionParser.parse(reply, final: true)
        XCTAssertNil(parsed.card)
        XCTAssertEqual(parsed.text, reply)
    }

    func testAnswersRoundTrip() throws {
        let card = try XCTUnwrap(ChatQuestionParser.parse(block(validJSON), final: true).card)
        let answers: [String: ChatQuestionAnswer.Entry] = [
            "scope": .init(labels: ["v0.11"]),
            "2": .init(labels: ["Support", "Execs"], other: "the board")
        ]
        let text = ChatQuestionAnswer.format(card, answers: answers)
        XCTAssertEqual(text, """
        Answers:
        - Which release? → v0.11
        - Who reads it? → Support, Execs, Other: the board
        """)
        XCTAssertEqual(ChatQuestionAnswer.selections(in: text, for: card), answers)
    }

    func testAHandTypedReplyHasNoSelections() throws {
        let card = try XCTUnwrap(ChatQuestionParser.parse(block(validJSON), final: true).card)
        XCTAssertTrue(ChatQuestionAnswer.selections(in: "the current one, for support", for: card).isEmpty)
    }
}
