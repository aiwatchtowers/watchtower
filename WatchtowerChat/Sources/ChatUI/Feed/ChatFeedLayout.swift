import ChatWire
import Foundation

/// The feed's rows, built from the messages (pure): one row per message with its drawn parts, then the approvals no
/// part shows — the flat `feed.actions` of a Mac one version behind, whose messages carry no parts.
public enum ChatFeedLayout {
    public enum Row: Identifiable, Equatable {
        case message(ChatFeed.Message, parts: [ChatPart])
        case approvals([ChatFeed.Action])

        public var id: String {
            switch self {
            case .message(let message, _): ChatFeedLayout.rowID(message.id)
            case .approvals: "approvals"
            }
        }
    }

    /// The row id of the message with this id (what a scroll targets).
    public static func rowID(_ messageID: Int64) -> String { "m\(messageID)" }

    public static func rows(messages: [ChatFeed.Message], actions: [ChatFeed.Action]) -> [Row] {
        var shown = Set<Int64>()
        var rows: [Row] = []
        for message in messages {
            let parts = ChatMessageParts.parts(for: message)
            for part in parts where part.kind == ChatPartKind.approval {
                if let payload = try? part.decodePayload(ChatApprovalPayload.self) { shown.insert(payload.id) }
            }
            rows.append(.message(message, parts: parts))
        }
        let rest = actions.filter { !shown.contains($0.id) }
        if !rest.isEmpty { rows.append(.approvals(rest)) }
        return rows
    }

    /// A question card is answerable on the latest reply that nothing has answered yet, while no turn runs (a
    /// `system` line after it does not count).
    public static func isAnswerable(_ id: Int64, in messages: [ChatFeed.Message], isTurnRunning: Bool) -> Bool {
        guard !isTurnRunning, messages.last(where: { $0.role == "assistant" })?.id == id else { return false }
        return ownerReply(after: id, in: messages) == nil
    }

    /// The owner's words right after the reply with this id: what answered its card.
    public static func ownerReply(after id: Int64, in messages: [ChatFeed.Message]) -> String? {
        guard let index = messages.firstIndex(where: { $0.id == id }), messages[index].role == "assistant" else { return nil }
        return messages[(index + 1)...].first { $0.role == "user" }?.text
    }
}
