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

    package mutating func toggleExpand(_ pane: WorkspacePane) {
        if expanded == pane {
            expanded = nil
        } else if pane == primary || pane == secondary {
            expanded = pane
        }
    }

    /// Panel click: a visible pane stays as is; otherwise it replaces the
    /// primary (single) or the secondary (split). An expansion is dropped first.
    package mutating func show(_ pane: WorkspacePane) {
        if visiblePanes.contains(pane) { return }
        expanded = nil
        if isSplit {
            secondary = pane
        } else {
            primary = pane
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

    /// Bad or missing data → `.default`; the divider is clamped to its range.
    package static func decode(_ data: Data?) -> Self {
        guard let data, var layout = try? JSONDecoder().decode(Self.self, from: data) else { return .default }
        layout.dividerFraction = min(max(layout.dividerFraction, dividerRange.lowerBound), dividerRange.upperBound)
        return layout
    }
}
