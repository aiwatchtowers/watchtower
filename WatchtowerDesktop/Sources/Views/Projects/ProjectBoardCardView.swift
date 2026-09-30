import SwiftUI
import WatchtowerCore

/// One target of the project board as a task card: status icon, title,
/// priority/status chips, counters, and — for a parent — its children's
/// progress and a collapse chevron. `trailing` is the card's action slot.
struct ProjectBoardCardView<Trailing: View>: View {
    let row: ProjectBoardRow
    let isSelected: Bool
    let isCollapsed: Bool
    let onToggle: () -> Void
    @ViewBuilder let trailing: () -> Trailing

    @State private var hovering = false

    private var target: Target { row.node.target }
    private var card: ProjectBoardCard { ProjectBoardCard(row.node) }

    var body: some View {
        let card = card
        HStack(alignment: .top, spacing: 8) {
            chevron
            Image(systemName: target.statusIcon)
                .foregroundStyle(ProjectBoardColors.status(target.statusColor))
            VStack(alignment: .leading, spacing: 5) {
                Text(card.title.isEmpty ? "Untitled" : card.title)
                    .font(row.hasChildren ? .callout.weight(.semibold) : .callout)
                    .lineLimit(2)
                    .strikethrough(card.isDone)
                    .foregroundStyle(card.isClosed ? .secondary : .primary)
                chips(card)
                if let children = card.children {
                    ProgressView(value: children.fraction)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .tint(children.done == children.total ? .green : .accentColor)
                }
            }
            Spacer(minLength: 4)
            trailing()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(background)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isSelected ? 1.5 : 0.5)
        )
        .opacity(card.isClosed && !isSelected ? 0.6 : 1)
        .padding(.leading, CGFloat(min(row.depth, 6)) * 18)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var chevron: some View {
        if row.hasChildren {
            Button(action: onToggle) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12, height: 16)
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "Show sub-tasks" : "Hide sub-tasks")
        } else {
            Color.clear.frame(width: 12, height: 16)
        }
    }

    private var background: some View {
        let fill: Color = if isSelected {
            Color.accentColor.opacity(0.12)
        } else if hovering {
            Color.primary.opacity(0.06)
        } else {
            Color(nsColor: .controlBackgroundColor)
        }
        return RoundedRectangle(cornerRadius: 8).fill(fill)
    }

    private func chips(_ card: ProjectBoardCard) -> some View {
        HStack(spacing: 6) {
            ProjectBoardChip(
                text: target.priority.capitalized,
                color: ProjectBoardColors.priority(target.priority),
                dot: true
            )
            ProjectBoardChip(
                text: ProjectBoardCard.statusLabel(target.status),
                color: ProjectBoardColors.status(target.statusColor)
            )
            if let children = card.children {
                counter("\(children.done)/\(children.total)", systemImage: "checklist", help: "Sub-tasks done")
            }
            if let progress = card.leafProgress {
                counter("\(Int(progress * 100))%", systemImage: "chart.bar.fill", help: "Progress")
            }
            if row.node.unreadForOwner > 0 {
                counter("\(row.node.unreadForOwner)", systemImage: "bubble.left.fill", help: "New agent comments", color: .blue)
            }
            if row.node.openComments > 0 {
                counter("\(row.node.openComments)", systemImage: "text.bubble", help: "Open comments", color: .orange)
            }
            if !row.node.documents.isEmpty {
                counter("\(row.node.documents.count)", systemImage: "doc.text", help: "Documents")
            }
        }
        .lineLimit(1)
    }

    private func counter(_ text: String, systemImage: String, help: String, color: Color = .secondary) -> some View {
        Label(text, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(.caption2)
            .foregroundStyle(color)
            .help(help)
    }
}

extension ProjectBoardCardView where Trailing == EmptyView {
    init(row: ProjectBoardRow, isSelected: Bool, isCollapsed: Bool, onToggle: @escaping () -> Void) {
        self.init(row: row, isSelected: isSelected, isCollapsed: isCollapsed, onToggle: onToggle) { EmptyView() }
    }
}

/// A small tinted capsule: a card's priority or status, and the detail pane's
/// menu labels.
struct ProjectBoardChip: View {
    let text: String
    let color: Color
    var dot = false

    var body: some View {
        HStack(spacing: 4) {
            if dot {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(text).font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(dot ? Color.primary : color)
        .background(color.opacity(0.14), in: Capsule())
    }
}

/// The Targets tab's colours for status and priority.
enum ProjectBoardColors {
    /// Maps `Target.statusColor`'s name to a colour; an unknown status is neutral.
    static func status(_ name: String) -> Color {
        switch name {
        case "blue": .blue
        case "teal": .teal
        case "red": .red
        case "green": .green
        case "gray": .gray
        case "purple": .purple
        default: .secondary
        }
    }

    static func priority(_ priority: String) -> Color {
        switch priority {
        case "high": .red
        case "low": .blue
        default: .orange
        }
    }
}
