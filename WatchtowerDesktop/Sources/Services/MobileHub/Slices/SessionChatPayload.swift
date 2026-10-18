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
    /// Entries dropped per re-encode while the payload is over budget.
    private static let dropChunk = 10

    private struct Subagent: Encodable {
        let agentID: String
        let type: String
        let description: String
        let status: String

        enum CodingKeys: String, CodingKey {
            case agentID = "agent_id"
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
        let updatedAt: Date
        let live: Bool
        var entriesMore: Int
        var entries: [Entry]

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case agentID = "agent_id"
            case updatedAt = "updated_at"
            case live
            case entriesMore = "entries_more"
            case entries
        }
    }

    static func encode(
        _ feed: SessionFeedPayload,
        sessionID: Int64,
        agentID: String?,
        live: Bool,
        now: Date
    ) throws -> Data {
        let tail = SliceClip.list(Array(feed.entries.reversed()), limit: maxEntries)
        var payload = Payload(
            sessionID: sessionID,
            agentID: agentID,
            updatedAt: now,
            live: live,
            entriesMore: tail.more ?? 0,
            entries: tail.items.reversed().map(entry)
        )
        let encoder = RelayCoder.makeEncoder()
        var data = try encoder.encode(payload)
        while data.count > maxBytes, !payload.entries.isEmpty {
            let drop = min(dropChunk, payload.entries.count)
            payload.entries.removeFirst(drop)
            payload.entriesMore += drop
            data = try encoder.encode(payload)
        }
        return data
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
                    type: $0.type,
                    description: SliceClip.text($0.description, limit: maxLabel).text,
                    status: $0.status
                )
            }
        )
    }
}
