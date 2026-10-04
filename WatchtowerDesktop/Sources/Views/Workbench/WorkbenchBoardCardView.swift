import SwiftUI
import WatchtowerCore

/// One target of the project board as a task card: status icon, title,
/// its `#id`, priority/status chips, counters, and — for a parent — its children's
/// progress and a collapse chevron. `trailing` is the card's action slot,
/// told whether the pointer is over the card; `caption` is an extra line
/// under the title (the kanban's parent chain).
struct WorkbenchBoardCardView<Trailing: View>: View {
    let row: WorkbenchBoardRow
    let isSelected: Bool
    let isCollapsed: Bool
    var caption: String?
    let onToggle: () -> Void
    @ViewBuilder let trailing: (_ hovering: Bool) -> Trailing

    @State private var hovering = false
    @State private var chevronHovering = false

    private var target: Target { row.node.target }
    private var card: WorkbenchBoardCard { WorkbenchBoardCard(row.node) }

    var body: some View {
        let card = card
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: target.statusIcon)
                .foregroundStyle(WorkbenchBoardColors.status(target.statusColor))
            VStack(alignment: .leading, spacing: 5) {
                Text(card.title.isEmpty ? "Untitled" : card.title)
                    .font(row.hasChildren ? .callout.weight(.semibold) : .callout)
                    .lineLimit(2)
                    .strikethrough(card.isDone)
                    .foregroundStyle(card.isClosed ? .secondary : .primary)
                if let caption {
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(caption)
                }
                chips(card)
                if let children = card.children {
                    ProgressView(value: children.fraction)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .tint(children.done == children.total ? .green : .accentColor)
                }
            }
            Spacer(minLength: 4)
            trailing(hovering)
        }
        .padding(.leading, WorkbenchBoardChevron.zoneWidth)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .background(background)
        .overlay(alignment: .leading) { chevron }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isSelected ? 1.5 : 0.5)
        )
        .opacity(card.isClosed && !isSelected ? 0.6 : 1)
        .padding(.leading, CGFloat(min(row.depth, 6)) * 18)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    /// A parent's collapse control is the card's whole left strip (board
    /// #370): a click anywhere in it folds the sub-tasks and never reaches the
    /// list's selection, which opens the card. A leaf keeps the strip empty so
    /// titles line up.
    @ViewBuilder
    private var chevron: some View {
        if row.hasChildren {
            Button(action: onToggle) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(chevronHovering ? Color.primary : Color.secondary)
                    .frame(width: WorkbenchBoardChevron.zoneWidth, height: 16)
                    .padding(.top, 8)
                    .frame(minHeight: WorkbenchBoardChevron.zoneWidth, maxHeight: .infinity, alignment: .top)
                    .background(
                        UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8)
                            .fill(chevronHovering ? Color.primary.opacity(0.08) : Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { chevronHovering = $0 }
            .onDisappear { chevronHovering = false }
            .help(isCollapsed ? "Show sub-tasks" : "Hide sub-tasks")
            .accessibilityLabel(isCollapsed ? "Show sub-tasks" : "Hide sub-tasks")
            .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
            .accessibilityIdentifier(WorkbenchBoardChevron.accessibilityID)
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

    private func chips(_ card: WorkbenchBoardCard) -> some View {
        HStack(spacing: 6) {
            Text(WorkbenchTargetNumber.label(target.id))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("Target number — right-click to copy it")
            WorkbenchBoardChip(
                text: target.priority.capitalized,
                color: WorkbenchBoardColors.priority(target.priority),
                dot: true
            )
            WorkbenchBoardChip(
                text: WorkbenchBoardCard.statusLabel(target.status),
                color: WorkbenchBoardColors.status(target.statusColor)
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

extension WorkbenchBoardCardView where Trailing == EmptyView {
    init(
        row: WorkbenchBoardRow,
        isSelected: Bool,
        isCollapsed: Bool,
        caption: String? = nil,
        onToggle: @escaping () -> Void
    ) {
        self.init(row: row, isSelected: isSelected, isCollapsed: isCollapsed, caption: caption, onToggle: onToggle) { _ in
            EmptyView()
        }
    }
}

/// The board card's collapse strip: wide enough to hit without aiming
/// (board #370), and findable by tests.
enum WorkbenchBoardChevron {
    static let zoneWidth: CGFloat = 28
    static let accessibilityID = "workbench-board-card-chevron"
}

/// A small tinted capsule: a card's priority or status, and the detail card's
/// drift findings.
struct WorkbenchBoardChip: View {
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
enum WorkbenchBoardColors {
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

/// A board target's number as the agent writes it (`#163`, board #207), and
/// the copy to the pasteboard behind the card menu and the detail card.
enum WorkbenchTargetNumber {
    static func label(_ id: Int) -> String { "#\(id)" }

    static func copy(_ id: Int) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(label(id), forType: .string)
    }
}

/// The context menu of a board row or kanban card: copy the number, and
/// "Move to…" another target or the top level (board #186).
struct WorkbenchTargetMenu: View {
    let target: Target
    let vm: WorkbenchBoardViewModel

    var body: some View {
        Button("Copy \(WorkbenchTargetNumber.label(target.id))") { WorkbenchTargetNumber.copy(target.id) }
        Divider()
        Menu("Move to") {
            ForEach(WorkbenchBoardOutline.moveDestinations(for: target.id, in: vm.roots)) { row in
                Button(Self.destinationTitle(row)) { vm.move(target.id, under: row.id) }
            }
        }
        Button("Move to Top Level") { vm.move(target.id, under: nil) }
            .disabled(!WorkbenchBoardOutline.canMove(target.id, under: nil, in: vm.roots))
    }

    /// Indented by depth so the menu reads as the board's tree (capped like
    /// the board's own indent).
    private static func destinationTitle(_ row: WorkbenchBoardRow) -> String {
        let title = WorkbenchBoardCard.title(row.node.target.text)
        return String(repeating: "    ", count: min(row.depth, 6))
            + "\(WorkbenchTargetNumber.label(row.id))  \(title.isEmpty ? "Untitled" : title)"
    }
}

/// The list's drag payload (board #186): a prefixed id, so plain text dropped
/// from elsewhere (a number from the terminal) never moves a target.
enum WorkbenchTargetDrag {
    private static let prefix = "watchtower-board-target:"

    static func payload(_ id: Int) -> String { prefix + String(id) }

    static func targetID(_ payload: String) -> Int? {
        guard payload.hasPrefix(prefix) else { return nil }
        return Int(payload.dropFirst(prefix.count))
    }
}
