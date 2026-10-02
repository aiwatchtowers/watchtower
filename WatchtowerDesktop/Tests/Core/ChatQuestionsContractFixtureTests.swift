import XCTest
@testable import WatchtowerCore

/// `internal/chat/questions_contract.md` is the Go prompt's question-card
/// contract; the embedded chats append the same text from Swift and the
/// parser must accept the example it teaches (dual path, pinned both ways).
final class ChatQuestionsContractFixtureTests: XCTestCase {
    private static func contract() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/chat/questions_contract.md")
        return try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testTheSwiftPromptBlockIsTheGoContract() throws {
        XCTAssertEqual(ChatQuestionsContract.promptBlock, try Self.contract())
    }

    func testTheTaughtExampleParses() throws {
        let card = try XCTUnwrap(ChatQuestionParser.parse(try Self.contract(), final: true).card)
        XCTAssertEqual(card.questions.map(\.id), ["scope"])
        XCTAssertEqual(card.questions[0].options.map(\.label), ["v0.11", "v0.10"])
        XCTAssertEqual(card.questions[0].options.filter(\.recommended).count, 1)
    }
}
