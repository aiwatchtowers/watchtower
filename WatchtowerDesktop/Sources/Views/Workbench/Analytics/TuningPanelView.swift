import SwiftUI
import WatchtowerCore

/// Whether the tuning chat's tools are on for the panel: off is shown only
/// once the catalog has been read (or its read failed) — before the first
/// read the controller cannot know yet and switches when the catalog loads,
/// so the panel does not present the draft-only state as final.
enum TuningToolsState: Equatable {
    case on, off, undecided

    @MainActor static func of(toolsAvailable: Bool, catalog: AIModelCatalog) -> Self {
        if toolsAvailable { return .on }
        return catalog.isLoaded || catalog.unreadReason != nil ? .off : .undecided
    }
}

/// The tuning side panel beside the Analytics pane (spec 2026-11-03 §3,
/// §4.4): the title row with the conversation picker, the chat feed with the
/// coach's proposal cards inline, and the composer. Every string comes from
/// `TuningChatTexts`.
struct TuningPanelView: View {
    let chat: TuningChat
    let coach: CoachCenter?
    /// The period's figures line; nil while the report has none.
    let figures: TuningChatTexts.Figures?
    let starters: [ChatStarterPrompt]
    /// The pane's report is still loading.
    let loading: Bool
    let actions: CoachActions
    let onClose: () -> Void
    let onOpenSettings: () -> Void
    /// A proposal id: the pane's Accepted edits.
    let onShowAccepted: (Int64) -> Void
    var catalog: AIModelCatalog = .shared
    @State private var editing: CoachProposal?

    private var engine: EmbeddedChatEngine { chat.engine }
    private var toolsState: TuningToolsState { .of(toolsAvailable: chat.toolsAvailable, catalog: catalog) }
    private var isEmpty: Bool { engine.messages.isEmpty && !engine.isQueued }

    var body: some View {
        VStack(spacing: 0) {
            titleRow
            ChatFeedView(state: feedState, lastRowID: engine.messages.last?.id, density: .compact) {
                feed
            }
            if !isEmpty, toolsState == .off {
                TuningNoToolsCard(headline: TuningChatSurface.unavailableHelp(catalog: catalog),
                                  onOpenSettings: onOpenSettings)
                    .padding(.horizontal, Spacing.medium)
                    .padding(.bottom, Spacing.regular)
            }
            if let error = chat.loadError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Tone.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.medium)
                    .padding(.bottom, Spacing.compact)
            }
            EmbeddedChatComposer(engine: engine, placeholder: TuningChatTexts.placeholder, density: .compact,
                                 onEscape: onClose)
        }
        .task(id: ObjectIdentifier(chat)) { await chat.refreshCards() }
        .sheet(item: $editing) { proposal in
            if let coach { CoachEditSheet(proposal: proposal, coach: coach) }
        }
    }

    // MARK: - Title row

    private var titleRow: some View {
        HStack(spacing: Spacing.regular) {
            Text(TuningChatTexts.title).font(.headline)
            Menu {
                ForEach(chat.recent) { conversation in
                    Button(Self.title(of: conversation)) { chat.switchTo(conversation.id) }
                }
            } label: {
                MenuLabel(text: currentTitle, systemImage: "bubble.left.and.bubble.right", color: .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // A button-style menu draws the chip as built (capsule and
            // chevron); a borderless one keeps only its text and icon.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            // A long title truncates; New and Close keep their room.
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.regular)
            Button(TuningChatTexts.newButton) { Task { await chat.startNew() } }
                .buttonStyle(.kitQuiet)
                .fixedSize()
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.kitIcon(isOn: false))
                .fixedSize()
                .help(TuningChatTexts.closeHelp)
                .accessibilityLabel(TuningChatTexts.closeHelp)
        }
        .controlSize(.small)
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.regular)
    }

    private var currentTitle: String {
        chat.recent.first { $0.id == chat.conversationID }.map(Self.title(of:)) ?? TuningChatTexts.newChat
    }

    private static func title(of conversation: ChatConversation) -> String {
        let title = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? TuningChatTexts.newChat : title
    }

    // MARK: - Feed

    @ViewBuilder private var feed: some View {
        if isEmpty {
            TuningEmptyState(figures: figures, starters: toolsState == .on ? starters : [], loading: loading) {
                chat.send(starter: $0)
            }
            if toolsState == .off {
                TuningNoToolsCard(headline: TuningChatSurface.unavailableHelp(catalog: catalog),
                                  onOpenSettings: onOpenSettings)
            }
        } else {
            // Without tools the figures stay in view: the chat cannot read them.
            if toolsState == .off, let figures {
                TuningFiguresLine(figures: figures)
            }
            EmbeddedChatRows(engine: engine) { item in
                if item.message.isAssistant, !item.message.turnID.isEmpty {
                    cards(chat.cards.byTurn[item.message.turnID] ?? [])
                }
            }
            // A turn that stored no reply still shows what it proposed.
            cards(orphans)
        }
        cards(chat.cards.trailing)
        if let error = unresolvedCardsError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(Tone.warning)
        }
    }

    /// The coach's list could not be read while the chat has cards it
    /// cannot draw without it: say so instead of dropping them silently.
    private var unresolvedCardsError: String? {
        guard let error = coach?.proposals?.error else { return nil }
        let known = Set(coach?.proposals?.value?.map(\.id) ?? [])
        let all = chat.cards.trailing + chat.cards.byTurn.values.flatMap { $0 }
        return all.contains { !known.contains(Self.proposalID($0)) } ? error : nil
    }

    private static func proposalID(_ card: TuningCard) -> Int64 {
        switch card {
        case let .proposal(id): id
        }
    }

    /// Cards of turns with no assistant row on show, in the order they
    /// were filed.
    private var orphans: [TuningCard] {
        let turns = Set(engine.messages.filter(\.message.isAssistant).map(\.message.turnID))
        return chat.cards.byTurn
            .filter { !turns.contains($0.key) }
            .flatMap(\.value)
            .sorted { Self.proposalID($0) < Self.proposalID($1) }
    }

    @ViewBuilder private func cards(_ cards: [TuningCard]) -> some View {
        ForEach(cards) { card in
            switch card {
            case let .proposal(id):
                proposalCard(id)
            }
        }
    }

    /// An open proposal is the coach's card (its Accept secondary in the
    /// panel, D17); a settled one folds to one line. Until the coach's list
    /// holds the proposal nothing is drawn.
    @ViewBuilder private func proposalCard(_ id: Int64) -> some View {
        if let coach, let proposal = coach.proposals?.value?.first(where: { $0.id == id }) {
            if proposal.status == "open" {
                CoachProposalCardView(proposal: proposal, isFirst: false, coach: coach, actions: actions) {
                    editing = proposal
                }
            } else {
                TuningAcceptedLine(proposal: proposal, written: coach.written[proposal.id]) {
                    onShowAccepted(proposal.id)
                }
            }
        }
    }

    private var feedState: ChatAutoScrollPolicy.ThreadState {
        .init(conversationID: engine.spec.key.conversationID, lastMessageID: engine.messages.last?.id,
              scrollTarget: nil, liveMessageID: engine.liveTurn?.messageID)
    }
}

