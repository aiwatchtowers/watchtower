import Foundation

/// The chat-mode binding a chat VM hands to `watchtower ai query`: which
/// surface is speaking, which conversation, and the turn id proposals made
/// during this turn attach to. Only the main AI Chat and the target chat
/// ever build one (AGENT-04); every other surface passes nil.
package struct ChatToolMode: Equatable, Sendable {
    package let surface: String
    package let conversationID: Int64
    package let turnID: String
    package let contextType: String?
    package let contextID: String?

    package init(surface: String, conversationID: Int64, turnID: String, contextType: String? = nil, contextID: String? = nil) {
        self.surface = surface
        self.conversationID = conversationID
        self.turnID = turnID
        self.contextType = contextType
        self.contextID = contextID
    }

    package var cliArgs: [String] {
        var args = ["--tools", "chat", "--surface", surface, "--conversation", String(conversationID), "--turn", turnID]
        if let contextType, let contextID {
            args += ["--context-type", contextType, "--context-id", contextID]
        }
        return args
    }
}
