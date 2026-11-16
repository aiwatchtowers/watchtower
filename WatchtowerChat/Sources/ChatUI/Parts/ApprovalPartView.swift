import ChatWire
import SwiftUI
import WatchtowerDesign

/// An agent action waiting for the owner, or its outcome (the `approval` part; for a Mac one version behind, a feed
/// action). The body is the connector's own (`+Slack`, `+Confluence`, `+Connector`), else the arguments as sent; the
/// decision row (`+Decision`) approves or rejects through the screen (D12: the Mac's `actions approve|reject`, the
/// phone's hub). The Mac may draw its own card (`ChatPartActions.approvalCard`), shared with its Inbox.
struct ApprovalPartView: View {
    let payload: ChatApprovalPayload
    let context: ChatPartContext
    @Environment(\.chatUIStyle) var style

    var body: some View {
        if let custom = context.actions.approvalCard?(payload) {
            custom
        } else {
            style.card {
                VStack(alignment: .leading, spacing: Spacing.regular) {
                    header
                    content
                    decisionRow
                }
            }
            .accessibilityIdentifier("chat.approval.\(payload.id)")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            Text(Self.title(payload)).font(.callout.weight(.semibold)).lineLimit(2)
            Spacer(minLength: Spacing.regular)
            Text(Self.statusLabel(payload.status))
                .font(.caption)
                .foregroundStyle(Self.statusTone(payload.status))
        }
    }

    @ViewBuilder private var content: some View {
        if let slack = SlackApproval(payload) {
            SlackApprovalBody(slack: slack)
        } else if let edit = ConfluenceApproval(payload) {
            ConfluenceApprovalBody(edit: edit, openURL: context.actions.openURL)
        } else if let call = ConnectorApproval(payload) {
            ConnectorApprovalBody(call: call)
        } else if !payload.argsDisplay.isEmpty {
            Text(payload.argsDisplay)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(12)
                .textSelection(.enabled)
        }
    }

    /// The card's title: the engine's, else the tool's name.
    static func title(_ payload: ChatApprovalPayload) -> String {
        payload.title.isEmpty ? payload.tool : payload.title
    }
}
