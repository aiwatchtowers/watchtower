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
            case .message(let message, _): "m\(message.id)"
            case .approvals: "approvals"
            }
        }
    }

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
}
