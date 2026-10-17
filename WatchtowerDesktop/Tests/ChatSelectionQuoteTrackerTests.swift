import AppKit
import SwiftUI
import XCTest
@testable import WatchtowerDesktop

/// "Ask about this" (#536): the feed's selection is read from the window's
/// field editor while the rows keep rendering as SwiftUI `Text`.
@MainActor
final class ChatSelectionQuoteTrackerTests: XCTestCase {
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    private var window: NSWindow?
    private var tracker: ChatSelectionQuoteTracker?
    private var anchor: NSView?

    override func tearDown() {
        closeFeed()
        super.tearDown()
    }

    private func closeFeed() {
        if let tracker, let anchor { tracker.detach(from: anchor) }
        window?.close()
        (window, tracker, anchor) = (nil, nil, nil)
    }

    private func findTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField { return field }
        return view.subviews.lazy.compactMap { self.findTextField(in: $0) }.first
    }

    /// The assumption the tracker rests on: a selectable SwiftUI `Text` is
    /// an `NSTextField` (so selecting in it uses the window's field editor).
    /// If SwiftUI changes this, the button stops appearing — this fails
    /// first.
    func testASelectableSwiftUITextIsBackedByATextField() throws {
        let text = "Keep the retry budget small."
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        window.contentView = root
        let host = NSHostingView(rootView: Text(text).textSelection(.enabled))
        host.frame = root.bounds
        root.addSubview(host)
        let anchor = FlippedView(frame: root.bounds)
        root.addSubview(anchor)
        host.layoutSubtreeIfNeeded()
        let tracker = ChatSelectionQuoteTracker()
        tracker.quote = ChatFeedSelectionQuote(ownerTexts: { [] }, onQuote: { _ in })
        tracker.attach(to: anchor)
        (self.window, self.tracker, self.anchor) = (window, tracker, anchor)

        let field = try XCTUnwrap(findTextField(in: host))
        XCTAssertTrue(field.isSelectable)
        XCTAssertFalse(field.isEditable)
        let editor = try XCTUnwrap(window.fieldEditor(true, for: field) as? NSTextView)
        try XCTUnwrap(field.cell).select(withFrame: field.bounds, in: field, editor: editor, delegate: field,
                                         start: 0, length: 0)
        editor.setSelectedRange((text as NSString).range(of: "retry budget"))
        XCTAssertEqual(tracker.selection?.text, "retry budget")
    }

    /// A window with a read-only label over a full-size anchor, as the feed
    /// lays it out; returns the label's field editor.
    private func makeFeed(
        text: String,
        editable: Bool = false,
        ownerTexts: [String] = [],
        onQuote: @escaping (String) -> Void = { _ in }
    ) throws -> NSTextView {
        closeFeed()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        window.contentView = root
        let field = editable ? NSTextField(string: text) : NSTextField(labelWithString: text)
        field.isSelectable = true
        field.frame = NSRect(x: 20, y: 40, width: 400, height: 24)
        root.addSubview(field)
        let anchor = FlippedView(frame: root.bounds)
        root.addSubview(anchor)
        let tracker = ChatSelectionQuoteTracker()
        tracker.quote = ChatFeedSelectionQuote(ownerTexts: { ownerTexts }, onQuote: onQuote)
        tracker.attach(to: anchor)
        (self.window, self.tracker, self.anchor) = (window, tracker, anchor)
        // What a click in the text does: the window's field editor takes
        // over the field (no key window is needed for it).
        let editor = try XCTUnwrap(window.fieldEditor(true, for: field) as? NSTextView)
        try XCTUnwrap(field.cell).select(withFrame: field.bounds, in: field, editor: editor, delegate: field,
                                         start: 0, length: 0)
        XCTAssertTrue(editor.isFieldEditor)
        return editor
    }

    func testASelectionInAnAnswerIsOfferedWithItsPlace() throws {
        let text = "Keep the retry budget small."
        let editor = try makeFeed(text: text)
        editor.setSelectedRange((text as NSString).range(of: "retry budget"))
        let selection = try XCTUnwrap(tracker?.selection)
        XCTAssertEqual(selection.text, "retry budget")
        XCTAssertTrue(selection.rect.intersects(try XCTUnwrap(anchor).bounds))
        XCTAssertGreaterThan(selection.rect.width, 0)

        editor.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertNil(tracker?.selection, "a collapsed selection offers nothing")
    }

    /// The chip sits next to the selection, never on it, and takes a plain
    /// click; a right-click on the selection opens the menu; any other click
    /// is the window's.
    func testClicksOnTheChipAndTheSelection() throws {
        let text = "Keep the retry budget small."
        let editor = try makeFeed(text: text)
        editor.setSelectedRange((text as NSString).range(of: "retry budget"))
        let tracker = try XCTUnwrap(tracker)
        let selection = try XCTUnwrap(tracker.selection)
        let button = try XCTUnwrap(selection.button)
        XCTAssertFalse(button.intersects(selection.rect))
        let onButton = CGPoint(x: button.midX, y: button.midY)
        let onText = CGPoint(x: selection.rect.midX, y: selection.rect.midY)
        XCTAssertEqual(tracker.click(at: onButton, secondary: false), .ask)
        XCTAssertEqual(tracker.click(at: onText, secondary: true), .menu)
        XCTAssertEqual(tracker.click(at: onText, secondary: false), .none, "a click in the text re-selects")
        XCTAssertEqual(tracker.click(at: CGPoint(x: 490, y: 290), secondary: true), .none)
    }

    func testAskAboutThisHandsTheQuoteOverAndClears() throws {
        var quoted: [String] = []
        let text = "Ship on Friday."
        let editor = try makeFeed(text: text) { quoted.append($0) }
        editor.setSelectedRange((text as NSString).range(of: "Friday"))
        tracker?.askAboutSelection()
        XCTAssertEqual(quoted, ["Friday"])
        XCTAssertNil(tracker?.selection)
    }

    func testTheOwnersOwnMessageAndEditableFieldsOfferNothing() throws {
        let mine = "Why is it so small?"
        let editor = try makeFeed(text: mine, ownerTexts: [mine])
        editor.setSelectedRange((mine as NSString).range(of: "small"))
        XCTAssertNil(tracker?.selection, "the owner's bubble")

        let typed = "a search query"
        let field = try makeFeed(text: typed, editable: true)
        field.setSelectedRange((typed as NSString).range(of: "search"))
        XCTAssertNil(tracker?.selection, "a field the owner types in")
    }

    func testADetachedTrackerStopsListening() throws {
        let text = "Keep the retry budget small."
        let editor = try makeFeed(text: text)
        try tracker?.detach(from: XCTUnwrap(anchor))
        editor.setSelectedRange((text as NSString).range(of: "retry"))
        XCTAssertNil(tracker?.selection)
    }
}
