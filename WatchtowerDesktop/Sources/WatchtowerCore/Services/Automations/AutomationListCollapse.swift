import Foundation

/// Which list groups the owner folded (`automations.collapsedSections`).
/// A search expands the groups with a match without touching the stored set.
package struct AutomationListCollapse: Equatable, Sendable {
    package var collapsed: Set<String>

    package init(collapsed: Set<String> = []) {
        self.collapsed = collapsed
    }

    package func isExpanded(_ id: String, searching: Bool, hasMatch: Bool) -> Bool {
        if searching, hasMatch { return true }
        return !collapsed.contains(id)
    }

    package mutating func toggle(_ id: String) {
        if collapsed.remove(id) == nil { collapsed.insert(id) }
    }

    /// Opens a group, e.g. one that gets a new draft or a selected row.
    package mutating func reveal(_ id: String) {
        collapsed.remove(id)
    }
}
