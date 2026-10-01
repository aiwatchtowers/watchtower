import AppKit
import SwiftUI
import XCTest
@testable import WatchtowerDesktop

/// W12: a selection is offsets into one text. It survives a re-style of the
/// same content but never a content identity change, or doc A's offsets would
/// select — and anchor a comment to — text in doc B the owner never chose.
@MainActor
final class DocumentTextViewTests: XCTestCase {
    func testCarriedOnlyForTheSameContentAndInBounds() {
        let sel = NSRange(location: 3, length: 4)
        XCTAssertEqual(DocumentSelectionCarry.carried(sel, sameContent: true, newLength: 20), sel)
        XCTAssertEqual(DocumentSelectionCarry.carried(sel, sameContent: false, newLength: 20), DocumentSelectionCarry.none)
        XCTAssertEqual(DocumentSelectionCarry.carried(sel, sameContent: true, newLength: 5), DocumentSelectionCarry.none)
    }

    private func makeCoordinator(_ selection: Binding<NSRange>) -> (DocumentTextView.Coordinator, NSTextView) {
        let view = DocumentTextView(text: NSAttributedString(string: ""), contentID: "", selection: selection) { _ in }
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        textView.isEditable = false
        let coordinator = view.makeCoordinator()
        textView.delegate = coordinator
        return (coordinator, textView)
    }

    func testSwitchingContentClearsTheSelectionInTheViewAndTheBinding() async {
        var bound = NSRange(location: 0, length: 0)
        let (coordinator, textView) = makeCoordinator(Binding(get: { bound }, set: { bound = $0 }))
        coordinator.apply(NSAttributedString(string: "Doc A: keep the retry budget small"), contentID: "1#1", to: textView)
        textView.setSelectedRange(NSRange(location: 7, length: 4))
        await Task.yield()
        bound = NSRange(location: 7, length: 4)

        coordinator.apply(NSAttributedString(string: "Doc B: write the migration tests"), contentID: "2#1", to: textView)
        XCTAssertEqual(textView.selectedRange().length, 0, "B's text must not inherit A's offsets")
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(bound.length, 0, "the pane's selection is cleared too, so Comment disables")
    }

    func testRestylingTheSameContentKeepsTheSelection() {
        var bound = NSRange(location: 0, length: 0)
        let (coordinator, textView) = makeCoordinator(Binding(get: { bound }, set: { bound = $0 }))
        let text = "Doc A: keep the retry budget small"
        coordinator.apply(NSAttributedString(string: text), contentID: "1#1", to: textView)
        textView.setSelectedRange(NSRange(location: 7, length: 4))

        let highlighted = NSMutableAttributedString(string: text)
        highlighted.addAttribute(.backgroundColor, value: NSColor.yellow, range: NSRange(location: 0, length: 3))
        coordinator.apply(highlighted, contentID: "1#1", to: textView)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 7, length: 4))
    }

    /// #81: a table-of-contents pick scrolls the heading to the top, once per pick.
    func testScrollTargetJumpsToTheOffsetOncePerRequest() throws {
        let view = DocumentTextView(text: NSAttributedString(string: ""), contentID: "",
                                    selection: .constant(NSRange(location: 0, length: 0))) { _ in }
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 300, height: 120)
        let textView = try XCTUnwrap(scroll.documentView as? NSTextView)
        let coordinator = view.makeCoordinator()
        let body = (1...200).map { "Line \($0)" }.joined(separator: "\n") + "\n## Target\n"
        coordinator.apply(NSAttributedString(string: body), contentID: "1#1", to: textView)
        textView.layoutManager?.ensureLayout(for: try XCTUnwrap(textView.textContainer))

        let target = DocumentScrollTarget(offset: (body as NSString).range(of: "## Target").location)
        coordinator.scroll(textView, to: target)
        let jumped = scroll.contentView.bounds.minY
        XCTAssertGreaterThan(jumped, 1000, "the heading near the end is brought into view")

        scroll.contentView.scroll(to: .zero)
        coordinator.scroll(textView, to: target)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, "the same request does not scroll again")
        coordinator.scroll(textView, to: DocumentScrollTarget(offset: target.offset))
        XCTAssertEqual(scroll.contentView.bounds.minY, jumped, accuracy: 1, "a new pick of the same heading does")
    }
}
