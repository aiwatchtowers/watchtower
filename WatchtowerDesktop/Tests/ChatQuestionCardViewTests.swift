import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore

@MainActor
final class ChatQuestionCardViewTests: XCTestCase {
    private let card = ChatQuestionCard(questions: [
        ChatQuestion(id: "scope", question: "Which release?", options: [
            ChatQuestionOption(label: "v0.11", description: "Being cut now", recommended: true),
            ChatQuestionOption(label: "v0.10", description: "Last shipped")
        ])
    ])

    func testAnOpenCardShowsOptionsAndTheRecommendedMark() throws {
        let view = ChatQuestionCardView(card: card, answerText: nil) { _ in }
        XCTAssertNoThrow(try view.inspect().find(text: "Which release?"))
        XCTAssertNoThrow(try view.inspect().find(text: "Being cut now"))
        XCTAssertNoThrow(try view.inspect().find(text: "Recommended"))
        XCTAssertTrue(try view.inspect().find(button: "Send answers").isDisabled(), "nothing picked yet")
    }

    func testAnAnsweredCardTakesNoInput() throws {
        let answer = ChatQuestionAnswer.format(card, answers: ["scope": .init(labels: ["v0.10"])])
        let view = ChatQuestionCardView(card: card, answerText: answer) { _ in }
        XCTAssertNoThrow(try view.inspect().find(text: "Answered"))
        XCTAssertThrowsError(try view.inspect().find(button: "Send answers"))
    }

    func testACardThatCannotBeAnsweredHasNoSend() throws {
        let view = ChatQuestionCardView(card: card, answerText: nil, onAnswer: nil)
        XCTAssertThrowsError(try view.inspect().find(button: "Send answers"))
    }

    func testTheRowRendersTheCardInsteadOfTheBlock() throws {
        let json = #"{"questions": [{"question": "Which release?", "options": [{"label": "v0.11"}, {"label": "v0.10"}]}]}"#
        let body = AssistantMessageBody(text: "Two readings.\n```watchtower-question\n\(json)\n```",
                                        steps: [], isRunning: false)
        XCTAssertNoThrow(try body.inspect().find(ChatQuestionCardView.self))
        XCTAssertThrowsError(try body.inspect().find(text: json), "the JSON is not shown as text")
    }
}
