import GRDB
import SwiftUI
import WatchtowerCore

/// The Inbox tab's content (C1): one list and reading pane over every kind
/// that needs the owner — the day card, messages, tracks, ideas, and B's
/// proposals, due reminders and automation cards — under the filter bar
/// (All · Day · Messages · Tracks · Ideas · Automations). The learned-rules
/// manager still feeds the digest/tracks/briefing/catch-up prompts
/// (`ListLearnedRulesByPipeline`) and the assistant profile editor still
/// feeds Catch-Up compose and the idea chat, so they keep their door here:
/// the header's ⋯ menu opens them in the reading pane (R7).
/// Reads `appState.actionStripViewModel` (AppState-owned so it survives
/// navigation, the `SlackAccountsViewModel` house pattern), re-`refresh()`es
/// on every appear — cross-process daemon/CLI writes don't fire
/// `ValueObservation` (see the view model's own doc comment) — and tells it
/// when the Inbox is on screen, which drives its 30 s poll.
struct ActionStripView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
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
                    dayPane: { dayPane($0, vm: vm) },
                    ideas: appState.ideasViewModel,
                    ideaPane: { ideaPane($0, vm: vm) },
                    onOpenSaveDraft: { appState.openSaveProposalDraft($0) },
                    workbenches: appState.inboxWorkbenches,
                    onRetryBuiltin: { id in
                        Task {
                            await vm.retryBuiltinUpgrade(id) { try await appState.restartOnChain(appState.daemonControl) }
                        }
                    },
                    onReconnectSlack: { id in await appState.reconnectSlack(accountID: id) },
                    sessionHoldsCall: { appState.chatSessionPool?.holdsSessionCall($0) ?? false },
                    emptyState: appState.emptyStateContext,
                    onOpenConnections: {
                        appState.settingsTab = .connections
                        openSettings()
                    },
                    ownerKnown: appState.owner.isKnown,
                    learnedRulesDB: appState.databaseManager?.dbPool,
                    profile: appState.secretaryProfileViewModel,
                    tracks: appState.tracksViewModel,
                    trackControls: appState.customTrackControls
                )
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Inbox")
        .task {
            await appState.actionStripViewModel?.refresh()
            // The cheat sheet reads the dictionary through this VM, so a
            // Settings edit made while the Inbox was out of view shows up.
            appState.reactionDictionaryViewModel?.refresh()
            await appState.refreshOwner()
        }
        // The briefing and day-plan switches gate today's placeholder card.
        .onChange(of: appState.featureVisibility.disabledFeatureIDs, initial: true) { _, ids in
            appState.actionStripViewModel?.disabledFeatures = ids
        }
        .onAppear { appState.actionStripViewModel?.setOnScreen(true) }
        .onDisappear { appState.actionStripViewModel?.setOnScreen(false) }
    }

    /// The Your day card over the AppState-owned plan; nil without a CLI.
    private func dayPane(_ day: InboxDayCard, vm: ActionStripViewModel) -> InboxDayPane? {
        guard let plan = appState.dayPlanViewModel else { return nil }
        let makeTask: (BriefingTaskSource) async -> String? = { source in
            guard let briefing = day.briefing else { return nil }
            return await appState.makeTask(from: source, briefing: briefing)
        }
        return InboxDayPane(
            card: day,
            today: HomeFeedBuilder.dayString(Date(), calendar: .current),
            plan: plan,
            owner: appState.owner,
            onDone: { vm.markDayDone(day.date) },
            onCommand: { command in Task { await appState.perform(command) } },
            onOpenSource: appState.openDayPlanItemSource,
            onOpenBriefingLink: appState.openBriefingLink,
            onMakeTask: makeTask,
            briefing: appState.briefingViewModel,
            emptyState: appState.emptyStateContext,
            onOpenConnections: {
                appState.settingsTab = .connections
                openSettings()
            },
            onMade: { await vm.refresh() },
            briefingOn: vm.feed.briefingOn,
            dayPlanOn: vm.feed.dayPlanOn
        )
    }

    /// The idea card over the AppState-owned ideas view model; nil before it exists.
    private func ideaPane(_ idea: Idea, vm: ActionStripViewModel) -> InboxIdeaPane? {
        guard let ideas = appState.ideasViewModel else { return nil }
        return InboxIdeaPane(
            idea: idea,
            ideas: ideas,
            allIdeas: vm.feed.ideas,
            onChange: { await vm.refresh() },
            onMadeTask: { appState.navigateToTarget($0) },
            onDeleted: { id in
                // Its Discuss chat went with it: stop a reply still streaming.
                appState.embeddedChatCenter.dropContext(type: IdeaChatSurface.contextType, id: String(id))
            }
        )
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

    /// The dictionary is edited on the Reactions built-in's card (C3).
    private func openReactionDictionary() {
        appState.openBuiltinAutomation(BuiltinAutomationCard.reactionsID)
    }
}

