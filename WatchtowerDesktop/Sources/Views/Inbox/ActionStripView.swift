import SwiftUI
import WatchtowerCore

/// The Inbox tab's content: a flat strip of due reminders and pending agent-
/// action proposals — the reaction-command surface, which replaced the
/// situations Dashboard (now deleted). The Dashboard's two sibling tabs did
/// not go with it: the learned-rules manager still feeds the digest/tracks/
/// briefing/catch-up prompts (`ListLearnedRulesByPipeline`) and the assistant
/// profile editor still feeds Catch-Up compose and the idea chat, so they
/// keep their door here behind this view's own segmented control
/// (`.learned`/`.profile`).
/// Reads `appState.actionStripViewModel` (AppState-owned so it survives
/// navigation, the `SlackAccountsViewModel` house pattern) and
/// re-`refresh()`s on every appear — cross-process daemon/CLI writes don't
/// fire `ValueObservation` (see the view model's own doc comment).
struct ActionStripView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings
    @State private var stripTab: StripTab = .actions

    enum StripTab { case actions, learned, profile }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $stripTab) {
                Text("Actions").tag(StripTab.actions)
                Text("Learned").tag(StripTab.learned)
                Text("Profile").tag(StripTab.profile)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            switch stripTab {
            case .actions:
                if let vm = appState.actionStripViewModel {
                    ActionStripActionsView(
                        vm: vm,
                        cheatSheetRows: cheatSheetRows,
                        feature: ReactionCheatSheetView.FeatureState.from(
                            features: appState.featureManager.features,
                            lastCheck: vm.lastReactionCheck
                        ),
                        isEnabling: appState.featureManager.isApplying,
                        featureError: appState.featureManager.loadError,
                        onEnable: enableReactionCommands,
                        onOpenSettings: openReactionDictionary,
                        onOpen: open
                    )
                } else {
                    ProgressView()
                }
            case .learned:
                if let dbPool = appState.databaseManager?.dbPool {
                    InboxLearnedRulesView(db: dbPool)
                } else {
                    databaseUnavailableNotice
                }
            case .profile:
                if let vm = appState.secretaryProfileViewModel {
                    SecretaryProfileView(vm: vm)
                } else {
                    databaseUnavailableNotice
                }
            }
        }
        .navigationTitle("Inbox")
        .task {
            appState.actionStripViewModel?.refresh()
            // The cheat sheet reads the dictionary through this VM, so a
            // Settings edit made while the Inbox was out of view shows up.
            appState.reactionDictionaryViewModel?.refresh()
        }
    }

    /// The live dictionary (`reaction_command_map` + `tool_trust`) through
    /// the same AppState-owned VM the Settings editor edits — one source.
    private var cheatSheetRows: [ReactionCheatSheet.Row] {
        appState.reactionDictionaryViewModel?.cheatSheetRows ?? []
    }

    /// The same Feature Manager path Settings → Features uses (`features
    /// enable` + daemon restart), minus the rest of whatever is staged there.
    /// In-flight/error state lives on the AppState-owned service, so it
    /// survives navigating away mid-enable.
    private func enableReactionCommands() {
        let manager = appState.featureManager
        Task {
            await manager.enableNow(ReactionCheatSheetView.reactionCommandsFeatureID) {
                try await DaemonManager.restart()
            }
        }
    }

    /// A card's "Open": the row the action created, or the screen it touched.
    private func open(_ destination: AgentActionDestination) {
        switch destination {
        case .idea(let id): appState.navigateToIdea(id)
        case .target(let id): appState.navigateToTarget(id)
        case .track(let id): appState.navigateToTrack(id)
        case .boards: appState.selectedDestination = .boards
        case .url(let url): NSWorkspace.shared.open(url)
        }
    }

    private func openReactionDictionary() {
        appState.settingsTab = .connections
        appState.settingsConnection = .slack
        openSettings()
    }

    private var databaseUnavailableNotice: some View {
        Text("Database unavailable")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The Actions segment: the strip itself, or — when it is empty — the
/// reaction cheat sheet in its place. On a non-empty strip the cheat sheet
/// stays one `?` click away in a popover, never inline (a card-shaped help
/// block among real cards would read as something waiting on the owner).
/// Split out of `ActionStripView` so it takes plain inputs and can be tested
/// without an `AppState`.
struct ActionStripActionsView: View {
    let vm: ActionStripViewModel
    let cheatSheetRows: [ReactionCheatSheet.Row]
    let feature: ReactionCheatSheetView.FeatureState
    let isEnabling: Bool
    let featureError: String?
    let onEnable: () -> Void
    let onOpenSettings: () -> Void
    let onOpen: (AgentActionDestination) -> Void

    @State private var showsCheatSheet = false

    var body: some View {
        VStack(spacing: 0) {
            if let message = vm.lastError {
                errorBanner(message)
            }
            if vm.actionRows.isEmpty && vm.reminderRows.isEmpty {
                ScrollView {
                    ReactionCheatSheetView(
                        rows: cheatSheetRows,
                        feature: feature,
                        isEnabling: isEnabling,
                        error: featureError,
                        onEnable: onEnable,
                        onOpenSettings: onOpenSettings
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
                }
                .accessibilityIdentifier("actionStrip.cheatSheet")
            } else {
                HStack {
                    Spacer()
                    Button {
                        showsCheatSheet = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Reaction commands")
                    .accessibilityIdentifier("actionStrip.cheatSheetButton")
                    .popover(isPresented: $showsCheatSheet, arrowEdge: .bottom) {
                        ReactionCheatSheetView(rows: cheatSheetRows, onOpenSettings: onOpenSettings)
                            .frame(width: 440)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                List {
                    if !vm.reminderRows.isEmpty {
                        Section("Reminders") {
                            ForEach(vm.reminderRows) { reminder in
                                ReminderRow(reminder: reminder, vm: vm)
                            }
                        }
                    }
                    if !vm.actionRows.isEmpty {
                        Section("Proposals") {
                            ForEach(vm.actionRows) { action in
                                AgentActionCardView(
                                    action: action,
                                    inFlight: vm.actionFeed.inFlight.contains(action.id),
                                    onApprove: { Task { await vm.approve(action.id) } },
                                    onReject: { Task { await vm.reject(action.id) } },
                                    onRetry: { Task { await vm.retry(action.id) } },
                                    onOpen: onOpen
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    /// The `IdeasView` house pattern: a write failure
    /// otherwise vanishes into `vm.lastError` with nothing rendering it.
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
}

/// One due reminder: its note, a link to the Slack message it was set from
/// (none when the ref is empty or unparseable), and Done / Snooze 1h.
struct ReminderRow: View {
    let reminder: Reminder
    let vm: ActionStripViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(reminder.note.isEmpty ? "Reminder" : reminder.note)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let source = SlackMessageRef.url(reminder.messageRef) {
                    Link("Slack message ↗", destination: source)
                        .font(.caption)
                }
            }
            Spacer()
            Button("Done") { vm.markReminderDone(reminder.id) }
            Button("Snooze 1h") {
                let until = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
                vm.snoozeReminder(reminder.id, until: until)
            }
        }
        .padding(.vertical, 4)
    }
}
