import SwiftUI

/// The board segment: filter chips (Open, In progress, Blocked, Archive)
/// over the target tree; a row opens the target's detail. New targets the
/// phone sent show on top until the Mac has added them.
struct BoardView: View {
    let replica: WorkbenchReplicaModel
    let writer: BoardWriter
    let workbenchID: Int64
    let now: Date
    @State private var filter = BoardFilter.open
    /// The owner flipped the Done fold from the filter's default (closed
    /// under Open, open under Archive, where every archived target stays
    /// visible); a filter change resets it.
    @State private var doneFlipped = false
    /// Done sub-targets of shown groups under Open (#1191), remembered.
    @AppStorage(ShowDoneButton.storageKey) private var showDoneChildren = false
    @State private var sendError: String?

    var body: some View {
        let board = BoardModel(
            workbenchID: workbenchID, snapshot: replica.snapshot, filter: filter, showDone: showDoneChildren, now: now
        )
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.regular) {
                chips(board)
                ShowDoneButton(doneCount: board.doneChildCount, showDone: $showDoneChildren)
                if !board.pendingCreates.isEmpty {
                    SectionHeader("New targets")
                    writes(board.pendingCreates)
                }
                if !board.unplacedReplies.isEmpty {
                    SectionHeader("Replies")
                    writes(board.unplacedReplies)
                }
                if board.roots.isEmpty {
                    Text(filter == .archive ? "Nothing archived" : "No targets here")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Spacing.small)
                } else {
                    ForEach(BoardLane.lanes(board.roots)) { lane in
                        laneView(lane)
                    }
                }
            }
            .padding(.horizontal, Spacing.large)
            .padding(.bottom, Spacing.large)
        }
        .background(Color(.systemBackground))
        .alert("Couldn't dismiss", isPresented: Binding(get: { sendError != nil }, set: { if !$0 { sendError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(sendError ?? "")
        }
    }

    /// Closed under Open (mockup 5), open under Archive, unless flipped.
    static func doneFoldOpen(flipped: Bool, filter: BoardFilter) -> Bool {
        (filter == .archive) != flipped
    }

    private var showDone: Bool { Self.doneFoldOpen(flipped: doneFlipped, filter: filter) }

    private func writes(_ rows: [BoardWriteRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { CardRowDivider() }
                BoardWriteRowView(row: row, onApplyAnyway: { _ in }, onDismiss: dismiss)
            }
        }
        .card()
    }

    /// A lane (mockup 5): its title and count, then its cards. The done lane
    /// is a fold ("▸ Done 14"), closed until opened.
    @ViewBuilder
    private func laneView(_ lane: BoardLane) -> some View {
        if lane.isDone {
            Button {
                withAnimation(Motion.toggle) { doneFlipped.toggle() }
            } label: {
                HStack(spacing: Spacing.regular) {
                    Image(systemName: showDone ? "chevron.down" : "chevron.right")
                        .font(TypeScale.meta)
                        .frame(width: PhoneMetrics.iconColumn)
                    Text(lane.title).font(TypeScale.laneHeader)
                    Text("\(lane.nodes.count)").font(TypeScale.laneHeader).monospacedDigit().foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(SectionHeader.insets)
                .frame(minHeight: PhoneMetrics.minTouch)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(showDone ? "Expanded" : "Collapsed")
            if showDone {
                ForEach(lane.nodes) { BoardNodeView(node: $0) }
            }
        } else {
            SectionHeader(lane.title, count: lane.nodes.count, style: .lane)
            ForEach(lane.nodes) { BoardNodeView(node: $0) }
        }
    }

    private func dismiss(_ row: BoardWriteRow) {
        do {
            try writer.dismiss(row)
        } catch {
            sendError = BoardWriteText.sendError(error)
        }
    }

    /// B1: the chips in one row when they fit, else a horizontal scroll whose
    /// trailing 24 pt fade shows that they scroll.
    private func chips(_ board: BoardModel) -> some View {
        ViewThatFits(in: .horizontal) {
            chipRow(board)
            ScrollView(.horizontal, showsIndicators: false) {
                chipRow(board)
            }
            .mask {
                HStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: Spacing.wide)
                }
            }
        }
    }

    private func chipRow(_ board: BoardModel) -> some View {
        HStack(spacing: 0) {
            ForEach(BoardFilter.allCases) { chip in
                FilterChip(title: chip.title, count: board.count(chip), isSelected: chip == filter) {
                    filter = chip
                    doneFlipped = false
                }
            }
        }
    }
}

/// One lane of the board: the top-level targets sharing a status or column
/// label, in board order (mockup 5). Presentation only; the tree is the
/// model's.
struct BoardLane: Identifiable, Equatable {
    let title: String
    let nodes: [BoardNode]
    let isDone: Bool

    var id: String { (isDone ? "done:" : "lane:") + title }

    /// Roots grouped by their label, `column ?? status label` (the replica
    /// carries no column order, so lanes follow first-seen board order and a
    /// parent falls into its status lane, not its children's); done roots
    /// share one lane, placed last.
    static func lanes(_ roots: [BoardNode]) -> [Self] {
        var order: [String] = []
        var groups: [String: [BoardNode]] = [:]
        for node in roots where !node.row.isDimmed {
            let title = node.row.statusText
            if groups[title] == nil { order.append(title) }
            groups[title, default: []].append(node)
        }
        var lanes = order.map { Self(title: $0, nodes: groups[$0] ?? [], isDone: false) }
        let done = roots.filter(\.row.isDimmed)
        if !done.isEmpty { lanes.append(Self(title: "Done", nodes: done, isDone: true)) }
        return lanes
    }
}

/// One tree node: a board card; a node with visible children shows them
/// indented under it, and its chevron folds them.
struct BoardNodeView: View {
    let node: BoardNode
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            card
            if node.hasDisclosure, expanded {
                VStack(alignment: .leading, spacing: Spacing.regular) {
                    ForEach(node.children) { Self(node: $0) }
                }
                .padding(.leading, Spacing.large)
            }
        }
    }

    private var card: some View {
        NavigationLink(value: BoardTargetRoute(id: node.id)) {
            BoardCard(model: node.row.card, isDimmed: node.row.isDimmed)
                .padding(.trailing, node.hasDisclosure ? PhoneMetrics.minTouch - Spacing.large : 0)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            if node.hasDisclosure {
                Button {
                    withAnimation(Motion.toggle) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(TypeScale.meta)
                        .foregroundStyle(.secondary)
                        .frame(width: PhoneMetrics.minTouch, height: PhoneMetrics.minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Collapse sub-targets" : "Expand sub-targets")
            }
        }
    }
}
