import AppKit
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
@testable import ChatUI

/// "Ask about this" (#536): the feed's selection is read from the window's
/// field editor while the rows keep rendering as SwiftUI `Text`, and only a
/// selection inside a finished answer's region counts.
@MainActor
final class ChatSelectionQuoteTrackerTests: XCTestCase {
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    /// What macOS 27's SwiftUI text-interaction view shows the tracker: a
    /// first responder of static text reporting its selection through
    /// accessibility, no text view. Runs the macOS 27 path on every macOS.
    private final class InteractionStub: NSView {
        var selected = ""
        override var acceptsFirstResponder: Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
        override func accessibilitySelectedText() -> String? { selected }
    }

    private var windows: [NSWindow] = []
    private var tracker: ChatSelectionQuoteTracker?
    private var anchor: NSView?

    override func setUpWithError() throws {
        try WindowServerTestGate.skipIfAbsent()
    }

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

    /// The views backing selectable SwiftUI `Text`s: an `NSTextField` up to
    /// macOS 26, SwiftUI's own text-interaction view from macOS 27 (static
    /// text that takes first responder).
    private func swiftUITexts(in view: NSView) -> [NSView] {
        if view is NSTextField || (view.accessibilityRole() == .staticText && view.acceptsFirstResponder) {
            return [view]
        }
        return view.subviews.flatMap { swiftUITexts(in: $0) }
    }

    private func string(of view: NSView) -> String {
        (view as? NSTextField)?.stringValue ?? (view.accessibilityValue() as? String) ?? ""
    }

    /// Selects `range` in a selectable SwiftUI `Text` as the owner's drag
    /// does on this macOS: through the field editor on an `NSTextField`, or
    /// the text-interaction view's own selection followed by the mouse
    /// going up over it.
    private func select(_ range: NSRange, inSwiftUIText view: NSView, tracker: ChatSelectionQuoteTracker) throws {
        if let field = view as? NSTextField {
            try beginEditing(field).setSelectedRange(range)
            return
        }
        let window = try XCTUnwrap(view.window)
        XCTAssertTrue(window.makeFirstResponder(view))
        view.setAccessibilitySelectedTextRange(range)
        tracker.selectionEnded(in: window, at: view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil))
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
    /// an `NSTextField` using the window's field editor (up to macOS 26) or a
    /// first-responder view reporting its selection through accessibility
    /// (macOS 27). If SwiftUI changes this again, the chip stops appearing —
    /// this fails first.
    func testASelectableSwiftUITextQuotes() throws {
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

        let view = try XCTUnwrap(swiftUITexts(in: host).first)
        if let field = view as? NSTextField {
            XCTAssertTrue(field.isSelectable)
            XCTAssertFalse(field.isEditable)
        }
        try select((text as NSString).range(of: "retry budget"), inSwiftUIText: view, tracker: tracker)
        XCTAssertEqual(tracker.selection?.text, "retry budget")
        XCTAssertNotNil(tracker.selection?.button)
    }

    /// macOS 27: a click that drops the selection, or focus moving to a view
    /// with nothing selected, clears the chip once the mouse goes up.
    func testASwiftUITextSelectionGoesWhenTheFocusMoves() throws {
        let text = "Keep the retry budget small."
        let (window, root) = makeWindow()
        let host = NSHostingView(rootView: Text(text).textSelection(.enabled))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
        root.addSubview(host)
        let tracker = ChatSelectionQuoteTracker()
        addRegion(host.frame, to: root, tracker: tracker)
        let anchor = FlippedView(frame: root.bounds)
        root.addSubview(anchor)
        host.layoutSubtreeIfNeeded()
        tracker.attach(to: anchor)
        (self.tracker, self.anchor) = (tracker, anchor)
        let view = try XCTUnwrap(swiftUITexts(in: host).first)
        try XCTSkipIf(view is NSTextField, "up to macOS 26 the field editor's end of editing clears it")

        try select((text as NSString).range(of: "retry"), inSwiftUIText: view, tracker: tracker)
        XCTAssertEqual(tracker.selection?.text, "retry")
        view.setAccessibilitySelectedTextRange(NSRange(location: 2, length: 0))
        tracker.selectionEnded(in: window, at: nil)
        XCTAssertNil(tracker.selection, "a collapsed selection offers nothing")

        try select((text as NSString).range(of: "budget"), inSwiftUIText: view, tracker: tracker)
        XCTAssertEqual(tracker.selection?.text, "budget")
        window.makeFirstResponder(nil)
        tracker.selectionEnded(in: window, at: nil)
        XCTAssertNil(tracker.selection)
    }

