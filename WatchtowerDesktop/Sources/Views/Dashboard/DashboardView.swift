import SwiftUI

// MARK: - DashboardView

/// The secretary Dashboard feed — a master-detail split over a single rank-ordered
/// list of `Situation`s (clustered signals + target/track updates), replacing the
/// old two-tier Inbox feed. Selection, member-signal loading, and all mutating
/// actions are delegated to the `DashboardViewModel` passed in by the owning tab
/// container (`InboxFeedView`), mirroring how `InboxViewModel` is owned/passed there.
struct DashboardView: View {
    let vm: DashboardViewModel
    @Environment(AppState.self) private var appState

    // Create-target flow (DASH-03): fromSituation prefill → CreateTargetSheet →
    // onCreated marks the situation converted with the new target id.
    @State private var showCreateTarget = false
    @State private var targetPrefill: TargetPrefill?
    @State private var pendingSituationID: Int?
    @State private var isBuildingPrefill = false
    @State private var conversionError: String?

    // Create-track flow (DASH-03): CustomTrackManagementSheet's onCreated yields a
    // TrackDraft with no id, so the id is resolved afterwards via
    // TrackQueries.fetchLatestCustom — best-effort in v1 (see openCreateTrack).
    @State private var showCreateTrack = false
    @State private var trackSituationID: Int?

    var body: some View {
        VStack(spacing: 0) {
            if let msg = vm.errorMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
            }
            content
        }
        .sheet(isPresented: $showCreateTarget) {
            CreateTargetSheet(prefill: targetPrefill) { newID in
                guard let situationID = pendingSituationID else { return }
                vm.markConverted(situationID: situationID, targetID: newID, trackID: nil)
            }
        }
        .sheet(isPresented: $showCreateTrack) {
            CustomTrackManagementSheet(linkedTargetID: nil) { _ in
                resolveCreatedTrack()
            }
        }
    }

    private var content: some View {
        Group {
            if vm.situations.isEmpty {
                emptyState
            } else {
                HSplitView {
                    situationList
                        .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
                    reviewPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    // MARK: - Left: situation list

    private var situationList: some View {
        List(selection: Binding(
            get: { vm.selectedSituationID },
            set: { vm.select($0) }
        )) {
            ForEach(vm.situations) { situation in
                SituationRow(situation: situation)
                    .tag(situation.id)
                    .contextMenu { contextMenu(for: situation) }
            }

            Button("Load more") { vm.loadMore() }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func contextMenu(for situation: Situation) -> some View {
        Button {
            vm.done(situation)
        } label: {
            Label("Done", systemImage: "checkmark.circle")
        }
        Menu {
            Button("1 hour") { vm.snooze(situation, until: SnoozeDates.until(.oneHour)) }
            Button("Till tomorrow") { vm.snooze(situation, until: SnoozeDates.until(.tillTomorrow)) }
            Button("Till Monday") { vm.snooze(situation, until: SnoozeDates.until(.tillMonday)) }
        } label: {
            Label("Snooze", systemImage: "moon.zzz")
        }
        Divider()
        Button(role: .destructive) {
            vm.dismiss(situation)
        } label: {
            Label("Dismiss", systemImage: "archivebox")
        }
    }

    // MARK: - Right: review pane

    @ViewBuilder
    private var reviewPane: some View {
        if let situation = vm.selectedSituation {
            SituationReviewPane(
                situation: situation,
                memberSignals: vm.memberSignals(for: situation.id),
                memberSignalsLoaded: vm.memberSignalsLoaded(situation.id),
                senderName: { vm.senderName(for: $0) },
                channelName: { vm.channelName(for: $0) },
                slackURL: { vm.slackURL(for: $0) },
                onDone: { vm.done(situation) },
                onDismiss: { vm.dismiss(situation) },
                onSnooze: { option in vm.snooze(situation, until: SnoozeDates.until(option)) },
                onFeedback: { rating, comment in
                    Task { await vm.submitFeedback(situation, rating: rating, comment: comment) }
                },
                isCreatingTarget: isBuildingPrefill,
                onCreateTarget: { openCreateTarget(for: situation) },
                onCreateTrack: { openCreateTrack(for: situation) },
                onOpenTarget: { appState.navigateToTarget($0) },
                onOpenTrack: { appState.navigateToTrack($0) }
            )
        } else {
            VStack(spacing: 8) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("Select a situation")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Nothing needs your attention")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Composed situations from Slack signals, targets, and tracks will appear here")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            if !vm.isLoading {
                Button {
                    Task { await vm.generateNow() }
                } label: {
                    if vm.isGenerating {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Generate your inbox")
                        }
                    } else {
                        Label("Generate your inbox", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.isGenerating)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Create target / Create track (DASH-03)

    private func openCreateTarget(for situation: Situation) {
        guard let db = appState.databaseManager else {
            conversionError = "Database not available"
            return
        }
        Task { @MainActor in
            isBuildingPrefill = true
            defer { isBuildingPrefill = false }
            do {
                let pf = try await TargetPrefillBuilder.fromSituation(situation, db: db)
                targetPrefill = pf
                pendingSituationID = situation.id
                conversionError = nil
                showCreateTarget = true
            } catch {
                conversionError = "Failed to prepare prefill: \(error.localizedDescription)"
            }
        }
    }

    private func openCreateTrack(for situation: Situation) {
        trackSituationID = situation.id
        showCreateTrack = true
    }

    /// Resolves the id of the custom track `CustomTrackManagementSheet` just
    /// created (its `onCreated` yields a `TrackDraft`, not an id) by looking up
    /// the newest `origin='custom'` track. Best-effort: if that lookup fails or
    /// finds nothing, the situation is left open rather than guessing wrong —
    /// the user can retry from the dashboard.
    private func resolveCreatedTrack() {
        guard let situationID = trackSituationID, let db = appState.databaseManager else { return }
        Task { @MainActor in
            do {
                let track = try await db.dbPool.read { dbConn in
                    try TrackQueries.fetchLatestCustom(dbConn)
                }
                guard let track else {
                    conversionError = "Track created, but couldn't resolve its id — situation left open."
                    return
                }
                vm.markConverted(situationID: situationID, targetID: nil, trackID: track.id)
            } catch {
                conversionError = "Track created, but couldn't resolve its id: \(error.localizedDescription)"
            }
        }
    }
}
