import AppKit
import ChatUI
import ChatWire
import WatchtowerChatText
import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore

/// The question card every Mac surface draws since unified chat T12: ChatUI's `QuestionPartView` in the Mac's kit
/// style — in a chat reply (embedded chats, the main chat) and on an owner ask in the drawer (its draft mode).
@MainActor
final class ChatQuestionPartMacTests: XCTestCase {
    private let card = ChatQuestionCard(questions: [
        ChatQuestion(id: "scope", question: "Which release?", options: [
            ChatQuestionOption(label: "v0.11", description: "Being cut now", recommended: true),
            ChatQuestionOption(label: "v0.10", description: "Last shipped")
        ])
    ])

    func testAnOpenCardShowsOptionsAndTheRecommendedMark() throws {
        let view = chatCard(card, answerText: nil) { _ in }
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
        let view = chatCard(card, answerText: nil) { _ in }
        let button = try view.inspect().find(button: "Yes, see the RFC")
        let label = try button.labelView().find(ViewType.Text.self) { (try? $0.attributedString()) != nil }
        XCTAssertEqual(String(try label.attributedString().characters), "Yes, see the RFC",
                       "the label renders without its markup")
    }

    /// ⌘↩ in the Other field sends a complete card, as Send answers does.
    /// Hosted: the picks are the card's own state, kept only in a window.
    func testCommandReturnInOtherSendsACompleteCard() throws {
        let card = ChatQuestionCard(questions: [ChatQuestion(id: "q", question: "Which?", options: [ChatQuestionOption(label: "A")])])
        var sent: [String] = []
        let host = NSHostingView(rootView: chatCard(card, answerText: nil) { sent.append($0) }.frame(width: 320))
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

    private func chatCard(
        _ card: ChatQuestionCard, answerText: String?, onAnswer: ((String) -> Void)?
    ) -> some View {
        QuestionPartView(card: card, answerText: answerText, onAnswer: onAnswer)
            .environment(\.chatUIStyle, DesignKitChatStyle())
    }

    private func askCard(
        _ card: ChatQuestionCard, picks: Binding<[String: ChatQuestionAnswer.Entry]>, editable: Bool = true
    ) -> some View {
        QuestionPartView(card: card, draft: OwnerAskDrawer.questionDraft(
            picks: picks, editable: editable, onKey: nil, fieldFocus: nil, stop: nil, onLeaveField: nil))
            .environment(\.chatUIStyle, DesignKitChatStyle())
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
        let view = chatCard(card, answerText: answer) { _ in }
        XCTAssertNoThrow(try view.inspect().find(text: "Answered"))
        XCTAssertThrowsError(try view.inspect().find(button: "Send answers"))
    }

    func testACardThatCannotBeAnsweredHasNoSend() throws {
        let view = chatCard(card, answerText: nil, onAnswer: nil)
        XCTAssertThrowsError(try view.inspect().find(button: "Send answers"))
    }

    func testAnOwnerAskCardWritesItsPicksToTheDraftAndHasNoSend() throws {
        var stored: [String: ChatQuestionAnswer.Entry] = [:]
        let picks = Binding(get: { stored }, set: { stored = $0 })
        let view = askCard(card, picks: picks)
        XCTAssertThrowsError(try view.inspect().find(button: "Send answers"), "the ask's answer bar sends")
        try view.inspect().find(button: "v0.10").tap()
        XCTAssertEqual(stored, ["scope": .init(labels: ["v0.10"])])
    }

    func testAClosedOwnerAskCardTakesNoInput() throws {
        let picks = Binding.constant(["scope": ChatQuestionAnswer.Entry(labels: ["v0.11"])])
        let view = askCard(card, picks: picks, editable: false)
        XCTAssertTrue(try view.inspect().find(button: "v0.10").isDisabled())
        XCTAssertThrowsError(try view.inspect().find(ViewType.TextField.self), "no Other field to type into")
        XCTAssertThrowsError(try view.inspect().find(CommentTextEditor.self), "no Other field to type into")
    }

    /// A reply's question block is ChatUI's card, not its JSON (the shared parser, D14).
    func testTheRowRendersTheCardInsteadOfTheBlock() throws {
        let json = #"{"questions": [{"question": "Which release?", "options": [{"label": "v0.11"}, {"label": "v0.10"}]}]}"#
        let message = ChatFeed.Message(id: 1, role: "assistant", text: "Two readings.\n```watchtower-question\n\(json)\n```",
                                       createdAt: .distantPast)
        let row = ChatUI.ChatMessageRow(message: message, parts: ChatMessageParts.parts(for: message),
                                        context: ChatPartContext(message: message), rowActions: ChatRowActions(),
                                        isTurnRunning: false)
        XCTAssertNoThrow(try row.inspect().find(QuestionPartView.self))
        XCTAssertThrowsError(try row.inspect().find(text: json), "the JSON is not shown as text")
    }

    /// The drawer's card writes the same picks into the ask's draft as before, so the answer it sends is the same
    /// text: an option tap and an Other answer of its own.
    func testOwnerAskDrawerQuestionCardAnswers() throws {
        let card = ChatQuestionCard(questions: [
            ChatQuestion(id: "scope", question: "Which release?", options: [
                ChatQuestionOption(label: "v0.11"), ChatQuestionOption(label: "v0.10")
            ]),
            ChatQuestion(id: "why", question: "Why?", options: [ChatQuestionOption(label: "Speed")])
        ])
        var stored: [String: ChatQuestionAnswer.Entry] = [:]
        let picks = Binding(get: { stored }, set: { stored = $0 })
        try askCard(card, picks: picks).inspect().find(button: "v0.10").tap()
        let editors = try askCard(card, picks: picks).inspect().findAll(CommentTextEditor.self)
        XCTAssertEqual(editors.count, 2, "each question has the drawer's Other editor")
        let other = try editors[1].actualView()
        other.text = "Less risk"

        XCTAssertEqual(stored, ["scope": .init(labels: ["v0.10"]), "why": .init(other: "Less risk")])
        let answer = ChatQuestionAnswer.format(card, answers: stored)
        XCTAssertTrue(answer.contains("v0.10") && answer.contains("Less risk"), answer)
    }
}
