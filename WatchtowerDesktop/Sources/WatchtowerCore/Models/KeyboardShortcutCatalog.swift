import Foundation

/// The app's keyboard shortcuts by area (issue #288): the one list behind
/// Help › Keyboard Shortcuts, and the source of the guide's keyboard-shortcuts page ("By
/// area" section, `markdown`, kept identical by a test). Display only:
/// each chord stays bound where its action lives, so a new or moved chord
/// is added here by hand. Pure.
package enum KeyboardShortcutCatalog {
    package struct Entry: Equatable, Sendable, Identifiable {
        /// The chord as the menus print it ("⌥⌘S"); alternatives are
        /// joined with " / ".
        package let keys: String
        package let action: String
        package var id: String { keys }

        package init(_ keys: String, _ action: String) {
            self.keys = keys
            self.action = action
        }
    }

    package struct Area: Equatable, Sendable, Identifiable {
        package let title: String
        /// Where the area's keys work, when that is not obvious from the title.
        package let note: String?
        package let entries: [Entry]
        package var id: String { title }

        package init(_ title: String, note: String? = nil, _ entries: [Entry]) {
            self.title = title
            self.note = note
            self.entries = entries
        }
    }

    package static let areas: [Area] = [
        Area("Global", [
            Entry("⌘B", "Collapse or expand the menu"),
            Entry("⌘/", "Ask Watchtower: the chat over any tab"),
            Entry("⌃⌘R", "Run Automation… (with Automations turned on)"),
            Entry("⌃⌥D", "New Voice Idea, from anywhere in macOS"),
            Entry("⌘,", "Settings"),
            Entry("⌘Q", "Quit Watchtower")
        ]),
        Area("AI Chat", [
            Entry("⌘N", "New chat"),
            Entry("⌘K", "Search chats"),
            Entry("Return", "Send the message"),
            Entry("⇧Return", "New line"),
            Entry("Esc", "Stop the answer"),
            Entry("↑", "Edit your last message (in an empty field)"),
            Entry("⌘Return", "Save & Send an edited message"),
            Entry("↑ / ↓", "Previous / next chat (in the chat list)")
        ]),
        Area("Targets", [
            Entry("⌘N", "New target"),
            Entry("Return", "Brief the assistant (new target)"),
            Entry("⌘Return", "Just create (new target)"),
            Entry("⇧Return", "New line (new target)"),
            Entry("⌘Return / ⌃Return", "Send a comment, or save the text you are editing (target comments)"),
            Entry("Esc", "Cancel editing")
        ]),
        Area("Ideas", [
            Entry("⌘Return", "Create (new idea)")
        ]),
        Area("Workbench", note: "The Workbench menu lists most of these.", [
            Entry("⌘T", "New session"),
            Entry("⌘1–⌘9", "Open session 1–9 of the sessions list"),
            Entry("⌘K", "Go to… (the Files editor keeps ⌘K)"),
            Entry("⌥⌘S", "Show or hide the sessions panel"),
            Entry("⌘[", "Back to the workbench list (the Files editor keeps ⌘[)"),
            Entry("⌃⌘A", "Waiting for you, from anywhere in the window, the terminal included"),
            Entry("A", "Waiting for you (nothing focused)"),
            Entry("Esc", "Board: close the target panel, then leave the group")
        ]),
        Area("Sessions Panel", note: "After a click on the panel's empty space, the SESSIONS label or the group header.", [
            Entry("↑ / ↓", "Move the highlight"),
            Entry("Return", "Open the highlighted session"),
            Entry("⌘⌫", "Delete the highlighted session"),
            Entry("⌘Z", "Undo the delete"),
            Entry("Esc", "Back to the terminal")
        ]),
        Area("Go to… Palette", [
            Entry("↑ / ↓", "Move"),
            Entry("Return", "Open"),
            Entry("⌘Return", "Open a session of this workbench beside the one on screen"),
            Entry("Esc", "Close")
        ]),
        Area("Waiting for You", note: "Single keys work while no field, terminal or editor has the keyboard.", [
            Entry("J / K", "Next / previous ask (↓ / ↑ on a card)"),
            Entry("Return", "Open the ask in the drawer; in the drawer, write in the outlined field"),
            Entry("1–3", "Answer a Quick ask with that button"),
            Entry("Tab / ⇧Tab", "Next / previous question or step (drawer)"),
            Entry("1–9", "Pick that option, or mark a check step (drawer)"),
            Entry("N / P", "Next / previous margin comment (review)"),
            Entry("⌘Return", "Answer, Send or Approve"),
            Entry("⌘⇧Return", "Request changes (review)")
        ]),
        Area("Files Editor", note: "With a workbench page on screen; the Navigate menu lists most of these.", [
            Entry("⇧⌘O / ⇧⇧", "Open Quickly"),
            Entry("⇧⌘F", "Find in Workbench"),
            Entry("⌃⌘J", "Go to definition (or ⌘-click)"),
            Entry("⇧⌘U", "Show all usages"),
            Entry("⌘I", "Ask AI"),
            Entry("⌃6", "File symbols"),
            Entry("⌃⌘← / ⌃⌘→", "Back / forward"),
            Entry("⌘S", "Save now"),
            Entry("⌥⌘Return", "Hand to Session (an Ask AI answer)"),
            Entry("⌥⌘M", "Comment on the selected lines (Changes pane)")
        ]),
        Area("Open Quickly", [
            Entry("↑ / ↓", "Move"),
            Entry("Return", "Open in a preview tab"),
            Entry("⌥Return", "Open beside the pane on screen"),
            Entry("⌘Return", "Ask AI about what you typed"),
            Entry("Space", "Quick Look"),
            Entry("Esc", "Close")
        ]),
        Area("Run Automation", [
            Entry("↑ / ↓", "Move"),
            Entry("Return", "Run the highlighted automation"),
            Entry("Esc", "Close")
        ]),
        Area("Voices", note: "On the active card.", [
            Entry("Space", "Play the first clip"),
            Entry("Return", "Confirm"),
            Entry("1–9", "Pick that candidate")
        ]),
        Area("Settings", [
            Entry("⌘S", "Save")
        ])
    ]

    /// The guide's list: one `###` table per area.
    package static var markdown: String {
        areas.map { area in
            var lines = ["### \(area.title)", ""]
            if let note = area.note { lines += [note, ""] }
            lines += ["| Keys | Action |", "|---|---|"]
            lines += area.entries.map { "| **\($0.keys)** | \($0.action) |" }
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }
}
