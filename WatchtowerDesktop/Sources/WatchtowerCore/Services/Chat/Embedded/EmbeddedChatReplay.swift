import Foundation

/// The conversation so far, written into a turn that starts a fresh provider
/// run: a Claude turn resumes its session, which holds the earlier turns, but
/// a Codex or Ollama turn (or a Claude turn after a provider switch) starts
/// from nothing (board #361). The block and its wording follow the main
/// chat's Go replay (`internal/chat/replay.go`): the newest messages kept
/// first under `capCharacters`, the oldest dropped and counted. Pure.
package enum EmbeddedChatReplay {
    /// The main chat's cap (`chat.ReplayCapChars`), in characters.
    package static let capCharacters = 24000
    package static let header =
        "=== CONVERSATION SO FAR (replayed from Watchtower's history; the earlier model session is not available) ==="
    package static let footer = "=== END OF CONVERSATION SO FAR — the owner's new message follows ==="

    /// The block for the turn `turnID` (its own rows are left out), or nil
    /// when nothing came before it. System notices, failed replies and
    /// empty ones are skipped; a reply stopped early says so. A trailing
    /// owner message nothing answered is the one a Retry sends again, so it
    /// is left out too.
    package static func block(messages: [ChatMessageRecord], before turnID: String,
                              capCharacters: Int = capCharacters) -> String? {
        var entries: [(role: String, text: String)] = []
        for message in messages where message.turnID.isEmpty || message.turnID != turnID {
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            switch (message.role, message.status) {
            case ("user", _):
                entries.append(("Owner", text))
            case ("assistant", "complete"):
                entries.append(("Assistant", text))
            case ("assistant", "partial"):
                entries.append(("Assistant (stopped early)", text))
            default:
                continue
            }
        }
        if entries.last?.role == "Owner" { entries.removeLast() }
        guard !entries.isEmpty else { return nil }

        let rendered = entries.map { "\($0.role): \($0.text)\n" }
        var start = rendered.count
        var used = 0
        var kept = rendered
        for index in rendered.indices.reversed() {
            let size = rendered[index].count
            if used + size > capCharacters {
                if start == rendered.count {
                    // The newest alone is over the cap: cut, not dropped.
                    kept[index] = String(rendered[index].prefix(capCharacters - 1)) + "\n"
                    start = index
                }
                break
            }
            used += size
            start = index
        }
        var lines = [header + "\n"]
        if start > 0 { lines.append("[\(start) earlier messages omitted]\n") }
        lines += kept[start...]
        lines.append(footer + "\n\n")
        return lines.joined()
    }
}
