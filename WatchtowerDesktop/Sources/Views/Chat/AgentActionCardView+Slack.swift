import SwiftUI
import WatchtowerCore

/// The `send_slack_message` proposal on the agent-action card (spec
/// 2026-10-02 §7): the recipient pinned at propose time, the text — editable
/// while the row is pending — and, when the recipient exists in several
/// workspaces, a picker that must be set before Approve. The edits travel as
/// `actions approve --patch`, so Go saves them with the approval in one write.
extension AgentActionCardView {
    static func slackSummaryLines(for action: AgentAction) -> [String]? {
        guard let proposal = SlackSendProposal(action: action) else { return nil }
        // An editable pending card shows the text in its editor instead
        // (`AgentActionCardView.displayLines`).
        return [proposal.recipientLine, proposal.text]
    }

    static func slackRetryNote() -> String {
        "Retrying first checks whether the message already reached Slack and posts it only if it did not."
    }
}

/// Text editor + workspace picker for a pending Slack send. State lives on the
/// card (`slackDraft`/`slackPick`) so Approve reads the same values.
struct SlackSendEditor: View {
    let proposal: SlackSendProposal
    @Binding var text: String
    @Binding var pick: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if proposal.target == nil {
                Picker("Send from", selection: $pick) {
                    Text("Choose a workspace…").tag(Int?.none)
                    ForEach(Array(proposal.candidates.enumerated()), id: \.offset) { index, candidate in
                        Text(candidate.line).tag(Int?.some(index))
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("agentAction.slackWorkspace")
            }
            TextEditor(text: $text)
                .font(.callout)
                .frame(minHeight: 60, maxHeight: 180)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                .accessibilityIdentifier("agentAction.slackText")
            if text.unicodeScalars.count > SlackSendProposal.maxCharacters {
                Text("At most \(SlackSendProposal.maxCharacters) characters.")
                    .font(.caption).foregroundStyle(.red)
            } else if text != proposal.text {
                Text("Edited — Approve sends your version.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
