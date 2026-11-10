import GRDB
import SwiftUI
import WatchtowerCore

/// The Inbox tab's content: the folder menu and the selected folder
/// (`ActionStripActionsView`) over every kind that needs the owner — the
/// day card, messages, tracks, ideas, proposals, due reminders and
/// automation artifacts. The learned-rules
/// manager still feeds the digest/tracks/briefing/catch-up prompts
/// (`ListLearnedRulesByPipeline`) and the assistant profile editor still
/// feeds Catch-Up compose and the idea chat, so they keep their door here:
/// the root's ⋯ in the folder menu opens them in the reading pane (R7).
/// Reads `appState.actionStripViewModel` (AppState-owned so it survives
/// navigation, the `SlackAccountsViewModel` house pattern), re-`refresh()`es
/// on every appear — cross-process daemon/CLI writes don't fire
/// `ValueObservation` (see the view model's own doc comment) — and tells it
/// when the Inbox is on screen, which drives its 30 s poll.
struct ActionStripView: View {
    @Environment(AppState.self) private var appState

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
                    onOpenConnections: { appState.openConnections() },
                    ownerKnown: appState.owner.isKnown,
                    learnedRulesDB: appState.databaseManager?.dbPool,
                    profile: appState.secretaryProfileViewModel,
                    tracks: appState.tracksViewModel,
                    trackControls: appState.customTrackControls,
                    onTurnOnApprovals: { await appState.turnOnNeedsApproval() },
                    onRunHistory: { automationID, runID in
                        appState.openAutomationRun(automationID: automationID, runID: runID)
                    },
                    onNewArtifact: { appState.newInboxArtifact() },
                    onMakeTaskFromTrack: { await appState.makeTask(fromTrack: $0) },
                    onGoToTarget: { appState.navigateToTarget($0) },
                    artifactMenu: appState.inboxArtifactMenu
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
            onCommand: { command in Task { await appState.perform(command) } },
            onOpenSource: appState.openDayPlanItemSource,
            onOpenBriefingLink: appState.openBriefingLink,
            onMakeTask: makeTask,
            briefing: appState.briefingViewModel,
            emptyState: appState.emptyStateContext,
            onOpenConnections: { appState.openConnections() },
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
        case .boards: appState.openConnections(.jira)
        case .url(let url): NSWorkspace.shared.open(url)
        }
    }

    /// The dictionary is edited on the Reactions built-in's card (C3).
    private func openReactionDictionary() {
        appState.openBuiltinAutomation(BuiltinAutomationCard.reactionsID)
    }
}

