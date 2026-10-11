import SwiftUI
import WatchtowerCore

/// A Quick ask's one-tap row, shared by the banner over the terminal and
/// the stack card (spec 2026-10-10 Part 9.1–9.2): the options as buttons
/// (`OwnerAskQuickRow` — recommended first and prominent, descriptions as
/// tooltips), then Reply…, which swaps them for a one-line field (Return
/// sends, Esc cancels, a blank Return sends nothing), then Details when
/// given. The Reply text is the ask's draft (the question's "Other"), so it
/// outlives the view and the drawer shows it. Every answer goes through
/// `WorkbenchesViewModel.answerQuick`, the drawer's path; the row is off
/// while it is written and once it was. With the banner or card holding the
/// keyboard, 1–3 tap the first three buttons (`OwnerAskCardKeys`).
struct OwnerAskQuickActions: View {
    /// Past this a label is cut with "…"; its full text is in the help.
    static let maxChoiceWidth: CGFloat = 150

    let vm: WorkbenchesViewModel
    let ask: OwnerAsk
    let row: OwnerAskQuickRow
    /// Opens the drawer on the ask; nil where the card itself opens it.
    var details: (() -> Void)?

    @State private var replying = false
    @FocusState private var replyFocused: Bool

    var body: some View {
        let replyText = vm.asks.drafts.askDraft(for: ask.id).replyText(for: row.questionID)
        let enabled = OwnerAskQuickRow.isEnabled(answering: vm.asks.isAnswering(ask.id), answered: vm.asks.isAnswered(ask.id))
        VStack(alignment: .leading, spacing: 4) {
            Group {
                // A Reply typed earlier comes back open, with its text.
                if replying || !replyText.isEmpty {
                    replyRow(replyText)
                } else {
                    choiceRow
                }
            }
            .disabled(!enabled)
            if let error = vm.asks.answerErrors[ask.id] {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .controlSize(.small)
    }

    private var choiceRow: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(row.choices.enumerated()), id: \.element.label) { choiceButton($1, index: $0) }
            Button("Reply…") { replying = true }
                .buttonStyle(.bordered)
                .help("Answer in your own words, on one line")
            detailsButton
            sendingIndicator
        }
    }

    @ViewBuilder
    private func choiceButton(_ choice: OwnerAskQuickRow.Choice, index: Int) -> some View {
        let label = MarkdownView.inlineLabel(choice.label)
        let plain = String(label.characters)
        let tooltip = choice.tooltip.map { String(MarkdownView.inlineLabel($0).characters) } ?? plain
        let button = Button {
            send(row.answer(picking: choice.label))
        } label: {
            // `FlowLayout` sizes its items unproposed: the cap proposes a
            // width, so a long label is cut instead of overflowing the panel.
            CappedWidth(maxWidth: Self.maxChoiceWidth) {
                Text(label).lineLimit(1).truncationMode(.tail)
            }
        }
        .accessibilityLabel(plain)
        .help(OwnerAskCardKeys.hint(tooltip, index: index))
        if choice.isProminent {
            button.buttonStyle(.borderedProminent).accessibilityHint("Recommended")
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private func replyRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            TextField("Reply", text: replyBinding)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
                .focused($replyFocused)
                .onSubmit {
                    // A blank Reply is no answer: nothing is sent.
                    if let answer = row.reply(text) { send(answer) }
                }
                .onExitCommand { cancelReply() }
                // Only the owner's Reply… tap takes the keyboard: a field shown
                // because the draft already holds text (the other row of the
                // same ask, the drawer's Other…, a banner coming back) never
                // takes it from the terminal.
                .onAppear { if replying { replyFocused = true } }
            Button("Cancel") { cancelReply() }
                .buttonStyle(.borderless)
                .help("Back to the options (Esc)")
            detailsButton
            sendingIndicator
        }
    }

    @ViewBuilder
    private var detailsButton: some View {
        if let details {
            Button("Details", action: details)
                .buttonStyle(.borderless)
                .help("Open this ask in the drawer")
        }
    }

    @ViewBuilder
    private var sendingIndicator: some View {
        if vm.asks.isAnswering(ask.id) {
            ProgressView().controlSize(.small).accessibilityLabel("Sending answer")
        }
    }

    private var replyBinding: Binding<String> {
        Binding(
            get: { vm.asks.drafts.askDraft(for: ask.id).replyText(for: row.questionID) },
            set: { text in vm.asks.editDraft(ask.id) { $0.setReplyText(text, for: row.questionID) } }
        )
    }

    private func cancelReply() {
        replying = false
        vm.asks.editDraft(ask.id) { $0.setReplyText("", for: row.questionID) }
    }

    /// Unstructured, like the drawer's `press`: a view-bound task cancelled
    /// by navigation would surface as a failed answer.
    private func send(_ answer: OwnerAskAnswer) {
        Task { await vm.answerQuick(ask, with: answer) }
    }
}

