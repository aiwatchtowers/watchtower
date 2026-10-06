import SwiftUI
import WatchtowerCore

/// The bar above an entered group (spec 2026-10-06 Part 4): "Board › #A
/// title › #B title", every step above the scope a click back up to it,
/// then the scope's "N of M" (`WorkbenchGroupSummary`, the panel's rule)
/// and "✕ Leave group", one level up.
struct WorkbenchBoardPathBar: View {
    /// Top-level target first, the scope last; never empty.
    let path: [WorkbenchBoardNode]
    let showArchived: Bool
    /// A step: that group's id, nil for Board.
    let onJump: (Int?) -> Void
    let onLeave: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            step("Board", help: "Show the whole board") { onJump(nil) }
            ForEach(path.dropLast(), id: \.target.id) { node in
                separator
                step(label(node), help: "Show \(WorkbenchTargetNumber.label(node.target.id)) only") {
                    onJump(node.target.id)
                }
            }
            if let scope = path.last {
                separator
                Text(label(scope))
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                progress(WorkbenchGroupSummary(scope, showArchived: showArchived))
            }
            Button(action: onLeave) {
                Label("Leave group", systemImage: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Back to the level above (Esc)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private var separator: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    private func step(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .buttonStyle(.link)
        .help(help)
    }

    private func label(_ node: WorkbenchBoardNode) -> String {
        let title = WorkbenchBoardCard.title(node.target.text)
        return "\(WorkbenchTargetNumber.label(node.target.id)) \(title.isEmpty ? "Untitled" : title)"
    }

    private func progress(_ summary: WorkbenchGroupSummary) -> some View {
        HStack(spacing: 6) {
            ProgressView(value: Double(summary.done), total: Double(max(summary.total, 1)))
                .progressViewStyle(.linear)
                .controlSize(.small)
                .tint(summary.total > 0 && summary.done == summary.total ? .green : .accentColor)
                .frame(width: 80)
            Text("\(summary.done) of \(summary.total)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
        .help("Tasks done in this group")
    }
}