/// The Inbox under its filter bar: the list and reading pane
/// (`InboxSplitView`), or — when the filter has nothing and no editor is
/// open — the filter's empty state in its place. The empty All list keeps
/// the reaction cheat sheet inline (B); otherwise the cheat sheet stays one
/// `?` click away in the reading pane, never among the cards (a card-shaped
/// help block there would read as something waiting on the owner).
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
    /// A press on a card's buttons (`InboxCardCommand`).
    var onCardAction: (InboxCardCommand) -> Void = { _ in }
    /// The Your day card's pane (`ActionStripView.dayPane`); nil shows its title.
    var dayPane: ((InboxDayCard) -> InboxDayPane?)?
    /// The Ideas filter's New idea and Find Ideas rows; nil leaves them out.
    var ideas: IdeasViewModel?
    /// The idea card (`ActionStripView.ideaPane`); nil shows its title.
    var ideaPane: ((Idea) -> InboxIdeaPane?)?
    /// A `save_automation` proposal's **Open Draft** (`AppState.openSaveProposalDraft`).
    var onOpenSaveDraft: (SaveAutomationCardModel) -> Void = { _ in }
    /// The workbenches a card's agent press can go to (and that name a
    /// workbench proposal's scope).
    var workbenches: [Workbench] = []
    /// A built-in notice's **Retry** (its built-in id).
    var onRetryBuiltin: ((String) -> Void)?
    /// A failed Slack send's Reconnect Slack button (`AppState.reconnectSlack`).
    var onReconnectSlack: ((Int64) async -> String?)?
    /// `AgentActionCardView.sessionHoldsCall` for a row (a connector call).
    var sessionHoldsCall: ((AgentAction) -> Bool)?
    /// The empty list's readiness and actions (`AppState.emptyStateContext`).
    var emptyState: EmptyStateContext = .neutral
    /// With no owner identity the daemon skips the inbox, briefing and day
    /// plan (OWNER-02), so the empty All and Day lists say why and point at
    /// Connections, as Briefings and Day Plan did.
    var onOpenConnections: () -> Void = {}
    var ownerKnown = true
    /// Learned Rules' database and Assistant Profile's view model (the ⋯ menu).
    var learnedRulesDB: DatabasePool?
    var profile: SecretaryProfileViewModel?
    /// The track card's view model and a custom track's controls.
    var tracks: TracksViewModel?
    var trackControls: (any CustomTrackControlling)?
    /// The moment the list's times are told from; nil is now (design shots fix it).
    var now: Date?

    /// What the header opened in the reading pane, and the Ideas filter's
    /// open row; settable at init so a design shot can open one.
    @State var aux: InboxAuxPane?
    @State var ideasRow: InboxIdeasRow?
    @State private var newIdea = InboxNewIdeaDraft()
    @State private var backfillRange = InboxIdeaBackfillRange(from: Date(), to: Date())

    var body: some View {
        let isEmpty = vm.sections.isEmpty
        VStack(spacing: 0) {
            if let message = vm.lastError {
                errorBanner(message)
            }
            InboxFilterBar(
                filter: filter,
                showsCheatSheetButton: !(isEmpty && vm.filter == .all),
                onOpenAux: openAux,
                onFindIdeas: ideas.map { _ in { openIdeasRow(.findIdeas) } }
            ) {
                if let ideas {
                    InboxIdeasHeader(isMining: ideas.isBackfilling,
                                     row: Binding(get: { ideasRow }, set: openIdeasRow))
                }
            }
            if vm.filter == .ideas, let ideas, let ideasRow {
                self.ideasRow(ideasRow, ideas: ideas)
                    .padding(.horizontal, Spacing.medium)
                    .padding(.bottom, Spacing.regular)
            }
            if isEmpty && aux == nil {
                ScrollView {
                    emptyList.padding(.top, Spacing.wide)
                }
                .accessibilityIdentifier(vm.filter == .all ? "actionStrip.cheatSheet" : "inbox.emptyFilter")
            } else {
                InboxSplitView(
                    vm: vm,
                    proposalCard: card,
                    saveProposal: saveProposal,
                    workbenches: workbenches,
                    onRetryBuiltin: onRetryBuiltin,
                    onCardAction: onCardAction,
                    dayPane: dayPane,
                    ideaPane: ideaPane.map { make in
                        { idea in
                            // One prominent action: the open New idea row's Create.
                            make(idea).map { pane in
                                var pane = pane
                                pane.approveIsPrimary = !(vm.filter == .ideas && ideasRow == .newIdea)
                                return pane
                            }
                        }
                    },
                    onOpenAutomationRun: onOpenAutomationRun,
                    now: now,
                    aux: $aux,
                    cheatSheet: cheatSheet,
                    learnedRulesDB: learnedRulesDB,
                    profile: profile,
                    tracks: tracks,
                    trackControls: trackControls
                ) {
                    emptyList
                }
            }
        }
    }

    private var filter: Binding<InboxFilter> {
        Binding(get: { vm.filter }, set: { vm.filter = $0 })
    }

    /// The reaction cheat sheet with the feature's enable/status line.
    private var cheatSheet: ReactionCheatSheetView {
        ReactionCheatSheetView(
            rows: cheatSheetRows,
            feature: feature,
            isEnabling: isEnabling,
            error: featureError,
            onEnable: onEnable,
            onOpenSettings: onOpenSettings
        )
    }

    /// Opens (or closes, nil) the Ideas filter's row; Find Ideas starts from
    /// the range that is mining, or the last two weeks.
    private func openIdeasRow(_ row: InboxIdeasRow?) {
        if row == .findIdeas, ideasRow != .findIdeas, let ideas {
            backfillRange = .initial(ideas)
        }
        ideasRow = row
    }

    @ViewBuilder
    private func ideasRow(_ row: InboxIdeasRow, ideas: IdeasViewModel) -> some View {
        switch row {
        case .newIdea:
            InboxNewIdeaRow(ideas: ideas, draft: $newIdea, onCreated: { id in
                ideasRow = nil
                await vm.open(.ideas, select: .idea(id))
            }, onCancel: { ideasRow = nil })
        case .findIdeas:
            InboxIdeaBackfillRow(ideas: ideas, range: $backfillRange) { ideasRow = nil }
        }
    }

    /// The header's pane opens in the reading pane in place of the selected card.
    private func openAux(_ pane: InboxAuxPane) {
        aux = pane
        Task { await vm.select(nil) }
    }

    /// The filter's empty state: All keeps the reaction cheat sheet (B), All
    /// and Day say why when the owner is unknown.
    @ViewBuilder
    private var emptyList: some View {
        TabEmptyState(copyKey: vm.filter.emptyCopyKey, context: emptyState) {
            if !ownerKnown, vm.filter == .all || vm.filter == .day {
                NoOwnerEmptyState(openConnections: onOpenConnections)
            }
            if vm.filter == .all {
                cheatSheet.frame(maxWidth: .infinity)
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
