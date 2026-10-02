import Foundation
import WatchtowerCore

extension EmbeddedChatEngine {
    /// The rows as `ChatMessage`s — what a surface's controller and its
    /// tests read: stable ids (`UUID(chatRowID:)`) and the live reply's text.
    var chatMessages: [ChatMessage] {
        messages.map { item in
            let live = liveTurn.flatMap { $0.messageID == item.id ? $0 : nil }
            let row = item.message.toChatMessage()
            return ChatMessage(id: UUID(chatRowID: item.id), role: row.role, text: live?.fullText ?? row.text,
                               timestamp: row.timestamp, isStreaming: live != nil, turnID: row.turnID)
        }
    }
}
