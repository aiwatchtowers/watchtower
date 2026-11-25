import ChatWire
import Foundation

/// Workchat's session feed (`SessionFeedEntry`, built by Go `internal/sessionfeed`) as ChatUI's feed messages (unified
/// chat spec §9.2). The session keeps its own engine (the session feed store and the terminal); only the drawing moves
/// onto ChatUI. The owner's lines and the answers to asks are the owner's, the agent's text is the answer, and
/// everything else — Watchtower's own lines, the brief, notices, separators and peer cards — is a `system` line the
/// Mac draws itself. Subagent markers map to no message: agents live in the 👥 list, never in the dialog (#2065). No
/// parts are built (D14): ChatUI derives them from the text.
package enum WorkchatFeedAdapter {
    /// ChatUI's role of a line that is neither the owner's nor an answer.
    package static let systemRole = "system"

    /// The known entries in order; a kind this build does not know is left out. An owner line's image paths read
    /// `[Image #N]`, as in the field (`WorkchatOwnerImages`).
    package static func messages(_ entries: [SessionFeedEntry]) -> [ChatFeed.Message] {
        entries.compactMap { entry in
            guard let role = role(for: entry.kind) else { return nil }
            let text = entry.kind == "owner" ? WorkchatOwnerImages.shown(entry.text, markdown: true) : entry.text
            return ChatFeed.Message(id: messageID(entry.id), role: role, text: text, createdAt: entry.at ?? .distantPast)
        }
    }

    /// The entries that make the dialog: everything but the subagent markers,
    /// which draw nothing (the empty state and the feed window count these).
    package static func dialog(_ entries: [SessionFeedEntry]) -> [SessionFeedEntry] {
        entries.filter { $0.kind != "subagent" }
    }

    /// The role an entry kind takes; nil for a kind this build does not know and for a subagent marker.
    package static func role(for kind: String) -> String? {
        switch kind {
        case "owner", "ask_answer": "user"
        case "agent": "assistant"
        case "watchtower", "brief", "event", "separator", "peer": systemRole
        default: nil
        }
    }

    /// A stable message id for a feed entry's string id (64-bit FNV-1a, kept positive): the same entry keeps its row
    /// across reads, and the Mac finds the entry again by it.
    package static func messageID(_ entryID: String) -> Int64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in entryID.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Int64(bitPattern: hash & UInt64(Int64.max))
    }

    /// The line under a message: "via Watchtower" for a line Watchtower carried, then its time.
    package static func caption(_ entry: SessionFeedEntry) -> [String] {
        var parts: [String] = []
        if entry.kind == "ask_answer" { parts.append("via Watchtower") }
        if let at = entry.at { parts.append(at.formatted(.dateTime.hour().minute())) }
        return parts
    }

    /// An ask answer's bubble names its ask ("Ask #12") and the ask's title over the text.
    package static func askHeader(_ entry: SessionFeedEntry) -> (label: String, title: String?)? {
        guard entry.kind == "ask_answer" else { return nil }
        return (entry.askID.map { "Ask #\($0)" } ?? "Ask", entry.title.flatMap { $0.isEmpty ? nil : $0 })
    }
}
