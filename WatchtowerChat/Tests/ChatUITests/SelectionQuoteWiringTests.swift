#if os(macOS)
import AppKit
import ChatWire
import SwiftUI
import XCTest
@testable import ChatUI

/// D10: on the Mac a finished answer in the shared feed marks its body for "Ask about this" when the feed quotes.
@MainActor
final class SelectionQuoteWiringTests: XCTestCase {
    private func host(_ view: some View) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: view)
        hosting.frame = window.contentLayoutRect
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date())
        return window
    }

    func testAFinalAnswerMarksItsRegionWhenTheFeedQuotes() {
        let tracker = ChatSelectionQuoteTracker()
        let window = host(ChatAnswerText(text: "Keep the retry budget small.", isFinal: true, isOwner: false)
            .environment(\.chatAnswerRegions, tracker))
        XCTAssertEqual(tracker.regionCount, 1)
        window.close()
    }

    func testAStreamingAnswerOrAnOwnerMessageMarksNothing() {
        let tracker = ChatSelectionQuoteTracker()
        let window = host(VStack {
            ChatAnswerText(text: "Draft", isFinal: false, isOwner: false)
            ChatAnswerText(text: "Owner text", isFinal: true, isOwner: true)
        }
        .environment(\.chatAnswerRegions, tracker))
        XCTAssertEqual(tracker.regionCount, 0)
        window.close()
    }
}
#endif
