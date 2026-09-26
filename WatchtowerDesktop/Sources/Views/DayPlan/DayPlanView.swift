import SwiftUI
import WatchtowerCore

struct DayPlanView: View {
    @Bindable var vm: DayPlanViewModel
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings
    @State private var showRegen = false
    @State private var showCreate = false
    @State private var meetingPrepEventID: String?
    @State private var meetingPrepVM = MeetingPrepViewModel()
    @State private var userNotes: String = ""
    @State private var briefingExistsForDate: Bool = false

    var body: some View {
        mainContent(vm)
    }

    // MARK: - Main Content

    @ViewBuilder
    private func mainContent(_ vm: DayPlanViewModel) -> some View {
        VStack(spacing: 0) {
            headerBar(vm)
            Divider()

            if vm.hasConflicts {
                DayPlanConflictBanner(
                    owner: appState.owner,
                    summary: vm.plan?.conflictSummary,
                    onRegenerate: { showRegen = true },
                    onCheckAgain: { Task { await vm.checkConflicts() } }
                )
                .padding(.top, 8)
            }

            if let errorMsg = vm.generationError {
                generationErrorBanner(errorMsg, vm)
            }

            if Self.showsNoOwnerState(owner: appState.owner, hasPlan: vm.plan != nil) {
                NoOwnerEmptyState(openConnections: openConnections)
            } else {
                planBody(vm)
            }

            DayPlanFooterBar(
                owner: appState.owner,
                hasPlan: vm.plan != nil,
                isGenerating: vm.isGenerating,
                onGenerate: { Task { await vm.regenerate(feedback: nil) } },
                onRegenerate: { showRegen = true },
                onReset: { Task { await vm.reset() } }
            )
        }
        .sheet(isPresented: $showRegen) {
            RegenerateFeedbackSheet(vm: vm, isPresented: $showRegen)
        }
        .sheet(isPresented: $showCreate) {
            CreateDayPlanItemSheet(vm: vm, isPresented: $showCreate)
        }
        .sheet(isPresented: Binding(
            get: { meetingPrepEventID != nil },
            set: { if !$0 { meetingPrepEventID = nil } }
        )) {
            if let id = meetingPrepEventID {
                MeetingPrepDetailView(
                    eventID: id,
                    viewModel: meetingPrepVM,
                    userNotes: $userNotes,
                    onClose: { meetingPrepEventID = nil }
                )
                .id(id)
                .frame(minWidth: 480, minHeight: 520)
            }
        }
        .task {
            await appState.refreshOwner()
            let date = appState.pendingDayPlanDate ?? todayString()
            await vm.loadFor(date: date)
            if appState.pendingDayPlanDate == date {
                appState.pendingDayPlanDate = nil
            }
            refreshBriefingExists()
        }
        .onChange(of: appState.pendingDayPlanDate) { _, newDate in
            guard let d = newDate else { return }
            Task {
                await vm.loadFor(date: d)
                if appState.pendingDayPlanDate == d {
                    appState.pendingDayPlanDate = nil
                }
                refreshBriefingExists()
            }
        }
        .onChange(of: vm.plan?.planDate) { _, _ in
            refreshBriefingExists()
        }
    }

    private func generationErrorBanner(_ message: String, _ vm: DayPlanViewModel) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
            Spacer()
            Button("Dismiss") { vm.generationError = nil }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // MARK: - Plan Body

