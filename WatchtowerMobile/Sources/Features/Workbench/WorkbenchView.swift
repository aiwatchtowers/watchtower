import SwiftUI

/// The Workbench tab, level 2: a title switcher over the workbenches, New
/// session (wired with the start flow), the mono subline and the Sessions |
/// Board segment. Sessions holds the Waiting-for-you stack, its closed asks
/// and the SESSIONS list. On Board, + opens New target.
struct WorkbenchView: View {
    enum Segment: String, CaseIterable, Identifiable {
        case sessions = "Sessions"
        case board = "Board"

        var id: Self { self }
    }

    let replica: WorkbenchReplicaModel
    let writer: BoardWriter
    @State private var workbenchID: Int64
    @State private var segment = Segment.sessions
    @State private var showClosed = false
    @State private var addingTarget = false

    init(replica: WorkbenchReplicaModel, writer: BoardWriter, workbenchID: Int64) {
        self.replica = replica
        self.writer = writer
        _workbenchID = State(initialValue: workbenchID)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let menu = WorkbenchMenuModel(workbenchID: workbenchID, snapshot: replica.snapshot, now: context.date) {
                content(menu, now: context.date)
            } else {
                ContentUnavailableView(
                    "Workbench not found",
                    systemImage: "hammer",
                    description: Text("It was removed on your Mac.")
                )
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { switcher }
            ToolbarItem(placement: .topBarTrailing) {
                // Starting a session from the phone comes with its own
                // flow; until then New session is disabled.
                Button {
                    addingTarget = true
                } label: {
                    Label(segment == .board ? "New target" : "New session", systemImage: "plus")
                }
                .disabled(segment != .board || replica.snapshot.workbench(workbenchID) == nil)
            }
        }
        .sheet(isPresented: $addingTarget) {
            NewBoardTargetSheet(replica: replica, writer: writer, workbenchID: workbenchID)
        }
    }

    private var switcher: some View {
        Menu {
            Picker("Workbench", selection: $workbenchID) {
                ForEach(replica.snapshot.orderedWorkbenches) { workbench in
                    Text(workbench.name).tag(workbench.id)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(replica.snapshot.workbench(workbenchID)?.name ?? "Workbench")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("Switch workbench")
    }

    private func content(_ menu: WorkbenchMenuModel, now: Date) -> some View {
        VStack(spacing: 8) {
            Text(menu.subline)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Picker("View", selection: $segment) {
                ForEach(Segment.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            switch segment {
            case .sessions: sessions(menu)
            case .board: BoardView(replica: replica, writer: writer, workbenchID: menu.id, now: now)
            }
        }
    }

    private func sessions(_ menu: WorkbenchMenuModel) -> some View {
        List {
            if !menu.waiting.isEmpty || menu.closedLabel != nil {
                Section {
                    ForEach(menu.waiting) { card in
                        NavigationLink(value: AskRoute(id: card.id)) { WaitingCardView(card: card) }
                            .listRowSeparator(.hidden)
                    }
                    if let closed = menu.closedLabel {
                        DisclosureGroup(closed, isExpanded: $showClosed) {
                            ForEach(menu.closedAsks) { ask in
                                NavigationLink(value: AskRoute(id: ask.id)) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(ask.title).font(.subheadline).foregroundStyle(.primary)
                                        Text(AskText.status(ask))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(menu.waitingHeader)
                        .foregroundStyle(menu.waitingHeaderTone.color)
                }
            }
            Section("Sessions") {
                if let empty = menu.sessionsEmptyText {
                    Text(empty).foregroundStyle(.secondary)
                } else {
                    ForEach(menu.sessions) { row in
                        NavigationLink(value: SessionRoute(id: row.id)) { SessionRowView(row: row) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}
