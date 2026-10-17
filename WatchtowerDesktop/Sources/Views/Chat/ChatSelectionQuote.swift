import AppKit
import SwiftUI
import WatchtowerCore

/// What a feed offers for a selection in an answer: "Ask about this", which
/// hands the selected passage to the composer's quote batch. Only the main
/// chat has a batch; an embedded chat passes none and keeps plain
/// selection + ⌘C.
struct ChatFeedSelectionQuote {
    let onQuote: (String) -> Void
}

/// How the tracker listens: the notification center and the local event
/// monitor, injectable so a test can see that `detach` stops both.
struct ChatSelectionQuoteListening {
    var center: NotificationCenter = .default
    var addMouseDownMonitor: (@escaping (NSEvent) -> NSEvent?) -> Any? = { handler in
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: handler)
    }
    var removeMonitor: (Any) -> Void = { NSEvent.removeMonitor($0) }
}

/// Finds the passage the owner selected in an answer, and where it is.
///
/// The feed keeps rendering with SwiftUI `Text` + `.textSelection(.enabled)`
/// (`MarkdownView`): no per-row text view, so a long thread lays out as
/// before. On macOS such a `Text` is a selectable `NSTextField`, and
/// selecting in it puts the window's field editor (an `NSTextView`) in it —
/// so the selection is read from the field editor through public AppKit:
/// its `string`, `selectedRange()` and `firstRect(forCharacterRange:)`. A
/// selection therefore stays inside one text block (a paragraph, a list
/// item, a table cell). Should SwiftUI stop backing the text this way, the
/// chip simply never appears and selection + ⌘C keep working
/// (`ChatSelectionQuoteTrackerTests` pins the assumption).
///
/// Only a selection inside a finished answer's body counts: each such body
/// carries an invisible region view (`ChatAnswerRegionMarker`), and the
/// selection's box must lie inside one of them — never the owner's bubbles,
/// steps, error or action cards, sources, or the streaming reply.
@MainActor
@Observable
final class ChatSelectionQuoteTracker {
    struct Selection: Equatable {
        let text: String
        /// The selection's box in the anchor's coordinates (the feed's
        /// visible area, top-left origin).
        let rect: CGRect
        /// Where the "Ask about this" chip sits, same coordinates; nil when
        /// it has no room on screen (`SelectionCommentPlacement`).
        let button: CGRect?
    }

    static let buttonSize = CGSize(width: 118, height: 24)

    private(set) var selection: Selection?

    @ObservationIgnored var quote: ChatFeedSelectionQuote?
    @ObservationIgnored private let listening: ChatSelectionQuoteListening
    @ObservationIgnored private weak var anchor: NSView?
    @ObservationIgnored private weak var editor: NSTextView?
    /// The answer region the current selection lies in.
    @ObservationIgnored private weak var region: NSView?
    @ObservationIgnored private let regions = NSHashTable<NSView>.weakObjects()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Geometry of the current selection: the feed's scroll view and the
    /// region's frame.
    @ObservationIgnored private var geometryObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var mouseMonitor: Any?

    init(listening: ChatSelectionQuoteListening = .init()) {
        self.listening = listening
    }

