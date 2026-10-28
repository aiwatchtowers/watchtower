import SwiftUI

/// The Workbench tab, level 2: a title switcher over the workbenches, New
/// session (the start sheet with a target picker), the branch and board counts and the
/// Sessions | Board segment. Sessions lists the workbench's sessions in the Desktop
/// panel's order (mockup 2), with the closed asks folded at the end. On Board, +
/// opens New target.
struct WorkbenchView: View {
    enum Segment: String, CaseIterable, Identifiable {
        case sessions = "Sessions"
        case board = "Board"
        /// Only when the workbench has automations (ask #692).
        case automations = "Automations"

        var id: Self { self }
    }

    @Environment(AppEnvironment.self) private var env
    let replica: WorkbenchReplicaModel
    let writer: BoardWriter
    @State private var workbenchID: Int64
    @State private var segment: Segment
    @State private var showClosed = false
    @State private var showFinished = false
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
            if let menu = menu(at: context.date) {
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
        // Another workbench, or the last automation removed, leaves no Automations segment.
        .onChange(of: segments) { if !segments.contains(segment) { segment = .sessions } }
        .toolbar {
            ToolbarItem(placement: .principal) { switcher }
            // Automations only runs what the Mac has: nothing to add there.
            if segment != .automations {
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
        }
        .sheet(isPresented: $addingTarget) {
            NewBoardTargetSheet(replica: replica, writer: writer, workbenchID: workbenchID)
        }
        .sheet(isPresented: $startingSession) {
            StartSessionSheet(workbenchID: workbenchID, target: nil, fixed: false) { openSession = SessionRoute(id: $0) }
        }
        .navigationDestination(item: $openSession) { route in
            WorkchatView(replica: replica, sessionID: route.id, store: env.store, requester: env.chatRequests)
        }
    }

    /// Automations shows only when the workbench has some.
    private var segments: [Segment] {
        let automations = replica.snapshot.workbench(workbenchID)?.automations ?? []
        return automations.isEmpty ? [.sessions, .board] : Segment.allCases
    }

    private func menu(at date: Date) -> WorkbenchMenuModel? {
        WorkbenchMenuModel(
            workbenchID: workbenchID, snapshot: replica.snapshot, now: date, asOf: env.macReachability(now: date).asOf
        )
    }

    private var switcher: some View {
        Menu {
            Picker("Workbench", selection: $workbenchID) {
                ForEach(replica.snapshot.orderedWorkbenches) { workbench in
                    Text(workbench.name).tag(workbench.id)
                }
            }
        } label: {
            HStack(spacing: Spacing.small) {
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
        VStack(spacing: Spacing.regular) {
            HStack(spacing: Spacing.regular) {
                if let branch = menu.branch {
                    Pill(text: branch, style: .neutral, monospaced: true)
                }
                MetaLine(items: menu.boardCounts).font(TypeScale.meta)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.large)
            Picker("View", selection: $segment) {
                ForEach(segments) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Spacing.large)
            switch segment {
            // The working timers tick each second; the rest follows the
            // minute timeline.
            case .sessions:
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    sessions(self.menu(at: context.date) ?? menu)
                }
            case .board: BoardView(replica: replica, writer: writer, workbenchID: menu.id, now: now)
            case .automations: WorkbenchAutomationsView(replica: replica, writer: writer, workbenchID: menu.id, now: now)
            }
        }
    }

    /// Sessions (spec §5.5, mockup 2): one card per section, the finished
    /// fold, then the closed asks. A `ScrollView`, so each row is its own
    /// link.
    private func sessions(_ menu: WorkbenchMenuModel) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !menu.unattachedAsks.isEmpty {
                    SectionHeader("Asks", count: menu.unattachedAsks.count, tone: .waitingForYou)
                    WaitingStack(asks: menu.unattachedAsks)
                }
                if let empty = menu.sessionsEmptyText {
                    Text(empty).foregroundStyle(.secondary).padding(.top, Spacing.large)
                }
                ForEach(menu.sections) { section in
                    SectionHeader(section.title, count: section.rows.count, tone: section.tone)
                    SessionCard(rows: section.rows)
                }
                if let finished = menu.finishedLabel {
                    DisclosureGroup(finished, isExpanded: $showFinished) {
                        SessionCard(rows: menu.finished)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.small)
                    .padding(.top, Spacing.medium)
                }
                if let closed = menu.closedLabel {
                    DisclosureGroup(closed, isExpanded: $showClosed) {
                        ForEach(menu.closedAsks) { ask in
                            NavigationLink(value: AskRoute(id: ask.id)) {
                                VStack(alignment: .leading, spacing: Spacing.tight) {
                                    Text(ask.title).font(TypeScale.rowTitle).foregroundStyle(.primary)
                                    Text(AskText.status(ask)).font(TypeScale.meta).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, minHeight: PhoneMetrics.minTouch, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.small)
                    .padding(.top, Spacing.medium)
                }
            }
            .padding(.horizontal, Spacing.large)
            .padding(.bottom, Spacing.large)
        }
        .background(Color(.systemBackground))
    }
}

/// A section's sessions on one card (mockup 2): the state mark, the title,
/// the Mac's caption and the time, rows split by hairlines; each opens its
/// workchat.
private struct SessionCard: View {
    static let rowInsets = EdgeInsets(top: Spacing.regular, leading: 0, bottom: Spacing.regular, trailing: 0)

    let rows: [SessionRowModel]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    CardRowDivider()
                }
                NavigationLink(value: SessionRoute(id: row.id)) {
                    FlatRow(icon: row.icon, title: row.title, titleLineLimit: 1, insets: Self.rowInsets) {
                        MetaLine(items: row.panelMetaItems)
                    } trailing: {
                        if let time = row.time {
                            Text(time).font(TypeScale.time).foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                .buttonStyle(.plain)
            }
        }
        .card(padding: EdgeInsets(top: Spacing.tight, leading: Spacing.medium, bottom: Spacing.tight, trailing: Spacing.medium))
    }
}
