import AppKit
import SwiftUI
import WatchtowerCore

/// What a feed offers for a selection in an answer: "Ask about this", which
/// hands the selected passage to the composer's quote batch. Only the main
/// chat has a batch; an embedded chat passes none and keeps plain
/// selection + ⌘C.
struct ChatFeedSelectionQuote {
    /// The owner's messages as their bubbles show them: a selection in one
    /// of them offers no quote.
    let ownerTexts: () -> [String]
    let onQuote: (String) -> Void
}

/// Finds the passage the owner selected in the feed, and where it is.
///
/// The feed keeps rendering with SwiftUI `Text` + `.textSelection(.enabled)`
/// (`MarkdownView`): no per-row text view, so a long thread lays out as
/// before. On macOS such a `Text` is a selectable `NSTextField`, and
/// selecting in it puts the window's field editor (an `NSTextView`) in it —
/// so the selection is read from the field editor through public AppKit:
/// its `string`, `selectedRange()` and `firstRect(forCharacterRange:)`. A
/// selection therefore stays inside one text block (a paragraph, a list
/// item, a table cell). Should SwiftUI stop backing the text this way, the
/// button simply never appears and selection + ⌘C keep working
/// (`ChatSelectionQuoteTrackerTests` pins the assumption).
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

    /// What a mouse-down in the feed does.
    enum Click: Equatable {
        case none
        /// On the chip: quote now.
        case ask
        /// A right-click (or Control-click) on the selection: the menu.
        case menu
    }

    static let buttonSize = CGSize(width: 118, height: 24)

    private(set) var selection: Selection?

    @ObservationIgnored var quote: ChatFeedSelectionQuote?
    @ObservationIgnored private weak var anchor: NSView?
    @ObservationIgnored private weak var editor: NSTextView?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var scrollObserver: NSObjectProtocol?
    @ObservationIgnored private var menuMonitor: Any?

    /// Starts listening; the anchor is the view covering the feed's visible
    /// area, the coordinates `selection.rect` is in.
    func attach(to anchor: NSView) {
        self.anchor = anchor
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSTextView.didChangeSelectionNotification, object: nil, queue: nil) { [weak self] note in
                let textView = note.object as? NSTextView
                MainActor.assumeIsolated { self?.selectionChanged(in: textView) }
            },
            center.addObserver(forName: NSText.didEndEditingNotification, object: nil, queue: nil) { [weak self] note in
                let textView = note.object as? NSTextView
                MainActor.assumeIsolated { if let textView, textView === self?.editor { self?.clear() } }
            },
            center.addObserver(forName: NSWindow.didResizeNotification, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        ]
        menuMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            let taken = MainActor.assumeIsolated { self?.handleMouseDown(event) ?? false }
            return taken ? nil : event
        }
    }

    /// Stops listening once `anchor` leaves the screen — unless a newer
    /// anchor took over meanwhile.
    func detach(from anchor: NSView) {
        guard anchor === self.anchor else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let menuMonitor { NSEvent.removeMonitor(menuMonitor) }
        menuMonitor = nil
        clear()
        self.anchor = nil
    }

    /// "Ask about this": the passage joins the batch and the selection goes.
    func askAboutSelection() {
        guard let text = selection?.text else { return }
        clear()
        quote?.onQuote(text)
    }

    /// The chip takes its click here, before the window sees it: a click
    /// the window handled would end the text field's editing first, and the
    /// chip would vanish under the pointer before its button fired.
    func click(at point: CGPoint, secondary: Bool) -> Click {
        guard let selection else { return .none }
        if secondary { return selection.rect.insetBy(dx: -2, dy: -2).contains(point) ? .menu : .none }
        return selection.button?.contains(point) == true ? .ask : .none
    }

    func selectionChanged(in textView: NSTextView?) {
        // Only a read-only field editor: a selectable SwiftUI `Text`. The
        // composer and every text field the owner types in are editable.
        guard let textView, textView.isFieldEditor, !textView.isEditable else { return }
        editor = textView
        refresh()
    }

    private func refresh() {
        guard let editor, let anchor, let quote,
              let rect = Self.selectionRect(of: editor, in: anchor),
              rect.intersects(anchor.bounds),
              let text = ChatQuoteReply.selectionQuote(in: editor.string, selection: editor.selectedRange(),
                                                       ownerTexts: quote.ownerTexts()) else {
            setSelection(nil)
            return
        }
        observeScrolling(of: editor)
        let origin = SelectionCommentPlacement.origin(selection: rect, container: anchor.bounds.size, button: Self.buttonSize)
        setSelection(Selection(text: text, rect: rect,
                               button: origin.map { CGRect(origin: $0, size: Self.buttonSize) }))
    }

    private func clear() {
        editor = nil
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        setSelection(nil)
    }

    /// Sets only a change, so an unchanged refresh re-renders nothing.
    private func setSelection(_ new: Selection?) {
        if selection != new { selection = new }
    }

    /// Scrolling the feed moves the selection on screen.
    private func observeScrolling(of editor: NSTextView) {
        guard scrollObserver == nil, let clip = editor.enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// The selection's box in `anchor`'s coordinates: its first line joined
    /// with its last character. `firstRect` works on either text system, so
    /// SwiftUI's field editor is never switched to TextKit 1 by reading it.
    static func selectionRect(of editor: NSTextView, in anchor: NSView) -> CGRect? {
        let range = editor.selectedRange()
        guard range.length > 0, let window = anchor.window, editor.window === window else { return nil }
        let first = editor.firstRect(forCharacterRange: range, actualRange: nil)
        let last = editor.firstRect(forCharacterRange: NSRange(location: NSMaxRange(range) - 1, length: 1), actualRange: nil)
        let onScreen = first.union(last)
        guard !onScreen.isEmpty else { return nil }
        return anchor.convert(window.convertFromScreen(onScreen), from: nil)
    }

    /// A click on the chip quotes; a right-click (or Control-click) on the
    /// selection opens Ask About This / Copy — SwiftUI's own menu for a
    /// selectable `Text` cannot take an item, so this one replaces it
    /// there. Any other click is left alone.
    private func handleMouseDown(_ event: NSEvent) -> Bool {
        guard let anchor, event.window === anchor.window else { return false }
        let secondary = event.type == .rightMouseDown || event.modifierFlags.contains(.control)
        switch click(at: anchor.convert(event.locationInWindow, from: nil), secondary: secondary) {
        case .none:
            return false
        case .ask:
            askAboutSelection()
            return true
        case .menu:
            guard let selection else { return false }
            showMenu(for: selection.text, event: event, in: anchor)
            return true
        }
    }

    private func showMenu(for text: String, event: NSEvent, in anchor: NSView) {
        let menu = NSMenu()
        let ask = NSMenuItem(title: "Ask About This", action: #selector(MenuTarget.ask), keyEquivalent: "")
        let copy = NSMenuItem(title: "Copy", action: #selector(MenuTarget.copyText), keyEquivalent: "")
        let target = MenuTarget(tracker: self, text: text)
        for item in [ask, copy] {
            item.target = target
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: anchor)
        withExtendedLifetime(target) {}
    }

    @MainActor
    private final class MenuTarget: NSObject {
        weak var tracker: ChatSelectionQuoteTracker?
        let text: String

        init(tracker: ChatSelectionQuoteTracker, text: String) {
            self.tracker = tracker
            self.text = text
        }

        @objc func ask() {
            tracker?.clear()
            tracker?.quote?.onQuote(text)
        }

        @objc func copyText() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}

/// The feed's selection overlay: an invisible anchor over the visible area
/// and the floating "Ask about this" button next to the selection. Reads
/// the tracker alone, so a selection change re-renders no row.
struct ChatSelectionQuoteOverlay: View {
    let tracker: ChatSelectionQuoteTracker
    let quote: ChatFeedSelectionQuote

    var body: some View {
        ZStack(alignment: .topLeading) {
            ChatSelectionAnchor(tracker: tracker, quote: quote).allowsHitTesting(false)
            if let button = tracker.selection?.button {
                // A mouse click reaches the tracker first (`click(at:)`);
                // the button is the keyboard and VoiceOver path.
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
