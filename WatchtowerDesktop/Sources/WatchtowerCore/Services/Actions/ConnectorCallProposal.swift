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
    package typealias Approval = SlackSendProposal.Approval

    /// Go `internal/tools` `sessionEndedBeforeApproval` /
    /// `sessionEndedWhileRunning`: the errors `ExpireSessionCalls` writes on
    /// the rows a dead session left. Change both together.
    package static let sessionEndedBeforeApproval = "session ended before approval"
    package static let sessionEndedWhileRunning = "session ended while the call ran; outcome unknown"
    /// The chat gate's `CancelSessionCall` reasons: the 15-minute approval
    /// timeout (spec decision Q3) and Stop/Close. Change both together.
    package static let notApprovedInTime = "not approved within 15 minutes"
    package static let stopped = "stopped"

    /// Shown beside Reject on a pending call the card cannot read.
    package static let unreadableNote = "This call's details can't be shown, so it can't be approved — reject it and ask again."

    /// The connector's display name ("claude.ai Gmail").
    package let server: String
    package let toolName: String
    /// The stored input, re-indented with every token as stored — what the
    /// card shows and what the editor starts from. Numbers are never
    /// re-encoded, so the card shows exactly what the session sends.
    package let inputJSON: String

    /// Nil for another tool, and for args without a server, a tool or an
    /// object `input` (unreadable: the card falls back to the raw arguments
    /// and offers no Approve — a call the owner cannot read is never approved).
    package init?(action: AgentAction) {
        guard action.tool == Self.tool else { return nil }
        let args = action.args
        guard let server = args["server"] as? String, !server.isEmpty,
              let toolName = args["tool"] as? String, !toolName.isEmpty,
              args["input"] is [String: Any],
              let raw = RawJSON.member("input", of: action.argsJSON) else { return nil }
        self.server = server
        self.toolName = toolName
        self.inputJSON = RawJSON.indented(raw)
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
    package func approval(editedInput: String) -> Approval? {
        if editedInput == inputJSON { return .plain }
        return patch(editedInput: editedInput).map { .edited(patch: $0) }
    }

    /// Whether the live chat session that proposed `action` still holds it:
    /// the conversation's session runs a turn, and it is the row's turn (the
    /// gate waits inside the turn that proposed the call). `runningTurnID` is
    /// nil when that conversation has no live session running a turn. A row
    /// without a turn id is never held: nothing ties it to the running turn.
    package static func sessionHolds(_ action: AgentAction, runningTurnID: String?) -> Bool {
        guard let runningTurnID, !action.turnID.isEmpty else { return false }
        return action.turnID == runningTurnID
    }

    /// Approve only while the session that waits for it is alive — an
    /// approval nobody can claim would read as a call about to run.
    package static func canApprove(_ action: AgentAction, sessionHolds: Bool) -> Bool {
        action.isPending && sessionHolds
    }

    /// Whether the status label already words this session call's error
    /// (the expiry and cancel reasons, per status); any other error is shown
    /// on its own line.
    package static func labelCarriesError(_ action: AgentAction) -> Bool {
        guard action.isSessionApplied else { return false }
        switch action.status {
        case "rejected": return [notApprovedInTime, stopped].contains(action.error)
        case "failed": return [sessionEndedBeforeApproval, sessionEndedWhileRunning, stopped].contains(action.error)
        default: return false
        }
    }

    /// The card's status line. Approve stops at `approved` (the session runs
    /// the call), so `approved` never reads "Done"; a row whose session is
    /// gone says so rather than looking like it still runs.
    package static func statusLabel(for action: AgentAction, sessionHolds: Bool) -> String {
        switch action.status {
        case "pending":
            return sessionHolds ? "Awaiting your approval" : "Chat session ended — reject to dismiss"
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
            // Stop after the owner approved (`ExpireSessionCall`, or right
            // after the claim, `FinishSessionCall`): never sent.
            case stopped: return "Chat stopped — not sent"
            default: return "Failed"
            }
        default:
            return action.status
        }
    }
}

