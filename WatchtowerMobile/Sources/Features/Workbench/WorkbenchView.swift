import SwiftUI

/// The Workbench tab, level 2: a title switcher over the workbenches, New
/// session (the start sheet with a target picker), the branch and board counts and the
/// Sessions | Board segment. Sessions holds the Waiting-for-you stack, its closed asks
/// and the SESSIONS list. On Board, + opens New target.
struct WorkbenchView: View {
    enum Segment: String, CaseIterable, Identifiable {
        case sessions = "Sessions"
        case board = "Board"

        var id: Self { self }
    }

    @Environment(AppEnvironment.self) private var env
    let replica: WorkbenchReplicaModel
    let writer: BoardWriter
    @State private var workbenchID: Int64
    @State private var segment: Segment
    @State private var showClosed = false
    @State private var addingTarget = false
    @State private var startingSession = false
    @State private var openSession: SessionRoute?

    /// `segment` is for the screenshot tour; the app always opens Sessions.
    init(replica: WorkbenchReplicaModel, writer: BoardWriter, workbenchID: Int64, segment: Segment = .sessions) {
        self.replica = replica
        self.writer = writer
        _workbenchID = State(initialValue: workbenchID)
        _segment = State(initialValue: segment)
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
                Button {
                    if segment == .board {
                        addingTarget = true
                    } else {
                        startingSession = true
                    }
                } label: {
                    Label(segment == .board ? "New target" : "New session", systemImage: "plus")
                }
                .disabled(replica.snapshot.workbench(workbenchID) == nil)
            }
        }
        .sheet(isPresented: $addingTarget) {
            NewBoardTargetSheet(replica: replica, writer: writer, workbenchID: workbenchID)
        }
        .sheet(isPresented: $startingSession) {
            StartSessionSheet(workbenchID: workbenchID, target: nil, fixed: false) { openSession = SessionRoute(id: $0) }
        }
        .navigationDestination(item: $openSession) { route in
            SessionDetailView(replica: replica, sessionID: route.id, store: env.store, requester: env.reportRequests)
        }
        .navigationDestination(for: SessionChatRoute.self) { route in
            SessionChatView(replica: replica, route: route, store: env.store, requester: env.chatRequests)
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
            HStack(spacing: Spacing.regular) {
                if let branch = menu.branch {
                    Pill(text: branch, style: .neutral, monospaced: true)
                }
                MetaLine(items: menu.boardCounts).font(TypeScale.meta)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.large)
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

    /// Sessions (design pass S2, S3): a `ScrollView`, so each ask row of the
    /// waiting card is its own link.
    private func sessions(_ menu: WorkbenchMenuModel) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !menu.waiting.isEmpty {
                    SectionHeader(menu.waitingHeader, tone: menu.waitingHeaderTone)
                    WaitingStack(asks: menu.waiting)
                        .padding(.horizontal, Spacing.large)
                }
                if let closed = menu.closedLabel {
                    DisclosureGroup(closed, isExpanded: $showClosed) {
                        ForEach(menu.closedAsks) { ask in
                            NavigationLink(value: AskRoute(id: ask.id)) {
                                VStack(alignment: .leading, spacing: Spacing.tight) {
                                    Text(ask.title).font(TypeScale.rowTitle).foregroundStyle(.primary)
                                    Text(AskText.status(ask)).font(TypeScale.meta).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .font(TypeScale.meta)
                    .foregroundStyle(.secondary)
                    .padding(RowInsets.flat)
                }
                SectionHeader("Sessions")
                if let empty = menu.sessionsEmptyText {
                    Text(empty).foregroundStyle(.secondary).padding(.horizontal, Spacing.large)
                } else {
                    ForEach(Array(menu.sessions.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            RowDivider()
                        }
                        NavigationLink(value: SessionRoute(id: row.id)) { SessionRowView(row: row) }
                            .buttonStyle(.plain)
                    }
                }
            }
            .padding(.bottom, Spacing.large)
        }
        .background(Color(.systemBackground))
    }
}
