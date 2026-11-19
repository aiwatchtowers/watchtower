#if os(macOS)
import AppKit
import XCTest
@testable import ChatUI

/// ⌥↓ in the composer's text view (#2065 spec §3): with a hook it toggles the
/// Workchat steps list and leaves the text alone; without one the key does
/// what it always did. Driven by a synthetic key event, not a selector.
@MainActor
final class ComposerOptionArrowDownTests: XCTestCase {
    private func makeView() -> (NSWindow, PastingTextView) {
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 300, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = PastingTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        view.isRichText = false
        window.contentView = view
        window.makeFirstResponder(view)
        view.string = "first line\nsecond line"
        view.setSelectedRange(NSRange(location: 0, length: 0))
        return (window, view)
    }

    private func arrowDown(_ modifiers: NSEvent.ModifierFlags, in window: NSWindow) throws -> NSEvent {
        let arrow = String(utf16CodeUnits: [unichar(NSDownArrowFunctionKey)], count: 1)
        return try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers.union([.numericPad, .function]),
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: arrow, charactersIgnoringModifiers: arrow, isARepeat: false, keyCode: 125))
    }

    func testOptionDownCallsTheHook() throws {
        let (window, view) = makeView()
        defer { window.close() }
        var calls = 0
        view.onOptionArrowDown = { calls += 1 }
        view.keyDown(with: try arrowDown(.option, in: window))
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(view.string, "first line\nsecond line")
        XCTAssertEqual(view.selectedRange().location, 0, "the caret stays where it was")
    }

    func testPlainDownWithHookMovesTheCaret() throws {
        let (window, view) = makeView()
        defer { window.close() }
        var calls = 0
        view.onOptionArrowDown = { calls += 1 }
        view.keyDown(with: try arrowDown([], in: window))
        XCTAssertEqual(calls, 0, "only ⌥↓ is taken")
        XCTAssertNotEqual(view.selectedRange().location, 0)
    }

    func testPlainDownWithoutHookKeepsDefault() throws {
        let (window, view) = makeView()
        defer { window.close() }
        view.keyDown(with: try arrowDown(.option, in: window))
        XCTAssertEqual(view.string, "first line\nsecond line")
        XCTAssertNotEqual(view.selectedRange().location, 0, "⌥↓ moves the caret as before")
    }
}
#endif
