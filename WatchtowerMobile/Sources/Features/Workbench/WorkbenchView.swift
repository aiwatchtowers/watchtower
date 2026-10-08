import SwiftUI

/// The Workbench tab, level 2: a title switcher over the workbenches, New
/// session (wired with the start flow), the mono subline and the Sessions |
/// Board segment. Sessions holds the Waiting-for-you stack, its closed asks
/// and the SESSIONS list. Read-only.
struct WorkbenchView: View {
    enum Segment: String, CaseIterable, Identifiable {
        case sessions = "Sessions"
        case board = "Board"

        var id: Self { self }
    }

    let replica: WorkbenchReplicaModel
    @State private var workbenchID: Int64
    @State private var segment = Segment.sessions
    @State private var showClosed = false

    init(replica: WorkbenchReplicaModel, workbenchID: Int64) {
        self.replica = replica
        _workbenchID = State(initialValue: workbenchID)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let menu = WorkbenchMenuModel(workbenchID: workbenchID, snapshot: replica.snapshot, now: context.date) {
                content(menu)
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
                // Starting a session and adding a target from the phone come
                // with their own flows; until then the button is disabled.
                Button {} label: {
                    Label(segment == .board ? "New target" : "New session", systemImage: "plus")
                }
                .disabled(true)
            }
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

    private func content(_ menu: WorkbenchMenuModel) -> some View {
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
            case .board: BoardView(replica: replica, workbenchID: menu.id)
            }
        }
    }

    private func sessions(_ menu: WorkbenchMenuModel) -> some View {
        List {
            if !menu.waiting.isEmpty || menu.closedLabel != nil {
                Section {
                    ForEach(menu.waiting) { card in
                        WaitingCardView(card: card)
                            .listRowSeparator(.hidden)
                    }
                    if let closed = menu.closedLabel {
                        DisclosureGroup(closed, isExpanded: $showClosed) {
                            ForEach(menu.closedAsks) { ask in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ask.title).font(.subheadline)
                                    Text(ask.status.rawValue.capitalized)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
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
