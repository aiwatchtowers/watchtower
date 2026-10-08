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
        .listStyle(.insetGrouped)
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

    private func chips(_ board: BoardModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(BoardFilter.allCases) { chip in
                    let title = board.count(chip).map { "\(chip.title) \($0)" } ?? chip.title
                    Button(title) { filter = chip }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .tint(chip == filter ? .accentColor : .secondary)
                }
            }
            .padding(.vertical, 6)
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
    }
}

/// A board row: status glyph, title, sub-line, priority and progress.
struct BoardRowView: View {
    let row: BoardRowModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: row.statusGlyph)
                .foregroundStyle(row.statusTone.color)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .lineLimit(2)
                    .foregroundStyle(row.isDimmed ? .secondary : .primary)
                if !row.details.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(row.details.enumerated()), id: \.offset) { index, detail in
                            if index > 0 {
                                Text("·").foregroundStyle(.secondary)
                            }
                            Text(detail.text).foregroundStyle(detail.tone.color)
                        }
                    }
                    .font(.caption)
                    .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                if let priority = row.priorityLabel {
                    Text(priority)
                        .font(.caption2.monospaced().weight(.semibold))
                        .foregroundStyle(row.priorityTone.color)
                }
                if let progress = row.progressText {
                    Text(progress)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