    /// Starts listening; the anchor is the view covering the feed's visible
    /// area, the coordinates `selection.rect` is in.
    func attach(to anchor: NSView) {
        self.anchor = anchor
        guard observers.isEmpty else { return }
        let center = listening.center
        anchor.postsFrameChangedNotifications = true
        observers = [
            center.addObserver(forName: NSTextView.didChangeSelectionNotification, object: nil, queue: nil) { [weak self] note in
                let textView = note.object as? NSTextView
                MainActor.assumeIsolated { self?.selectionChanged(in: textView) }
            },
            center.addObserver(forName: NSText.didEndEditingNotification, object: nil, queue: nil) { [weak self] note in
                let textView = note.object as? NSTextView
                MainActor.assumeIsolated { if let textView, textView === self?.editor { self?.clear() } }
            },
            // The side panel, the sidebar, a window resize.
            center.addObserver(forName: NSView.frameDidChangeNotification, object: anchor, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        ]
        mouseMonitor = listening.addMouseDownMonitor { [weak self] event in
            let window = event.window
            let location = event.locationInWindow
            let taken = MainActor.assumeIsolated { self?.handleMouseDown(in: window, at: location) ?? false }
            return taken ? nil : event
        }
    }

    /// Stops listening once `anchor` leaves the screen — unless a newer
    /// anchor took over meanwhile.
    func detach(from anchor: NSView) {
        guard anchor === self.anchor else { return }
        observers.forEach(listening.center.removeObserver)
        observers = []
        if let mouseMonitor { listening.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        clear()
        self.anchor = nil
    }

    /// A finished answer's body on screen (`ChatAnswerRegionMarker`).
    func addRegion(_ view: NSView) { regions.add(view) }

    func removeRegion(_ view: NSView) {
        regions.remove(view)
        if view === region { clear() }
    }

    /// "Ask about this": the passage joins the batch and the selection goes.
    func askAboutSelection() {
        guard let text = selection?.text else { return }
        clear()
        quote?.onQuote(text)
    }

    func selectionChanged(in textView: NSTextView?) {
        // Only a read-only field editor (a selectable SwiftUI `Text`) in the
        // feed's own window: the composer and every field the owner types in
        // are editable, and a selection in another window never touches the
        // feed's.
        guard let textView, let window = anchor?.window, textView.window === window else { return }
        // The owner moved to a field they type in (the composer, a search
        // field): the answer's selection is gone.
        guard textView.isFieldEditor, !textView.isEditable else {
            clear()
            return
        }
        editor = textView
        region = nil
        stopObservingGeometry()
        guard let rect = currentRect(), let found = regionContaining(rect) else {
            setSelection(nil)
            return
        }
        region = found
        observeGeometry(of: found)
        refresh()
    }

    /// Re-measures the selection inside its region (scroll, reflow, resize).
    private func refresh() {
        guard let editor, let anchor, let region, region.window === anchor.window,
              let rect = currentRect(), Self.box(of: region, in: anchor).insetBy(dx: -2, dy: -2).contains(rect),
              rect.intersects(anchor.bounds),
              let text = ChatQuoteReply.selectedText(editor.string, selection: editor.selectedRange()) else {
            setSelection(nil)
            return
        }
        let origin = SelectionCommentPlacement.origin(selection: rect, container: anchor.bounds.size, button: Self.buttonSize)
        setSelection(Selection(text: text, rect: rect, button: origin.map { CGRect(origin: $0, size: Self.buttonSize) }))
    }

    private func currentRect() -> CGRect? {
        guard let editor, let anchor else { return nil }
        return Self.selectionRect(of: editor, in: anchor)
    }

    private func regionContaining(_ rect: CGRect) -> NSView? {
        guard let anchor else { return nil }
        return regions.allObjects.first { view in
            view.window === anchor.window && Self.box(of: view, in: anchor).insetBy(dx: -2, dy: -2).contains(rect)
        }
    }

    private static func box(of view: NSView, in anchor: NSView) -> CGRect {
        anchor.convert(view.bounds, from: view)
    }

    private func clear() {
        editor = nil
        region = nil
        stopObservingGeometry()
        setSelection(nil)
    }

    /// Sets only a change, so an unchanged refresh re-renders nothing.
    private func setSelection(_ new: Selection?) {
        if selection != new { selection = new }
    }

    /// Scrolling the feed (the region's own scroll view — never a code
    /// block's or table's inner horizontal one) and a reflow of the thread
    /// move the selection on screen.
    private func observeGeometry(of region: NSView) {
        let center = listening.center
        region.postsFrameChangedNotifications = true
        var observers = [
            center.addObserver(forName: NSView.frameDidChangeNotification, object: region, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        ]
        if let clip = region.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        geometryObservers = observers
    }

    private func stopObservingGeometry() {
        geometryObservers.forEach(listening.center.removeObserver)
        geometryObservers = []
    }

    /// The selection's box in `anchor`'s coordinates: the union of every
    /// line it covers. `firstRect` works on either text system, so SwiftUI's
    /// field editor is never switched to TextKit 1 by reading it.
    static func selectionRect(of editor: NSTextView, in anchor: NSView) -> CGRect? {
        let range = editor.selectedRange()
        guard range.length > 0, let window = anchor.window, editor.window === window else { return nil }
        var onScreen = CGRect.null
        var location = range.location
        while location < NSMaxRange(range) {
            var line = NSRange(location: 0, length: 0)
            let rect = editor.firstRect(forCharacterRange: NSRange(location: location, length: NSMaxRange(range) - location),
                                        actualRange: &line)
            if !rect.isEmpty { onScreen = onScreen.union(rect) }
            guard line.length > 0, NSMaxRange(line) > location else { break }
            location = NSMaxRange(line)
        }
        guard !onScreen.isNull, !onScreen.isEmpty else { return nil }
        return anchor.convert(window.convertFromScreen(onScreen), from: nil)
    }

    /// The chip takes its click here, before the window sees it: a click
    /// the window handled would end the text field's editing first, and the
    /// chip would vanish under the pointer before its button fired. The
    /// geometry is measured again first, so a stale box never takes a
    /// click; a click in another window, or off the chip, is left alone.
    func handleMouseDown(in window: NSWindow?, at locationInWindow: CGPoint) -> Bool {
        guard selection != nil, let anchor, let window, window === anchor.window else { return false }
        refresh()
        guard let button = selection?.button, button.contains(anchor.convert(locationInWindow, from: nil)) else {
            return false
        }
        askAboutSelection()
        return true
    }
}

/// The feed's selection overlay: an invisible anchor over the visible area
/// and the floating "Ask about this" chip next to the selection. Reads the
/// tracker alone, so a selection change re-renders no row.
struct ChatSelectionQuoteOverlay: View {
    let tracker: ChatSelectionQuoteTracker
    let quote: ChatFeedSelectionQuote

    var body: some View {
        ZStack(alignment: .topLeading) {
            ChatSelectionAnchor(tracker: tracker, quote: quote).allowsHitTesting(false)
            if let button = tracker.selection?.button {
                // A mouse click reaches the tracker first
                // (`handleMouseDown`); the button's own action is a fallback.
                Button { tracker.askAboutSelection() } label: {
                    Label("Ask about this", systemImage: "text.quote")
                        .font(.callout)
                        .lineLimit(1)
                        .frame(width: button.width, height: button.height)
                }
                .buttonStyle(FloatingCommentButtonStyle())
                .help("Quote the selection in your reply")
                .padding(.leading, button.minX)
                .padding(.top, button.minY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A flipped, invisible view over the feed's visible area: the coordinates
/// the tracker measures the selection in, and its window. The tracker
/// listens while it is on screen.
private struct ChatSelectionAnchor: NSViewRepresentable {
    let tracker: ChatSelectionQuoteTracker
    let quote: ChatFeedSelectionQuote

    final class AnchorView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeCoordinator() -> ChatSelectionQuoteTracker { tracker }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        tracker.quote = quote
        tracker.attach(to: view)
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        tracker.quote = quote
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: ChatSelectionQuoteTracker) {
        coordinator.detach(from: view)
    }
}

/// An invisible view behind a finished answer's body: the region a
/// selection must lie in to be quotable. No layout, no drawing, no hits.
struct ChatAnswerRegionMarker: NSViewRepresentable {
    let tracker: ChatSelectionQuoteTracker

    final class RegionView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeCoordinator() -> ChatSelectionQuoteTracker { tracker }

    func makeNSView(context: Context) -> RegionView {
        let view = RegionView()
        tracker.addRegion(view)
        return view
    }

    func updateNSView(_ view: RegionView, context: Context) {}

    static func dismantleNSView(_ view: RegionView, coordinator: ChatSelectionQuoteTracker) {
        coordinator.removeRegion(view)
    }
}

private struct ChatAnswerRegionsKey: EnvironmentKey {
    static let defaultValue: ChatSelectionQuoteTracker? = nil
}

extension EnvironmentValues {
    /// The feed's selection tracker, for finished answers to mark their
    /// body; nil in a feed without "Ask about this" (embedded chats).
    var chatAnswerRegions: ChatSelectionQuoteTracker? {
        get { self[ChatAnswerRegionsKey.self] }
        set { self[ChatAnswerRegionsKey.self] = newValue }
    }
}
