import SwiftUI

/// "Run Automation…" — the app-menu item opening the quick-run palette
/// (spec §12.7). Owner ruling 2026-10-15: one key combination does the same
/// thing everywhere, so it has its own key equivalent ⌃⌘R (⌘K stays the
/// Workbench tab's Go to… and the Chat tab's Search Chats). The one
/// definition the menu command and the tests read.
enum RunAutomationCommand {
    static let key: Character = "r"
    static let modifiers: EventModifiers = [.control, .command]
    static let title = "Run Automation…"

    enum Target: Equatable {
        case runAutomationPalette, unavailable
    }

    /// The menu item is shown only while the quick-run center exists
    /// (the database is open).
    static func isAvailable(hasCenter: Bool) -> Bool {
        hasCenter
    }

    /// What the shortcut does. `selected` is ignored on purpose: the answer
    /// is the same on every tab, which is what the tests pin.
    static func target(hasCenter: Bool, selected _: SidebarDestination?) -> Target {
        isAvailable(hasCenter: hasCenter) ? .runAutomationPalette : .unavailable
    }
}
