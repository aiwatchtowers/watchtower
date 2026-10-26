import SwiftUI
import WatchtowerCore

/// The workbench's workspace area with the Clean Up screen over it while it
/// is open (board #1107, spec 2026-10-26-worktree-cleanup-screen §3.1). The
/// screen covers the area rather than replacing it: the panes stay in the
/// view tree — hidden, out of hit-testing and accessibility — so a
/// session's terminal is never detached or re-created, and closing the
/// screen shows the workspace exactly as it was.
struct CleanupCoveredWorkspace: View {
    @Bindable var vm: WorkbenchesViewModel
    let project: Workbench

    var body: some View {
        let covered = vm.cleanupScreenOpen(projectID: project.id)
        ZStack {
            // An ask filed outside the app has no terminal to sit beside:
            // its drawer takes the page's trailing edge.
            OwnerAskDrawerHost(vm: vm, ask: vm.asks.drawerAsk(projectID: project.id).flatMap { $0.sessionID == nil ? $0 : nil }) {
                WorkspaceAreaView(vm: vm, project: project)
            }
            .opacity(covered ? 0 : 1)
            .allowsHitTesting(!covered)
            .accessibilityHidden(covered)
            if covered {
                CleanupScreenView(vm: vm, project: project)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The Clean Up screen (spec §4, §5; mockup
/// `docs/design/mockups/worktree-cleanup/`): header, progress line or
/// result bar, toolbar, the list in two groups, footer, and the one
/// confirmation. Every changing text comes from `CleanupScreenModel`; the
/// state lives in `vm.cleanupScreens` (in memory only).
struct CleanupScreenView: View {
    @Bindable var vm: WorkbenchesViewModel
    let project: Workbench
    @State private var keptFolded = true
    @State private var canGoFolded = false
    /// The empty state's **Show kept**: the list shows although nothing can go.
    @State private var showsKept = false
    @State private var confirming = false
    /// The Search field has the keyboard: ⌘A and Esc are its own then.
    @State private var searchFocused = false
    @FocusState private var focused: Bool

    static let title = "Clean up worktrees and branches"
    static let subtitle = "Nothing goes until you select it and confirm. Unsaved or unpushed work is never removed."

    var body: some View {
        // "Checked 1 min ago", "active 9 days ago" move on by themselves.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .background(Surface.detail)
        // Keys go to the screen, not to the hidden terminal behind it
        // (pinned by `CleanupScreenViewTests`).
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            focused = true
            // Back on a page whose apply ended meanwhile: its keeps show too.
            unfoldKeptAfterApply()
        }
        .onChange(of: isDone) { _, done in
            // A row kept at apply time moves to Kept: show it.
            if done { unfoldKeptAfterApply() }
        }
    }

    /// Unfolds Kept once per ended apply, so a fold the owner makes after
    /// it holds when the screen shows again.
    private func unfoldKeptAfterApply() {
        guard isDone, let run = vm.cleanupScreenProgress(projectID: projectID)?.runID,
              state.keptUnfoldedRun != run else { return }
        keptFolded = false
        vm.cleanupScreens[projectID]?.keptUnfoldedRun = run
    }

    private var projectID: Int64 { project.id }

    private var state: CleanupScreenState {
        vm.cleanupScreens[projectID] ?? CleanupScreenState(scope: .workbench(projectID))
    }

    private var phase: SessionCleanupPhase {
        vm.sessionCleanup?.cleanupPhase(for: state.scope) ?? .idle
    }

    private var isDone: Bool {
        if case .done = phase { return true }
        return false
    }

    /// A binding into the screen's state; writes are dropped once it closed.
    private func binding<Value>(_ keyPath: WritableKeyPath<CleanupScreenState, Value>) -> Binding<Value> {
        Binding(
            get: { state[keyPath: keyPath] },
            set: { value in vm.cleanupScreens[projectID]?[keyPath: keyPath] = value }
        )
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let model = vm.cleanupScreenModel(projectID: projectID, now: now)
            ?? CleanupScreenModel(items: [], checking: [], sizing: [], now: now)
        let progress = vm.cleanupScreenProgress(projectID: projectID)
        let empty = showsEmptyState(model, progress: progress)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                CleanupStatusLine(
                    vm: vm, projectID: projectID, state: state, progress: progress, now: now
                )
                .padding(.top, Spacing.cozy)
                .padding(.bottom, Spacing.medium)
                if empty {
                    emptyState(model)
                } else {
                    CleanupToolbar(vm: vm, projectID: projectID, state: state, filters: binding(\.filters)) {
                        searchFocused = $0
                    }
                    .padding(.bottom, Spacing.cozy)
                    list(model)
                }
            }
            .padding(.horizontal, Spacing.page)
            .padding(.top, Spacing.large)
            if !empty {
                CleanupFooter(
                    vm: vm, projectID: projectID, model: model, state: state,
                    ticks: binding(\.ticks), confirming: $confirming, searchFocused: searchFocused
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $confirming) {
            CleanupConfirmSheet(title: model.confirmationTitle(for: model.liveTicks(state.ticks))) {
                Task { await vm.applyCleanupScreen(projectID: projectID) }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.medium) {
            Text(Self.title)
                .font(.headline)
            Text(Self.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(Self.subtitle)
        }
    }

    /// Mockup G: a fresh plan where nothing can go, until **Show kept**.
    private func showsEmptyState(_ model: CleanupScreenModel, progress: SessionCleanupProgress?) -> Bool {
        guard !showsKept, case .ready = progress?.stage else { return false }
        return model.rows(filters: CleanupFilters(), sort: .size, ascending: false).canGo.isEmpty
    }

    private func emptyState(_ model: CleanupScreenModel) -> some View {
        TabEmptyState(copyKey: Self.emptyCopyKey, context: .neutral) {
            if let kept = model.emptyKeptText() {
                Text(kept)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(CleanupScreenModel.showKeptTitle) {
                    showsKept = true
                    keptFolded = false
                }
                .buttonStyle(.kitQuiet)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.wide)
    }

    /// The `EmptyStateCopyTable` key of mockup G.
    static let emptyCopyKey = "workbenchCleanup"

    private func list(_ model: CleanupScreenModel) -> some View {
        let rows = model.rows(filters: state.filters, sort: state.sort, ascending: state.ascending)
        let shown = (canGoFolded ? [] : rows.canGo) + (keptFolded ? [] : rows.kept)
        return VStack(spacing: 0) {
            CleanupColumnHeader(sort: binding(\.sort), ascending: binding(\.ascending))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    groupHeader("Can go", count: rows.canGo.count, summary: nil, folded: $canGoFolded)
                    if !canGoFolded {
                        ForEach(rows.canGo) { row in rowView(row, model: model, shown: shown) }
                    }
                    // Nothing kept: no Kept group (mockup E); Can go always shows.
                    if !rows.kept.isEmpty {
                        groupHeader("Kept", count: rows.kept.count, summary: model.keptSummary(), folded: $keptFolded)
                    }
                    if !keptFolded {
                        ForEach(rows.kept) { row in rowView(row, model: model, shown: shown) }
                    }
                }
                .padding(.bottom, Spacing.regular)
            }
        }
    }

    private func groupHeader(_ title: String, count: Int, summary: String?, folded: Binding<Bool>) -> some View {
        Button {
            withAnimation(Motion.panel) { folded.wrappedValue.toggle() }
        } label: {
            HStack(spacing: Spacing.compact) {
                SectionHeader(title: title, systemImage: folded.wrappedValue ? "chevron.right" : "chevron.down",
                              count: count)
                    .textCase(.uppercase)
                if let summary, !summary.isEmpty {
                    Text("· \(summary)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(KitQuietButtonStyle(label: .secondary))
        .controlSize(.small)
        .padding(.top, Spacing.compact)
    }

    private func rowView(_ row: CleanupRow, model: CleanupScreenModel, shown: [CleanupRow]) -> some View {
        CleanupRowView(row: row, ticked: state.ticks.contains(row.id)) { shift in
            click(row, shift: shift, model: model, shown: shown)
        }
    }

    /// A click or its checkbox ticks or unticks the row; ⇧ does the range
    /// from the row clicked last (rows that cannot be chosen are skipped).
    private func click(_ row: CleanupRow, shift: Bool, model: CleanupScreenModel, shown: [CleanupRow]) {
        guard row.canChoose, var screen = vm.cleanupScreens[projectID] else { return }
        let on = !screen.ticks.contains(row.id)
        if shift, let anchor = screen.lastClicked {
            screen.ticks = model.tickRange(from: anchor, to: row.id, in: shown, on: on, ticks: screen.ticks)
        } else if on {
            screen.ticks.insert(row.id)
        } else {
            screen.ticks.remove(row.id)
        }
        screen.lastClicked = row.id
        vm.cleanupScreens[projectID] = screen
    }
}

/// Under the title: the plan's progress, "Checked … · N worktrees, M
/// branches" with **Refresh**, or the result bar after an apply or a
/// failure (mockups A–F). The words are `CleanupScreenModel`'s.
struct CleanupStatusLine: View {
    let vm: WorkbenchesViewModel
    let projectID: Int64
    let state: CleanupScreenState
    let progress: SessionCleanupProgress?
    let now: Date

    var body: some View {
        let stage = progress?.stage ?? .listing
        switch stage {
        case let .done(plan) where !state.resultDismissed:
            resultBar(plan)
        case .failed where !state.resultDismissed:
            failureBar(text(stage))
        case .failed:
            HStack { refresh }
        case let .checking(done, total), let .sizing(done, total):
            progressLine(text(stage), fraction: total > 0 ? Double(done) / Double(total) : 0)
        case .listing:
            progressLine(text(stage), fraction: nil)
        case .applying:
            HStack(spacing: Spacing.regular) {
                ProgressView().controlSize(.mini)
                Text(text(stage)).font(.caption).foregroundStyle(.secondary)
                refresh
            }
        case .ready, .done:
            HStack(spacing: Spacing.regular) {
                Text(text(stage)).font(.caption).foregroundStyle(.secondary)
                refresh
            }
        }
    }

    private var sessionScope: Bool {
        if case .session = state.scope { return true }
        return false
    }

    private func text(_ stage: CleanupStage) -> String {
        let items = (progress?.items ?? []).filter { !$0.done }
        return CleanupScreenModel.progressText(
            stage,
            worktrees: items.filter { $0.kind == .worktree }.count,
            branches: items.filter { $0.kind == .branch }.count,
            sessionScope: sessionScope,
            now: now
        )
    }

    private var refresh: some View {
        Button("Refresh") { vm.refreshCleanup(projectID: projectID) }
            .buttonStyle(.kitQuiet)
            .controlSize(.small)
            .disabled(!vm.canRefreshCleanup(projectID: projectID))
    }

    private func progressLine(_ text: String, fraction: Double?) -> some View {
        HStack(spacing: Spacing.regular) {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .controlSize(.mini)
                .frame(width: 160)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .frame(minHeight: 22, alignment: .leading)
    }

    /// Mockup C: "✓ Freed ~15 GB · removed …" and the apply-time keeps.
    private func resultBar(_ plan: SessionCleanupPlan) -> some View {
        let result = CleanupScreenModel.resultText(plan, sent: state.sentKeys)
        let failure = vm.sessionCleanup?.failureText(for: state.scope)
        return bar {
            Image(systemName: failure == nil ? "checkmark" : "xmark")
                .foregroundStyle(failure == nil ? Tone.success : Tone.error)
            Text(result.freed)
            if let kept = result.kept {
                Text("· \(kept)").foregroundStyle(Tone.warning)
            }
            if let failure {
                Text("· \(failure)").foregroundStyle(Tone.error).lineLimit(1).help(failure)
            }
            Spacer(minLength: Spacing.regular)
            dismiss
        }
    }

    /// Mockup E: the whole run failed — **Retry** and **Dismiss**.
    private func failureBar(_ text: String) -> some View {
        bar {
            Image(systemName: "xmark").foregroundStyle(Tone.error)
            Text(text).foregroundStyle(Tone.error).lineLimit(2).help(text)
            Spacer(minLength: Spacing.regular)
            Button("Retry") { vm.retryCleanup(projectID: projectID) }
                .buttonStyle(.kitQuiet)
                .disabled(!vm.canRefreshCleanup(projectID: projectID))
            dismiss
        }
    }

    private var dismiss: some View {
        Button("Dismiss") { vm.cleanupScreens[projectID]?.resultDismissed = true }
            .buttonStyle(.kitQuiet)
    }

    private func bar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: Spacing.regular) { content() }
            .font(.caption)
            .controlSize(.small)
            .padding(.vertical, Spacing.compact)
            .padding(.horizontal, Spacing.cozy)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Fill.card, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
    }
}
