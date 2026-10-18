import Foundation
import WatchtowerCore
import WatchtowerSync

/// The wire payload of the `session_chat` slice: the CLI's session feed
/// (`SessionFeedPayload`, oldest first) cut to the newest 300 entries, texts
/// clipped at 4000, labels at 200, and the encoded size held under 600 000
/// bytes by dropping the oldest entries. Everything dropped is counted in
/// `entries_more`. Wire shape: the Kit mirror `WatchtowerKit.SessionChat`.
enum SessionChatPayload {
    static let maxEntries = 300
    static let maxText = 4000
    static let maxLabel = 200
    static let maxBytes = 600_000

    private struct Subagent: Encodable {
        let agentID: String
        let toolUseID: String
        let type: String
        let description: String
        let status: String

        enum CodingKeys: String, CodingKey {
            case agentID = "agent_id"
            case toolUseID = "tool_use_id"
            case type, description, status
        }
    }

    private struct Entry: Encodable {
        let id: String
        let kind: String
        let at: Date?
        let text: String
        let textClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
        let askID: Int64?
        let title: String?
        let via: String?
        let subagent: Subagent?

        enum CodingKeys: String, CodingKey {
            case id, kind, at, text, title, via, subagent
            case textClipped = "text_clipped"
            case askID = "ask_id"
        }
    }

    private struct Payload: Encodable {
        let sessionID: Int64
        let agentID: String?
        let live: Bool
        let entriesMore: Int
        let entries: [Entry]

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case agentID = "agent_id"
            case live
            case entriesMore = "entries_more"
            case entries
        }
    }

    /// The FEED-02 kinds only (`SessionFeedEntry.knownKinds`: no tool calls,
    /// thinking or kinds a newer CLI adds), cut to the newest `maxEntries`,
    /// then trimmed from the oldest end until the encoded size fits
    /// `maxBytes`. The payload carries no clock, so an unchanged feed encodes
    /// to the same bytes and is not uploaded again.
    static func encode(
        _ feed: SessionFeedPayload,
        sessionID: Int64,
        agentID: String?,
        live: Bool
    ) throws -> Data {
        let known = feed.entries.filter { SessionFeedEntry.knownKinds.contains($0.kind) }
        let tail = SliceClip.list(Array(known.reversed()), limit: maxEntries)
        let entries = tail.items.reversed().map(entry)
        let encoder = RelayCoder.makeEncoder()
        // Each entry is measured once; the envelope is measured with the
        // largest `entries_more` it can carry.
        let sizes = try entries.map { try encoder.encode($0).count }
        let overhead = try encoder.encode(Payload(
            sessionID: sessionID, agentID: agentID, live: live, entriesMore: known.count, entries: []
        )).count
        var kept = entries.count
        var total = overhead + max(0, kept - 1) // the commas between entries
        total += sizes.reduce(0, +)
        var dropped = 0
        while total > maxBytes, kept > 0 {
            total -= sizes[dropped] + (kept > 1 ? 1 : 0)
            dropped += 1
            kept -= 1
        }
        return try encoder.encode(Payload(
            sessionID: sessionID,
            agentID: agentID,
            live: live,
            entriesMore: (tail.more ?? 0) + dropped,
            entries: Array(entries.dropFirst(dropped))
        ))
    }

    private static func entry(_ source: SessionFeedEntry) -> Entry {
        let text = SliceClip.text(source.text, limit: maxText)
        return Entry(
            id: source.id,
            kind: source.kind,
            at: source.at,
            text: text.text,
            textClipped: text.clipped,
            askID: source.askID,
            title: source.title.map { SliceClip.text($0, limit: maxLabel).text },
            via: source.via,
            subagent: source.subagent.map {
                Subagent(
                    agentID: $0.agentID,
                    toolUseID: $0.toolUseID,
                    type: $0.type,
                    description: SliceClip.text($0.description, limit: maxLabel).text,
                    status: $0.status
                )
            }
        )
    }
}
