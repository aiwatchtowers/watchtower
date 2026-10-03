import SwiftUI
import WatchtowerCore

/// The drawer's footer (spec 2026-10-03 Part 8). An open ask: Later (closes
/// the drawer, the draft stays) and the kind's answer buttons — Request
/// changes / Approve, Send (naming the unmarked items), Answer — enabled per
/// `OwnerAskPresentation.canAnswer`, with the reason when they are not.
/// A closed ask: what became of it, and Discard draft while a draft is kept
/// (an ask withdrawn under the owner's answer).
struct OwnerAskAnswerBar: View {
    let asks: OwnerAsksViewModel
    let ask: OwnerAsk
    let statusLine: String

    var body: some View {
        let draft = asks.drafts.draft(for: ask.id)
        let answering = asks.answering.contains(ask.id)
        let actions = OwnerAskPresentation.answerActions(for: ask, draft: draft)
        VStack(alignment: .leading, spacing: 6) {
            if let error = asks.answerErrors[ask.id] {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            // Why the primary button is off; a review's verdict comes with
            // its button, so only what else is missing shows.
            if let primary = actions.last, let blocker = OwnerAskPresentation.blocker(ask, draft: draft, with: primary) {
                Text(blocker).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if ask.isOpen {
                    Button("Later") { asks.closeDrawer(projectID: ask.projectID) }
                        .help("Close; your draft is kept")
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
        let button = Button(action.label) {
            // Unstructured: a view-bound task cancelled by navigation would
            // surface as a failed answer.
            let (asks, ask) = (asks, ask)
            Task { await asks.answer(ask, verdict: action.verdict) }
        }
        .disabled(!enabled)
        if action.isPrimary {
            button.buttonStyle(.borderedProminent)
        } else {
            button
        }
    }
}
