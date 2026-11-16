import XCTest
@testable import WatchtowerChatText

/// `internal/chat/testdata/question_parse_cases.json` is read by the Go twin
/// (`chat.ParseQuestionCard`) too: one fixture, pinned from both sides.
final class QuestionParseFixtureTests: XCTestCase {
    private struct Case: Decodable {
        struct Option: Decodable { let label: String; let description: String; let recommended: Bool }
        struct Question: Decodable { let id: String; let question: String; let multi: Bool; let options: [Option] }
        struct Card: Decodable { let questions: [Question] }
        let name: String
        let text: String
        let final: Bool
        let rest: String
        let card: Card?
        let readable: String
    }

    private static func cases() throws -> [Case] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // WatchtowerChatTextTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerChatText
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/chat/testdata/question_parse_cases.json")
        return try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
    }

    private static func card(_ raw: Case.Card?) -> ChatQuestionCard? {
        raw.map { card in
            ChatQuestionCard(questions: card.questions.map { question in
                ChatQuestion(id: question.id, question: question.question, multi: question.multi,
                             options: question.options.map {
                                 ChatQuestionOption(label: $0.label, description: $0.description, recommended: $0.recommended)
                             })
            })
        }
    }

    func testSharedQuestionParseCases() throws {
        let cases = try Self.cases()
        XCTAssertGreaterThanOrEqual(cases.count, 20)
        for tc in cases {
            let parsed = ChatQuestionParser.parse(tc.text, final: tc.final)
            XCTAssertEqual(parsed.text, tc.rest, tc.name)
            XCTAssertEqual(parsed.card, Self.card(tc.card), tc.name)
            XCTAssertEqual(ChatQuestionParser.readableText(tc.text), tc.readable, tc.name)
        }
    }
}
