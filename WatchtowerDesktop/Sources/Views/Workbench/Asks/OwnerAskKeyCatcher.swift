import AppKit
import SwiftUI
import WatchtowerCore

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
/// inside its own frame (the drawer's active state, board #412).
struct OwnerAskKeyCatcher: NSViewRepresentable {
    /// A bare key while no field has the keyboard; true when it acted.
    var onPress: ((OwnerAskKeyMap.Press) -> Bool)?
    /// A click in the window; true when inside this view.
    var onMouseDown: ((Bool) -> Void)?
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
    }

    private func update(_ view: CatcherView) {
        view.onKey = onKey
        view.onPress = onPress
        view.onMouseDown = onMouseDown
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
        /// Whether its window takes keys as the key window — not as the main
        /// window behind a key panel (Open Quickly), which AppKit also
        /// offers key equivalents. `!isVisible` is for never-shown test
        /// windows only: in the app only a visible key window gets keys.
        var isKey: @MainActor (NSWindow) -> Bool = { $0.isKeyWindow || !$0.isVisible }
        private var clickMonitor: Any?

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

        private func clicked(_ event: NSEvent) {
            guard let window, event.window === window else { return }
            onMouseDown?(isInside(event.locationInWindow))
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
        /// or read-only text inside the drawer —
        /// told by where its visible part's middle is. Clipped to its own
        /// bounds: outside a scroll view a text view's `visibleRect` can
        /// reach past them, over the drawer.
        func takesKeys(in window: NSWindow) -> Bool {
            guard window.attachedSheet == nil, isKey(window) else { return false }
            guard let responder = window.firstResponder, responder !== window else { return true }
            guard let text = responder as? NSTextView, !text.isEditable else { return false }
            let visible = text.convert(text.visibleRect.intersection(text.bounds), to: nil)
            return isInside(NSPoint(x: visible.midX, y: visible.midY))
        }
    }
}
