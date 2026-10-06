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

}
