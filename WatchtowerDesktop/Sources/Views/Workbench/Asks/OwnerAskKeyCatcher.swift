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
struct OwnerAskKeyCatcher: NSViewRepresentable {
    /// The key pressed; true for ⌘⇧↩.
    let onKey: (Bool) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onKey = onKey
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onKey = onKey
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

    final class CatcherView: NSView {
        var onKey: ((Bool) -> Void)?

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard let window, let key = OwnerAskKeyCatcher.answerKey(event), takesKeys(in: window) else {
                return super.performKeyEquivalent(with: event)
            }
            onKey?(key == .commandShiftReturn)
            return true
        }

        /// Nothing has the keyboard, or read-only text inside the drawer —
        /// told by where its visible part's middle is. Clipped to its own
        /// bounds: outside a scroll view a text view's `visibleRect` can
        /// reach past them, over the drawer.
        private func takesKeys(in window: NSWindow) -> Bool {
            guard let responder = window.firstResponder, responder !== window else { return true }
            guard let text = responder as? NSTextView, !text.isEditable else { return false }
            let visible = text.convert(text.visibleRect.intersection(text.bounds), to: nil)
            return convert(bounds, to: nil).contains(NSPoint(x: visible.midX, y: visible.midY))
        }
    }
}
