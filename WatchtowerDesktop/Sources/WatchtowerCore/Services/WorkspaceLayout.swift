import Foundation

/// One pane of a project workspace: a terminal session or one of the two
/// project views.
package enum WorkspacePane: Codable, Hashable, Sendable {
    case session(Int64)
    case board
    case documents
}

/// Which panes a project page shows, persisted per project under
/// `WorkspaceLayout.key(projectID:)`. Pure value type: the view owns the
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
    package mutating func replace(_ slot: WorkspacePane, with pane: WorkspacePane) {
        guard slot != pane else { return }
        let wasExpanded = expanded == slot
        if primary == slot {
            if secondary == pane { secondary = slot }
            primary = pane
        } else if secondary == slot {
            if primary == pane { primary = slot }
            secondary = pane
        } else {
            return
        }
        if wasExpanded { expanded = pane }
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

    package static func key(projectID: Int64) -> String { "projects.layout.\(projectID)" }

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
