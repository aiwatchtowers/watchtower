import ChatWire
import SwiftUI
import WatchtowerDesign

/// The `send_slack_message` proposal on the card (spec 2026-10-02 §7): the recipient pinned at propose time, the text —
/// editable while the row is pending where the screen takes edits — and, when the recipient exists in several
/// workspaces, a picker that must be set before Approve. The edits travel as `actions approve --patch`, so Go saves them
/// with the approval in one write.
extension AgentActionCard {
    static let slackRetryNote =
        "Retrying first checks whether the message already reached Slack and posts it only if it did not."

    /// The owner's edits travel with the approval; no edits is a plain approve. An edit that cannot be encoded is
    /// reported, never dropped for the original draft.
    func approveSlack(_ slack: SlackSendProposal, text: String) {
        do {
            switch try slack.approval(text: text, pick: drafts.pick) {
            case .edited(let patch): services.decide(action, .approve(patch: patch))
            case .plain: services.decide(action, .approve(patch: nil))
            }
            slackMessage = nil
        } catch {
            slackMessage = "Could not save your edits: \(error.localizedDescription)"
        }
    }

    func slackTextBinding(_ slack: SlackSendProposal) -> Binding<String> {
        Binding(get: { drafts.slack ?? slack.text }, set: { text in editDrafts { $0.slack = text } })
    }
}

/// Text editor + workspace picker for a pending Slack send. State lives on the card (`CardDrafts`) so
/// Approve reads the same values.
struct SlackSendEditor: View {
    let proposal: SlackSendProposal
    @Binding var text: String
    @Binding var pick: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            if proposal.target == nil {
                // Radio rows rather than a menu: a menu item cannot style the identity apart from the free-text label.
                Picker("Send from", selection: $pick) {
                    ForEach(Array(proposal.candidates.enumerated()), id: \.offset) { index, candidate in
                        SlackRecipientText(recipient: candidate).tag(Int?.some(index))
                    }
                }
                .slackWorkspacePickerStyle()
                .accessibilityIdentifier("agentAction.slackWorkspace")
            }
            TextEditor(text: $text)
                .font(.callout)
                .frame(minHeight: 60, maxHeight: 180)
                .scrollContentBackground(.hidden)
                .padding(Spacing.small)
                .background(ApprovalEditorChrome.background, in: RoundedRectangle(cornerRadius: Radius.control))
                .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(ApprovalEditorChrome.stroke))
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

/// A recipient as the card shows it: what the person can set (label, real name) and the workspace, then for a DM the
/// handle and user id alone on their own line in a secondary monospaced style — a display name cannot change its font,
/// so one imitating "@handle · U…" never reads as the pinned identity.
struct SlackRecipientText: View {
    /// The hairline gap between the place and the pinned identity under it.
    private static let identityGap: CGFloat = 1

    let recipient: SlackSendProposal.Recipient
    var prefix = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Self.identityGap) {
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

/// The card's "To:" line: the pinned recipient (`SlackRecipientText`), or, before a workspace is picked, the ask to
/// choose one.
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
