import SwiftUI

/// The board segment (#1781): a search field, one row of quick filters
/// (Waiting for me, Sessions running, High, Blocked, All, Done, Archive)
/// over the target tree in the owner's lanes; a row opens the target's
/// detail. New targets the phone sent show on top until the Mac has added
/// them.
struct BoardView: View {
    let replica: WorkbenchReplicaModel
    let writer: BoardWriter
    let workbenchID: Int64
    let now: Date
    @Environment(AppEnvironment.self) private var env
    /// The owner's chip; nil = the opening filter (`BoardFilter.opening`).
    @State private var chosen: BoardFilter?
    @State private var query: String
    @State private var sendError: String?

    init(
        replica: WorkbenchReplicaModel,
        writer: BoardWriter,
        workbenchID: Int64,
        now: Date,
        filter: BoardFilter? = nil,
        query: String = ""
    ) {
        self.replica = replica
        self.writer = writer
        self.workbenchID = workbenchID
        self.now = now
        _chosen = State(initialValue: filter)
        _query = State(initialValue: query)
    }

    var body: some View {
        let board = BoardModel(workbenchID: workbenchID, snapshot: replica.snapshot, filter: chosen, query: query, now: now)
        let folds = board.folds ? env.boardFolds.folds(hubID: env.activeHubID, workbenchID: workbenchID) : nil
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.regular) {
                BoardSearchField(query: $query)
                if board.isSearching {
                    Text(board.searchCaption)
                        .font(TypeScale.meta)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Spacing.small)
                } else {
                    chips(board)
                }
                if !board.pendingCreates.isEmpty {
                    SectionHeader("New targets")
                    writes(board.pendingCreates)
                }
                if !board.unplacedReplies.isEmpty {
                    SectionHeader("Replies")
                    writes(board.unplacedReplies)
                }
                if let empty = board.emptyText {
                    Text(empty)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Spacing.small)
                }
                ForEach(board.lanes) { lane in
                    laneView(lane, folds: folds)
                }
            }
            .padding(.horizontal, Spacing.large)
            .padding(.bottom, Spacing.large)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(Color(.systemBackground))
        .alert("Couldn't dismiss", isPresented: Binding(get: { sendError != nil }, set: { if !$0 { sendError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(sendError ?? "")
        }
    }

    private func writes(_ rows: [BoardWriteRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { CardRowDivider() }
                BoardWriteRowView(row: row, onApplyAnyway: { _ in }, onDismiss: dismiss)
            }
        }
        .card()
    }

    /// A lane (mockup 5): its title and count, then its cards. Under All
    /// (`folds` set) the header folds the lane, remembered; Backlog and Done
    /// start folded.
    @ViewBuilder
    private func laneView(_ lane: BoardLane, folds: BoardFolds?) -> some View {
        if let folds {
            let isOpen = folds.isLaneOpen(lane)
            Button {
                withAnimation(Motion.toggle) { updateFolds { $0.toggleLane(lane) } }
            } label: {
                HStack(spacing: Spacing.regular) {
                    Text(lane.title).font(TypeScale.laneHeader).foregroundStyle(.primary)
                    Text("\(lane.nodes.count)").font(TypeScale.laneHeader).monospacedDigit().foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(TypeScale.meta)
                        .foregroundStyle(.secondary)
                }
                .padding(SectionHeader.insets)
                .frame(minHeight: PhoneMetrics.minTouch)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(SectionHeader.spokenLabel(lane.title, count: lane.nodes.count))
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
            if isOpen {
                ForEach(lane.nodes) { BoardNodeView(node: $0, folds: folds, onToggle: toggleGroup) }
            }
        } else {
            SectionHeader(lane.title, count: lane.nodes.count, style: .lane)
            ForEach(lane.nodes) { BoardNodeView(node: $0, folds: nil, onToggle: toggleGroup) }
        }
    }

    private func toggleGroup(_ id: Int64) {
        withAnimation(Motion.toggle) { updateFolds { $0.toggleGroup(id) } }
    }

    private func updateFolds(_ change: (inout BoardFolds) -> Void) {
        env.boardFolds.update(hubID: env.activeHubID, workbenchID: workbenchID, change)
    }

    private func dismiss(_ row: BoardWriteRow) {
        do {
            try writer.dismiss(row)
        } catch {
            sendError = BoardWriteText.sendError(error)
        }
    }

    /// B1: the chips in one row when they fit, else a horizontal scroll whose
    /// trailing 24 pt fade shows that they scroll; the shown filter is
    /// scrolled into view (#1781: the opening filter may be off the edge).
    private func chips(_ board: BoardModel) -> some View {
        ViewThatFits(in: .horizontal) {
            chipRow(board)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    chipRow(board)
                }
                .onAppear { proxy.scrollTo(board.filter, anchor: .center) }
                .onChange(of: board.filter) { _, shown in
                    withAnimation(Motion.toggle) { proxy.scrollTo(shown, anchor: .center) }
                }
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
                FilterChip(title: chip.title, count: board.count(chip), isSelected: chip == board.filter) {
                    chosen = chip
                }
                .id(chip)
            }
        }
    }
}

/// The board's search field: title, #number or branch (#1781); ✕ clears it.
private struct BoardSearchField: View {
    @Binding var query: String

    var body: some View {
        let field = RoundedRectangle(cornerRadius: Radius.pill, style: .continuous)
        HStack(spacing: Spacing.small) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(BoardModel.searchPrompt, text: $query)
                .font(TypeScale.rowTitle)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .frame(minHeight: PhoneMetrics.minTouch)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: PhoneMetrics.minTouch, height: PhoneMetrics.minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, Spacing.medium)
        .background(Fill.card, in: field)
        .overlay(field.strokeBorder(Stroke.hairlineColor, lineWidth: Stroke.hairline))
    }
}

/// One tree node: a board card; a node with visible children shows them
/// indented under it. Under All (`folds` set) its chevron folds them,
/// remembered, folded until opened; elsewhere every match shows open.
struct BoardNodeView: View {
    let node: BoardNode
    let folds: BoardFolds?
    let onToggle: (Int64) -> Void

    private var isOpen: Bool { folds?.isGroupOpen(node.id) ?? true }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            card
            if node.hasDisclosure, isOpen {
                VStack(alignment: .leading, spacing: Spacing.regular) {
                    ForEach(node.children) { Self(node: $0, folds: folds, onToggle: onToggle) }
                }
                .padding(.leading, Spacing.large)
            }
        }
    }

    private var foldable: Bool { node.hasDisclosure && folds != nil }

    private var card: some View {
        NavigationLink(value: BoardTargetRoute(id: node.id)) {
            BoardCard(model: node.card, isDimmed: node.isDimmed)
                .padding(.trailing, foldable ? PhoneMetrics.minTouch - Spacing.large : 0)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            if foldable {
                Button {
                    onToggle(node.id)
                } label: {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(TypeScale.meta)
                        .foregroundStyle(.secondary)
                        .frame(width: PhoneMetrics.minTouch, height: PhoneMetrics.minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isOpen ? "Collapse sub-targets" : "Expand sub-targets")
            }
        }
    }
}
