import AppKit
import SwiftUI
import XCTest
@testable import WatchtowerDesktop

/// `CommentTextEditor` hosted in a window, through AppKit's own chain:
/// undo across text set from outside, and focus reaching `onFocus`.
@MainActor
final class CommentTextEditorHostedTests: XCTestCase {
    private final class Box {
        var text = ""
    }

    private func host(_ box: Box, onFocus: (() -> Void)? = nil) -> (NSWindow, NSHostingView<AnyView>) {
        let host = NSHostingView(rootView: Self.editor(box, onFocus: onFocus))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 120)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        spin()
        return (window, host)
    }

    private static func editor(_ box: Box, onFocus: (() -> Void)?) -> AnyView {
        AnyView(CommentTextEditor(text: Binding(get: { box.text }, set: { box.text = $0 }), onFocus: onFocus))
    }

    private func spin() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private func textView(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        return view.subviews.lazy.compactMap { self.textView(in: $0) }.first
    }

    /// Paging to another ask swaps the draft under the same field: ⌘Z
    /// must not bring the previous ask's text back.
    func testTextSetFromOutsideIsNotUndoable() throws {
        let box = Box()
        let (window, host) = host(box)
        defer { window.close() }
        let textView = try XCTUnwrap(textView(in: host))
        XCTAssertTrue(window.makeFirstResponder(textView))
        textView.insertText("ask A's note", replacementRange: textView.selectedRange())
        XCTAssertEqual(box.text, "ask A's note")
        XCTAssertEqual(textView.undoManager?.canUndo, true, "typing is undoable")

        box.text = "ask B's note"
        host.rootView = Self.editor(box, onFocus: nil)
        host.layoutSubtreeIfNeeded()
        spin()
        XCTAssertEqual(textView.string, "ask B's note")
        XCTAssertEqual(textView.undoManager?.canUndo, false, "nothing of ask A is left to undo")
    }

    func testTakingTheKeyboardRunsOnFocus() throws {
        var focused = 0
        let (window, host) = host(Box()) { focused += 1 }
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(try XCTUnwrap(textView(in: host))))
        spin()
        XCTAssertEqual(focused, 1)
    }

    /// A click into the field that already has the keyboard (its card made
    /// inactive by a click elsewhere that took no focus) runs it again.
    func testAClickWhileFocusedRunsOnFocus() throws {
        var focused = 0
        let (window, host) = host(Box()) { focused += 1 }
        defer { window.close() }
        let textView = try XCTUnwrap(textView(in: host))
        XCTAssertTrue(window.makeFirstResponder(textView))
        spin()
        let point = textView.convert(NSPoint(x: 10, y: 10), to: nil)
        func click(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        let down = try XCTUnwrap(click(.leftMouseDown))
        // The text view's tracking loop ends on this mouse-up.
        NSApp.postEvent(try XCTUnwrap(click(.leftMouseUp)), atStart: false)
        textView.mouseDown(with: down)
        spin()
        XCTAssertEqual(focused, 2, "taking the keyboard, then the click")
    }
}
