import GRDB
import SwiftUI
import WatchtowerCore

/// The Inbox read like mail (spec B1, C1 §6.1): the list on the left —
/// Needs your decision, Today, Earlier, for the chosen filter, or the
/// filter's empty state — and the reading pane on the right, which also
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
    /// The list column when the filter has nothing.
    let emptyList: EmptyList

    @Environment(\.markdownNavScreens) private var navScreens

    init(
        vm: ActionStripViewModel,
        proposalCard: @escaping (AgentAction) -> AgentActionCardView,
        saveProposal: ((AgentAction) -> SaveAutomationProposalPane)? = nil,
        workbenches: [Workbench] = [],
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

    var body: some View {
        let now = now ?? Date()
        let sections = vm.sections
        PanelSplit(isPanelShown: true, width: inboxPaneWidth) {
            list(sections, now: now)
        } panel: {
            if let aux {
                InboxAuxPaneView(pane: aux, cheatSheet: cheatSheet, learnedRulesDB: learnedRulesDB,
                                 profile: profile) { self.aux = nil }
            } else {
                pane(sections, now: now)
            }
        }
        .detailBackground()
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
                        InboxListRow(item: item, proposalLabel: proposalLabel(item), now: now)
                            .tag(Optional(item.id))
                            .listRowSeparator(.hidden)
                    }
                }
                if vm.filter == .day, vm.feed.hasOlderDays {
                    showOlderRow
                }
            }
            .clearPlainList()
            .onExitCommand { Task { await vm.select(nil) } }
        }
    }

    /// The Day filter's last row while older dates exist: 30 more per press.
    private var showOlderRow: some View {
        Button("Show older") { vm.showOlderDays() }
            .buttonStyle(.kitQuiet)
            .controlSize(.small)
            .help("Show 30 more days")
            .selectionDisabled()
            .listRowSeparator(.hidden)
    }

    /// A section's title; the Tracks filter's Stopped fold opens and closes here.
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

    private func proposalLabel(_ item: InboxListItem) -> String? {
        guard case .proposal(let action) = item else { return nil }
        return vm.actionLabels[action.id]
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
            workbenches: workbenches,
            dayCard: { card in
                if let pane = dayPane?(card) {
                    around(pane, card)
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
    }

    /// The day pane with what only the split view knows.
    private func around(_ pane: InboxDayPane, _ card: InboxDayCard) -> InboxDayPane {
        var pane = pane
        pane.navScreens = navScreens
        pane.workbenches = workbenches
        pane.isWriting = vm.isWriting(.day(card.date))
        return pane
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
        case .day(let date): vm.markDayDone(date)
        case .proposal, .idea: break
        }
    }

    /// An output's Dismiss, a message's Hide.
    private func dismiss(_ id: InboxSelection) async {
        switch id {
        case .output(let output): await vm.dismissOutput(output)
        case .message(let message): await vm.hideMessage(message)
        case .proposal, .reminder, .day, .track, .idea: break
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
        case .proposal, .output, .day, .track, .idea: break
        }
    }
}

/// The reading pane's width, shared by every `InboxSplitView`.
private let inboxPaneWidth = PanelSplitWidth(key: "inbox.readingPaneWidth", range: 420...900, ideal: 560)

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
