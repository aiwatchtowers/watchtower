import Foundation

/// A `send_slack_message` proposal as the card shows it (spec 2026-10-02 §7):
/// who it goes to, the text, and — when the recipient exists in several
/// workspaces — the candidates the owner picks from. Everything comes from the
/// args Normalize pinned at propose time (`internal/tools/slack_send.go`); the
/// card never re-resolves a recipient.
package struct SlackSendProposal: Equatable, Sendable {
    package static let tool = "send_slack_message"
    /// Go `tools.SlackSendScopeHint`: the phrase every "this token cannot
    /// send" failure carries. Change both together.
    package static let scopeHint = "sign in again to grant send"
    /// Go `slackSendMaxRunes`.
    package static let maxCharacters = 4000

    package struct Recipient: Equatable, Sendable {
        package let accountID: Int64
        package let workspace: String
        package let label: String
        package let threadTS: String
        package let isDM: Bool

        /// "#general in Acme", "a thread in #general in Acme", "@Alice in Acme".
        package var line: String {
            let place = threadTS.isEmpty || isDM ? label : "a thread in \(label)"
            return workspace.isEmpty ? place : "\(place) in \(workspace)"
        }
    }

    package let text: String
    package let target: Recipient?
    package let candidates: [Recipient]

    /// Nil for another tool, and for args with neither a pinned target nor
    /// candidates (unreadable: the card falls back to the raw arguments).
    package init?(action: AgentAction) {
        guard action.tool == Self.tool else { return nil }
        let args = action.args
        let target = (args["target"] as? [String: Any]).map(Self.recipient)
        let candidates = (args["candidates"] as? [[String: Any]] ?? []).map(Self.recipient)
        guard target != nil || !candidates.isEmpty else { return nil }
        self.text = AgentAction.stringValue(args["text"]) ?? ""
        self.target = target
        self.candidates = candidates
    }

    package init(text: String, target: Recipient?, candidates: [Recipient]) {
        self.text = text
        self.target = target
        self.candidates = candidates
    }

    private static func recipient(_ raw: [String: Any]) -> Recipient {
        Recipient(
            accountID: (raw["account_id"] as? NSNumber)?.int64Value ?? 0,
            workspace: AgentAction.stringValue(raw["workspace"]) ?? "",
            label: AgentAction.stringValue(raw["label"]) ?? "?",
            threadTS: AgentAction.stringValue(raw["thread_ts"]) ?? "",
            isDM: !(AgentAction.stringValue(raw["user_id"]) ?? "").isEmpty
        )
    }

    /// The card's "To:" line. With candidates and no pick yet it asks for one.
    package var recipientLine: String {
        if let target { return "To: \(target.line)" }
        let label = candidates.first?.label ?? "?"
        return "To: \(label) — exists in \(candidates.count) workspaces, choose one"
    }

    /// Whether Approve may run: a workspace is chosen (pinned or picked) and
    /// the text is sendable. Mirrors Go `slackSendReady`.
    package func canApprove(text editedText: String, pick: Int?) -> Bool {
        let trimmed = editedText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Go counts runes: unicode scalars, not grapheme clusters.
        guard !trimmed.isEmpty, editedText.unicodeScalars.count <= Self.maxCharacters else { return false }
        if target != nil { return true }
        guard let pick else { return false }
        return candidates.indices.contains(pick)
    }

    /// The `actions approve --patch` JSON for the owner's edits, nil when there
    /// are none (a plain approve). Only `text` and `candidate` are editable —
    /// Go `reviseSlackSend` refuses anything else. Throws rather than return
    /// nil when the edits cannot be encoded, so they are never silently
    /// replaced by the original draft.
    package func patch(text editedText: String, pick: Int?) throws -> String? {
        var fields: [String: Any] = [:]
        if editedText != text { fields["text"] = editedText }
        if target == nil, let pick { fields["candidate"] = pick }
        guard !fields.isEmpty else { return nil }
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else { throw PatchError.unencodable }
        return json
    }

    package enum PatchError: Error { case unencodable }

    /// What Approve runs: a plain approve, or one carrying the owner's edits.
    package enum Approval: Equatable, Sendable {
        case plain
        case edited(patch: String)
    }

    /// The card's Approve decision for the editor's current text and pick.
    package func approval(text editedText: String, pick: Int?) throws -> Approval {
        try patch(text: editedText, pick: pick).map { .edited(patch: $0) } ?? .plain
    }

    /// The account to re-consent when a send failed for want of the
    /// `chat:write` grant; nil for any other failure.
    package static func reconnectAccountID(_ action: AgentAction) -> Int64? {
        guard action.tool == tool, action.status == "failed", action.error.contains(scopeHint),
              let proposal = Self(action: action) else { return nil }
        return proposal.target?.accountID
    }
}