    /// The timeline + backlog body; replaced by `NoOwnerEmptyState` when
    /// there is neither an owner nor a plan to show.
    private func planBody(_ vm: DayPlanViewModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Timeline section
                sectionHeader("TIMELINE")

                if vm.timeblocks.isEmpty && vm.allDayItems.isEmpty {
                    Text("No scheduled timeblocks")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                } else {
                    DayPlanTimelineView(
                        items: vm.timeblocks,
                        allDayEvents: vm.allDayItems,
                        calendarEventsByID: vm.calendarEventsByID,
                        onToggle: { item in
                            Task {
                                if item.isDone {
                                    await vm.markPending(item)
                                } else {
                                    await vm.markDone(item)
                                }
                            }
                        },
                        onPrepare: { eventID in
                            // Fresh VM per meeting avoids showing cached prep from a previous event.
                            meetingPrepVM = MeetingPrepViewModel()
                            meetingPrepEventID = eventID
                            meetingPrepVM.generate(eventID: eventID)
                        },
                        onNavigate: { item in
                            navigateToSource(item)
                        }
                    )
                }

                // Backlog section
                HStack {
                    sectionHeader("BACKLOG (if time permits)")
                    Spacer()
                    Button {
                        showCreate = true
                    } label: {
                        Label("Add", systemImage: "plus")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .padding(.trailing, 16)
                }

                if vm.backlogItems.isEmpty {
                    Text("No backlog items")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                } else {
                    ForEach(vm.backlogItems) { item in
                        DayPlanItemRow(
                            item: item,
                            onToggle: {
                                Task {
                                    if item.isDone {
                                        await vm.markPending(item)
                                    } else {
                                        await vm.markDone(item)
                                    }
                                }
                            },
                            onDelete: {
                                Task { await vm.delete(item) }
                            },
                            onNavigateSource: {
                                navigateToSource(item)
                            }
                        )
                        Divider()
                            .padding(.leading, 42)
                    }
                }
            }
            .padding(.bottom, 16)
        }
    }

    /// OWNER-02: the empty state replaces the plan body only when there is no
    /// owner identity AND no plan — an existing plan stays readable.
    static func showsNoOwnerState(owner: Owner, hasPlan: Bool) -> Bool {
        !owner.isKnown && !hasPlan
    }

    private func openConnections() {
        appState.settingsTab = .connections
        openSettings()
    }

    // MARK: - Header

    private func headerBar(_ vm: DayPlanViewModel) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Day Plan — \(vm.plan?.planDate ?? todayString())")
                    .font(.title2)
                    .fontWeight(.bold)
            }

            Spacer()

            if briefingExistsForDate || vm.plan?.briefingId != nil {
                Button {
                    openBriefing()
                } label: {
                    Label("Briefing", systemImage: "sun.max")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Open today's briefing")
            }

            let (done, total) = vm.progress
            if total > 0 {
                Text("\(done)/\(total)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .padding(.leading, 8)
            }

            if vm.isGenerating {
                ProgressView()
                    .controlSize(.small)
                    .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Navigation

    private func navigateToSource(_ item: DayPlanItem) {
        guard let sid = item.sourceId, !sid.isEmpty else { return }
        switch item.sourceType {
        case .task:
            if let id = Int(sid) {
                appState.navigateToTarget(id)
            }
        case .briefingAttention:
            // briefing_attention source_id points at the attention item's inner source
            // (track/digest/people/task), not a briefings.id. Route to the plan's linked
            // briefing, or fall back to the briefings list.
            if let bid = vm.plan?.briefingId {
                appState.navigateToBriefing(Int(bid))
            } else {
                appState.selectedDestination = .briefings
            }
        case .jira:
            appState.selectedDestination = .boards
        case .focus, .calendar, .manual:
            break
        }
    }

    private func openBriefing() {
        if let bid = vm.plan?.briefingId {
            appState.navigateToBriefing(Int(bid))
        } else {
            appState.selectedDestination = .briefings
        }
    }

    private func refreshBriefingExists() {
        guard let db = appState.databaseManager else {
            briefingExistsForDate = false
            return
        }
        let dateStr = vm.plan?.planDate ?? todayString()
        briefingExistsForDate = (try? db.dbPool.read { db in
            try BriefingQueries.fetchByDate(db, date: dateStr) != nil
        }) ?? false
    }

    // MARK: - Helpers

    private func todayString() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: Date())
    }
}

/// Day Plan's action footer, split out of `DayPlanView` so it takes no
/// `@Environment(AppState.self)` and ViewInspector can drive it (the
/// `TrayMenuContent` pattern). Every action here runs a `day-plan` CLI
/// command that needs the owner, so with no owner identity (OWNER-02) the
/// footer renders nothing.
struct DayPlanFooterBar: View {
    let owner: Owner
    let hasPlan: Bool
    let isGenerating: Bool
    let onGenerate: () -> Void
    let onRegenerate: () -> Void
    let onReset: () -> Void

    var body: some View {
        if owner.isKnown {
            VStack(spacing: 0) {
                Divider()
                actions
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            if hasPlan {
                Button("Regenerate with feedback…", action: onRegenerate)
                    .buttonStyle(.bordered)
                    .disabled(isGenerating)
            } else {
                Button("Generate today's plan", action: onGenerate)
                    .buttonStyle(.borderedProminent)
                    .disabled(isGenerating)
            }

            Spacer()

            if hasPlan {
                Button("Reset plan", action: onReset)
                    .buttonStyle(.bordered)
                    .foregroundStyle(.red)
                    .disabled(isGenerating)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
