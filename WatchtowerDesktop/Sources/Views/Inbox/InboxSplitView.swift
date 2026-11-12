import GRDB
import SwiftUI
import WatchtowerCore

/// The Inbox read like mail (spec B1, C1 §6.1): the list on the left —
/// Needs your decision, Today, Earlier, for the legacy entry the root opened
/// (Track my threads, Idea finder, Messages), or its empty state — and the reading pane on the right, which also
/// holds the reaction cheat sheet, Learned Rules or Assistant Profile when
/// the header opens one.
/// Arrow keys move the selection, Escape clears it, and opening a card marks
/// it read (`ActionStripViewModel.select`). Done, Dismiss, Hide or Snooze on
/// the shown card opens the next row.
struct InboxSplitView<EmptyList: View>: View {
    let vm: ActionStripViewModel
    /// A proposal's card in the reading pane.
    let proposalCard: (AgentAction) -> AgentActionCardView
    /// A pending `save_automation` proposal in the reading pane.
    let saveProposal: ((AgentAction) -> SaveAutomationProposalPane)?
    /// The workbenches a card's agent press can go to.
    let workbenches: [Workbench]
    /// A built-in notice's **Retry** (its built-in id).
    let onRetryBuiltin: ((String) -> Void)?
    let onCardAction: (InboxCardCommand) -> Void
    /// The Your day card's pane; nil shows its title and source line.
    let dayPane: ((InboxDayCard) -> InboxDayPane?)?
    /// The idea card; nil shows its title and source line.
    let ideaPane: ((Idea) -> InboxIdeaPane?)?
    let onOpenAutomationRun: ((Int64) -> Void)?
    /// The moment Today starts from; nil is now (design shots fix it).
    let now: Date?
    /// What the header opened in the reading pane; nil shows the card.
    @Binding var aux: InboxAuxPane?
    /// The reaction cheat sheet the `?` opens; nil says it is unavailable.
    let cheatSheet: ReactionCheatSheetView?
    /// Learned Rules' database; nil says it is unavailable.
    let learnedRulesDB: DatabasePool?
    /// Assistant Profile's view model; nil says it is unavailable.
    let profile: SecretaryProfileViewModel?
    /// The track card's view model and a custom track's controls; nil
    /// (tests, design shots) shows a track card's title and source line.
    let tracks: TracksViewModel?
    let trackControls: (any CustomTrackControlling)?
    /// The list column when the list has nothing.
    let emptyList: EmptyList
    /// A message card's Reply (`messageReply(_:onPress:)`); nil draws none.
    private(set) var messageReplyContent: (HomeFeedInboxRow) -> InboxRowActionsContent? = { _ in nil }
    private(set) var onMessageReplyPress: (Int, InboxRowPress) -> Void = { _, _ in }

    @Environment(\.markdownNavScreens) private var navScreens

    init(
        vm: ActionStripViewModel,
        proposalCard: @escaping (AgentAction) -> AgentActionCardView,
        saveProposal: ((AgentAction) -> SaveAutomationProposalPane)? = nil,
        workbenches: [Workbench] = [],
        onRetryBuiltin: ((String) -> Void)? = nil,
        onCardAction: @escaping (InboxCardCommand) -> Void,
        dayPane: ((InboxDayCard) -> InboxDayPane?)? = nil,
        ideaPane: ((Idea) -> InboxIdeaPane?)? = nil,
        onOpenAutomationRun: ((Int64) -> Void)? = nil,
        now: Date? = nil,
        aux: Binding<InboxAuxPane?> = .constant(nil),
        cheatSheet: ReactionCheatSheetView? = nil,
        learnedRulesDB: DatabasePool? = nil,
        profile: SecretaryProfileViewModel? = nil,
        tracks: TracksViewModel? = nil,
        trackControls: (any CustomTrackControlling)? = nil,
        @ViewBuilder emptyList: () -> EmptyList
    ) {
        self.vm = vm
        self.proposalCard = proposalCard
        self.saveProposal = saveProposal
        self.workbenches = workbenches
        self.onRetryBuiltin = onRetryBuiltin
        self.onCardAction = onCardAction
        self.dayPane = dayPane
        self.ideaPane = ideaPane
        self.onOpenAutomationRun = onOpenAutomationRun
        self.now = now
        _aux = aux
        self.cheatSheet = cheatSheet
        self.learnedRulesDB = learnedRulesDB
        self.profile = profile
        self.tracks = tracks
        self.trackControls = trackControls
        self.emptyList = emptyList()
    }

