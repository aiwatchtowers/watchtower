import SwiftUI
import WatchtowerCore

/// The Inbox tab's content: due reminders, pending agent-action proposals
/// and open automation inbox outputs, as a list and a reading pane — the reaction-command
/// surface, which replaced the
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
                        onOpen: open,
                        onOpenAutomationRun: { runID in appState.openAutomationRun(runID: runID) },
                        onCardAction: { command in Task { await appState.perform(command) } },
                        onOpenSaveDraft: { appState.openSaveProposalDraft($0) },
                        workbenches: appState.inboxWorkbenches,
                        onReconnectSlack: { id in await appState.reconnectSlack(accountID: id) },
                        sessionHoldsCall: { appState.chatSessionPool?.holdsSessionCall($0) ?? false },
                        emptyState: appState.emptyStateContext,
                        onOpenConnections: {
                            appState.settingsTab = .connections
                            openSettings()
                        },
                        ownerKnown: appState.owner.isKnown
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
            await appState.refreshOwner()
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
                try await appState.restartOnChain(appState.daemonControl)
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

/// The Actions segment: the list and reading pane (`InboxSplitView`), or —
/// when it is empty — the reaction cheat sheet in its place. On a non-empty
/// strip the cheat sheet
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
    /// An automation row's label (run id) and an output card's automation
    /// line: open that automation's card with the run expanded. Nil (tests)
    /// renders them as plain text.
    var onOpenAutomationRun: ((Int64) -> Void)?
    /// A press on an automation card's buttons (`InboxCardCommand`).
    var onCardAction: (InboxCardCommand) -> Void = { _ in }
    /// A `save_automation` proposal's **Open Draft** (`AppState.openSaveProposalDraft`).
    var onOpenSaveDraft: (SaveAutomationCardModel) -> Void = { _ in }
    /// The workbenches a card's agent press can go to (and that name a
    /// workbench proposal's scope).
    var workbenches: [Workbench] = []
    /// A failed Slack send's Reconnect Slack button (`AppState.reconnectSlack`).
    var onReconnectSlack: ((Int64) async -> String?)?
    /// `AgentActionCardView.sessionHoldsCall` for a row (a connector call).
    var sessionHoldsCall: ((AgentAction) -> Bool)?
    /// The empty strip's readiness and actions (`AppState.emptyStateContext`).
    var emptyState: EmptyStateContext = .neutral
    /// With no owner identity the daemon skips the inbox (OWNER-02), so the
    /// empty strip says why and points at Connections, as Briefings and Day
    /// Plan do.
    var onOpenConnections: () -> Void = {}
    var ownerKnown = true

    var body: some View {
        VStack(spacing: 0) {
            if let message = vm.lastError {
                errorBanner(message)
            }
            if vm.actionRows.isEmpty && vm.reminderRows.isEmpty && vm.outputRows.isEmpty {
                ScrollView {
                    TabEmptyState(.inbox, context: emptyState) {
                        if !ownerKnown {
                            NoOwnerEmptyState(openConnections: onOpenConnections)
                        }
                        ReactionCheatSheetView(
                            rows: cheatSheetRows,
                            feature: feature,
                            isEnabling: isEnabling,
                            error: featureError,
                            onEnable: onEnable,
                            onOpenSettings: onOpenSettings
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.top, 24)
                }
                .accessibilityIdentifier("actionStrip.cheatSheet")
            } else {
                InboxSplitView(
                    vm: vm,
                    cheatSheetRows: cheatSheetRows,
                    onOpenSettings: onOpenSettings,
                    proposalCard: card,
                    saveProposal: saveProposal,
                    workbenches: workbenches,
                    onCardAction: onCardAction,
                    onOpenAutomationRun: onOpenAutomationRun
                )
            }
        }
    }

    private func card(_ action: AgentAction) -> AgentActionCardView {
        AgentActionCardView(
            action: action,
            inFlight: vm.actionFeed.inFlight.contains(action.id),
            onApprove: { Task { await vm.approve(action.id, shownArgs: action.argsJSON) } },
            onReject: { Task { await vm.reject(action.id) } },
            onRetry: { Task { await vm.retry(action.id) } },
            gestureError: vm.actionFeed.rowErrors[action.id],
            onOpen: onOpen,
            onApproveEdited: { patch in Task { await vm.approve(action.id, shownArgs: action.argsJSON, patch: patch) } },
            onReconnectSlack: onReconnectSlack,
            contextLabel: vm.actionLabels[action.id],
            onOpenContext: openContext(action),
            onDismiss: { Task { await vm.dismiss(action.id) } },
            sessionHoldsCall: sessionHoldsCall?(action) ?? false
        )
    }

    private func saveProposal(_ action: AgentAction) -> SaveAutomationProposalPane {
        SaveAutomationProposalPane(
            action: action,
            workbenchName: { id in workbenches.first { $0.id == id }?.name },
            contextLabel: vm.actionLabels[action.id],
            inFlight: vm.actionFeed.inFlight.contains(action.id),
            gestureError: vm.actionFeed.rowErrors[action.id]?.message,
            onOpenDraft: { onOpenSaveDraft($0) },
            onReject: { Task { await vm.reject(action.id) } }
        )
    }

    /// Only a row whose label names a run gets a clickable label.
    private func openContext(_ action: AgentAction) -> (() -> Void)? {
        guard let onOpenAutomationRun, let runID = ActionStripViewModel.automationRunID(action) else { return nil }
        return { onOpenAutomationRun(runID) }
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
