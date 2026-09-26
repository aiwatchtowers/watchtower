import Foundation

/// Where an applied agent action's "Open" affordance leads: the row the tool
/// created (read from its `result_json`, `internal/tools/*.go`), a web page,
/// or a screen. Views only switch on it; the mapping lives here so it is
/// testable without SwiftUI.
package enum AgentActionDestination: Equatable, Sendable {
    case idea(Int)
    case target(Int)
    case track(Int)
    case url(URL)
    /// `connect_jira_board` — the Boards tab; there is no per-board selection.
    case boards
}

extension AgentAction {
    /// Nil unless the row is `applied`: a pending/failed/rejected row created
    /// nothing, and an `approved`/`executing` one has not finished. Also nil
    /// for a tool with nothing to open (`brief_context` renders its summary in
    /// the card, `remind_me`'s reminder lives in the strip itself) and for a
    /// result missing the key its tool always writes.
    package var destination: AgentActionDestination? {
        guard status == "applied" else { return nil }
        switch tool {
        case "create_idea": return resultID("idea_id").map(AgentActionDestination.idea)
        case "create_target": return resultID("target_id").map(AgentActionDestination.target)
        case "create_track": return resultID("track_id").map(AgentActionDestination.track)
        case "create_jira_issue": return resultWebURL("url").map(AgentActionDestination.url)
        case "connect_jira_board": return .boards
        default: return nil
        }
    }

    /// The Slack message a reaction command was placed on. Only a reaction
    /// row carries a message ref in `context_id` (REACT-02,
    /// `internal/reactioncmd/pipeline.go`); other surfaces use the column
    /// for their own ids.
    package var sourceMessageURL: URL? {
        guard contextType == "reaction" else { return nil }
        return SlackMessageRef.url(contextID)
    }

    private func resultID(_ key: String) -> Int? {
        guard let raw = resultString(key), let id = Int(raw), id > 0 else { return nil }
        return id
    }

    private func resultWebURL(_ key: String) -> URL? {
        guard let raw = resultString(key), let url = URL(string: raw),
              url.scheme == "https" || url.scheme == "http" else { return nil }
        return url
    }
}

/// The `<channel_id>@<message_ts>` message ref a reaction command threads
/// through (`agent_actions.context_id`, `reminders.message_ref`). The channel
/// id may be namespaced (`1:C0ABC`).
package enum SlackMessageRef {
    /// Splits on the LAST `@` (a Slack ts never contains one); nil unless both
    /// halves are non-empty.
    package static func parse(_ ref: String) -> (channelID: String, messageTS: String)? {
        guard let at = ref.lastIndex(of: "@") else { return nil }
        let channel = String(ref[..<at])
        let ts = String(ref[ref.index(after: at)...])
        guard !channel.isEmpty, !ts.isEmpty else { return nil }
        return (channel, ts)
    }

    /// The web archives permalink — it needs no team id, so it works for a
    /// namespaced ref of any connected account (`SlackDeepLink.archives`
    /// strips the namespace).
    package static func url(_ ref: String) -> URL? {
        guard let parsed = parse(ref) else { return nil }
        return SlackDeepLink.archives(channelID: parsed.channelID, messageTS: parsed.messageTS)
    }
}
