import Foundation
import WatchtowerCore

extension ChatMessageRecord {
    func toChatMessage() -> ChatMessage {
        let msgRole: ChatMessage.Role = switch role {
        case "user": .user
        case "system": .system
        default: .assistant
        }
        return ChatMessage(
            id: UUID(),
            role: msgRole,
            text: text,
            timestamp: createdDate,
            isStreaming: false,
            turnID: turnID.isEmpty ? nil : turnID
        )
    }
}
