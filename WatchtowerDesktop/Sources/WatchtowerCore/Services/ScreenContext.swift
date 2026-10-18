import Foundation

/// What the owner is looking at when they ask the assistant a question
/// (in-app help). Rendered as a block prefixed to the provider text only —
/// never stored with the owner message.
package struct ScreenContext: Equatable, Sendable {
    package let tab: String
    /// The tab's empty-state status line; nil unless the empty state is on screen.
    package let status: String?
    /// The selected item's title; nil when the tab has no selection.
    package let selected: String?

    package init(tab: String, status: String? = nil, selected: String? = nil) {
        self.tab = tab
        self.status = status
        self.selected = selected
    }

    package var block: String {
        var lines = ["=== CURRENT SCREEN ===", "Tab: \(tab)"]
        if let status { lines.append("Status: \(status)") }
        if let selected { lines.append("Selected: \(selected)") }
        lines.append("===")
        return lines.joined(separator: "\n")
    }
}
