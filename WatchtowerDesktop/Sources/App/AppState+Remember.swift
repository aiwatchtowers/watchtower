extension AppState {
    /// The main chat (and Ask Watchtower, which uses the same view model).
    func wireRemember(_ chat: ChatViewModel) {
        chat.onOwnerMessageStored = { [weak self] text, conversationID, messageID in
            self?.embeddedChats.rememberCenter?.ownerMessageSent(text: text, conversationID: conversationID, messageID: messageID)
        }
    }

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
        selectedDestination = .chat
    }
}
