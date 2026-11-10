import AppKit
import XCTest
@testable import WatchtowerDesktop

/// #1073: `FeedScrollerInset` puts a stale `scrollerInsets.right` (left by
/// an inspector column's close animation) back to the feed's trailing safe
/// area. The animation itself is not reproduced here — a planted stale value
/// is, on a plain scroll view in a window that is never ordered in.
@MainActor
final class ChatFeedScrollerInsetTests: XCTestCase {
    /// Counts the writes to its scroller insets.
    private final class CountingScrollView: NSScrollView {
        var insetWrites = 0
        override var scrollerInsets: NSEdgeInsets {
            didSet { insetWrites += 1 }
        }
    }

    private let stale = NSEdgeInsets(top: 5, left: 3, bottom: 7, right: 420)
    private var window: NSWindow?

    override func tearDown() {
        window?.close()
        window = nil
        super.tearDown()
    }

    /// A scroll view with a vertical scroller, the inset view in its
    /// document view, both in an off-screen window; the scroller insets
    /// planted stale after the view's own first write.
    private func makeFeed(trailing: CGFloat) -> (CountingScrollView, FeedScrollerInset.InsetView) {
        let scrollView = CountingScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scrollView.hasVerticalScroller = true
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 2000))
        scrollView.documentView = document
        let inset = FeedScrollerInset.InsetView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        inset.trailing = trailing
        document.addSubview(inset)
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        self.window = window
        spin()
        scrollView.scrollerInsets = stale
        scrollView.insetWrites = 0
        return (scrollView, inset)
    }

    private func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    private func assertInsets(
        _ scrollView: NSScrollView,
        right: CGFloat,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let insets = scrollView.scrollerInsets
        XCTAssertEqual(insets.right, right, message, file: file, line: line)
        XCTAssertEqual(insets.top, stale.top, "top untouched", file: file, line: line)
        XCTAssertEqual(insets.left, stale.left, "left untouched", file: file, line: line)
        XCTAssertEqual(insets.bottom, stale.bottom, "bottom untouched", file: file, line: line)
    }

    func testApplyPutsAStaleTrailingInsetBackOnlyOnTheRightEdge() {
        let (scrollView, inset) = makeFeed(trailing: 0)
        inset.apply()
        assertInsets(scrollView, right: 0, "the closed inspector's width is gone at once")
        spin()
        assertInsets(scrollView, right: 0, "and stays gone after the hop")
    }

    func testTheHopCorrectsAStaleWriteThatLandsAfterApply() {
        let (scrollView, inset) = makeFeed(trailing: 0)
        inset.apply()
        // SwiftUI's late animation frame, after this view's first write.
        scrollView.scrollerInsets = stale
        spin()
        assertInsets(scrollView, right: 0, "the next run-loop turn writes the settled value again")
    }

    func testAnOpenInspectorKeepsItsWidth() {
        let (scrollView, inset) = makeFeed(trailing: 418)
        inset.apply()
        spin()
        assertInsets(scrollView, right: 418, "an open column's width is the settled value")
    }

    func testNothingIsWrittenWhenTheInsetIsAlreadySettled() {
        let (scrollView, inset) = makeFeed(trailing: 420)
        inset.apply()
        spin()
        assertInsets(scrollView, right: 420, "already settled")
        XCTAssertEqual(scrollView.insetWrites, 0, "a settled inset is never rewritten")
    }

    func testWithoutAScrollViewNothingHappens() {
        let inset = FeedScrollerInset.InsetView(frame: .zero)
        inset.trailing = 0
        inset.apply()
        inset.settle()
        spin()
        XCTAssertNil(inset.enclosingScrollView)
    }

    func testAScrollOfTheFeedSettlesAStaleInset() {
        let (scrollView, _) = makeFeed(trailing: 0)
        // No update, no hop: only the scroll that would show the knob.
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 300))
        assertInsets(scrollView, right: 0, "a scroll re-settles the scroller")
    }

    func testARemovedViewWritesNothingOnAScroll() {
        let (scrollView, inset) = makeFeed(trailing: 0)
        inset.removeFromSuperview()
        scrollView.scrollerInsets = stale
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 300))
        assertInsets(scrollView, right: stale.right, "a removed view writes nothing")
    }
}
