import WatchtowerCore

extension AppState {
    /// Settings → Profile scrolled to Instructions (the "Open in Settings" of
    /// a remembered line, and the pointer in System → Workbench).
    func openInstructionsSettings() {
        settingsTab = .profile
        settingsAnchor = .instructions
        openSettingsWindow?()
    }

    /// A conversation in AI Chat (the "Open chat" of a line added from a chat).
    func openChatConversation(_ id: Int64) {
        ensureChatViewModels()
        chatViewModel?.select(conversationID: id)
        chatPanelModel?.selectedConversationID = id
        selectedDestination = .chat
    }

    /// A conversation in AI Chat scrolled to one of its messages (a `chat`
    /// mention on an Inbox idea card), the ⌘K hit path.
    func openChatMessage(conversationID: Int64, messageID: Int64) {
        ensureChatViewModels()
        selectedDestination = .chat
        chatViewModel?.select(conversationID: conversationID)
        chatPanelModel?.selectedConversationID = conversationID
    }
}
