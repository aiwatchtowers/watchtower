import SwiftUI
import WatchtowerCore

/// The `claude_ai_connector_call` proposal on the agent-action card (spec
/// 2026-10-16-chat-claude-ai-tools-design D5): which claude.ai connector and
/// tool the chat wants to run and the exact input, editable while the row is
/// pending (the edit travels as `actions approve --patch {"input": …}`).
struct ConnectorCallDetails: View {
    let proposal: ConnectorCallProposal
    /// The editor's text while the owner edits the input; nil shows it read-only.
    let draft: Binding<String>?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Connector: \(proposal.server)").font(.callout)
            Text("Tool: \(proposal.toolName)").font(.callout)
            if let draft {
                ConnectorInputEditor(proposal: proposal, text: draft)
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

/// Monospaced editor for the call's input; Approve stays disabled while the
/// text is not a JSON object (`ConnectorCallProposal.approval`).
private struct ConnectorInputEditor: View {
    let proposal: ConnectorCallProposal
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: $text)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 80, maxHeight: 260)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                .accessibilityIdentifier("agentAction.connectorEditor")
            if proposal.approval(editedInput: text) == nil {
                Text("The input must be a JSON object.").font(.caption).foregroundStyle(.red)
            } else if text != proposal.inputJSON {
                Text("Edited — Approve sends your version.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
