import SwiftUI
import WatchtowerCore

/// The drawer's footer (spec 2026-10-03 Part 8). An open ask: Dismiss
/// (closes the ask unanswered, board #223 — it replaced Later; the drawer's
/// × still closes it with the draft kept) and the kind's answer buttons — Request
/// changes / Approve, Send ("N not checked" above it), Answer — enabled per
/// `OwnerAskPresentation.canAnswer`, with the reason when they are not;
/// their keys (⌘↩, a review's Request changes ⌘⇧↩) in their help.
/// A closed ask: what became of it, and Discard draft while a draft is kept
/// (an ask withdrawn under the owner's answer).
struct OwnerAskAnswerBar: View {
    let asks: OwnerAsksViewModel
    let ask: OwnerAsk
    let statusLine: String

    var body: some View {
        let draft = asks.drafts.askDraft(for: ask.id)
        let answering = asks.isAnswering(ask.id)
        let actions = OwnerAskPresentation.answerActions(for: ask.kind)
        VStack(alignment: .leading, spacing: 6) {
            if let error = asks.answerErrors[ask.id] {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            // Why the primary button is off; a review's verdict comes with
            // its button, so only what else is missing shows.
            if let primary = actions.last, let blocker = OwnerAskPresentation.blocker(ask, draft: draft, with: primary) {
                Text(blocker).font(.caption).foregroundStyle(.secondary)
            }
            if ask.isOpen, let notChecked = OwnerAskPresentation.notChecked(ask, draft: draft) {
                Text(notChecked)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help("Sent as Didn't check")
            }
            HStack(spacing: 8) {
                if ask.isOpen {
                    Button("Dismiss") { asks.dismiss(ask) }
                        .disabled(answering)
                        .help("Close this ask without answering; the agent goes on without it")
                    Spacer()
                    if answering { ProgressView().controlSize(.small) }
                    ForEach(actions, id: \.verdict) { action in
                        answerButton(action, enabled: OwnerAskPresentation.canAnswer(ask, draft: draft, with: action, answering: answering))
                    }
                } else {
                    Text(statusLine).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if !draft.isEmpty {
                        Button("Discard draft", role: .destructive) { asks.drafts.discard(ask.id) }
                    }
                    Button("Close") { asks.closeDrawer(projectID: ask.projectID) }
                }
            }
        }
        .padding(10)
    }

    @ViewBuilder
    private func answerButton(_ action: OwnerAskPresentation.AnswerAction, enabled: Bool) -> some View {
        let button = Button(action.label) { asks.press(action, on: ask) }
            .disabled(!enabled)
            // Not a `.keyboardShortcut`: SwiftUI runs one before the
            // focused view, so it would take ⌘↩ from every field of the
            // window. The drawer's fields and `OwnerAskKeyCatcher` press it.
            .help("Shortcut: \(OwnerAskPresentation.keyLabel(action))")
        if action.isPrimary {
            button.buttonStyle(.borderedProminent)
        } else {
            button
        }
    }
}
