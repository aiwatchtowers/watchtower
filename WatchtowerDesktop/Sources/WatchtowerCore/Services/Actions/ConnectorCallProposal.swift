import Foundation

/// A `claude_ai_connector_call` proposal as the card shows it (spec
/// 2026-10-16-chat-claude-ai-tools-design D5): the claude.ai connector and
/// tool the main chat's session wants to run, and the exact input it sends
/// once approved. The row is session-applied (Go `Tool.AppliedBySession`):
/// Approve stops at `approved`, the live chat session that proposed it claims
/// and runs it, and nothing else ever can — so the card offers no Retry and
/// says when that session is gone instead of implying the call still runs.
package struct ConnectorCallProposal: Equatable, Sendable {
    package static let tool = "claude_ai_connector_call"

    /// Go `internal/tools` `sessionEndedBeforeApproval` /
    /// `sessionEndedWhileRunning`: the errors `ExpireSessionCalls` writes on
    /// the rows a dead session left. Change both together.
    package static let sessionEndedBeforeApproval = "session ended before approval"
    package static let sessionEndedWhileRunning = "session ended while the call ran; outcome unknown"
    /// The gate's `CancelSessionCall` reasons (plan Task 8): the 15-minute
    /// approval timeout and Stop/Close. Change both together.
    package static let notApprovedInTime = "not approved within 15 minutes"
    package static let stopped = "stopped"

    /// The connector's display name ("claude.ai Gmail").
    package let server: String
    package let toolName: String
    /// The input object pretty-printed — what the card shows and what the
    /// editor starts from.
    package let inputJSON: String

    /// Nil for another tool, and for args whose `input` is not an object
    /// (unreadable: the card falls back to the raw arguments and offers no
    /// Approve — approving a call the owner cannot read is never offered).
    package init?(action: AgentAction) {
        guard action.tool == Self.tool else { return nil }
        let args = action.args
        guard let input = args["input"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: input,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        self.server = AgentAction.stringValue(args["server"]) ?? "?"
        self.toolName = AgentAction.stringValue(args["tool"]) ?? "?"
        self.inputJSON = text
    }

    /// The `actions approve --patch` JSON for the owner's edited input —
    /// `{"input": <the text as typed>}` — or nil when the text is not a JSON
    /// object (Approve stays disabled). Only `input` is editable: Go
    /// `reviseConnectorCall` refuses anything else, and server/tool never
    /// change. The edited text is embedded verbatim, not re-serialised, so
    /// what the owner typed (number spelling included) is what runs.
    package func patch(editedInput: String) -> String? {
        let trimmed = editedInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return nil }
        return #"{"input":"# + trimmed + "}"
    }

    /// What Approve runs for the editor's text: a plain approve when the text
    /// is unchanged, the edit otherwise; nil when the text is not an object.
    package func approval(editedInput: String) -> SlackSendProposal.Approval? {
        if editedInput == inputJSON { return .plain }
        return patch(editedInput: editedInput).map { .edited(patch: $0) }
    }

    /// Whether the live chat session that proposed `action` still holds it:
    /// the conversation's session runs a turn, and it is the row's turn (the
    /// gate waits inside the turn that proposed the call). `runningTurnID` is
    /// nil when that conversation has no live session running a turn. A row
    /// without a turn id is held by any running turn.
    package static func sessionHolds(_ action: AgentAction, runningTurnID: String?) -> Bool {
        guard let runningTurnID else { return false }
        return action.turnID.isEmpty || action.turnID == runningTurnID
    }

    /// Approve only while the session that waits for it is alive — an
    /// approval nobody can claim would read as a call about to run.
    package static func canApprove(_ action: AgentAction, sessionHolds: Bool) -> Bool {
        action.isPending && sessionHolds
    }

    /// The card's status line. Approve stops at `approved` (the session runs
    /// the call), so `approved` never reads "Done"; a row whose session is
    /// gone says so rather than looking like it still runs.
    package static func statusLabel(for action: AgentAction, sessionHolds: Bool = true) -> String {
        switch action.status {
        case "pending":
            return sessionHolds ? "Awaiting your approval" : "Chat session ended — can no longer run"
        case "approved":
            return sessionHolds ? "Approved — the chat is running it" : "Chat session ended — not sent"
        case "executing":
            return sessionHolds ? "Running…" : "Chat session ended — outcome unknown"
        case "applied":
            return "Done"
        case "rejected":
            switch action.error {
            case notApprovedInTime: return "Cancelled — not approved in time"
            case stopped: return "Cancelled — chat stopped"
            default: return "Rejected"
            }
        case "failed":
            switch action.error {
            case sessionEndedBeforeApproval: return "Chat session ended — not sent"
            case sessionEndedWhileRunning: return "Chat session ended — outcome unknown"
            case "": return "Failed"
            default: return "Failed — \(action.error)"
            }
        default:
            return action.status
        }
    }
}