    /// This split view with Reply on its reading pane's message card
    /// (`InboxReadingPane.messageReply(_:onPress:)`).
    func messageReply(
        _ content: @escaping (HomeFeedInboxRow) -> InboxRowActionsContent?,
        onPress: @escaping (Int, InboxRowPress) -> Void
    ) -> Self {
        var split = self
        split.messageReplyContent = content
        split.onMessageReplyPress = onPress
        return split
    }

    var body: some View {
        let now = now ?? Date()
        let sections = vm.sections
        HSplitView {
            list(sections, now: now)
                .inboxListColumn()
            Group {
                if let aux {
                    InboxAuxPaneView(pane: aux, cheatSheet: cheatSheet, learnedRulesDB: learnedRulesDB,
                                     profile: profile) { self.aux = nil }
                } else {
                    pane(sections, now: now)
                }
            }
            .inboxPaneColumn()
        }
    }

    // MARK: - The list

    @ViewBuilder
    private func list(_ sections: [InboxSection], now: Date) -> some View {
        if sections.isEmpty {
            ScrollView {
                emptyList.padding(.top, Spacing.wide)
            }
        } else {
            List(selection: selection) {
                // Each title is a plain row that cannot be selected, not a
                // Section header: a plain List pins its header and draws a
                // hairline under it.
                ForEach(sections, id: \.title) { section in
                    sectionTitle(section)
                        .padding(.top, Spacing.regular)
                        .selectionDisabled()
                        .listRowSeparator(.hidden)
                    ForEach(section.items) { item in
                        InboxLegacyListRow(item: item, now: now)
                            .tag(Optional(item.id))
                            .listRowSeparator(.hidden)
                    }
                }
            }
            .clearPlainList()
            .onExitCommand { Task { await vm.select(nil) } }
        }
    }

    /// A section's title; Track my threads' Stopped fold opens and closes here.
    @ViewBuilder
    private func sectionTitle(_ section: InboxSection) -> some View {
        if section.foldable {
            HStack(spacing: Spacing.regular) {
                SectionHeader(title: section.title, systemImage: "pause.circle")
                Spacer()
                Button(vm.showsStopped ? "Hide" : "Show") { vm.showsStopped.toggle() }
                    .buttonStyle(.kitQuiet)
                    .controlSize(.small)
                    .help(vm.showsStopped ? "Hide the tracks you stopped watching"
                                          : "Show the tracks you stopped watching")
            }
        } else {
            SectionHeader(title: section.title, systemImage: Self.icon(section.title), count: section.items.count)
        }
    }

    private var selection: Binding<InboxSelection?> {
        // The highlight moves at once; only the opening's `read_at` waits.
        Binding(get: { vm.selection }, set: { item in
            aux = nil
            vm.selection = item
            Task { await vm.select(item) }
        })
    }

    private static func icon(_ section: String) -> String {
        switch section {
        case "Needs your decision": "hand.raised"
        case "Today": "sun.max"
        default: "clock"
        }
    }

    // MARK: - The reading pane

    private func pane(_ sections: [InboxSection], now: Date) -> some View {
        let shown = vm.selection.flatMap { id in sections.flatMap(\.items).first { $0.id == id } }
        return InboxReadingPane(
            item: shown,
            navScreens: navScreens,
            targets: vm.targetButtons(now: now),
            now: now,
            isWriting: shown.map { vm.isWriting($0.id) } ?? false,
            onCommand: onCardAction,
            onOpenAutomationRun: onOpenAutomationRun,
            onDone: { shown.map { close($0.id, in: sections, done) } },
            onDismiss: { shown.map { close($0.id, in: sections, dismiss) } },
            onSnooze: { duration in
                shown.map { card in close(card.id, in: sections) { id in await snooze(id, duration) } }
            },
            proposalCard: proposalCard,
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
            trackCard: { trackPane($0, in: sections, now: now) },
            ideaCard: { idea in
                if let pane = ideaPane?(idea) {
                    pane
                } else {
                    InboxCardPlaceholder(idea: idea).padding(Spacing.page)
                }
            }
        )
        .messageReply(messageReplyContent, onPress: onMessageReplyPress)
    }

