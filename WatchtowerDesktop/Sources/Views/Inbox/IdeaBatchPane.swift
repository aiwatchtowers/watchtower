import SwiftUI
import WatchtowerCore

/// Idea finder's pane (spec "Idea finder (phase 3)"): today's batch as one
/// card at a time with **Keep** / **Drop** / **Later** / **Make a Target…**
/// (keys K / D / L / T), the batch's progress, then "Kept today". Once the
/// batch is done it offers **Next N** while candidates are left. The whole
/// list stays one press away through **Backlog · N**.
///
/// The pane writes nothing itself: `onPress` hands the shown idea to the
/// caller (`IdeasViewModel.press(_:on:)`), and `isWriting` is that idea's
/// verdict key pending (`InboxIdeaPane.writeKey`). A card takes one press:
/// a second key or button press on it before the batch re-reads does
/// nothing, so the next card is judged only by a press after it is shown.
struct IdeaBatchPane: View {
    let state: IdeaBatchState
    let isWriting: Bool
    let errorMessage: String?
    /// The shown card's quotes and source (`IdeaBatchCardFacts.read`); nil on
    /// a failed read leaves them out.
    let loadFacts: (Int) async -> IdeaBatchCardFacts?
    let onPress: (IdeaBatchPress, Idea) -> Void
    let onNext: () -> Void
    let onBacklog: () -> Void
    let onDismissError: () -> Void

    /// The press gate, held by reference: it is bookkeeping and never drawn,
    /// so recording a press does not redraw the pane.
    @State private var ownGate = IdeaBatchPressGate.Box()
    /// A test's gate in place of the pane's own (an unhosted view keeps no
    /// `@State` between taps).
    var gateOverride: IdeaBatchPressGate.Box?
    private var gate: IdeaBatchPressGate.Box { gateOverride ?? ownGate }
    @State private var facts: ShownFacts?
    @FocusState private var focused: Bool

    /// Facts belong to the card they were read for.
    private struct ShownFacts {
        let ideaID: Int
        let facts: IdeaBatchCardFacts
    }

    init(
        state: IdeaBatchState,
        isWriting: Bool,
        errorMessage: String?,
        loadFacts: @escaping (Int) async -> IdeaBatchCardFacts?,
        onPress: @escaping (IdeaBatchPress, Idea) -> Void,
        onNext: @escaping () -> Void,
        onBacklog: @escaping () -> Void,
        onDismissError: @escaping () -> Void
    ) {
        self.state = state
        self.isWriting = isWriting
        self.errorMessage = errorMessage
        self.loadFacts = loadFacts
        self.onPress = onPress
        self.onNext = onNext
        self.onBacklog = onBacklog
        self.onDismissError = onDismissError
    }

