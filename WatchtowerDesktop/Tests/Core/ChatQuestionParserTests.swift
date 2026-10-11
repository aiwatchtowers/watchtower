import XCTest
@testable import WatchtowerCore

/// The two decode paths of `ChatQuestionParser` (spec 2026-10-10 Part 3.5):
/// an owner ask raised from chat may hold a question with no options; a chat
/// card never does.
final class ChatQuestionParserTests: XCTestCase {
    private static func zeroOptionsFixture() throws -> Data {
        try Data(contentsOf: OwnerAskFixtures.directory("cards").appendingPathComponent("owner_ask_zero_options.json"))
    }

    /// E18a: the same JSON the owner-ask decode accepts is no chat card,
    /// fenced in a reply or not.
    func testZeroOptionCardIsRefused() throws {
        let data = try Self.zeroOptionsFixture()
        XCTAssertNil(ChatQuestionParser.decodeCard(data))
        XCTAssertNotNil(ChatQuestionParser.decodeOwnerAskQuestions(data))

        let body = try XCTUnwrap(String(bytes: data, encoding: .utf8))
        let reply = "Which host?\n\(ChatQuestionParser.fence)\n\(body)\n```"
        let parsed = ChatQuestionParser.parse(reply, final: true)
        XCTAssertNil(parsed.card)
        XCTAssertEqual(parsed.text, reply, "the block stays in the text")
    }

    /// The owner-ask path keeps every other bound of the card.
    func testTheOwnerAskPathAllowsNoOptionsAndNothingElseNew() {
        func questions(_ options: String, multi: Bool = false) -> Data {
            Data(#"{"questions":[{"id":"1","question":"Q?","multi":\#(multi),"options":[\#(options)]}]}"#.utf8)
        }
        XCTAssertNotNil(ChatQuestionParser.decodeOwnerAskQuestions(questions("")))
        XCTAssertNotNil(ChatQuestionParser.decodeOwnerAskQuestions(questions(#"{"label":"A"},{"label":"B"}"#)))
        XCTAssertNil(ChatQuestionParser.decodeOwnerAskQuestions(questions(#"{"label":"A"}"#)), "one option")
        XCTAssertNil(ChatQuestionParser.decodeOwnerAskQuestions(
            questions(#"{"label":"A"},{"label":"B"},{"label":"C"},{"label":"D"},{"label":"E"}"#)), "five options")
        XCTAssertNil(ChatQuestionParser.decodeOwnerAskQuestions(questions(#"{"label":"A"},{"label":"A"}"#)), "duplicate labels")
        XCTAssertNil(ChatQuestionParser.decodeOwnerAskQuestions(Data(#"{"questions":[]}"#.utf8)), "no questions")
        XCTAssertNil(ChatQuestionParser.decodeCard(questions("")), "the chat card path still refuses no options")
    }
}
