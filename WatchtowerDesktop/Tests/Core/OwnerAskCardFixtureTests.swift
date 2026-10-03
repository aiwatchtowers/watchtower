import XCTest
@testable import WatchtowerCore

/// An ask's questions are a chat question card: Go's `asks.Validate` and the
/// Swift `ChatQuestionParser` decoder accept and reject the same
/// `internal/asks/testdata/cards` files.
final class OwnerAskCardFixtureTests: XCTestCase {
    func testTheCardDecoderAgreesWithGoOnEveryFixture() throws {
        let files = try OwnerAskFixtures.files("cards")
        XCTAssertGreaterThanOrEqual(files.count, 10)
        for file in files {
            let card = ChatQuestionParser.decodeCard(file.data)
            if file.name.hasPrefix("valid_") {
                XCTAssertNotNil(card, "\(file.name) is accepted by Go")
            } else {
                XCTAssertTrue(file.name.hasPrefix("invalid_"), file.name)
                XCTAssertNil(card, "\(file.name) is rejected by Go")
            }
        }
    }

    func testAnAcceptedCardIsTrimmedAndKeepsItsIDs() throws {
        let data = try Data(contentsOf: OwnerAskFixtures.directory("cards").appendingPathComponent("valid_unknown_keys_ignored.json"))
        let card = try XCTUnwrap(ChatQuestionParser.decodeCard(data))
        XCTAssertEqual(card.questions.map(\.id), ["tone"])
        XCTAssertEqual(card.questions[0].question, "Which tone?")
        XCTAssertEqual(card.questions[0].options.map(\.label), ["Formal", "Casual"])
    }
}
