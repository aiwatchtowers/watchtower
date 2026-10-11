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
    @State private var sendError: String?

    var body: some View {
        let board = BoardModel(workbenchID: workbenchID, snapshot: replica.snapshot, filter: filter, now: now)
        List {
            if !board.pendingCreates.isEmpty {
                Section("New targets") {
                    ForEach(board.pendingCreates) { row in
                        BoardWriteRowView(row: row, onApplyAnyway: { _ in }, onDismiss: dismiss)
                    }
                }
            }
            if !board.unplacedReplies.isEmpty {
                Section("Replies") {
                    ForEach(board.unplacedReplies) { row in
                        BoardWriteRowView(row: row, onApplyAnyway: { _ in }, onDismiss: dismiss)
                    }
                }
            }
            Section {
                if board.roots.isEmpty {
                    Text(filter == .archive ? "Nothing archived" : "No targets here")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(board.roots) { BoardNodeView(node: $0) }
                }
            } header: {
                chips(board)
                    .textCase(nil)
                    .listRowInsets(EdgeInsets())
            }
        }
        .listStyle(.plain)
        .alert("Couldn't dismiss", isPresented: Binding(get: { sendError != nil }, set: { if !$0 { sendError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(sendError ?? "")
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
            chipRow(board).padding(.horizontal, Spacing.large)
            ScrollView(.horizontal, showsIndicators: false) {
                chipRow(board).padding(.horizontal, Spacing.large)
            }
            .mask {
                HStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 24)
                }
            }
        }
    }

    private func chipRow(_ board: BoardModel) -> some View {
        HStack(spacing: Spacing.compact) {
            ForEach(BoardFilter.allCases) { chip in
                FilterChip(title: chip.title, count: board.count(chip), isSelected: chip == filter) { filter = chip }
            }
        }
    }
}

/// One tree node: a disclosure when it has visible children, else a row.
struct BoardNodeView: View {
    let node: BoardNode
    @State private var expanded = true

    var body: some View {
        if node.hasDisclosure {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(node.children) { Self(node: $0) }
            } label: {
                link
            }
        } else {
            link
        }
    }

    private var link: some View {
        NavigationLink(value: BoardTargetRoute(id: node.id)) {
            BoardRowView(row: node.row)
        }
        .listRowInsets(RowInsets.flat)
    }
}

/// A board row (design pass B2): the status glyph in its tone, the title (two
/// lines; struck through and secondary when done), a meta line with the
/// priority dot first, and a thin bar under it when the progress is a
/// percent. Nothing on the right but the list's chevron.
struct BoardRowView: View {
    let row: BoardRowModel

    var body: some View {
        FlatRow(icon: .symbol(row.statusGlyph, tone: row.statusTone), title: row.title, isDimmed: row.isDimmed, insets: EdgeInsets()) {
            if row.hasMeta {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    HStack(spacing: Spacing.compact) {
                        PriorityDot(priority: row.priority)
                        MetaLine(items: row.details)
                    }
                    if let value = row.progressValue {
                        ThinProgressBar(value: value, tone: row.progressTone, height: 3).frame(width: 64)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(row.statusText)
    }
}