    var body: some View {
        VStack(spacing: 0) {
            if let errorMessage {
                // A dismissed failure leaves the card on screen: it can be pressed again.
                WriteErrorBanner(message: errorMessage, onClose: {
                    gate.value.release()
                    onDismissError()
                })
            }
            InboxCardColumn {
                VStack(alignment: .leading, spacing: Spacing.large) {
                    InboxPaneHeader(tile: InboxTile(kind: .ideas), title: "Idea finder",
                                    subtitle: state.paneSubtitle) {
                        Button("Backlog · \(state.backlogCount)", action: onBacklog)
                            .buttonStyle(.kitSecondary)
                    }
                    if !state.batchIDs.isEmpty {
                        progress
                    }
                    if let idea = state.remaining.first {
                        card(idea)
                        keyHint
                    } else {
                        done
                    }
                    if !state.keptToday.isEmpty {
                        keptToday
                    }
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(phases: .down) { handle($0) }
        // Another card is shown: it takes its own press.
        .onChange(of: state.remaining.first?.id) { gate.value.release() }
        // A failed write leaves the card on screen: it can be pressed again.
        .onChange(of: errorMessage) { _, message in
            if message != nil { gate.value.release() }
        }
        .onChange(of: isWriting) { wasWriting, writing in
            if wasWriting, !writing, errorMessage != nil { gate.value.release() }
        }
    }

    // MARK: - Parts

    private var progress: some View {
        ProgressView(value: Double(state.judgedCount), total: Double(state.batchIDs.count))
            .progressViewStyle(.linear)
            .tint(InboxTile.tint(.ideas))
            .accessibilityLabel("\(state.judgedCount) of \(state.batchIDs.count) judged")
    }

    private func card(_ idea: Idea) -> some View {
        let shown = facts?.ideaID == idea.id ? facts?.facts : nil
        return VStack(alignment: .leading, spacing: Spacing.medium) {
            Chip(text: Self.chipText(idea, sourceLabel: shown?.sourceLabel ?? ""), color: .secondary)
            Text(idea.title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !idea.essence.isEmpty {
                Text(idea.essence)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let quote = shown?.quote, !quote.isEmpty {
                Text(quote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(Spacing.regular)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Fill.rest, in: RoundedRectangle(cornerRadius: Radius.row))
            }
            buttons(idea)
        }
        .padding(Spacing.page)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .task(id: idea.id) {
            let loaded = await loadFacts(idea.id)
            facts = loaded.map { ShownFacts(ideaID: idea.id, facts: $0) }
        }
    }

    private func buttons(_ idea: Idea) -> some View {
        HStack(spacing: Spacing.regular) {
            Button(IdeaBatchPress.keep.title) { dispatch(.keep, idea) }
                .buttonStyle(.kitPrimary)
            Button(IdeaBatchPress.drop.title) { dispatch(.drop, idea) }
                .buttonStyle(.kitSecondary)
            Button(IdeaBatchPress.later.title) { dispatch(.later, idea) }
                .buttonStyle(.kitSecondary)
            Spacer(minLength: Spacing.regular)
            Button(IdeaBatchPress.makeTarget.title) { dispatch(.makeTarget, idea) }
                .buttonStyle(.kitQuiet)
        }
        .controlSize(.small)
        .disabled(isWriting)
    }

    private var keyHint: some View {
        HStack(spacing: Spacing.medium) {
            keyHintItem("K", "keep")
            keyHintItem("D", "drop")
            keyHintItem("L", "later")
            keyHintItem("T", "make a target")
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
        .accessibilityElement(children: .combine)
    }

    private func keyHintItem(_ key: String, _ label: String) -> some View {
        HStack(spacing: Spacing.small) {
            Text(key)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .padding(.horizontal, Spacing.small)
                .background(Fill.card, in: RoundedRectangle(cornerRadius: Radius.mark))
            Text(label)
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            if !state.batchIDs.isEmpty {
                Text("Today’s batch done")
                    .font(.headline)
            }
            if state.nextAvailable > 0 {
                Button(state.nextTitle, action: onNext)
                    .buttonStyle(.kitPrimary)
                    .controlSize(.small)
            } else {
                Text("Nothing left to judge from the last 30 days")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var keptToday: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            SectionHeader(title: "Kept today", systemImage: "checkmark.circle", count: state.keptToday.count)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                ForEach(state.keptToday) { idea in
                    HStack(spacing: Spacing.regular) {
                        Text(idea.title)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: Spacing.regular)
                        Chip(text: "kept", color: Tone.status("green"))
                    }
                    .kitRow(isSelected: false)
                }
            }
        }
    }

    // MARK: - Presses

    private func handle(_ key: KeyPress) -> KeyPress.Result {
        guard key.modifiers.isDisjoint(with: [.command, .control, .option]),
              key.characters.count == 1, let character = key.characters.first,
              let press = IdeaBatchPress(key: character),
              let idea = state.remaining.first else { return .ignored }
        dispatch(press, idea)
        return .handled
    }

    private func dispatch(_ press: IdeaBatchPress, _ idea: Idea) {
        guard gate.value.admit(idea.id, isWriting: isWriting) else { return }
        onPress(press, idea)
    }

    // MARK: - Texts

    /// "<kind> · from <source>, <age>"; without mentions "<kind> · <age>",
    /// and without a readable `created_at` the age is left out.
    static func chipText(_ idea: Idea, sourceLabel: String) -> String {
        let age = TimeFormatting.parseISO(idea.createdAt).map { TimeFormatting.relativeTime(from: $0) }
        let origin: String
        switch (sourceLabel.isEmpty, age) {
        case (false, let age?): origin = "from \(sourceLabel), \(age)"
        case (false, nil): origin = "from \(sourceLabel)"
        case (true, let age?): origin = age
        case (true, nil): return idea.kindRaw
        }
        return "\(idea.kindRaw) · \(origin)"
    }
}

/// One press per shown card: a card that was pressed takes no further press
/// until another card is shown or its write failed (`release`), and nothing
/// is admitted while a verdict is writing.
struct IdeaBatchPressGate: Equatable {
    private(set) var pressedID: Int?

    /// The pane's reference to its gate.
    final class Box {
        var value = IdeaBatchPressGate()
    }

    mutating func admit(_ ideaID: Int, isWriting: Bool) -> Bool {
        guard !isWriting, pressedID != ideaID else { return false }
        pressedID = ideaID
        return true
    }

    mutating func release() {
        pressedID = nil
    }
}
