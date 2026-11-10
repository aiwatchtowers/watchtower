import AppKit
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// #1073: the feed's vertical scroller under the chat's inspector column.
/// SwiftUI moves it left by the open column's width, frame by frame of the
/// column's animation; a close whose last frames are skipped left it where
/// the column's edge was, so it flashed in the middle of the feed.
@MainActor
final class ChatFeedScrollerInsetTests: XCTestCase {
    private final class Panel: ObservableObject {
        @Published var open = false
    }

    private struct Harness: View {
        @ObservedObject var panel: Panel

        var body: some View {
            let state = ChatAutoScrollPolicy.ThreadState(conversationID: 1, lastMessageID: 1, scrollTarget: nil,
                                                         liveMessageID: nil)
            ChatFeedView(state: state, lastRowID: 1) {
                ForEach(0..<6, id: \.self) { _ in
                    AssistantMessageBody(text: String(repeating: "Prose that wraps across the column. ", count: 30),
                                         steps: [], isRunning: false)
                }
            }
            .inspector(isPresented: $panel.open) {
                Color.clear.inspectorColumnWidth(min: 320, ideal: 420, max: 900)
            }
        }
    }

    private var window: NSWindow?

    override func tearDown() {
        window?.orderOut(nil)
        window = nil
        super.tearDown()
    }

    private func settle(_ host: NSView) {
        for _ in 0..<8 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            host.layoutSubtreeIfNeeded()
        }
    }

    private func feedScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView, scrollView.hasVerticalScroller { return scrollView }
        return view.subviews.lazy.compactMap { self.feedScrollView(in: $0) }.first
    }

    func testScrollerReturnsToTheEdgeWhenTheInspectorClosesOnABusyMainThread() throws {
        let panel = Panel()
        let host = NSHostingView(rootView: Harness(panel: panel))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        self.window = window
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        settle(host)
        let scrollView = try XCTUnwrap(feedScrollView(in: host))
        XCTAssertEqual(scrollView.scrollerInsets.right, 0, "no inspector: the scroller sits at the edge")

        panel.open = true
        settle(host)
        XCTAssertGreaterThan(scrollView.scrollerInsets.right, 300, "an open inspector moves the scroller to its edge")

        // The close starts animating, then the main thread is busy past the
        // animation's end (as a panel close that reloads the chat can be).
        panel.open = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        Thread.sleep(forTimeInterval: 0.4)
        settle(host)

        XCTAssertEqual(scrollView.scrollerInsets.right, 0, "the scroller is back at the feed's trailing edge")
        let scroller = try XCTUnwrap(scrollView.verticalScroller)
        XCTAssertEqual(scroller.frame.maxX, scrollView.bounds.maxX, accuracy: 1)
    }
}