/// Proposes at most `maxWidth` to its one child, even when its own
/// proposal is unspecified.
private struct CappedWidth: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let width = min(proposal.width ?? .infinity, maxWidth)
        return child.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// A Quick answer's notice where the owner tapped (`quickNotices`): where
/// the line went, or that the ask was withdrawn under the tap — the drawer's
/// texts — until Dismiss.
struct OwnerAskQuickNoticeRow: View {
    let vm: WorkbenchesViewModel
    let notice: OwnerAsksViewModel.QuickNotice

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: notice.notice == .withdrawn ? "exclamationmark.triangle" : "checkmark.circle")
                .foregroundStyle(notice.notice == .withdrawn ? .orange : .green)
                .accessibilityHidden(true)
            Text("\(Text.askNumber(notice.ask.id)) \(notice.notice.text)")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Dismiss") { vm.asks.dismissNotice(askID: notice.ask.id) }
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
    }
}

/// A banner's or stack card's keys while it holds the keyboard (board #412,
/// `OwnerAskKeyMap.Place.card`): 1–3 tap that option of a Quick ask — the
/// same `answerQuick` a click runs, off while the row is —, Return opens
/// the ask in the drawer, J / K (↓ / ↑) move to the next or previous card.
/// Nothing unless `focused`: a key typed in the terminal or a field never
/// reaches a card.
@MainActor
struct OwnerAskCardKeys {
    let vm: WorkbenchesViewModel
    let ask: OwnerAsk
    let focused: Bool
    let open: () -> Void
    /// To the next (true) or previous card; false when there is none.
    var move: (Bool) -> Bool = { _ in false }

    /// A choice's help with its key, for the first three.
    static func hint(_ tooltip: String, index: Int) -> String {
        index < OwnerAskKeyMap.maxQuickDigit ? "\(tooltip) (press \(index + 1))" : tooltip
    }

    /// True when the key acted; false leaves it to the window.
    func press(_ press: OwnerAskKeyMap.Press) -> Bool {
        guard focused, let action = OwnerAskKeyMap.action(for: press, at: .card(quickChoices: quickRow?.choices.count ?? 0)) else {
            return false
        }
        switch action {
        case let .choose(option): return answer(option)
        case .open:
            open()
            return true
        case .nextAsk, .previousAsk: return move(action == .nextAsk)
        default: return false
        }
    }

    /// The row a digit taps: none while an answer is written or once one was.
    private var quickRow: OwnerAskQuickRow? {
        guard OwnerAskQuickRow.isEnabled(answering: vm.asks.isAnswering(ask.id), answered: vm.asks.isAnswered(ask.id)) else {
            return nil
        }
        return OwnerAskQuickRow(ask: ask)
    }

    private func answer(_ option: Int) -> Bool {
        guard let row = quickRow, option < row.choices.count else { return false }
        let answer = row.answer(picking: row.choices[option].label)
        Task { [vm, ask] in await vm.answerQuick(ask, with: answer) }
        return true
    }
}

extension OwnerAskKeyMap.Press {
    /// A SwiftUI key press as the key map reads it.
    init(_ press: KeyPress) {
        self.init(characters: String(press.key.character),
                  shift: press.modifiers.contains(.shift),
                  otherModifiers: !press.modifiers.isDisjoint(with: [.command, .option, .control]),
                  isRepeat: press.phase == .repeat)
    }
}