    private struct InteractionFeed {
        let window: NSWindow
        let stub: InteractionStub
        let tracker: ChatSelectionQuoteTracker
        let quoted: () -> [String]
    }

    /// A window with an interaction stub inside a finished answer's region,
    /// focused.
    private func makeInteractionFeed(listening: ChatSelectionQuoteListening = .init()) -> InteractionFeed {
        let (window, root) = makeWindow()
        let stub = InteractionStub(frame: NSRect(x: 20, y: 40, width: 400, height: 60))
        root.addSubview(stub)
        let tracker = ChatSelectionQuoteTracker(listening: listening)
        addRegion(NSRect(x: 10, y: 30, width: 420, height: 80), to: root, tracker: tracker)
        let anchor = FlippedView(frame: root.bounds)
        root.addSubview(anchor)
        var quoted: [String] = []
        tracker.quote = ChatFeedSelectionQuote { quoted.append($0) }
        tracker.attach(to: anchor)
        (self.tracker, self.anchor) = (tracker, anchor)
        window.makeFirstResponder(stub)
        return InteractionFeed(window: window, stub: stub, tracker: tracker) { quoted }
    }

    private func up(_ feed: InteractionFeed, atStub point: CGPoint?) {
        feed.tracker.selectionEnded(in: feed.window, at: point.map { feed.stub.convert($0, to: nil) })
    }

    /// The macOS 27 path end to end, whatever macOS runs the test: offered,
    /// kept in place while unchanged, cleared with the selection or focus.
    func testTheInteractionPathOffersKeepsAndClears() throws {
        let feed = makeInteractionFeed()
        feed.stub.selected = "retry"
        up(feed, atStub: CGPoint(x: 50, y: 20))
        let first = try XCTUnwrap(feed.tracker.selection)
        XCTAssertEqual(first.text, "retry")
        XCTAssertNotNil(first.button)

        up(feed, atStub: CGPoint(x: 300, y: 50))
        XCTAssertEqual(feed.tracker.selection, first, "a click off the text leaves the same selection's chip in place")
        up(feed, atStub: nil)
        XCTAssertEqual(feed.tracker.selection, first, "so does a key such as ⌘C")

        feed.stub.selected = "retry budget"
        up(feed, atStub: nil)
        XCTAssertEqual(feed.tracker.selection?.text, "retry budget", "a changed selection is measured again")

        feed.stub.selected = ""
        up(feed, atStub: CGPoint(x: 50, y: 20))
        XCTAssertNil(feed.tracker.selection, "a collapsed selection offers nothing")

        feed.stub.selected = "budget"
        up(feed, atStub: CGPoint(x: 50, y: 20))
        XCTAssertEqual(feed.tracker.selection?.text, "budget")
        feed.window.makeFirstResponder(nil)
        up(feed, atStub: nil)
        XCTAssertNil(feed.tracker.selection, "the focus moved away")
    }

    /// "Ask about this" leaves the passage selected in its `Text`: the
    /// click's own mouse-up must not bring the chip back for it.
    func testAQuotedInteractionSelectionDoesNotComeBack() throws {
        let feed = makeInteractionFeed()
        feed.stub.selected = "retry"
        up(feed, atStub: CGPoint(x: 50, y: 20))
        feed.tracker.askAboutSelection()
        XCTAssertEqual(feed.quoted(), ["retry"])
        up(feed, atStub: CGPoint(x: 50, y: 20))
        XCTAssertNil(feed.tracker.selection)

        feed.stub.selected = "budget"
        up(feed, atStub: CGPoint(x: 50, y: 20))
        XCTAssertEqual(feed.tracker.selection?.text, "budget", "a new selection is offered again")
    }

    private func mouseUpEvent(at point: CGPoint, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
    }

