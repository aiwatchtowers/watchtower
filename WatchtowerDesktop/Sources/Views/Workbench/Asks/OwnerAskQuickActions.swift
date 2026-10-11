import SwiftUI
import WatchtowerCore

/// A Quick ask's one-tap row, shared by the banner over the terminal and
/// the stack card (spec 2026-10-10 Part 9.1–9.2): the options as buttons
/// (`OwnerAskQuickRow` — recommended first and prominent, descriptions as
/// tooltips), then Reply…, which swaps them for a one-line field (Return
/// sends, Esc cancels, a blank Return sends nothing), then Details when
/// given. Every answer goes through `WorkbenchesViewModel.answerQuick`, the
/// drawer's path; the buttons are off while it is written.
struct OwnerAskQuickActions: View {
    let vm: WorkbenchesViewModel
    let ask: OwnerAsk
    let row: OwnerAskQuickRow
    /// Opens the drawer on the ask; nil where the card itself opens it.
    var details: (() -> Void)?

    @State private var replying = false
    @State private var replyText = ""
    @FocusState private var replyFocused: Bool

    var body: some View {
        let answering = vm.asks.isAnswering(ask.id)
        VStack(alignment: .leading, spacing: 4) {
            FlowLayout(spacing: 6) {
                if replying {
                    replyField
                } else {
                    ForEach(row.choices, id: \.label) { choiceButton($0) }
                    Button("Reply…") { replying = true }
                        .buttonStyle(.bordered)
                        .help("Answer in your own words, on one line")
                }
                if let details {
                    Button("Details", action: details)
                        .buttonStyle(.borderless)
                        .help("Open this ask in the drawer")
                }
                if answering { ProgressView().controlSize(.small) }
            }
            .disabled(answering)
            if let error = vm.asks.answerErrors[ask.id] {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private func choiceButton(_ choice: OwnerAskQuickRow.Choice) -> some View {
        let button = Button(choice.label) { send(row.answer(picking: choice.label)) }
            .help(choice.tooltip ?? choice.label)
        if choice.isProminent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private var replyField: some View {
        HStack(spacing: 6) {
            TextField("Reply", text: $replyText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 160, idealWidth: 260)
                .focused($replyFocused)
                .onSubmit {
                    // A blank Reply is no answer: nothing is sent.
                    if let answer = row.reply(replyText) { send(answer) }
                }
                .onExitCommand { cancelReply() }
                .onAppear { replyFocused = true }
            Button("Cancel") { cancelReply() }
                .buttonStyle(.borderless)
                .help("Back to the options (Esc)")
        }
    }

    private func cancelReply() {
        replying = false
        replyText = ""
    }

    /// Unstructured, like the drawer's `press`: a view-bound task cancelled
    /// by navigation would surface as a failed answer.
    private func send(_ answer: OwnerAskAnswer) {
        Task { await vm.answerQuick(ask, with: answer) }
    }
}
