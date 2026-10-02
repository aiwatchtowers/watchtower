import SwiftUI
import WatchtowerCore

/// The Board pane's kanban mode: leaf targets in status columns. Clicking a
/// card selects it (the detail pane is shared with the list mode); dragging a
/// card to another column sets its status through the same writer the status
/// menu uses. The menu stays the keyboard/accessibility path.
struct ProjectBoardKanbanView: View {
    let board: ProjectBoardKanban
    let selectedTargetID: Int?
    let onSelect: (Int) -> Void
    /// Returns whether the status was written.
    let onMove: (_ targetID: Int, _ status: String) -> Bool

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(board.columns) { column in
                    ProjectBoardKanbanColumnView(
                        column: column,
                        selectedTargetID: selectedTargetID,
                        onSelect: onSelect
                    ) { id, status in
                        // Only this board's own cards move; see showsCard.
                        board.showsCard(id) && onMove(id, status)
                    }
                }
            }
            .padding(10)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct ProjectBoardKanbanColumnView: View {
    let column: ProjectBoardKanban.Column
    let selectedTargetID: Int?
    let onSelect: (Int) -> Void
    let onMove: (_ targetID: Int, _ status: String) -> Bool

    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(column.title).font(.subheadline.weight(.semibold))
                Text("\(column.cards.count + column.hiddenCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(column.cards) { card in
                        ProjectBoardCardView(
                            row: card.row,
                            isSelected: selectedTargetID == card.id,
                            isCollapsed: false,
                            caption: card.breadcrumb.isEmpty ? nil : card.breadcrumb,
                            onToggle: {},
                            trailing: { hovering in
                                WorkOnTargetButton(target: card.row.node.target, compact: true,
                                                   isVisible: hovering || selectedTargetID == card.id)
                            }
                        )
                        .onTapGesture { onSelect(card.id) }
                        .draggable(String(card.id))
                    }
                    if column.hiddenCount > 0 {
                        Text("\(column.hiddenCount) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Turn on Show done to see every done target")
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .frame(width: 250)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isTargeted ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isTargeted ? Color.accentColor : .clear, lineWidth: 1.5)
        )
        .modifier(DropTarget(column: column, isTargeted: $isTargeted, onMove: onMove))
    }
}

/// A column takes drops only when it stands for one status (not Other).
private struct DropTarget: ViewModifier {
    let column: ProjectBoardKanban.Column
    @Binding var isTargeted: Bool
    let onMove: (_ targetID: Int, _ status: String) -> Bool

    func body(content: Content) -> some View {
        if column.acceptsDrops {
            content.dropDestination(for: String.self) { items, _ in
                // Every id is attempted; the drop succeeds if any moved.
                let moved = items.compactMap(Int.init).filter { onMove($0, column.status) }
                return !moved.isEmpty
            } isTargeted: { isTargeted = $0 }
        } else {
            content
        }
    }
}