    /// The monitor: a mouse-up in the feed's window reads the selection
    /// after the event is handled, with the mouse's place; a key-up has
    /// none; another window's event is left alone.
    func testTheMonitorReadsTheSelectionAfterAMouseOrKeyUp() throws {
        var handler: ((NSEvent) -> NSEvent?)?
        var pending: [() -> Void] = []
        var listening = ChatSelectionQuoteListening()
        listening.addEventMonitor = { handler = $0; return NSObject() }
        listening.removeMonitor = { _ in }
        listening.afterEvent = { pending.append($0) }
        func flush() {
            let run = pending
            pending = []
            run.forEach { $0() }
        }
        let feed = makeInteractionFeed(listening: listening)
        let monitor = try XCTUnwrap(handler)
        feed.stub.selected = "retry"

        let point = feed.stub.convert(CGPoint(x: 50, y: 20), to: nil)
        let mouseUp = try mouseUpEvent(at: point, in: feed.window)
        XCTAssertTrue(monitor(mouseUp) === mouseUp, "the event goes on to the window")
        XCTAssertNil(feed.tracker.selection, "read only once the window has handled it")
        XCTAssertEqual(pending.count, 1)
        flush()
        let byMouse = try XCTUnwrap(feed.tracker.selection?.rect)
        XCTAssertEqual(byMouse.height, ChatSelectionQuoteTracker.pointBoxHeight, "a sliver at the mouse")

        feed.stub.selected = "retry budget"
        let keyUp = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: feed.window.windowNumber,
            context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        _ = monitor(keyUp)
        flush()
        XCTAssertEqual(feed.tracker.selection?.rect.height, 60, "a key: the whole visible text")

        let (other, _) = makeWindow()
        let elsewhere = try mouseUpEvent(at: point, in: other)
        _ = monitor(elsewhere)
        XCTAssertTrue(pending.isEmpty, "another window's event is not looked at")
    }

    /// A wide code block scrolled sideways takes the selection out of its
    /// viewport: the chip goes.
    func testScrollingTheCodeBlockSidewaysDropsTheChip() throws {
        let (window, root) = makeWindow()
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 40, width: 300, height: 60))
        let stub = InteractionStub(frame: NSRect(x: 0, y: 0, width: 1000, height: 60))
        scroll.documentView = stub
        root.addSubview(scroll)
        let tracker = ChatSelectionQuoteTracker()
        addRegion(NSRect(x: 10, y: 30, width: 420, height: 80), to: root, tracker: tracker)
        let anchor = FlippedView(frame: root.bounds)
        root.addSubview(anchor)
        tracker.quote = ChatFeedSelectionQuote { _ in }
        tracker.attach(to: anchor)
        (self.tracker, self.anchor) = (tracker, anchor)
        window.makeFirstResponder(stub)
        stub.selected = "retry"
        tracker.selectionEnded(in: window, at: stub.convert(CGPoint(x: 50, y: 30), to: nil))
        XCTAssertEqual(tracker.selection?.text, "retry")

        scroll.contentView.scroll(to: NSPoint(x: 600, y: 0))
        XCTAssertNil(tracker.selection)
    }

    /// No character boxes on macOS 27: the box is a line-high sliver at the
    /// point the mouse went up, kept inside the view's visible part.
    func testTheInteractionBoxSitsAtTheMouseInsideTheView() {
        let (_, root) = makeWindow()
        let view = NSView(frame: NSRect(x: 10, y: 10, width: 200, height: 100))
        root.addSubview(view)
        let height = ChatSelectionQuoteTracker.pointBoxHeight
        XCTAssertEqual(ChatSelectionQuoteTracker.interactionBox(in: view, at: CGPoint(x: 50, y: 50)),
                       CGRect(x: 50, y: 50 - height / 2, width: 1, height: height))
        XCTAssertEqual(ChatSelectionQuoteTracker.interactionBox(in: view, at: CGPoint(x: 500, y: -10)),
                       CGRect(x: 199, y: 0, width: 1, height: height), "a drag past the edge stays inside")
        XCTAssertEqual(ChatSelectionQuoteTracker.interactionBox(in: view, at: nil), view.bounds, "a key: the visible part")
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

        let texts = swiftUITexts(in: host)
        let owner = try XCTUnwrap(texts.first { string(of: $0).hasPrefix("Owner") })
        let answer = try XCTUnwrap(texts.first { string(of: $0).hasPrefix("Answer") })

        try select(NSRange(location: 0, length: 5), inSwiftUIText: owner, tracker: tracker)
        XCTAssertNil(tracker.selection, "outside every answer region")
        try select(NSRange(location: 0, length: 6), inSwiftUIText: answer, tracker: tracker)
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

    /// Typing somewhere in the feed's window (the composer, a search field)
    /// drops the answer's selection and its chip.
    func testAnEditableEditorInTheFeedsWindowClearsTheSelection() throws {
        let text = "Keep the retry budget small."
        let feed = try makeFeed(text: text)
        feed.editor.setSelectedRange((text as NSString).range(of: "retry"))
        XCTAssertNotNil(feed.tracker.selection)

        // Its own editor, so the answer's field editor never ends editing
        // here: only the notification can clear the selection.
        let composerEditor = NSTextView(frame: NSRect(x: 20, y: 200, width: 400, height: 24))
        composerEditor.isFieldEditor = true
        composerEditor.isEditable = true
        feed.root.addSubview(composerEditor)
        NotificationCenter.default.post(name: NSTextView.didChangeSelectionNotification, object: composerEditor)
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
        listening.addEventMonitor = { _ in
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
