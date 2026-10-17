import AppKit
import SwiftUI
import XCTest
@testable import WatchtowerDesktop

/// "Ask about this" (#536): the feed's selection is read from the window's
/// field editor while the rows keep rendering as SwiftUI `Text`, and only a
/// selection inside a finished answer's region counts.
@MainActor
final class ChatSelectionQuoteTrackerTests: XCTestCase {
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    private var windows: [NSWindow] = []
    private var tracker: ChatSelectionQuoteTracker?
    private var anchor: NSView?

    override func tearDown() {
        if let tracker, let anchor { tracker.detach(from: anchor) }
        windows.forEach { $0.close() }
        (windows, tracker, anchor) = ([], nil, nil)
        super.tearDown()
    }

    private func makeWindow() -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        window.contentView = root
        windows.append(window)
        return (window, root)
    }

    private func findTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField { return field }
        return view.subviews.lazy.compactMap { self.findTextField(in: $0) }.first
    }

    /// What a click in the text does: the window's field editor takes over
    /// the field (no key window is needed for it).
    private func beginEditing(_ field: NSTextField) throws -> NSTextView {
        let window = try XCTUnwrap(field.window)
        let editor = try XCTUnwrap(window.fieldEditor(true, for: field) as? NSTextView)
        try XCTUnwrap(field.cell).select(withFrame: field.bounds, in: field, editor: editor, delegate: field,
                                         start: 0, length: 0)
        return editor
    }

    private func addField(_ text: String, editable: Bool = false, frame: NSRect, to root: NSView) -> NSTextField {
        let field = editable ? NSTextField(string: text) : NSTextField(labelWithString: text)
        field.isSelectable = true
        field.frame = frame
        root.addSubview(field)
        return field
    }

    private func addRegion(_ frame: NSRect, to root: NSView, tracker: ChatSelectionQuoteTracker) {
        let region = NSView(frame: frame)
        root.addSubview(region, positioned: .below, relativeTo: nil)
        tracker.addRegion(region)
    }

    private struct Feed {
        let window: NSWindow
        let root: NSView
        let tracker: ChatSelectionQuoteTracker
        let editor: NSTextView
    }

    /// A window with one read-only label and, unless `inRegion` is false, a
    /// finished answer's region around it; a full-size anchor on top.
    private func makeFeed(
        text: String,
        editable: Bool = false,
        inRegion: Bool = true,
        listening: ChatSelectionQuoteListening = .init(),
        onQuote: @escaping (String) -> Void = { _ in }
    ) throws -> Feed {
        let (window, root) = makeWindow()
        let field = addField(text, editable: editable, frame: NSRect(x: 20, y: 40, width: 400, height: 24), to: root)
        let tracker = ChatSelectionQuoteTracker(listening: listening)
        if inRegion { addRegion(NSRect(x: 10, y: 30, width: 420, height: 44), to: root, tracker: tracker) }
        let anchor = FlippedView(frame: root.bounds)
        root.addSubview(anchor)
        tracker.quote = ChatFeedSelectionQuote(onQuote: onQuote)
        tracker.attach(to: anchor)
        (self.tracker, self.anchor) = (tracker, anchor)
        return Feed(window: window, root: root, tracker: tracker, editor: try beginEditing(field))
    }

    /// The assumption the tracker rests on: a selectable SwiftUI `Text` is
    /// an `NSTextField` using the window's field editor. If SwiftUI changes
    /// this, the chip stops appearing — this fails first.
    func testASelectableSwiftUITextIsBackedByATextField() throws {
        let text = "Keep the retry budget small."
        let (_, root) = makeWindow()
        let host = NSHostingView(rootView: Text(text).textSelection(.enabled))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
        root.addSubview(host)
        let tracker = ChatSelectionQuoteTracker()
        addRegion(host.frame, to: root, tracker: tracker)
        let anchor = FlippedView(frame: root.bounds)
        root.addSubview(anchor)
        host.layoutSubtreeIfNeeded()
        tracker.quote = ChatFeedSelectionQuote { _ in }
        tracker.attach(to: anchor)
        (self.tracker, self.anchor) = (tracker, anchor)

        let field = try XCTUnwrap(findTextField(in: host))
        XCTAssertTrue(field.isSelectable)
        XCTAssertFalse(field.isEditable)
        let editor = try beginEditing(field)
        editor.setSelectedRange((text as NSString).range(of: "retry budget"))
        XCTAssertEqual(tracker.selection?.text, "retry budget")
    }

    /// The real marker behind a SwiftUI answer: its text quotes, a text
    /// outside it (an owner bubble) does not.
    func testTheAnswerMarkerScopesSwiftUIText() throws {
        let tracker = ChatSelectionQuoteTracker()
        let (_, root) = makeWindow()
        let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 20) {
            Text("Owner asks about the retry budget").textSelection(.enabled)
            VStack { Text("Answer keeps the retry budget small").textSelection(.enabled) }
                .background { ChatAnswerRegionMarker(tracker: tracker) }
        })
        host.frame = root.bounds
        root.addSubview(host)
        let anchor = FlippedView(frame: root.bounds)
        root.addSubview(anchor)
        host.layoutSubtreeIfNeeded()
        tracker.quote = ChatFeedSelectionQuote { _ in }
        tracker.attach(to: anchor)
        (self.tracker, self.anchor) = (tracker, anchor)

        var fields: [NSTextField] = []
        func collect(_ view: NSView) {
            if let field = view as? NSTextField { fields.append(field) }
            view.subviews.forEach(collect)
        }
        collect(host)
        let owner = try XCTUnwrap(fields.first { $0.stringValue.hasPrefix("Owner") })
        let answer = try XCTUnwrap(fields.first { $0.stringValue.hasPrefix("Answer") })

        let ownerEditor = try beginEditing(owner)
        ownerEditor.setSelectedRange(NSRange(location: 0, length: 5))
        XCTAssertNil(tracker.selection, "outside every answer region")
        let answerEditor = try beginEditing(answer)
        answerEditor.setSelectedRange(NSRange(location: 0, length: 6))
        XCTAssertEqual(tracker.selection?.text, "Answer")
    }

    func testASelectionInAnAnswerIsOfferedWithItsPlace() throws {
        let text = "Keep the retry budget small."
        let feed = try makeFeed(text: text)
        feed.editor.setSelectedRange((text as NSString).range(of: "retry budget"))
        let selection = try XCTUnwrap(feed.tracker.selection)
        XCTAssertEqual(selection.text, "retry budget")
        XCTAssertGreaterThan(selection.rect.width, 0)
        let button = try XCTUnwrap(selection.button)
        XCTAssertFalse(button.intersects(selection.rect), "the chip sits next to the selection")

        feed.editor.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertNil(feed.tracker.selection, "a collapsed selection offers nothing")
    }

    /// The owner's bubbles, steps, cards and the streaming reply carry no
    /// region: a selection there offers nothing.
    func testASelectionOutsideEveryAnswerRegionOffersNothing() throws {
        let text = "Why is it so small?"
        let feed = try makeFeed(text: text, inRegion: false)
        feed.editor.setSelectedRange((text as NSString).range(of: "small"))
        XCTAssertNil(feed.tracker.selection)
    }

    func testAnEditableFieldOffersNothing() throws {
        let text = "a search query"
        let feed = try makeFeed(text: text, editable: true)
        feed.editor.setSelectedRange((text as NSString).range(of: "search"))
        XCTAssertNil(feed.tracker.selection)
    }

    /// A selection in another window neither offers a quote nor clears the
    /// feed's.
    func testASelectionInAnotherWindowLeavesTheFeedAlone() throws {
        let text = "Keep the retry budget small."
        let feed = try makeFeed(text: text)
        feed.editor.setSelectedRange((text as NSString).range(of: "retry"))
        let shown = try XCTUnwrap(feed.tracker.selection)

        let (_, otherRoot) = makeWindow()
        let other = addField("Somewhere else entirely", frame: NSRect(x: 20, y: 40, width: 400, height: 24), to: otherRoot)
        let otherEditor = try beginEditing(other)
        otherEditor.setSelectedRange(NSRange(location: 0, length: 9))
        XCTAssertEqual(feed.tracker.selection, shown)
        otherEditor.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertEqual(feed.tracker.selection, shown)
    }

    func testTheChipTakesAClickOnlyInTheFeedsWindowAndOnTheChip() throws {
        var quoted: [String] = []
        let text = "Keep the retry budget small."
        let feed = try makeFeed(text: text) { quoted.append($0) }
        feed.editor.setSelectedRange((text as NSString).range(of: "retry budget"))
        let button = try XCTUnwrap(feed.tracker.selection?.button)
        // The anchor fills the flipped root: its coordinates are the window's
        // content view's, flipped.
        let onButton = feed.root.convert(CGPoint(x: button.midX, y: button.midY), to: nil)
        let (otherWindow, _) = makeWindow()

        XCTAssertFalse(feed.tracker.handleMouseDown(in: otherWindow, at: onButton), "another window's click passes")
        XCTAssertFalse(feed.tracker.handleMouseDown(in: feed.window, at: feed.root.convert(CGPoint(x: 490, y: 290), to: nil)))
        XCTAssertEqual(quoted, [])
        XCTAssertTrue(feed.tracker.handleMouseDown(in: feed.window, at: onButton))
        XCTAssertEqual(quoted, ["retry budget"])
        XCTAssertNil(feed.tracker.selection)
        XCTAssertFalse(feed.tracker.handleMouseDown(in: feed.window, at: onButton), "no selection, no chip")
    }

    /// The box is measured again before a click: once the text moved, the
    /// old chip place takes nothing.
    func testAClickNeverUsesAStaleBox() throws {
        var quoted: [String] = []
        let text = "Keep the retry budget small."
        let feed = try makeFeed(text: text) { quoted.append($0) }
        feed.editor.setSelectedRange((text as NSString).range(of: "retry budget"))
        let button = try XCTUnwrap(feed.tracker.selection?.button)
        let onOldButton = feed.root.convert(CGPoint(x: button.midX, y: button.midY), to: nil)
        // The answer scrolls far away (region and text together).
        for view in feed.root.subviews where !(view is FlippedView) {
            view.frame = view.frame.offsetBy(dx: 0, dy: 600)
        }
        XCTAssertFalse(feed.tracker.handleMouseDown(in: feed.window, at: onOldButton))
        XCTAssertEqual(quoted, [])
    }

    func testAskAboutThisHandsTheQuoteOverAndClears() throws {
        var quoted: [String] = []
        let text = "Ship on Friday."
        let feed = try makeFeed(text: text) { quoted.append($0) }
        feed.editor.setSelectedRange((text as NSString).range(of: "Friday"))
        feed.tracker.askAboutSelection()
        XCTAssertEqual(quoted, ["Friday"])
        XCTAssertNil(feed.tracker.selection)
    }

    /// `detach` removes every observer and the mouse monitor: a private
    /// center stops delivering, and the monitor seam sees one add and one
    /// remove.
    func testDetachStopsTheObserversAndTheMonitor() throws {
        let center = NotificationCenter()
        var added = 0
        var removed = 0
        var listening = ChatSelectionQuoteListening(center: center)
        listening.addMouseDownMonitor = { _ in
            added += 1
            return NSObject()
        }
        listening.removeMonitor = { _ in removed += 1 }
        let text = "Keep the retry budget small."
        let feed = try makeFeed(text: text, listening: listening)
        feed.editor.setSelectedRange((text as NSString).range(of: "retry"))
        XCTAssertNil(feed.tracker.selection, "the private center has not delivered yet")
        center.post(name: NSTextView.didChangeSelectionNotification, object: feed.editor)
        XCTAssertEqual(feed.tracker.selection?.text, "retry")

        try feed.tracker.detach(from: XCTUnwrap(anchor))
        XCTAssertNil(feed.tracker.selection)
        XCTAssertEqual(added, 1)
        XCTAssertEqual(removed, 1)
        feed.editor.setSelectedRange((text as NSString).range(of: "budget"))
        center.post(name: NSTextView.didChangeSelectionNotification, object: feed.editor)
        XCTAssertNil(feed.tracker.selection)
        tracker = nil
    }

    /// The box covers every line of a selection that wraps, not its first
    /// line alone.
    func testAWrappedSelectionCoversEveryLine() throws {
        let text = "one two three four five six seven eight nine ten eleven twelve"
        let (window, root) = makeWindow()
        let field = NSTextField(wrappingLabelWithString: text)
        field.isSelectable = true
        field.frame = NSRect(x: 20, y: 20, width: 120, height: 200)
        root.addSubview(field)
        let anchor = FlippedView(frame: root.bounds)
        root.addSubview(anchor)
        XCTAssertTrue(window.contentView === root)
        let editor = try beginEditing(field)
        editor.setSelectedRange(NSRange(location: 0, length: (text as NSString).length))
        let all = try XCTUnwrap(ChatSelectionQuoteTracker.selectionRect(of: editor, in: anchor))
        editor.setSelectedRange(NSRange(location: 0, length: 3))
        let first = try XCTUnwrap(ChatSelectionQuoteTracker.selectionRect(of: editor, in: anchor))
        XCTAssertGreaterThan(all.height, first.height * 2, "several lines")
    }
}
