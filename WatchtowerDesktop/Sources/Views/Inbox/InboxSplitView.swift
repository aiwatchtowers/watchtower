import SwiftUI
import WatchtowerCore

/// The Actions segment of a non-empty Inbox, read like mail (spec B1): the
/// list on the left — Needs your decision, Today, Earlier — and the reading
/// pane on the right. Arrow keys move the selection, Escape clears it, and
/// opening a card marks it read (`ActionStripViewModel.select`). Done,
/// Dismiss or Snooze on the shown card opens the next row.
struct InboxSplitView: View {
    let vm: ActionStripViewModel
    let cheatSheetRows: [ReactionCheatSheet.Row]
    let onOpenSettings: () -> Void
    /// A proposal's card in the reading pane.
    let proposalCard: (AgentAction) -> AgentActionCardView
    /// A pending `save_automation` proposal in the reading pane.
    var saveProposal: ((AgentAction) -> SaveAutomationProposalPane)?
    /// The workbenches a card's agent press can go to.
    var workbenches: [Workbench] = []
    let onCardAction: (InboxCardCommand) -> Void
    var onOpenAutomationRun: ((Int64) -> Void)?
    /// The moment Today starts from; nil is now (design shots fix it).
    var now: Date?

    @Environment(\.markdownNavScreens) private var navScreens
    @State private var showsCheatSheet = false

    static let paneWidth = PanelSplitWidth(key: "inbox.readingPaneWidth", range: 420...900, ideal: 560)

    var body: some View {
        let now = now ?? Date()
        let sections = InboxListBuilder.sections(proposals: vm.actionRows, reminders: vm.reminderRows,
                                                 outputs: vm.outputRows, now: now, calendar: .current)
        PanelSplit(isPanelShown: true, width: Self.paneWidth) {
            list(sections, now: now)
        } panel: {
            pane(sections, now: now)
        }
        .detailBackground()
    }

    // MARK: - The list

    private func list(_ sections: [InboxSection], now: Date) -> some View {
        VStack(spacing: 0) {
            header
            List(selection: selection) {
                // Each title is a plain row that cannot be selected, not a
                // Section header: a plain List pins its header and draws a
                // hairline under it.
                ForEach(sections, id: \.title) { section in
                    SectionHeader(title: section.title, systemImage: Self.icon(section.title),
                                  count: section.items.count)
                        .padding(.top, Spacing.regular)
                        .selectionDisabled()
                        .listRowSeparator(.hidden)
                    ForEach(section.items) { item in
                        InboxListRow(item: item, proposalLabel: proposalLabel(item), now: now)
                            .tag(Optional(item.id))
                            .listRowSeparator(.hidden)
                    }
                }
            }
            .clearPlainList()
            .onExitCommand { Task { await vm.select(nil) } }
        }
    }

    /// The list's header: the reaction cheat sheet stays one `?` away.
    private var header: some View {
        HStack {
            Spacer()
            Button {
                showsCheatSheet = true
            } label: {
                Image(systemName: "questionmark.circle")
            }
            .buttonStyle(.kitIcon(isOn: false))
            .help("Reaction commands")
            .accessibilityLabel("Reaction commands")
            .accessibilityIdentifier("actionStrip.cheatSheetButton")
            .popover(isPresented: $showsCheatSheet, arrowEdge: .bottom) {
                ReactionCheatSheetView(rows: cheatSheetRows, onOpenSettings: onOpenSettings)
                    .frame(width: 440)
                    .popoverSurface()
            }
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.top, Spacing.compact)
    }

    private var selection: Binding<InboxSelection?> {
        // The highlight moves at once; only the opening's `read_at` waits.
        Binding(get: { vm.selection }, set: { item in
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
            isWriting: shown.map(isWriting) ?? false,
            onCommand: onCardAction,
            onOpenAutomationRun: onOpenAutomationRun,
            onDone: { shown.map { close($0.id, in: sections, done) } },
            onDismiss: { shown.map { close($0.id, in: sections, dismiss) } },
            onSnooze: { shown.map { close($0.id, in: sections, snooze) } },
            proposalCard: proposalCard,
            saveProposal: saveProposal,
            workbenches: workbenches
        )
    }

    private func isWriting(_ item: InboxListItem) -> Bool {
        switch item.id {
        case .output(let id): vm.isWriting(output: id)
        case .reminder(let id): vm.isWriting(reminder: id)
        case .proposal: false
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
            guard !isListed(id), vm.selection == nil || vm.selection == id else { return }
            await vm.select(next)
        }
    }

    private func isListed(_ id: InboxSelection) -> Bool {
        switch id {
        case .output(let output): vm.outputRows.contains { $0.id == output }
        case .reminder(let reminder): vm.reminderRows.contains { $0.id == reminder }
        case .proposal(let action): vm.actionRows.contains { $0.id == action }
        }
    }

    private func done(_ id: InboxSelection) async {
        switch id {
        case .output(let output): await vm.markOutputDone(output)
        case .reminder(let reminder): await vm.markReminderDone(reminder)
        case .proposal: break
        }
    }

    private func dismiss(_ id: InboxSelection) async {
        if case .output(let output) = id { await vm.dismissOutput(output) }
    }

    private func snooze(_ id: InboxSelection) async {
        guard case .reminder(let reminder) = id else { return }
        let until = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        await vm.snoozeReminder(reminder, until: until)
    }
}
