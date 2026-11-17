import ChatWire
import SwiftUI
import WatchtowerDesign

/// The `claude_ai_connector_call` proposal on the card (spec 2026-10-16-chat-claude-ai-tools-design D5): which claude.ai
/// connector and tool the chat wants to run and the exact input, editable on the Mac while the row is pending (the edit
/// travels as `actions approve --patch {"input": …}`). The phone shows the input read-only.
struct ConnectorCallDetails: View {
    let proposal: ConnectorCallProposal
    /// The editor's text while the owner edits the input; nil shows it read-only.
    let draft: Binding<String>?
    /// What Approve would run for the editor's text (nil: not an object).
    let approval: ConnectorCallProposal.Approval?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("Connector: \(proposal.server)").font(.callout)
            Text("Tool: \(proposal.toolName)").font(.callout)
            if let draft {
                ConnectorInputEditor(text: draft, approval: approval)
            } else {
                ScrollView {
                    Text(proposal.inputJSON)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .accessibilityIdentifier("agentAction.connectorInput")
            }
        }
    }
}

/// The note under the connector editor: Approve stays off while the text is not a JSON object.
struct ConnectorInputNote: View {
    let approval: ConnectorCallProposal.Approval?

    var body: some View {
        if approval == nil {
            Text("The input must be a JSON object.").font(.caption).foregroundStyle(.red)
        } else if approval != .plain {
            Text("Edited — Approve sends your version.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
