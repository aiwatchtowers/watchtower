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
        // The text-only summary (cheat sheet, tests); the card itself shows
        // the recipient with `SlackRecipientLine`.
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
                // Radio rows rather than a menu: a menu item cannot style the
                // identity apart from the free-text label.
                Picker("Send from", selection: $pick) {
                    ForEach(Array(proposal.candidates.enumerated()), id: \.offset) { index, candidate in
                        SlackRecipientText(recipient: candidate).tag(Int?.some(index))
                    }
                }
                .pickerStyle(.radioGroup)
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

/// A recipient as the card shows it: what the person can set (label, real
/// name) and the workspace, then for a DM the handle and user id alone on
/// their own line in a secondary monospaced style — a display name cannot
/// change its font, so one imitating "@handle · U…" never reads as the
/// pinned identity.
struct SlackRecipientText: View {
    let recipient: SlackSendProposal.Recipient
    var prefix = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(prefix + recipient.place)
            if !recipient.identity.isEmpty {
                Text(recipient.identity)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("agentAction.slackIdentity")
            }
        }
    }
}

/// The card's "To:" line: the pinned recipient (`SlackRecipientText`), or,
/// before a workspace is picked, the ask to choose one.
struct SlackRecipientLine: View {
    let proposal: SlackSendProposal

    var body: some View {
        Group {
            if let target = proposal.target {
                SlackRecipientText(recipient: target, prefix: "To: ")
            } else {
                Text(proposal.recipientLine)
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
}