    /// The track card; Done and Stop watching open the next row once it left.
    @ViewBuilder
    private func trackPane(_ card: InboxTrackCard, in sections: [InboxSection], now: Date) -> some View {
        let id = InboxSelection.track(card.track.id)
        if let tracks, let trackControls {
            InboxTrackPane(
                card: card, tracks: tracks, controls: trackControls, isWriting: vm.isWriting(id),
                onDone: { close(id, in: sections, done) },
                onStopWatching: { close(id, in: sections) { _ in await vm.stopWatching(card.track) } },
                // The card stays listed (it moves out of the Stopped fold).
                onRestore: { Task { await vm.restoreTrack(card.track) } },
                onCommand: onCardAction, workbenches: workbenches
            )
        } else {
            InboxCardColumn { InboxCardPlaceholder(track: card, now: now) }
        }
    }

    /// Runs `write` on the shown row; once the row has left the list, opens
    /// the next one, as mail does.
    private func close(
        _ id: InboxSelection,
        in sections: [InboxSection],
        _ write: @escaping @MainActor (InboxSelection) async -> Void
    ) {
        let next = InboxListBuilder.selection(after: id, in: sections)
        Task {
            await write(id)
            // The refresh after the write may already have moved the
            // selection to `next`; opening it still writes its read mark.
            guard !isListed(id), vm.selection == nil || vm.selection == id || vm.selection == next else { return }
            await vm.select(next)
        }
    }

    private func isListed(_ id: InboxSelection) -> Bool {
        vm.sections.contains { $0.items.contains { $0.id == id } }
    }

    private func done(_ id: InboxSelection) async {
        switch id {
        case .output(let output): await vm.markOutputDone(output)
        case .reminder(let reminder): await vm.markReminderDone(reminder)
        case .message(let message): await vm.messageDone(message)
        case .track(let track): await vm.markTrackDone(track)
        case .proposal, .day, .idea, .builtinNotice: break
        }
    }

    /// An output's Dismiss, a message's Hide.
    private func dismiss(_ id: InboxSelection) async {
        switch id {
        case .output(let output): await vm.dismissOutput(output)
        case .message(let message): await vm.hideMessage(message)
        case .proposal, .reminder, .day, .track, .idea, .builtinNotice: break
        }
    }

    /// A reminder snoozes an hour; a message for its chosen duration.
    private func snooze(_ id: InboxSelection, _ duration: String) async {
        switch id {
        case .reminder(let reminder):
            // The reminder pane offers only Snooze 1h ("1h").
            let seconds: TimeInterval = duration == "1h" ? 3600 : 0
            guard seconds > 0 else { return }
            let until = ISO8601DateFormatter().string(from: Date().addingTimeInterval(seconds))
            await vm.snoozeReminder(reminder, until: until)
        case .message(let message): await vm.snoozeMessage(message, duration: duration)
        case .proposal, .output, .day, .track, .idea, .builtinNotice: break
        }
    }
}

extension View {
    /// The Inbox's list column (`PaneWidth.inboxList*`), shared by the
    /// folder list and every `InboxSplitView`.
    func inboxListColumn() -> some View {
        frame(minWidth: PaneWidth.inboxListMin, idealWidth: PaneWidth.inboxListIdeal,
              maxWidth: PaneWidth.inboxListMax, maxHeight: .infinity)
            .detailBackground()
    }

    /// The Inbox's reading pane: the rest of the window. Its layout
    /// priority keeps the split from giving the rail or the list more than
    /// their ideal width.
    func inboxPaneColumn() -> some View {
        frame(minWidth: PaneWidth.detailMin, maxWidth: .infinity, maxHeight: .infinity)
            .detailBackground()
            .layoutPriority(1)
    }
}

/// The reaction cheat sheet, Learned Rules or Assistant Profile in the
/// reading pane, under a title with a close button back to the card.
struct InboxAuxPaneView: View {
    let pane: InboxAuxPane
    let cheatSheet: ReactionCheatSheetView?
    let learnedRulesDB: DatabasePool?
    let profile: SecretaryProfileViewModel?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(pane.title).font(.headline)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.kitIcon(isOn: false))
                    .help("Close")
                    .accessibilityLabel("Close")
            }
            .padding(.horizontal, Spacing.medium)
            .padding(.vertical, Spacing.regular)
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch pane {
        case .reactionCommands:
            if let cheatSheet {
                ScrollView {
                    cheatSheet.padding(Spacing.medium)
                }
            } else {
                unavailable
            }
        case .learnedRules:
            if let learnedRulesDB {
                InboxLearnedRulesView(db: learnedRulesDB)
            } else {
                unavailable
            }
        case .profile:
            if let profile {
                SecretaryProfileView(vm: profile)
            } else {
                unavailable
            }
        }
    }

    private var unavailable: some View {
        Text("Database unavailable")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
