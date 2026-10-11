import SwiftUI
import WatchtowerCore

/// A group's "N of M done" in the panel (spec 2026-10-06 Part 3): the bar
/// over the group's leaves and the count per status, zeros left out.
struct WorkbenchGroupProgress: View {
    let summary: WorkbenchGroupSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            WorkbenchCompactProgress(done: summary.done, total: summary.total,
                                     label: "\(summary.done) of \(summary.total) done")
            if !summary.breakdown.isEmpty {
                Text(summary.breakdown.map { "\(WorkbenchBoardCard.statusLabel($0.status)) \($0.count)" }
                    .joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The group panel's SUB-TASKS tree (`WorkbenchSubtaskTree`): a click opens
/// the sub-task in the panel; nested groups and the "✓ N closed" rows fold
/// here only (panel-local, never remembered).
struct WorkbenchGroupSubtasks: View {
    let group: WorkbenchBoardNode
    let showArchived: Bool
    let onOpen: (Int) -> Void

    @State private var collapsed: Set<Int> = []
    @State private var unfoldedClosed: Set<Int> = []

    private static let indent: CGFloat = 16

    var body: some View {
        let rows = WorkbenchSubtaskTree.rows(
            of: group, collapsed: collapsed, unfoldedClosed: unfoldedClosed, showArchived: showArchived
        )
        VStack(alignment: .leading, spacing: 2) {
            WorkbenchDetailSectionHeader(title: "Sub-tasks", systemImage: "list.bullet.indent",
                                         count: WorkbenchSubtaskTree.count(of: group, showArchived: showArchived))
                .padding(.bottom, 6)
            if rows.isEmpty {
                Text("Every sub-task is archived. Turn on Archive to see them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                switch row {
                case let .target(row): targetRow(row)
                case let .closed(fold): closedRow(fold)
                }
            }
        }
    }

    private func targetRow(_ row: WorkbenchBoardRow) -> some View {
        let target = row.node.target
        let title = WorkbenchBoardCard.title(target.text)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            if row.hasChildren {
                Button { toggle(&collapsed, row.id) } label: {
                    Image(systemName: collapsed.contains(row.id) ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
                .help(collapsed.contains(row.id) ? "Show its sub-tasks" : "Hide its sub-tasks")
                .accessibilityLabel(collapsed.contains(row.id) ? "Expand" : "Collapse")
            } else {
                Color.clear.frame(width: 12, height: 1)
            }
            Button { onOpen(row.id) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: target.statusIcon)
                        .font(.caption)
                        .foregroundStyle(WorkbenchBoardColors.status(target.statusColor))
                    Text(WorkbenchTargetNumber.label(target.id))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(title.isEmpty ? "Untitled" : title)
                        .font(.callout)
                        .foregroundStyle(row.node.archived ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(WorkbenchTargetNumber.label(target.id)) in the panel")
            .accessibilityLabel("\(WorkbenchTargetNumber.label(target.id)) \(title), "
                + WorkbenchBoardCard.statusLabel(target.status))
        }
        .padding(.leading, CGFloat(row.depth) * Self.indent)
        .padding(.vertical, 3)
    }

    private func closedRow(_ fold: WorkbenchSubtaskTree.ClosedFold) -> some View {
        Button { toggle(&unfoldedClosed, fold.parentID) } label: {
            HStack(spacing: 6) {
                Image(systemName: fold.unfolded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 12)
                Text("✓ \(fold.count) closed")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, CGFloat(fold.depth) * Self.indent)
        .padding(.vertical, 3)
        .help(fold.unfolded ? "Hide the done and dismissed sub-tasks" : "Show the done and dismissed sub-tasks")
    }

    private func toggle(_ set: inout Set<Int>, _ id: Int) {
        if set.remove(id) == nil { set.insert(id) }
    }
}
