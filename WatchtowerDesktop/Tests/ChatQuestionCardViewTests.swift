import AppKit
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

    /// ⌘↩ in the Other field sends a complete card, as Send answers does.
    /// Hosted: the picks are the card's own state, kept only in a window.
    func testCommandReturnInOtherSendsACompleteCard() throws {
        let card = ChatQuestionCard(questions: [ChatQuestion(id: "q", question: "Which?", options: [ChatQuestionOption(label: "A")])])
        var sent: [String] = []
        let host = NSHostingView(rootView: ChatQuestionCardView(card: card, answerText: nil) { sent.append($0) }.frame(width: 320))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        spin()
        let field = try XCTUnwrap(textView(in: host))
        XCTAssertTrue(window.makeFirstResponder(field))

        XCTAssertFalse(field.performKeyEquivalent(with: try commandReturn(window)), "an empty card does not send")
        field.insertText("Neither", replacementRange: field.selectedRange())
        spin()
        XCTAssertTrue(field.performKeyEquivalent(with: try commandReturn(window)))

        XCTAssertEqual(sent, [ChatQuestionAnswer.format(card, answers: ["q": .init(other: "Neither")])])
    }

    private func spin() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private func textView(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        return view.subviews.lazy.compactMap { self.textView(in: $0) }.first
    }

    private func commandReturn(_ window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                       context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false,
                                       keyCode: CommentEditorKeys.returnKeyCode))
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
