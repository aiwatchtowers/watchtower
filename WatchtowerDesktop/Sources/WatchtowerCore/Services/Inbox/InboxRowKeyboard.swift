import Foundation

/// What a key on the focused row of Waiting for me or Mail waiting does
/// (spec "Waiting for me and Mail waiting", keyboard in both panes).
package enum InboxKeyCommand: Equatable, Sendable {
    case moveDown, moveUp
    /// Opens the focused row's **Snooze ▾** menu: the owner picks the
    /// duration there, as with the mouse; the key never picks one.
    case openSnoozeMenu
    case press(InboxRowPress)
}

/// The keys of a focused artifact row. J/K move on any row; a ping
/// (`inbox_item`) has E done, R reply (only with a Reply… of its own),
/// S its Snooze menu, ⏎ open, ⌘K hand to agent; a Mail waiting sender has
/// ⏎ open, E Mark All Done…, M mute. Nothing else is a key: no S or R on
/// a sender, no action key on the Older note row.
package enum InboxRowKeymap {
    /// The key's name: its lowercased character, or `"return"`.
    package static let returnKey = "return"

    package static func command(key: String, command: Bool, kind: InboxRef.Kind, canReply: Bool) -> InboxKeyCommand? {
        switch (key, command) {
        case ("j", false): return .moveDown
        case ("k", false): return .moveUp
        default: break
        }
        switch kind {
        case .inboxItem: return ping(key: key, command: command, canReply: canReply)
        case .mailSender: return command ? nil : sender(key: key)
        case .waitingOlder, .track, .idea, .reminder, .action: return nil
        }
    }

    private static func ping(key: String, command: Bool, canReply: Bool) -> InboxKeyCommand? {
        switch (key, command) {
        case ("k", true): .press(.handToAgent)
        case ("e", false): .press(.done)
        case ("r", false): canReply ? .press(.reply) : nil
        case ("s", false): .openSnoozeMenu
        case (returnKey, false): .press(.open)
        default: nil
        }
    }

    private static func sender(key: String) -> InboxKeyCommand? {
        switch key {
        case returnKey: .press(.open)
        case "e": .press(.markAllDone)
        case "m": .press(.mute)
        default: nil
        }
    }

    /// Whether the rows take keys at all: only while the pane itself holds
    /// the keyboard, and never while a row's Reply composer is open (its
    /// field is in the pane: J, E, S or ⏎ typed there are text).
    package static func takesKeys(hostHasKeyboard: Bool, replyOpen: Bool) -> Bool {
        hostHasKeyboard && !replyOpen
    }

    /// Whether the row's native actions would take `command` now, as its
    /// buttons are drawn: nothing while a press runs or in the preview; a
    /// press its button draws disabled (a CLI press without the CLI, Open
    /// without a link, Reply… while a reply is open) is not made either.
    package static func allows(_ command: InboxKeyCommand, content: InboxRowActionsContent) -> Bool {
        if command == .moveDown || command == .moveUp { return true }
        if content.isBusy || content.isPreview { return false }
        switch command {
        case .moveDown, .moveUp: return true
        case .openSnoozeMenu: return !content.isSnoozeOff
        case let .press(press):
            if content.isOff(press) { return false }
            switch (content.kind, press) {
            case let (.inboxItem(openLabel, openEnabled, _, _), .open): return openLabel != nil && openEnabled
            case let (.inboxItem(_, _, _, showsHandToAgent), .handToAgent): return showsHandToAgent
            case (.inboxItem, .reply): return content.hasReply && content.reply == nil
            case let (.mailSender(_, openEnabled), .open): return openEnabled
            default: return true
            }
        }
    }
}

/// What the row host does with a key on the focused row (`InboxRowKeymap.effect`).
package enum InboxRowKeyEffect: Equatable, Sendable {
    /// J/K: the focus moves this many rows.
    case move(Int)
    /// S: the row's own Snooze menu opens (`InboxRowKeyRequest`).
    case openSnoozeMenu
    /// ⌘K: the row's own Hand to Agent… opens, picker and all.
    case openHandToAgent
    /// E on a sender: its Mark All Done…'s inline confirmation; no press yet.
    case beginBulk(InboxBulkKey)
    /// Any other key: the press the row's own button makes.
    case press(InboxRowPress)
}

package extension InboxRowKeymap {
    /// A key press on the focused row `ref`, whose native actions are drawn
    /// as `content` (nil: a row the read does not list, J/K only), once the
    /// host holds the keyboard (`takesKeys`). ⌃ or ⌥ is never a row key.
    /// Nil: the press is not the rows' (`.ignored`).
    static func effect(
        key: String,
        command isCommand: Bool,
        controlOrOption: Bool,
        ref: InboxRef,
        content: InboxRowActionsContent?
    ) -> InboxRowKeyEffect? {
        guard !controlOrOption,
              let command = command(key: key, command: isCommand, kind: ref.kind,
                                    canReply: content?.hasReply ?? false) else { return nil }
        switch command {
        case .moveDown: return .move(1)
        case .moveUp: return .move(-1)
        case .openSnoozeMenu, .press: break
        }
        guard let content, allows(command, content: content) else { return nil }
        switch command {
        case .openSnoozeMenu: return .openSnoozeMenu
        case .press(.handToAgent): return .openHandToAgent
        case .press(.markAllDone): return .beginBulk(.sender(ref.key))
        case let .press(press): return .press(press)
        case .moveDown, .moveUp: return nil
        }
    }
}

/// The focused row of an artifact's list rows: `refs` are the shown,
/// unfolded rows in document order. A fresh focus starts on the first row.
package struct InboxRowFocus: Equatable, Sendable {
    package private(set) var refs: [InboxRef]
    package var focused: InboxRef?

    package init(refs: [InboxRef]) {
        self.refs = refs
        focused = refs.first
    }

    /// `delta` rows down (up when negative), clamped at the ends; with
    /// nothing focused, the first row.
    package mutating func move(_ delta: Int) {
        guard !refs.isEmpty else {
            focused = nil
            return
        }
        guard let focused, let index = refs.firstIndex(of: focused) else {
            self.focused = refs.first
            return
        }
        self.focused = refs[min(max(index + delta, 0), refs.count - 1)]
    }

    /// The rows after a read: the focused row while it is still listed,
    /// else the row now at its old index (the next one, once a row closed
    /// by E leaves), else the last row, else nothing. With nothing focused
    /// before, the first row.
    package mutating func reconcile(refs newRefs: [InboxRef]) {
        defer { refs = newRefs }
        if let focused, newRefs.contains(focused) { return }
        guard !newRefs.isEmpty else {
            focused = nil
            return
        }
        guard let focused, let old = refs.firstIndex(of: focused) else {
            self.focused = newRefs.first
            return
        }
        self.focused = newRefs[min(old, newRefs.count - 1)]
    }
}

package extension InboxRowActionsContent {
    /// Snooze ▾ is off as a whole: whether a snooze is off does not depend
    /// on its duration, so any one stands for the menu.
    var isSnoozeOff: Bool { isOff(.snooze(duration: "")) }

    /// The row's Reply composer is open (not the "waiting for approval" caption).
    var isComposingReply: Bool {
        if case .composing = reply { return true }
        return false
    }
}