/// Token-level reading of stored JSON text: a top-level member's raw value
/// and a re-indent that copies every token (string, number, literal) as is.
/// The input must already be valid JSON (callers decode it first).
enum RawJSON {
    /// The raw text of `key`'s value in the top-level object `json`.
    static func member(_ key: String, of json: String) -> String? {
        let chars = Array(json.unicodeScalars)
        var i = skipSpace(chars, 0)
        guard i < chars.count, chars[i] == "{" else { return nil }
        i += 1
        while true {
            i = skipSpace(chars, i)
            guard i < chars.count, chars[i] == "\"" else { return nil }
            let keyEnd = valueEnd(chars, i)
            let keyText = String(String.UnicodeScalarView(chars[i..<keyEnd]))
            let name = (try? JSONSerialization.jsonObject(with: Data(keyText.utf8), options: .fragmentsAllowed)) as? String
            i = skipSpace(chars, keyEnd)
            guard i < chars.count, chars[i] == ":" else { return nil }
            let start = skipSpace(chars, i + 1)
            let end = valueEnd(chars, start)
            if name == key { return String(String.UnicodeScalarView(chars[start..<end])) }
            i = skipSpace(chars, end)
            guard i < chars.count, chars[i] == "," else { return nil }
            i += 1
        }
    }

    /// `json` with two-space indentation and `"key": value` spacing; every
    /// token is copied verbatim, so no number is re-encoded — except that a
    /// string's `\uXXXX` escape of a printable character is shown as that
    /// character (Go's `json.Marshal` writes `<`, `>`, `&` as `\u003c`…, and
    /// an HTML mail body must read as written). The text stays equivalent JSON.
    static func indented(_ json: String) -> String {
        let chars = Array(json.unicodeScalars)
        var out = String.UnicodeScalarView()
        var depth = 0
        var i = 0
        func newline() { out.append("\n"); out.append(contentsOf: String(repeating: "  ", count: depth).unicodeScalars) }
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\"":
                let end = valueEnd(chars, i)
                appendString(chars[i..<end], to: &out)
                i = end
                continue
            case "{", "[":
                out.append(c)
                let next = skipSpace(chars, i + 1)
                if next < chars.count, chars[next] == "}" || chars[next] == "]" {
                    out.append(chars[next])
                    i = next + 1
                    continue
                }
                depth += 1
                newline()
            case "}", "]":
                depth -= 1
                newline()
                out.append(c)
            case ",":
                out.append(c)
                newline()
            case ":":
                out.append(contentsOf: ": ".unicodeScalars)
            case " ", "\t", "\n", "\r":
                break
            default:
                out.append(c)
            }
            i += 1
        }
        return String(out)
    }

    /// Copies a string token, turning `\uXXXX` of a printable scalar (not
    /// `"`, `\`, a control character or a surrogate) into the scalar itself.
    private static func appendString(_ token: ArraySlice<Unicode.Scalar>, to out: inout String.UnicodeScalarView) {
        var i = token.startIndex
        while i < token.endIndex {
            let c = token[i]
            guard c == "\\", i + 1 < token.endIndex else {
                out.append(c)
                i += 1
                continue
            }
            if token[i + 1] == "u", i + 6 <= token.endIndex,
               let code = UInt32(String(String.UnicodeScalarView(token[(i + 2)..<(i + 6)])), radix: 16),
               code >= 0x20, code != 0x22, code != 0x5C, !(0x7F...0x9F).contains(code),
               let scalar = Unicode.Scalar(code) {
                out.append(scalar)
                i += 6
            } else {
                out.append(contentsOf: token[i...(i + 1)])
                i += 2
            }
        }
    }

    private static func skipSpace(_ chars: [Unicode.Scalar], _ from: Int) -> Int {
        var i = from
        while i < chars.count, [" ", "\t", "\n", "\r"].contains(chars[i]) { i += 1 }
        return i
    }

    /// The index just past the value starting at `from` (a string, a nested
    /// object/array, or a bare number/literal).
    private static func valueEnd(_ chars: [Unicode.Scalar], _ from: Int) -> Int {
        guard from < chars.count else { return from }
        var i = from
        if chars[i] == "\"" {
            i += 1
            while i < chars.count, chars[i] != "\"" { i += chars[i] == "\\" ? 2 : 1 }
            return min(i + 1, chars.count)
        }
        if chars[i] == "{" || chars[i] == "[" {
            var depth = 0
            while i < chars.count {
                switch chars[i] {
                case "\"": i = valueEnd(chars, i); continue
                case "{", "[": depth += 1
                case "}", "]":
                    depth -= 1
                    if depth == 0 { return i + 1 }
                default: break
                }
                i += 1
            }
            return i
        }
        while i < chars.count, ![",", "}", "]", " ", "\t", "\n", "\r"].contains(chars[i]) { i += 1 }
        return i
    }
}
