import Foundation

/// When a panel list of tabs (the workbench sessions panel, the chat history)
/// scrolls (board #561): it follows the selection, and only the selection.
/// A new selection scrolls to its row at once when the row is listed;
/// otherwise — a new session is put on screen before its row is loaded — the
/// id waits as `pending` and scrolls the moment it first appears among the
/// rows. Row refreshes (status, reorder, asks arriving or closing) never
/// scroll, so the owner's own scroll stays put.
package struct PanelSelectionScrollPolicy<ID: Hashable & Sendable>: Sendable {
    /// The selected id still waiting for its row.
    package private(set) var pending: ID?
    /// The last selection seen, so a re-render with the same one is a no-op.
    private var selected: ID?

    package init() {}

    /// A new selection; returns the id to scroll to now, or nil (cleared,
    /// unchanged, or not listed yet — then it waits as `pending`).
    package mutating func panelScrollTarget(selecting id: ID?, rows: [ID]) -> ID? {
        guard id != selected else { return nil }
        selected = id
        pending = nil
        guard let id else { return nil }
        if rows.contains(id) { return id }
        pending = id
        return nil
    }

    /// The listed rows changed; returns the pending id (and clears it) once
    /// its row is listed, else nil.
    package mutating func panelScrollTarget(rows: [ID]) -> ID? {
        guard let id = pending, rows.contains(id) else { return nil }
        pending = nil
        return id
    }
}