// MARK: - Empty state

/// A new conversation: the period's figures and the starters, or the
/// loading line while the pane's report is read.
struct TuningEmptyState: View {
    let figures: TuningChatTexts.Figures?
    let starters: [ChatStarterPrompt]
    let loading: Bool
    let onStarter: (ChatStarterPrompt) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            if loading {
                HStack(spacing: Spacing.compact) {
                    ProgressView().controlSize(.small)
                    Text(TuningChatTexts.loading).font(.callout).foregroundStyle(.secondary)
                }
            } else {
                if let figures { TuningFiguresLine(figures: figures) }
                if !starters.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.compact) {
                        ForEach(starters) { starter in
                            Button { onStarter(starter) } label: { starterLabel(starter) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func starterLabel(_ starter: ChatStarterPrompt) -> some View {
        HStack(spacing: Spacing.regular) {
            Image(systemName: "text.bubble").foregroundStyle(.secondary)
            Text(starter.title).multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, Spacing.cozy)
        .padding(.vertical, Spacing.regular)
        .background(Fill.rest, in: RoundedRectangle(cornerRadius: Radius.row))
        .contentShape(RoundedRectangle(cornerRadius: Radius.row))
    }
}

/// "7 days · 23 sessions · 7 tasks · $41.20 · …"
struct TuningFiguresLine: View {
    let figures: TuningChatTexts.Figures

    var body: some View {
        Text(TuningChatTexts.figures(figures))
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }
}

// MARK: - No tools

/// The provider runs no tools (ollama, D52): the chat can talk but not
/// read or propose; Open Settings goes to Settings → System → AI.
struct TuningNoToolsCard: View {
    let headline: String
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Label(headline, systemImage: "wrench.and.screwdriver")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text(TuningChatTexts.noToolsDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(TuningChatTexts.openSettings, action: onOpenSettings)
                .buttonStyle(.kitSecondary)
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

// MARK: - Folded card

/// A settled chat proposal folded to one line: accepted ones point at the
/// pane's Accepted edits, where they are measured and can be rolled back.
/// A workbench repository file names the file and branch it wrote until
/// the commit is seen (§4.3a).
struct TuningAcceptedLine: View {
    let proposal: CoachProposal
    var written: CoachWrittenFile?
    let onShow: () -> Void

    private var isAccepted: Bool { proposal.status == "accepted" }

    var body: some View {
        if let text = TuningChatTexts.folded(proposal, written: written) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                Image(systemName: isAccepted ? "checkmark.circle.fill" : "minus.circle")
                    .foregroundStyle(isAccepted ? Tone.success : .secondary)
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Spacing.regular)
                if isAccepted {
                    Button(TuningChatTexts.showAccepted, action: onShow)
                        .buttonStyle(.kitQuiet)
                        .font(.callout)
                }
            }
            .padding(.horizontal, Spacing.cozy)
            .padding(.vertical, Spacing.regular)
            .background(Fill.rest, in: RoundedRectangle(cornerRadius: Radius.row))
        }
    }
}
