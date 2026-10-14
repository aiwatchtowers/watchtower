import AppKit
import SwiftUI
import WatchtowerCore
import WebKit

/// ⌘↩ / ⌘⇧↩ for an ask's answer buttons while no field has the keyboard
/// (owner ask #90): nothing focused, or only the drawer's own read-only
/// text (a review's document). Laid behind the drawer, it sees every key
/// equivalent of the window and takes one only then — a focused field
/// (a drawer field presses the button itself, a margin comment is left, a
/// target comment is sent), the terminal or the Files editor keep their
/// ⌘↩. Not a `.keyboardShortcut` on the buttons: SwiftUI runs one before
/// the focused view, so it would take ⌘↩ from all of them.
///
/// With `onPress` it also offers the bare keys of `OwnerAskKeyMap`
/// (board #412) under the same rule — AppKit hands every key down to the
/// window's key equivalents before the focused view — and takes one when
/// `onPress` acts on it; laid behind the page it does that alone (no
/// `onKey`, so ⌘↩ passes on to the drawer's). Every key needs its window
/// to be the key window with no sheet: AppKit offers key equivalents to
/// the main window too while a panel (Open Quickly) is key. With
/// `onMouseDown` it reports each click in its window and whether it fell
/// inside its own frame (the drawer's active state, board #412), and a
/// click inside takes the keyboard to the drawer (`takeKeyboard`, board
/// #536), handed back when the workbench's drawer goes (`canHandBack`).
struct OwnerAskKeyCatcher: NSViewRepresentable {
    /// A bare key while no field has the keyboard; true when it acted.
    var onPress: ((OwnerAskKeyMap.Press) -> Bool)?
    /// A click in the window; true when inside this view.
    var onMouseDown: ((Bool) -> Void)?
    /// A strip along the leading edge (the drawer's resize handle) whose
    /// clicks take no keyboard.
    var resizeEdge: CGFloat = 0
    /// Read once the catcher is gone: whether the keyboard a click took
    /// goes back — false while the drawer only moved to another host (a
    /// session's pane, the page's).
    var canHandBack: (() -> Bool)?
    /// Where the lender is kept: the workbench's, so a drawer moved to
    /// another host still hands back on its real close. nil: its own.
    var loan: OwnerAskKeyboardLoan?
    /// The key pressed; true for ⌘⇧↩. nil leaves both keys alone. Last:
    /// a lone trailing closure (`OwnerAskKeyCatcher { … }`) is this one.
    var onKey: ((Bool) -> Void)?

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        update(view)
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        update(view)
    }

    static func dismantleNSView(_ view: CatcherView, coordinator: ()) {
        view.stopWatchingClicks()
        // Once SwiftUI has finished taking the drawer down — and put up
        // the next host's, when it only moved.
        DispatchQueue.main.async {
            if view.canHandBack?() != false { view.handBackKeyboard() }
        }
    }

    private func update(_ view: CatcherView) {
        view.onKey = onKey
        view.onPress = onPress
        view.onMouseDown = onMouseDown
        view.resizeEdge = resizeEdge
        view.canHandBack = canHandBack
        view.loan = loan
    }

    enum Key {
        case commandReturn
        case commandShiftReturn
    }

    /// ⌘↩ or ⌘⇧↩, Return or the keypad's Enter; nil for any other key or
    /// modifiers (⌘⌥↩ is the code question's), and for a held key's
    /// auto-repeat: a ⌘↩ held past leaving a margin comment would
    /// otherwise reach the catcher with nothing focused and answer.
    static func answerKey(_ event: NSEvent) -> Key? {
        guard event.type == .keyDown, !event.isARepeat,
              [CommentEditorKeys.returnKeyCode, CommentEditorKeys.keypadEnterKeyCode].contains(event.keyCode) else { return nil }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch flags {
        case [.command]: return .commandReturn
        case [.command, .shift]: return .commandShiftReturn
        default: return nil
        }
    }

    /// `event` as `OwnerAskKeyMap` reads it; nil for anything but a key down.
    static func press(_ event: NSEvent) -> OwnerAskKeyMap.Press? {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let keypadEnter = event.keyCode == CommentEditorKeys.keypadEnterKeyCode
        return OwnerAskKeyMap.Press(characters: keypadEnter ? "\r" : event.charactersIgnoringModifiers ?? "",
                                    keyCode: event.keyCode,
                                    shift: flags.contains(.shift),
                                    otherModifiers: !flags.isDisjoint(with: [.command, .option, .control]),
                                    isRepeat: event.isARepeat)
    }

    final class CatcherView: NSView {
        var onKey: ((Bool) -> Void)?
        var onPress: ((OwnerAskKeyMap.Press) -> Bool)?
        var onMouseDown: ((Bool) -> Void)? {
            didSet { watchClicks() }
        }
        var resizeEdge: CGFloat = 0
        var canHandBack: (() -> Bool)?
        var loan: OwnerAskKeyboardLoan?
        private let ownLoan = OwnerAskKeyboardLoan()
        /// Whether its window takes keys as the key window — not as the main
        /// window behind a key panel (Open Quickly), which AppKit also
        /// offers key equivalents. `!isVisible` is for never-shown test
        /// windows only: in the app only a visible key window gets keys.
        var isKey: @MainActor (NSWindow) -> Bool = { $0.isKeyWindow || !$0.isVisible }
        private var clickMonitor: Any?
        /// What a click inside took the keyboard from, until
        /// `handBackKeyboard` or a later click takes it from something else.
        private var keyboardLender: NSView? {
            get { (loan ?? ownLoan).lender }
            set { (loan ?? ownLoan).lender = newValue }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            watchClicks()
        }

        /// A local monitor while it is in a window and someone listens.
        private func watchClicks() {
            guard window != nil, onMouseDown != nil else {
                stopWatchingClicks()
                return
            }
            guard clickMonitor == nil else { return }
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                MainActor.assumeIsolated { self?.clicked(event) }
                return event
            }
        }

        /// Not private: tests call it with the event the monitor would see.
        func clicked(_ event: NSEvent) {
            guard let window, event.window === window else { return }
            let point = event.locationInWindow
            onMouseDown?(isInside(point))
            guard isInside(point), point.x >= convert(bounds, to: nil).minX + resizeEdge else { return }
            // Who has the keyboard before AppKit handles the click, which
            // may move it (into a field, or onto the control itself).
            let before = window.firstResponder
            DispatchQueue.main.async { [weak self] in self?.takeKeyboard(in: window, before: before) }
        }

        /// A click inside moves the keyboard here, as a click into any
        /// other pane does (board #536): AppKit leaves it where it was —
        /// the terminal, Monaco, a field beside — when the click lands on
        /// a control that takes no focus (an option, a step's mark), or
        /// gives it to the control itself under Full Keyboard Access. Only
        /// the drawer's own text keeps it (a field the click hit, the
        /// document); anything else lets go, so ⌘↩ and the bare keys work
        /// as with nothing focused, while a terminal or Monaco that still
        /// has the keyboard — clicked last — keeps every key. Keyboard the
        /// click moved out of the drawer (an answered session's terminal)
        /// stays there. The lender is what had it before the click: under
        /// Full Keyboard Access that is the terminal, not the control —
        /// also a terminal the drawer covers (expanded, or a pane too
        /// narrow for both), which lies under it but is no part of it.
        func takeKeyboard(in window: NSWindow, before: NSResponder?) {
            guard let responder = window.firstResponder, responder !== window, !isOwnText(responder) else { return }
            guard responder === before || liesInside(responder) else { return }
            guard window.makeFirstResponder(nil) else { return }
            guard let before, before !== window, isWorkspace(before) || !liesInside(before) else { return }
            // A text field lends the keyboard, not the editor it borrowed.
            let editor = before as? NSText
            keyboardLender = editor?.isFieldEditor == true ? editor?.delegate as? NSView : before as? NSView
        }

        /// The drawer going: the keyboard back to what a click in it took
        /// it from, unless the owner put it somewhere since. The loan ends
        /// either way: a refused one must not reach a later drawer's close.
        func handBackKeyboard() {
            let lender = keyboardLender
            keyboardLender = nil
            guard let lender, !lender.isHiddenOrHasHiddenAncestor,
                  let window = lender.window, window.firstResponder === window else { return }
            window.makeFirstResponder(lender)
        }

        func stopWatchingClicks() {
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            clickMonitor = nil
        }

        /// Whether a point in window coordinates falls on this view.
        func isInside(_ point: NSPoint) -> Bool {
            convert(bounds, to: nil).contains(point)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard let window, takesKeys(in: window) else { return super.performKeyEquivalent(with: event) }
            if let onKey, let key = OwnerAskKeyCatcher.answerKey(event) {
                onKey(key == .commandShiftReturn)
                return true
            }
            if let onPress, let press = OwnerAskKeyCatcher.press(event), onPress(press) { return true }
            return super.performKeyEquivalent(with: event)
        }

        /// In the key window with no sheet up: nothing has the keyboard
        /// (the terminal, Monaco, any field or other view keeps every key),
        /// or read-only text inside the drawer. A click in the drawer gets
        /// here by letting go of the keyboard (`takeKeyboard`).
        func takesKeys(in window: NSWindow) -> Bool {
            guard window.attachedSheet == nil, isKey(window) else { return false }
            guard let responder = window.firstResponder, responder !== window else { return true }
            guard let text = responder as? NSTextView, !text.isEditable else { return false }
            return isOwnText(text)
        }

        /// Text inside the drawer, editable or not.
        private func isOwnText(_ responder: NSResponder) -> Bool {
            responder is NSTextView && liesInside(responder)
        }

        /// A session's terminal or the Files editor (Monaco): never part of
        /// the drawer, wherever it lies.
        private func isWorkspace(_ responder: NSResponder) -> Bool {
            var view = responder as? NSView
            while let current = view {
                if current is TerminalContainerView || current is WKWebView { return true }
                view = current.superview
            }
            return false
        }

        /// A view inside the drawer — told by where its visible part's
        /// middle is. Clipped to its own bounds: outside a scroll view a
        /// text view's `visibleRect` can reach past them, over the drawer.
        private func liesInside(_ responder: NSResponder) -> Bool {
            guard let view = responder as? NSView, view.window === window else { return false }
            let visible = view.convert(view.visibleRect.intersection(view.bounds), to: nil)
            return isInside(NSPoint(x: visible.midX, y: visible.midY))
        }
    }
}

/// What a click in an ask drawer took the keyboard from (board #536),
/// held weakly; one per workbench (`OwnerAsksViewModel.keyboardLoan`).
@MainActor
final class OwnerAskKeyboardLoan {
    weak var lender: NSView?
}
