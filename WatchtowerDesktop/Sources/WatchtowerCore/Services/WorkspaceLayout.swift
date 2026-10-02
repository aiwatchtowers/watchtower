import Foundation

/// One pane of a project workspace: a terminal session, one of the two
/// project views, or the code editor with its file tabs (POC).
package enum WorkspacePane: Codable, Hashable, Sendable {
    case session(Int64)
    case board
    case documents
    case files
}

/// The project page header's view buttons: a terminal (any session), the
/// Board or the Documents.
package enum WorkspaceView: CaseIterable, Sendable {
    case terminal
    case board
    case documents
    /// The code editor's file tabs (POC).
    case files

    /// What `pane` shows.
    package init(_ pane: WorkspacePane) {
        switch pane {
        case .session: self = .terminal
        case .board: self = .board
        case .documents: self = .documents
        case .files: self = .files
        }
    }

    package func matches(_ pane: WorkspacePane) -> Bool {
        Self(pane) == self
    }
}

/// Which panes a project page shows, persisted per project under
/// `WorkspaceLayout.key(workbenchID:)`. Pure value type: the view owns the
/// storage, this owns the rules.
package struct WorkspaceLayout: Codable, Equatable, Sendable {
    package static let dividerRange: ClosedRange<Double> = 0.2...0.8

    package var primary: WorkspacePane
    /// nil = single pane.
    package var secondary: WorkspacePane?
    /// Non-nil = that pane alone; the split is remembered underneath.
    package var expanded: WorkspacePane?
    package var dividerFraction: Double

    package static let `default` = Self(primary: .board, secondary: nil, expanded: nil, dividerFraction: 0.5)

    package var isSplit: Bool { secondary != nil }

    package var visiblePanes: [WorkspacePane] {
        if let expanded { return [expanded] }
        return [primary] + (secondary.map { [$0] } ?? [])
    }

    package mutating func split(with pane: WorkspacePane) {
        guard pane != primary else { return }
        secondary = pane
        expanded = nil
    }

    /// Keeps the primary pane; clears the secondary and any expansion.
    package mutating func unsplit() {
        secondary = nil
        expanded = nil
    }

    /// Only a split has something to expand; a single pane is a no-op.
    package mutating func toggleExpand(_ pane: WorkspacePane) {
        guard isSplit else { return }
        if expanded == pane {
            expanded = nil
        } else if pane == primary || pane == secondary {
            expanded = pane
        }
    }

    /// Panel click: an expansion is dropped first; then a pane already in a
    /// slot stays as is, otherwise it replaces the primary (single) or the
    /// secondary (split). Both slots never hold the same pane.
    package mutating func show(_ pane: WorkspacePane) {
        expanded = nil
        if pane == primary || pane == secondary { return }
        if isSplit {
            secondary = pane
        } else {
            primary = pane
        }
    }

    /// A pane's own picker: `slot` shows `pane` instead. A pane already in
    /// the other slot swaps places with it; an expansion follows its slot.
    /// Returns false when `slot` is in neither slot (nothing changes).
    @discardableResult
    package mutating func replace(_ slot: WorkspacePane, with pane: WorkspacePane) -> Bool {
        guard slot != pane else { return primary == slot || secondary == slot }
        let wasExpanded = expanded == slot
        if primary == slot {
            if secondary == pane { secondary = slot }
            primary = pane
        } else if secondary == slot {
            if primary == pane { primary = slot }
            secondary = pane
        } else {
            return false
        }
        if wasExpanded { expanded = pane }
        return true
    }

    /// A split pane's close button: the other pane stays, alone. A single
    /// pane cannot be removed.
    package mutating func remove(_ pane: WorkspacePane) {
        guard isSplit else { return }
        if secondary == pane {
            unsplit()
        } else if primary == pane, let next = secondary {
            primary = next
            unsplit()
        }
    }

    /// Send comments: puts `pane` on screen without hiding `kept` (the pane
    /// the owner sent from). Visible already → nothing moves; a split
    /// replaces the other pane; a single pane switches to it.
    package mutating func reveal(_ pane: WorkspacePane, keeping kept: WorkspacePane) {
        if visiblePanes.contains(pane) { return }
        if pane == primary || pane == secondary {
            expanded = nil
        } else if isSplit {
            expanded = nil
            replace(primary == kept ? secondary ?? primary : primary, with: pane)
        } else {
            primary = pane
        }
    }

    /// ⌘↵ in the go-to palette: `pane` on screen beside `kept`. A single
    /// pane splits with it second; a split replaces the pane that is not
    /// `kept` (`reveal`); on screen already → nothing moves.
    package mutating func openBeside(_ pane: WorkspacePane, keeping kept: WorkspacePane) {
        if isSplit {
            reveal(pane, keeping: kept)
        } else {
            split(with: pane)
        }
    }

    /// Whether a header view button shows as on: that kind of pane is on screen.
    package func isShowing(_ view: WorkspaceView) -> Bool {
        visiblePanes.contains(where: view.matches)
    }

    /// The header's Board / Documents button: puts `pane` on screen without
    /// hiding a terminal — a split keeps its session and swaps the other
    /// pane; a single pane switches to it (`reveal`).
    package mutating func showWorkbenchView(_ pane: WorkspacePane) {
        reveal(pane, keeping: sessionIDs.first.map { .session($0) } ?? primary)
    }

    /// The pane the header's session menu puts a session into: the terminal
    /// on screen, else the last pane on screen — the one the Terminal button
    /// replaces too (it keeps the first).
    package var terminalSlot: WorkspacePane {
        visiblePanes.first(where: WorkspaceView.terminal.matches) ?? visiblePanes.last ?? primary
    }

    /// A header view button turned off: in a split on screen, the pane it
    /// names closes and the other stays alone. One pane on screen (single
    /// or expanded) is never removed.
    package mutating func hide(_ view: WorkspaceView) {
        guard visiblePanes.count == 2, let pane = visiblePanes.first(where: view.matches) else { return }
        remove(pane)
    }

    package mutating func setDividerFraction(_ fraction: Double) {
        dividerFraction = min(max(fraction, Self.dividerRange.lowerBound), Self.dividerRange.upperBound)
    }

    /// The sessions in either slot, primary first.
    package var sessionIDs: [Int64] {
        [primary, secondary].compactMap { pane in
            if case let .session(id)? = pane { return id }
            return nil
        }
    }

    /// A deleted session never stays in the layout.
    package mutating func forgetSession(_ id: Int64, fallback: WorkspacePane) {
        let gone = WorkspacePane.session(id)
        if expanded == gone { expanded = nil }
        if secondary == gone { secondary = nil }
        if primary == gone {
            if let next = secondary {
                primary = next
                secondary = nil
            } else {
                primary = fallback
            }
        }
    }

    /// The `projects.` prefix predates the Workbench rename; persisted, so kept (spec 2026-10-02 A1).
    package static func key(workbenchID: Int64) -> String { "projects.layout.\(workbenchID)" }

    /// Bad or missing data → `.default`; the divider is clamped to its range,
    /// a secondary equal to the primary and an expansion naming neither slot
    /// are dropped.
    package static func decode(_ data: Data?) -> Self {
        guard let data, var layout = try? JSONDecoder().decode(Self.self, from: data) else { return .default }
        if layout.secondary == layout.primary { layout.secondary = nil }
        if let expanded = layout.expanded, !layout.isSplit || (expanded != layout.primary && expanded != layout.secondary) {
            layout.expanded = nil
        }
        layout.setDividerFraction(layout.dividerFraction)
        return layout
    }
}
