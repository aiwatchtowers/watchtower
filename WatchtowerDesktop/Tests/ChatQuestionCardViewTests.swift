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

    /// VoiceOver reads an option's label as shown, not its markup.
    func testAnOptionsAccessibilityLabelIsItsPlainText() throws {
        let card = ChatQuestionCard(questions: [ChatQuestion(id: "q", question: "Keep?", options: [
            ChatQuestionOption(label: "**Yes**, see [the RFC](https://example.com/rfc)")
        ])])
        let view = ChatQuestionCardView(card: card, answerText: nil) { _ in }
        let button = try view.inspect().find(button: "Yes, see the RFC")
        XCTAssertEqual(try button.accessibilityLabel().string(), "Yes, see the RFC")
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

    func testAnOwnerAskCardWritesItsPicksToTheDraftAndHasNoSend() throws {
        var stored: [String: ChatQuestionAnswer.Entry] = [:]
        let picks = Binding(get: { stored }, set: { stored = $0 })
        let view = ChatQuestionCardView(card: card, answerText: nil, onAnswer: nil, draftPicks: picks)
        XCTAssertThrowsError(try view.inspect().find(button: "Send answers"), "the ask's answer bar sends")
        try view.inspect().find(button: "v0.10").tap()
        XCTAssertEqual(stored, ["scope": .init(labels: ["v0.10"])])
    }

    func testAClosedOwnerAskCardTakesNoInput() throws {
        let picks = Binding.constant(["scope": ChatQuestionAnswer.Entry(labels: ["v0.11"])])
        let view = ChatQuestionCardView(card: card, answerText: nil, onAnswer: nil, draftPicks: picks, editable: false)
        XCTAssertTrue(try view.inspect().find(button: "v0.10").isDisabled())
        XCTAssertThrowsError(try view.inspect().find(ViewType.TextField.self), "no Other field to type into")
    }

    func testTheRowRendersTheCardInsteadOfTheBlock() throws {
        let json = #"{"questions": [{"question": "Which release?", "options": [{"label": "v0.11"}, {"label": "v0.10"}]}]}"#
        let body = AssistantMessageBody(text: "Two readings.\n```watchtower-question\n\(json)\n```",
                                        steps: [], isRunning: false)
        XCTAssertNoThrow(try body.inspect().find(ChatQuestionCardView.self))
        XCTAssertThrowsError(try body.inspect().find(text: json), "the JSON is not shown as text")
    }
}
