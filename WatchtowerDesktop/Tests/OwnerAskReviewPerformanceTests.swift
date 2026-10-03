import XCTest
import AppKit
import SwiftUI
@testable import WatchtowerDesktop
import WatchtowerCore

/// A review ask's document at the 2 MiB snapshot bound (spec 2026-10-03
/// Part 3).
@MainActor
final class OwnerAskReviewPerformanceTests: XCTestCase {
    /// About 2 MiB of Markdown: headings, paragraphs, lists, code, tables.
    static func syntheticSnapshot() -> String {
        var sections: [String] = []
        var size = 0
        var index = 0
        while size < 2 * 1024 * 1024 {
            index += 1
            let section = """
                ## Section \(index)

                Paragraph \(index): keep the retry budget small and the rollout slow, then widen it once the canary holds.

                - item one of \(index)
                - item two of \(index)

                ```
                let value\(index) = \(index)
                ```

                | Name | Owner |
                |---|---|
                | row \(index) | ops |

                """
            sections.append(section)
            size += section.utf8.count
        }
        return sections.joined(separator: "\n")
    }

    /// Adding or removing a margin comment on the largest snapshot only
    /// redraws: the attributed text is the same instance (keyed on the
    /// snapshot and typography alone), the text storage is not edited,
    /// nothing more is laid out, and a passage past the laid-out text gets
    /// no box rather than forcing seconds of layout on the main actor.
    func testACommentOnA2MiBSnapshotNeitherResetsNorLaysOutTheText() throws {
        let doc = DocumentRendering.render(Self.syntheticSnapshot())
        let text = DocumentAttributedString.make(doc, highlights: [:], activeThreadID: nil, typography: ReviewTypography.style)
        XCTAssertGreaterThan(text.length, 1_500_000)
        let view = DocumentTextView(text: text, contentID: "owner-ask/1", selection: .constant(DocumentSelectionCarry.none)) { _ in }
        let coordinator = view.makeCoordinator()
        let scroll = DocumentTextView.makeScrollView(horizontalInset: 20)
        scroll.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let textView = try XCTUnwrap(scroll.documentView as? NSTextView)
        let layout = try XCTUnwrap(textView.layoutManager)
        XCTAssertTrue(coordinator.apply(text, contentID: "owner-ask/1", to: textView))
        // The first screen, as drawing it would.
        layout.ensureLayout(forCharacterRange: NSRange(location: 0, length: 4000))
        let laidOut = layout.firstUnlaidCharacterIndex()

        var edits = 0
        let observer = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: textView.textStorage, queue: nil
        ) { _ in edits += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        let near = (doc.text as NSString).range(of: "Paragraph 2:")
        let deep = NSRange(location: text.length - 12, length: 5)
        let start = Date()
        // The body pass after the comment was added.
        let again = DocumentAttributedString.make(doc, highlights: [:], activeThreadID: nil, typography: ReviewTypography.style)
        let replaced = coordinator.apply(again, contentID: "owner-ask/1", to: textView)
        coordinator.applyHighlights([near, deep], to: textView, force: replaced)
        let rects = DocumentTextView.Coordinator.visibleRects(of: [near, deep], in: textView)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(again === text, "comments are not part of the text")
        XCTAssertFalse(replaced)
        XCTAssertEqual(edits, 0, "the text storage was not touched")
        XCTAssertEqual(layout.firstUnlaidCharacterIndex(), laidOut, "nothing more was laid out")
        XCTAssertNotNil(rects[0], "a passage on screen gets its box")
        XCTAssertNil(rects[1], "a passage past the laid-out text waits instead of forcing layout")
        XCTAssertNotNil(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: deep.location, effectiveRange: nil))
        XCTAssertLessThan(elapsed, 0.5, "measured \(elapsed) s; a forced layout of this text takes seconds")

        coordinator.applyHighlights([near], to: textView, force: false)
        XCTAssertNil(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: deep.location, effectiveRange: nil),
                     "a removed comment loses its highlight")
        XCTAssertNotNil(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: near.location, effectiveRange: nil))
        XCTAssertEqual(edits, 0)
    }

    /// The artifact panel keeps its highlights in the attributed text.
    func testHighlightRangesDefaultToNone() {
        let view = DocumentTextView(text: NSAttributedString(string: "x"), contentID: "a", selection: .constant(DocumentSelectionCarry.none)) { _ in }
        XCTAssertTrue(view.highlightRanges.isEmpty)
    }
}
