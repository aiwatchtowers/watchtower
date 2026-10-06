import SwiftUI
import WatchtowerCore

/// The Board pane's kanban mode: leaf targets in status columns, either one
/// lane per top-level group under a totals row ("Lanes: By group", spec
/// 2026-10-06 Part 2) or the flat columns ("Lanes: None"). Clicking a card
/// selects it (the detail pane is shared with the list mode); dragging a card
/// to another column sets its status through the same writer the status menu
/// uses. The menu stays the keyboard/accessibility path.
struct WorkbenchBoardKanbanView: View {
    let board: WorkbenchBoardKanban
    /// For the cards' context menu (copy the number, Move to…) and the
    /// lanes' fold state.
    let vm: WorkbenchBoardViewModel
    let selectedTargetID: Int?
    let onSelect: (Int) -> Void
    /// A lane header double-click: enter that group (spec 2026-10-06 Part 4).
    let onEnter: (Int) -> Void
    /// Returns whether the status was written.
    let onMove: (_ targetID: Int, _ status: String) -> Bool

    var body: some View {
        switch vm.kanbanLayout {
        case .columns: columns
        case .lanes: lanes
        }
    }

    private var columns: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: WorkbenchBoardKanbanLayout.spacing) {
                ForEach(board.columns) { column in
                    WorkbenchBoardKanbanColumnView(
                        column: column,
                        vm: vm,
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

    private var lanes: some View {
        let folded = vm.foldedLaneIDs(in: board.lanes)
        return ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 12, pinnedViews: [.sectionHeaders]) {
                Section {
                    if board.lanes.isEmpty {
                        Text(WorkbenchBoardSearch(vm.searchText) == nil
                             ? vm.emptyBoardText
                             : "No targets match the search.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }
                    ForEach(board.lanes) { lane in
                        WorkbenchBoardKanbanLaneView(
                            lane: lane,
                            columnCount: board.columns.count,
                            isFolded: folded.contains(lane.id),
                            isDoneUnfolded: vm.unfoldedDoneLanes.contains(lane.id),
                            // The scope's own Tasks lane would re-enter the scope.
                            entersGroup: lane.root != nil && lane.id != board.scopeID,
                            vm: vm,
                            selectedTargetID: selectedTargetID,
                            onSelect: onSelect,
                            onEnter: onEnter
                        ) { id, status in
                            // A card moves only within its own lane.
                            lane.showsCard(id) && onMove(id, status)
                        }
                    }
                } header: {
                    totals
                }
            }
            .padding(10)
        }
    }

    /// The column titles and, per column, the cards over the lanes shown —
    /// a folded lane's and a folded Done's included.
    private var totals: some View {
        HStack(spacing: WorkbenchBoardKanbanLayout.spacing) {
            ForEach(board.columns) { column in
                HStack {
                    Text(column.title).font(.subheadline.weight(.semibold))
                    Text("\(board.totals[column.status] ?? 0)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(width: WorkbenchBoardKanbanLayout.columnWidth)
            }
        }
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Shared column geometry, so the lanes line up under the totals row.
private enum WorkbenchBoardKanbanLayout {
    static let columnWidth: CGFloat = 250
    static let spacing: CGFloat = 10

    static func width(columns: Int) -> CGFloat {
        CGFloat(columns) * columnWidth + CGFloat(max(columns - 1, 0)) * spacing
    }
}

/// One lane: a header (fold chevron, `#id`, title, progress, status) over the
/// board's columns filled with this lane's cards. Clicking the header opens
/// the group in the panel, a double-click enters it; the chevron folds the
/// lane.
private struct WorkbenchBoardKanbanLaneView: View {
    let lane: WorkbenchBoardKanban.Lane
    let columnCount: Int
    let isFolded: Bool
    let isDoneUnfolded: Bool
    /// A double-click enters the lane's group: not for No group, nor for
    /// the scope's own Tasks lane.
    let entersGroup: Bool
    let vm: WorkbenchBoardViewModel
    let selectedTargetID: Int?
    let onSelect: (Int) -> Void
    let onEnter: (Int) -> Void
    let onMove: (_ targetID: Int, _ status: String) -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if !isFolded {
                // Judged with the Done fold closed, as Core keeps the lane;
                // the fold's own link stays, so its done cards are one click away.
                if !lane.hasVisibleCards, !isDoneUnfolded {
                    HStack(spacing: 12) {
                        Text("No open tasks")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if lane.doneFolded, lane.doneCount > 0 {
                            Button("✓ \(lane.doneCount) done — show") { vm.toggleLaneDone(lane.id) }
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                    }
                    .padding(.leading, WorkbenchBoardChevron.zoneWidth)
                } else {
                    HStack(alignment: .top, spacing: WorkbenchBoardKanbanLayout.spacing) {
                        ForEach(lane.columns) { column in
                            WorkbenchBoardKanbanLaneCellView(
                                lane: lane,
                                column: column,
                                isDoneUnfolded: isDoneUnfolded,
                                vm: vm,
                                selectedTargetID: selectedTargetID,
                                onSelect: onSelect,
                                onMove: onMove
                            )
                        }
                    }
                    // Every cell as tall as the lane's tallest: an empty
                    // column is a drop target over the whole lane height.
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { vm.toggleLane(lane.id) } label: {
                Image(systemName: isFolded ? "chevron.right" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: WorkbenchBoardChevron.zoneWidth, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isFolded ? "Show this lane" : "Fold this lane")
            .accessibilityLabel(isFolded ? "Show lane" : "Fold lane")
            .accessibilityValue(isFolded ? "Folded" : "Expanded")
            summary
        }
        .padding(.vertical, 4)
        .padding(.trailing, 10)
        .frame(width: WorkbenchBoardKanbanLayout.width(columns: columnCount), alignment: .leading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Everything right of the chevron; for a group lane a click opens the
    /// group in the panel, a double-click enters it. Both are actions for
    /// VoiceOver too.
    @ViewBuilder
    private var summary: some View {
        let content = HStack(spacing: 8) {
            if let root = lane.root {
                Text(WorkbenchTargetNumber.label(root.target.id))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(lane.title.isEmpty ? "Untitled" : lane.title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            progress
            if let root = lane.root {
                WorkbenchBoardChip(
                    text: WorkbenchBoardCard.statusLabel(root.target.status),
                    color: WorkbenchBoardColors.status(root.target.statusColor)
                )
            }
            Spacer(minLength: 0)
        }
        if let root = lane.root {
            let id = root.target.id
            // Simultaneous, not `onTapGesture(count: 2)` ahead of the single
            // tap: that would hold every single click until the double-click
            // interval passed.
            content
                .contentShape(Rectangle())
                .onTapGesture { vm.select(id) }
                .simultaneousGesture(TapGesture(count: 2).onEnded { if entersGroup { onEnter(id) } })
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { vm.select(id) }
                .accessibilityActions {
                    if entersGroup {
                        Button("Open Group") { onEnter(id) }
                    }
                }
                .help(entersGroup
                      ? "Open \(WorkbenchTargetNumber.label(id)); double-click to show only this group"
                      : "Open \(WorkbenchTargetNumber.label(id))")
        } else {
            content
        }
    }

    private var progress: some View {
        let progress = lane.progress
        return HStack(spacing: 6) {
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                .progressViewStyle(.linear)
                .controlSize(.small)
                .tint(progress.total > 0 && progress.done == progress.total ? .green : .accentColor)
                .frame(width: 80)
            Text("\(progress.done)/\(progress.total)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .help("Tasks done in this group")
    }
}

/// One column of a lane: its cards, no title (the totals row has it), and in
/// Done the per-lane fold.
private struct WorkbenchBoardKanbanLaneCellView: View {
    let lane: WorkbenchBoardKanban.Lane
    let column: WorkbenchBoardKanban.Column
    let isDoneUnfolded: Bool
    let vm: WorkbenchBoardViewModel
    let selectedTargetID: Int?
    let onSelect: (Int) -> Void
    let onMove: (_ targetID: Int, _ status: String) -> Bool

    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WorkbenchBoardKanbanCards(
                cards: lane.cards(column, unfolded: isDoneUnfolded),
                vm: vm,
                selectedTargetID: selectedTargetID,
                onSelect: onSelect
            )
            if column.status == "done", lane.doneFolded, lane.doneCount > 0 {
                Button(isDoneUnfolded ? "Hide done" : "✓ \(lane.doneCount) done — show") {
                    vm.toggleLaneDone(lane.id)
                }
                .buttonStyle(.link)
                .font(.caption)
                .padding(.horizontal, 4)
            }
        }
        .padding(8)
        .frame(width: WorkbenchBoardKanbanLayout.columnWidth, alignment: .topLeading)
        .frame(minHeight: 44, maxHeight: .infinity, alignment: .top)
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

private struct WorkbenchBoardKanbanColumnView: View {
    let column: WorkbenchBoardKanban.Column
    let vm: WorkbenchBoardViewModel
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
                    WorkbenchBoardKanbanCards(
                        cards: column.cards, vm: vm, selectedTargetID: selectedTargetID, onSelect: onSelect
                    )
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
        .frame(width: WorkbenchBoardKanbanLayout.columnWidth)
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

/// A column's cards, title and breadcrumb wrapped in full.
private struct WorkbenchBoardKanbanCards: View {
    let cards: [WorkbenchBoardKanban.Card]
    let vm: WorkbenchBoardViewModel
    let selectedTargetID: Int?
    let onSelect: (Int) -> Void

    var body: some View {
        ForEach(cards) { card in
            WorkbenchBoardCardView(
                row: card.row,
                isSelected: selectedTargetID == card.id,
                isCollapsed: false,
                caption: card.breadcrumb.isEmpty ? nil : card.breadcrumb,
                wrapsText: true,
                onToggle: {},
                trailing: { hovering in
                    WorkOnTargetButton(target: card.row.node.target, compact: true,
                                       isVisible: hovering || selectedTargetID == card.id)
                }
            )
            .onTapGesture { onSelect(card.id) }
            .contextMenu { WorkbenchTargetMenu(target: card.row.node.target, vm: vm) }
            .draggable(String(card.id))
        }
    }
}

/// A column takes drops only when it stands for one status (not Other).
private struct DropTarget: ViewModifier {
    let column: WorkbenchBoardKanban.Column
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