/// The Inbox (inbox builder B): the folder menu, then the selected folder —
/// its entry list beside the reading pane (the root and owner folders),
/// Needs approval's one column of cards, or, from a legacy entry of the
/// root (Track my threads, Idea finder, Messages; ask #445), today's list
/// for it with its own reading pane (`InboxSplitView`). An empty root says
/// so and keeps the reaction cheat sheet inline while nothing in the Inbox
/// waits on the owner (B); otherwise the cheat sheet stays one `?` click
/// away in the reading pane, never among the cards (a card-shaped help
/// block there would read as something waiting on the owner).
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
    /// The Idea finder's New idea and Find Ideas rows; nil leaves them out.
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
    /// Needs approval's **Turn On** (off and stopped notes): the built-in
    /// card's own `AppState.setBuiltinEnabled(["approval-cards"], on: true)`.
    var onTurnOnApprovals: () async -> String? = { nil }
    /// Needs approval's **Run History**: the automation's card, the run open.
    var onRunHistory: (Int64, Int64?) -> Void = { _, _ in }
    /// **+ New Artifact…** and the empty folders' **New Artifact…**: the
    /// Automations tab's New flow, the selected owner folder as its route.
    var onNewArtifact: () -> Void = {}
    /// A track row's **Make a Task** (`AppState.makeTask(fromTrack:)`): why it failed, or nil.
    var onMakeTaskFromTrack: (Track) async -> String? = { _ in nil }
    /// A track row's **Go to Target**, an idea made into a task.
    var onGoToTarget: (Int) -> Void = { _ in }
    /// The artifact ⋯ (reading pane, list rows) and Needs approval's ⋯;
    /// nil (tests, shots) draws neither.
    var artifactMenu: InboxArtifactMenuModel?

    /// What the header opened in the reading pane, and the Idea finder's
    /// open row; settable at init so a design shot can open one.
    @State var aux: InboxAuxPane?
    @State var ideasRow: InboxIdeasRow?
    @State private var newIdea = InboxNewIdeaDraft()
    @Environment(\.markdownNavScreens) private var navScreens
    @State private var backfillRange = InboxIdeaBackfillRange(from: Date(), to: Date())
    /// Proposals whose recipe card's **Edit…** was pressed: Needs approval
    /// draws their native card, with its argument editor, in its place.
    @State private var editingActions: Set<Int64> = []

    /// The Inbox's header and the strip's error line above all three
    /// columns (b-01), then the folder menu and the selected folder.
    var body: some View {
        VStack(spacing: 0) {
            header
            if let message = vm.lastError {
                errorBanner(message)
            }
            HSplitView {
                InboxFolderMenuColumn(model: vm.folderMenu, onOpenAux: openAux, onCommand: folderMenuCommand,
                                      onNewArtifact: onNewArtifact, onSelect: selectFolder)
                    .frame(minWidth: PaneWidth.sideListMin, idealWidth: PaneWidth.sideListIdeal,
                           maxWidth: PaneWidth.sideListMax, maxHeight: .infinity)
                inbox
                    .frame(minWidth: PaneWidth.detailMin, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var inbox: some View {
        VStack(spacing: 0) {
            if let list = vm.legacyList {
                legacyHeader(list)
                if list == .ideas, let ideas, let ideasRow {
                    self.ideasRow(ideasRow, ideas: ideas)
                        .padding(.horizontal, Spacing.medium)
                        .padding(.bottom, Spacing.regular)
                }
            }
            content
        }
        .confirmationDialog(deleteTitle, isPresented: deleteConfirming,
                            presenting: artifactMenu?.pendingDelete) { pending in
            Button("Delete", role: .destructive) {
                guard let artifactMenu else { return }
                Task { await artifactMenu.confirmDelete(pending) }
            }
            Button("Cancel", role: .cancel) { artifactMenu?.cancelDelete() }
        } message: { _ in
            Text("This removes the recipe file with its runs, state and outputs.")
        }
    }

    // MARK: - The ⋯ menus

    /// The artifact ⋯'s Delete…, behind the Automations tab's own confirmation.
    private var deleteConfirming: Binding<Bool> {
        Binding(get: { artifactMenu?.pendingDelete != nil }, set: { shown in
            if !shown { artifactMenu?.cancelDelete() }
        })
    }

    private var deleteTitle: String {
        "Delete “\(artifactMenu?.pendingDelete?.name ?? "")”?"
    }

    /// A folder-menu ⋯ press the menu does not carry out: Needs approval's.
    private func folderMenuCommand(_ folderID: Int64, _ command: InboxMenuCommand) {
        guard vm.folderMenu.tree.folder(folderID)?.kind == .approvals, let artifactMenu else { return }
        Task { await artifactMenu.performApprovals(command, fromFolder: folderID) }
    }

    /// `card`'s ⋯ in the reading pane.
    private func artifactMenuState(_ card: AutomationOutputCard) -> InboxArtifactMenuState? {
        guard let artifactMenu else { return nil }
        return InboxArtifactMenuState(
            entries: artifactMenu.content(for: card).entries,
            isDisabled: artifactMenu.isDisabled(card),
            isWorking: artifactMenu.isWorking(card),
            error: artifactMenu.headerErrors[card.id]
        ) { command in Task { await artifactMenu.perform(command, on: card) } }
    }

    /// The artifact a list row stands for.
    private func artifactCard(_ rowID: String) -> AutomationOutputCard? {
        for entry in vm.folderEntries {
            if case let .artifact(card) = entry, entry.id == rowID { return card }
        }
        return nil
    }

    /// An artifact row's context menu: its ⋯.
    private func rowContextMenu(_ row: InboxFolderListRow) -> [InboxMenuEntry] {
        guard row.kind == .artifact, let artifactMenu, let card = artifactCard(row.id),
              !artifactMenu.isDisabled(card) else { return [] }
        return artifactMenu.content(for: card).entries
    }

    private var folderKind: InboxFolderKind {
        (vm.folderMenu.tree.folder(vm.folderMenu.selectedFolderID) ?? vm.folderMenu.tree.root).kind
    }

    /// The empty root keeps the cheat sheet inline while nothing in the
    /// Inbox waits (every folder's count is 0); then its `?` is not shown.
    private var showsInlineCheatSheet: Bool {
        vm.hasRead && vm.legacyList == nil && aux == nil && folderKind == .root && vm.folderEntries.isEmpty
            && vm.folderMenu.snapshot.counts.values.allSatisfy { $0 == 0 }
    }

    /// The Inbox's title and the `?` (reaction commands), above the menu,
    /// the list and the reading pane.
    private var header: some View {
        HStack(spacing: Spacing.regular) {
            Text("Inbox").font(.headline)
            Spacer(minLength: 0)
            if !showsInlineCheatSheet {
                Button {
                    openAux(.reactionCommands)
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.kitIcon(isOn: false))
                .help("Reaction commands")
                .accessibilityLabel("Reaction commands")
                .accessibilityIdentifier("actionStrip.cheatSheetButton")
            }
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.regular)
    }

    /// A legacy list's way back to the root, its title and the Idea
    /// finder's controls.
    private func legacyHeader(_ list: InboxLegacyList) -> some View {
        HStack(spacing: Spacing.regular) {
            Button {
                vm.closeLegacy()
            } label: {
                Label(vm.folderMenu.tree.root.title, systemImage: "chevron.left")
            }
            .buttonStyle(.kitQuiet)
            .help("Back to the folder")
            Text(list.title).font(.headline)
            if list == .ideas, let ideas {
                InboxIdeasHeader(isMining: ideas.isBackfilling,
                                 row: Binding(get: { ideasRow }, set: openIdeasRow))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.regular)
    }

    @ViewBuilder
    private var content: some View {
        if !vm.hasRead, let reason = vm.firstReadError {
            // The first read failed: say so, never a spinner that never ends.
            Self.firstReadFailure(reason) { Task { await vm.refresh() } }
        } else if !vm.hasRead {
            // Nothing read yet: no "empty" or cheat sheet for a moment.
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("inbox.loading")
        } else if let list = vm.legacyList {
            legacySplit(list)
        } else if folderKind == .approvals {
            if let aux {
                auxPane(aux)
            } else {
                approvalsPane
            }
        } else if vm.folderEntries.isEmpty, aux == nil {
            folderList
        } else {
            PanelSplit(isPanelShown: true, width: inboxPaneWidth) {
                folderList
            } panel: {
                if let aux {
                    auxPane(aux)
                } else {
                    readingPane(vm.selectedEntry)
                }
            }
            .detailBackground()
        }
    }

    // MARK: - A folder's list and reading pane

    private var folderList: some View {
        // Labeled: with several closures a trailing one would be ambiguous.
        // swiftlint:disable trailing_closure
        InboxFolderContentList(
            content: vm.folderList,
            onSelect: { id in
                aux = nil
                Task { await vm.selectEntry(id) }
            },
            onNewArtifact: onNewArtifact,
            onMenu: entryMenu,
            contextMenu: rowContextMenu,
            emptyState: emptyState,
            emptyExtra: { rootEmptyExtra }
        )
        // swiftlint:enable trailing_closure
        .accessibilityIdentifier(showsInlineCheatSheet ? "actionStrip.cheatSheet" : "inbox.folderList")
        .task(id: listedArtifacts.map(\.automationID)) { await artifactMenu?.prepare(listedArtifacts) }
    }

    /// The artifacts the folder's list shows (their rows' context menus).
    private var listedArtifacts: [AutomationOutputCard] {
        vm.folderEntries.compactMap { entry in
            if case let .artifact(card) = entry { card } else { nil }
        }
    }

    /// Under the empty root: why it is empty without an owner (OWNER-02),
    /// and the reaction cheat sheet while nothing in the Inbox waits.
    @ViewBuilder
    private var rootEmptyExtra: some View {
        if folderKind == .root {
            if !ownerKnown {
                NoOwnerEmptyState(openConnections: onOpenConnections)
            }
            if showsInlineCheatSheet {
                cheatSheet.frame(maxWidth: .infinity)
            }
        }
    }

    /// A legacy entry's own ⋯ (the Idea finder's Find Ideas in Past
    /// Messages…), or an artifact row's context menu.
    private func entryMenu(_ entryID: String, _ command: InboxMenuCommand) {
        if let card = artifactCard(entryID), let artifactMenu {
            Task { await artifactMenu.perform(command, on: card) }
            return
        }
        guard command == .findIdeasInPastMessages, ideas != nil else { return }
        vm.openLegacy(.ideas)
        openIdeasRow(.findIdeas)
    }

    /// The entry's pane: an artifact (with its ⋯) or a day card in today's reading pane.
    @ViewBuilder
    private func readingPane(_ entry: InboxFolderEntry?) -> some View {
        switch entry {
        case let .artifact(card)?:
            pane(.output(card), menu: artifactMenuState(card))
                .task(id: card.automationID) { await artifactMenu?.prepare(card) }
        case let .legacyDay(card)?: pane(.day(card))
        case let .approval(item)?: pane(Self.listItem(item))
        case let .builtinNotice(notice)?: pane(.builtinNotice(notice))
        case .legacyTracks?, .legacyIdeas?, .legacyMessages?, nil: pane(nil)
        }
    }

    /// An approval as today's card: the recipe's card when it is current, else native.
    private static func listItem(_ item: NeedsApprovalItem) -> InboxListItem {
        if let recipe = item.recipe { return .output(recipe) }
        switch item.record {
        case let .action(action): return .proposal(action)
        case let .reminder(reminder): return .reminder(reminder)
        }
    }

    /// Today's reading pane over one card, its presses on the strip's writes.
    /// The reading pane for `item`; `inApprovals` draws it as one card of
    /// Needs approval's stack (`InboxReadingPane.stackedInApprovals()`).
    private func pane(
        _ item: InboxListItem?, inApprovals: Bool = false, menu: InboxArtifactMenuState? = nil
    ) -> some View {
        let now = now ?? Date()
        let pane = InboxReadingPane(
            item: item,
            navScreens: navScreens,
            targets: vm.targetButtons(now: now),
            now: now,
            isWriting: item.map { vm.isWriting($0.id) } ?? false,
            onCommand: onCardAction,
            onOpenAutomationRun: onOpenAutomationRun,
            onDone: { item.map { done($0.id) } },
            onDismiss: { item.map { dismiss($0.id) } },
            onSnooze: { duration in item.map { snooze($0.id, duration) } },
            proposalCard: card,
            saveProposal: saveProposal,
            onRetryBuiltin: onRetryBuiltin,
            workbenches: workbenches,
            artifactPeople: vm.feed.artifactPeople,
            dayCard: { card in
                if let pane = dayPane?(card) {
                    pane
                } else {
                    InboxCardPlaceholder(day: card)
                }
            },
            trackCard: { track in InboxCardColumn { InboxCardPlaceholder(track: track, now: now) } },
            ideaCard: { InboxCardPlaceholder(idea: $0).padding(Spacing.page) }
        )
        let handler = rowHandler(replyHost: InboxRefHooks.replyHost(item))
        let refHooks = refHooks(handler)
        let withHooks = pane
            .refHooks(refHooks.hooks)
            .messageReply({ refHooks.messageReply($0) }, onPress: Self.messageReplyPress(handler))
            .withArtifactMenu(menu)
        return inApprovals ? withHooks.stackedInApprovals() : withHooks
    }

    // MARK: - Native row actions

    /// The native actions on an artifact's rows with a `ref`.
    private func refHooks(_ handler: InboxRowActionHandler) -> InboxRefHooks {
        // Labeled: with several closures a trailing one would be ambiguous.
        // swiftlint:disable trailing_closure
        InboxRefHooks(vm: vm, navScreens: navScreens, workbenches: workbenches,
                      sessionHoldsCall: { sessionHoldsCall?($0) ?? false }, ideasAvailable: ideas != nil,
                      onCommand: onCardAction,
                      onPress: { ref, press in Self.dispatch(press, on: ref, handler) })
        // swiftlint:enable trailing_closure
    }

    /// A message card's Reply presses, by `inbox_items` id.
    private static func messageReplyPress(_ handler: InboxRowActionHandler) -> (Int, InboxRowPress) -> Void {
        { id, press in dispatch(press, on: InboxRef(kind: .inboxItem, id: Int64(id)), handler) }
    }

    /// The Reply composer's own presses at once (keystrokes keep their
    /// order); every other press in a task.
    private static func dispatch(_ press: InboxRowPress, on ref: InboxRef, _ handler: InboxRowActionHandler) {
        guard !handler.pressNow(press, on: ref) else { return }
        Task { await handler.press(press, on: ref) }
    }

    private func rowHandler(replyHost: String) -> InboxRowActionHandler {
        InboxRowActionHandler(
            vm: vm,
            ideas: ideas,
            onCommand: onCardAction,
            onMakeTaskFromTrack: onMakeTaskFromTrack,
            onGoToTarget: onGoToTarget,
            onIdeaMadeTask: onGoToTarget,
            onEditAction: { editingActions.insert($0) },
            onOpenSaveDraft: onOpenSaveDraft,
            sessionHoldsCall: { sessionHoldsCall?($0) ?? false },
            navScreens: navScreens,
            now: { now ?? Date() },
            replyHost: replyHost
        )
    }

    private func done(_ id: InboxSelection) {
        Task {
            switch id {
            case .output(let output): await vm.markOutputDone(output)
            case .reminder(let reminder): await vm.markReminderDone(reminder)
            case .proposal, .day, .track, .idea, .message, .builtinNotice: break
            }
        }
    }

    private func dismiss(_ id: InboxSelection) {
        guard case .output(let output) = id else { return }
        Task { await vm.dismissOutput(output) }
    }

    /// A reminder's Snooze 1h, the only snooze these cards offer.
    private func snooze(_ id: InboxSelection, _ duration: String) {
        guard case .reminder(let reminder) = id, duration == "1h" else { return }
        let until = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        Task { await vm.snoozeReminder(reminder, until: until) }
    }

    // MARK: - Needs approval

    private var approvalsPane: some View {
        let entries = vm.folderEntries
        // Labeled: with several closures a trailing one would be ambiguous.
        // swiftlint:disable trailing_closure
        return NeedsApprovalPane(
            count: entries.count,
            note: vm.approvalsNoteContent,
            menu: artifactMenu == nil ? []
                : InboxArtifactMenuContent.approvalsEntries(isEnabled: vm.folderMenu.approvalsEnabled),
            menuError: artifactMenu?.approvalsError,
            menuWorking: artifactMenu?.approvalsPressing ?? false,
            onNote: { Task { await vm.pressApprovalsNote(turnOn: onTurnOnApprovals, runHistory: onRunHistory) } },
            onMenu: { command in Task { await artifactMenu?.performApprovals(command) } },
            emptyState: emptyState,
            scrollTarget: vm.entrySelection,
            cards: {
                ForEach(entries) { entry in
                    approvalCard(entry).id(entry.id)
                }
            }
        )
        // swiftlint:enable trailing_closure
        .detailBackground()
    }

    /// One Needs approval card: a native proposal is today's card; a
    /// reminder, a notice and the recipe's card are today's reading pane on
    /// a card fill.
    @ViewBuilder
    private func approvalCard(_ entry: InboxFolderEntry) -> some View {
        switch entry {
        case let .approval(item) where item.recipe == nil || isEditing(item):
            if case let .action(action) = item.record {
                if action.tool == SaveAutomationCardModel.tool, action.isPending {
                    saveProposal(action)
                } else {
                    card(action)
                }
            } else {
                filled(Self.listItem(item))
            }
        case let .approval(item):
            // The recipe's card: no Done/Dismiss (they would close the
            // artifact, not the approval); its row's native actions act on it.
            filled(Self.listItem(item))
        case let .builtinNotice(notice):
            filled(.builtinNotice(notice))
        case .artifact, .legacyDay, .legacyTracks, .legacyIdeas, .legacyMessages:
            EmptyView()
        }
    }

    /// **Edit…** was pressed on this proposal's recipe card.
    private func isEditing(_ item: NeedsApprovalItem) -> Bool {
        guard case let .action(action) = item.record else { return false }
        return editingActions.contains(action.id)
    }

    private func filled(_ item: InboxListItem) -> some View {
        pane(item, inApprovals: true)
            .padding(Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
    }

    // MARK: - A legacy list

    /// Today's list for a legacy entry, with its own reading pane.
    private func legacySplit(_ list: InboxLegacyList) -> some View {
        // The Messages entry's card has Reply while it stands in for Waiting for me.
        let handler = rowHandler(replyHost: InboxRefHooks.replyHost(nil))
        let refHooks = refHooks(handler)
        return InboxSplitView(
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
                        pane.approveIsPrimary = !(list == .ideas && ideasRow == .newIdea)
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
            TabEmptyState(copyKey: list.emptyCopyKey, context: emptyState)
                .accessibilityIdentifier("inbox.emptyLegacyList")
        }
        .messageReply({ refHooks.messageReply($0) }, onPress: Self.messageReplyPress(handler))
    }

    // MARK: - The panes the header and the menu open

    private func auxPane(_ pane: InboxAuxPane) -> some View {
        InboxAuxPaneView(pane: pane, cheatSheet: cheatSheet, learnedRulesDB: learnedRulesDB,
                         profile: profile) { aux = nil }
            .detailBackground()
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

    /// Opens (or closes, nil) the Idea finder's row; Find Ideas starts from
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
                await vm.open(folder: nil, select: .card(.idea(id)))
            }, onCancel: { ideasRow = nil })
        case .findIdeas:
            InboxIdeaBackfillRow(ideas: ideas, range: $backfillRange) { ideasRow = nil }
        }
    }

    /// A folder picked in the menu: its list, nothing open.
    private func selectFolder(_ id: Int64) {
        aux = nil
        ideasRow = nil
        vm.selectFolder(id)
    }

    /// The menu's and header's pane opens in the reading pane in place of the selected card.
    private func openAux(_ pane: InboxAuxPane) {
        aux = pane
        Task { await vm.select(nil) }
    }

    private func card(_ action: AgentAction) -> AgentActionCardView {
        // An Inbox target button's newest proposal: the button's state, so a
        // stuck row (Needs approval keeps approved and executing rows on their
        // native card) offers Try again (apply, or apply --force on the same row).
        let targetState = vm.targetFacts(for: action).map { TargetButtonStateResolver.state($0, now: now ?? Date()) }
        return AgentActionCardView(
            action: action,
            inFlight: vm.actionFeed.inFlight.contains(action.id),
            onApprove: { Task { await vm.approve(action.id, shownArgs: action.argsJSON) } },
            onReject: { Task { await vm.reject(action.id) } },
            onRetry: {
                Task {
                    if targetState != nil { await vm.tryAgainTarget(action.id) } else { await vm.retry(action.id) }
                }
            },
            gestureError: vm.actionFeed.rowErrors[action.id],
            onOpen: onOpen,
            onApproveEdited: { patch in Task { await vm.approve(action.id, shownArgs: action.argsJSON, patch: patch) } },
            onReconnectSlack: onReconnectSlack,
            contextLabel: vm.actionLabels[action.id],
            onOpenContext: openContext(action),
            onDismiss: { Task { await vm.dismiss(action.id) } },
            sessionHoldsCall: sessionHoldsCall?(action) ?? false,
            targetButtonState: targetState,
            offersRetry: !vm.isSupersededButtonRow(action)
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

    /// The Inbox when its first read failed: the reason and Try Again.
    static func firstReadFailure(_ reason: String, onTryAgain: @escaping () -> Void) -> some View {
        FeatureEmptyState(
            copy: EmptyStateCopy(
                icon: "exclamationmark.triangle", title: "The Inbox could not be read", landsHere: reason,
                feature: nil, primaryAction: .tabAction(label: "Try Again")),
            readiness: nil, syncLine: nil, turnOnError: nil, isTurningOn: false,
            onAction: { _ in onTryAgain() },
            extra: { EmptyView() }
        )
        .accessibilityIdentifier("inbox.readFailed")
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
