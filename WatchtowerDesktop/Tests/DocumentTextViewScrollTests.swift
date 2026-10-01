import XCTest
import AppKit
@testable import WatchtowerDesktop
import WatchtowerCore

/// #179: commenting must keep the text where the owner scrolled it.
@MainActor
final class DocumentTextViewScrollTests: XCTestCase {
    private let markdown = (1...200).map { index in
        "Paragraph \(index) about the retry budget, the rollout plan, the error budget, "
            + "the on-call rotation and everything else a long document wraps over several lines."
    }
    .joined(separator: "\n\n")

    private func makeView(_ doc: RenderedDocument) -> (NSScrollView, NSTextView, DocumentTextView.Coordinator) {
        let parent = DocumentTextView(text: NSAttributedString(), contentID: "",
                                      selection: .constant(DocumentSelectionCarry.none)) { _ in }
        let coordinator = parent.makeCoordinator()
        let scroll = DocumentTextView.makeScrollView(horizontalInset: 16)
        scroll.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let textView = scroll.documentView as! NSTextView // swiftlint:disable:this force_cast
        textView.delegate = coordinator
        coordinator.apply(attributed(doc), contentID: "a", to: textView)
        coordinator.observeGeometry(of: scroll)
        if let container = textView.textContainer { textView.layoutManager?.ensureLayout(for: container) }
        return (scroll, textView, coordinator)
    }

    private func attributed(_ doc: RenderedDocument, highlight: NSRange? = nil) -> NSAttributedString {
        DocumentAttributedString.make(doc, highlights: highlight.map { [1: $0] } ?? [:], activeThreadID: 1)
    }

    private func scrollTop(_ scroll: NSScrollView) -> CGFloat { scroll.contentView.bounds.minY }

    private func scrolled(_ scroll: NSScrollView, to y: CGFloat) {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func testTheViewIsTextKit1FromTheStart() throws {
        let textView = try XCTUnwrap(DocumentTextView.makeScrollView(horizontalInset: 16).documentView as? NSTextView)
        XCTAssertNil(textView.textLayoutManager, "a mid-session TextKit 2 → 1 switch re-lays the text out under the owner")
    }

    func testAHighlightChangeKeepsTheScrollPosition() {
        let doc = DocumentRendering.render(markdown)
        let (scroll, textView, coordinator) = makeView(doc)
        scrolled(scroll, to: 2000)
        let range = (doc.text as NSString).range(of: "Paragraph 120 about")
        coordinator.apply(attributed(doc, highlight: range), contentID: "a", to: textView)
        XCTAssertEqual(scrollTop(scroll), 2000, accuracy: 1)
    }

    func testSelectingTextKeepsTheScrollPosition() {
        let doc = DocumentRendering.render(markdown)
        let (scroll, textView, _) = makeView(doc)
        scrolled(scroll, to: 2000)
        textView.setSelectedRange((doc.text as NSString).range(of: "Paragraph 120 about"))
        _ = DocumentTextView.Coordinator.visibleSelectionRect(textView)
        XCTAssertEqual(scrollTop(scroll), 2000, accuracy: 1)
    }

    func testARerenderOfTheSameTextKeepsThePositionAndNewTextStartsAtTheTop() {
        let doc = DocumentRendering.render(markdown)
        let (scroll, textView, coordinator) = makeView(doc)
        scrolled(scroll, to: 2000)
        coordinator.apply(attributed(doc), contentID: "b", to: textView)
        XCTAssertEqual(scrollTop(scroll), 2000, accuracy: 1, "an unchanged file re-read under a new render id stays put")
        coordinator.apply(attributed(DocumentRendering.render("Another document.")), contentID: "c", to: textView)
        XCTAssertEqual(scrollTop(scroll), 0, accuracy: 1)
    }

    /// AppKit's own behaviour, pinned because the comment list opening
    /// beside the text depends on it.
    func testANarrowerViewKeepsTheTopLineInView() throws {
        let doc = DocumentRendering.render(markdown)
        let (scroll, textView, _) = makeView(doc)
        let layout = try XCTUnwrap(textView.layoutManager)
        let target = (doc.text as NSString).range(of: "Paragraph 120 about")
        let lineTop = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: target.location), effectiveRange: nil)
            .minY + textView.textContainerOrigin.y
        scrolled(scroll, to: lineTop)
        XCTAssertEqual(ReadingAnchor.top(of: textView)?.character, target.location)

        scroll.frame.size.width = 240 // the comments panel opens beside the text
        let restored = expectation(description: "restored after the resize's layout")
        DispatchQueue.main.async { restored.fulfill() }
        wait(for: [restored], timeout: 2)
        let after = ReadingAnchor.top(of: textView)
        let paragraph = (doc.text as NSString).paragraphRange(for: target)
        XCTAssertTrue(after.map { NSLocationInRange($0.character, paragraph) } ?? false,
                      "top character \(String(describing: after)) left paragraph \(paragraph)")
        XCTAssertGreaterThan(scrollTop(scroll), lineTop, "re-wrapped text puts the same line further down")
    }

    func testANewInsetKeepsTheTopLineInView() throws {
        let doc = DocumentRendering.render(markdown)
        let (scroll, textView, _) = makeView(doc)
        let layout = try XCTUnwrap(textView.layoutManager)
        let target = (doc.text as NSString).range(of: "Paragraph 120 about")
        let lineTop = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: target.location), effectiveRange: nil)
            .minY + textView.textContainerOrigin.y
        scrolled(scroll, to: lineTop)
        DocumentTextView.setInset(120, on: textView) // a wider pane centres a readable column
        XCTAssertEqual(ReadingAnchor.top(of: textView)?.character, target.location)
        XCTAssertGreaterThan(scrollTop(scroll), lineTop)
    }
}
