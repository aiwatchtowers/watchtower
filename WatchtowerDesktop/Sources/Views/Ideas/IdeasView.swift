import SwiftUI
import WatchtowerCore

// MARK: - IdeasView
//
// The Ideas & Decisions registry screen: a master-detail split over a review
// queue ("For review", `vm.reviewItems`) and a filterable browsable registry
// (`vm.registryItems`) — copies `DashboardView`'s HSplitView + List(selection:)
// shape.
struct IdeasView: View {
    @Bindable var vm: IdeasViewModel
    @Environment(AppState.self) private var appState

    @State private var showCreateSheet = false
    @State private var showBackfillSheet = false
    @State private var searchDebounceTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            if let errorMessage = vm.errorMessage {
                errorBanner(errorMessage)
            }
            Group {
                if vm.reviewItems.isEmpty && vm.registryItems.isEmpty && !vm.isLoading {
                    emptyState
                } else {
                    HSplitView {
                        listPanel
                            .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
                        detailPanel
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .navigationTitle("Ideas")
        .sheet(isPresented: $showCreateSheet) {
            IdeaCreateSheet(vm: vm)
        }
        .sheet(isPresented: $showBackfillSheet) {
            IdeaBackfillSheet(vm: vm)
        }
        .onAppear {
            // startObserving() already loads; the extra refresh() is the
            // cross-process daemon-writes rule — the consolidator mines ideas
            // in the Go daemon, which ValueObservation cannot see — and is
            // what every RE-appear needs. startObserving is idempotent.
            vm.startObserving()
            vm.refresh()
        }
    }

    /// Write failures otherwise vanish into `vm.errorMessage` with nothing
    /// rendering it — the owner sees a button that silently did nothing
    /// (DashboardView:31 precedent).
    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: - Left: list panel

    private var listPanel: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            List(selection: Binding(
                get: { vm.selectedID },
                set: { vm.select($0) }
            )) {
                if !vm.reviewItems.isEmpty {
                    Section("For review") {
                        ForEach(vm.reviewItems) { idea in
                            IdeaRow(idea: idea).tag(idea.id)
                        }
                    }
                }
                Section("Registry") {
                    ForEach(vm.registryItems) { idea in
                        IdeaRow(idea: idea).tag(idea.id)
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Ideas")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                backfillStatusBadge
                Button {
                    showBackfillSheet = true
                } label: {
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .help("Find ideas in a past date range")
                Button {
                    showCreateSheet = true
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .help("Create an idea, note, or decision")
            }

            HStack(spacing: 8) {
                Picker("Kind", selection: $vm.kindFilter) {
                    Text("All kinds").tag(String?.none)
                    Text("Ideas").tag(String?.some("idea"))
                    Text("Decisions").tag(String?.some("decision"))
                    Text("Notes").tag(String?.some("note"))
                }
                .labelsHidden()

                Picker("Status", selection: $vm.statusFilter) {
                    Text("All statuses").tag(String?.none)
                    Text("Proposed").tag(String?.some("proposed"))
                    Text("Active").tag(String?.some("active"))
                    Text("Not now").tag(String?.some("not_now"))
                    Text("Converted").tag(String?.some("converted"))
                    Text("Dropped").tag(String?.some("dropped"))
                    Text("Rejected").tag(String?.some("rejected"))
                    Text("Merged").tag(String?.some("merged"))
                    Text("Superseded").tag(String?.some("superseded"))
                    Text("Reversed").tag(String?.some("reversed"))
                }
                .labelsHidden()
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search ideas…", text: $vm.searchText)
                    .textFieldStyle(.plain)
            }
            .padding(6)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(12)
        .onChange(of: vm.kindFilter) { vm.load() }
        .onChange(of: vm.statusFilter) { vm.load() }
        // Search runs a triple-LIKE query across ideas AND their mentions;
        // firing it per keystroke reloads the whole screen on every letter.
        .onChange(of: vm.searchText) { debounceSearch() }
        .onDisappear { searchDebounceTask?.cancel() }
    }

    /// The backfill run's always-visible surface (the sheet dismisses on
    /// Start so mining never blocks the app): an in-flight pill while mining,
    /// then the terminal outcome — error or summary — since the dismissed
    /// sheet is otherwise the only reader of those fields (including the
    /// pre-flight "CLI not found" failure, which never sets isBackfilling at
    /// all). Click = back into the sheet for details/Cancel.
    @ViewBuilder
    private var backfillStatusBadge: some View {
        if vm.isBackfilling {
            badgeCapsule(help: "Idea mining is running — click for details") {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                Text("Mining…")
                    .font(.caption)
                if let startedAt = vm.backfillStartedAt {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(IdeaBackfillSheet.elapsedString(from: startedAt, to: context.date))
                            .font(.caption)
                            .monospacedDigit()
                    }
                }
            }
        } else if let error = vm.backfillError {
            badgeCapsule(help: error) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("Mining failed")
                    .font(.caption)
            }
        } else if let summary = vm.backfillSummary {
            badgeCapsule(help: summary) {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.green)
                Text(summary)
                    .font(.caption)
                    .lineLimit(1)
            }
        }
    }

    private func badgeCapsule(help: String, @ViewBuilder content: () -> some View) -> some View {
        Button {
            showBackfillSheet = true
        } label: {
            HStack(spacing: 6, content: content)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func debounceSearch() {
        searchDebounceTask?.cancel()
        searchDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            vm.load()
        }
    }

    // MARK: - Right: detail panel

    @ViewBuilder
    private var detailPanel: some View {
        if let idea = vm.selectedItem {
            IdeaDetailPane(
                idea: idea,
                allIdeas: vm.reviewItems + vm.registryItems,
                onApprove: { vm.approve(idea) },
                onReject: { vm.reject(idea) },
                onActivate: { vm.activate(idea) },
                onNotNow: { date in vm.notNow(idea, until: date.map(Self.isoDateString) ?? "") },
                onDrop: { vm.drop(idea) },
                onMerge: { targetID in vm.merge(idea, into: targetID) },
                onConvert: {
                    if let targetID = vm.convertToTarget(idea) {
                        appState.navigateToTarget(targetID)
                    }
                },
                onSupersede: { vm.supersede(idea, by: nil) },
                onReverse: { vm.reverse(idea) },
                onRating: { rating, comment in vm.setRating(idea, rating: rating, comment: comment) }
            )
            // Identity at the CALL SITE, so the pane's OWN @State (rating
            // draft, merge-sheet selection) resets when the selection
            // changes — an .id inside the pane's body only resets its
            // children, which would let a previous idea's rating draft leak
            // into the next one. Same id on a poll-driven re-render of the
            // same idea → state survives (required).
            .id(idea.id)
        } else {
            emptySelection
        }
    }

    private var emptySelection: some View {
        VStack(spacing: 8) {
            Image(systemName: "lightbulb")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Select an idea")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "lightbulb")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No ideas yet")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Ideas and decisions mined from Slack, meetings, email, and Jira will collect here for review.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            // The header buttons live in filterBar, which the empty state
            // replaces wholesale — without these a fresh install (zero mined
            // ideas) has no way to trigger a backfill or create an idea.
            HStack(spacing: 12) {
                Button {
                    showBackfillSheet = true
                } label: {
                    Label("Find Ideas", systemImage: "sparkle.magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                Button {
                    showCreateSheet = true
                } label: {
                    Label("Create", systemImage: "plus.circle")
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 4)
            // The empty state replaces filterBar wholesale, and a fresh
            // install's very first backfill runs exactly here — without this
            // the dismissed sheet leaves no trace of the run (or its failure).
            backfillStatusBadge
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static func isoDateString(_ date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.string(from: date)
    }
}
