import WatchtowerCore

extension AppState {
    /// The main chat (and Ask Watchtower, which uses the same view model):
    /// remember and the knowledge prefixes, as on every embedded chat.
    func wireRemember(_ chat: ChatViewModel) {
        chat.onOwnerMessageStored = { [weak self] text, conversationID, messageID in
            self?.embeddedChats.ownerMessageStored(text: text, conversationID: conversationID, messageID: messageID)
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

    /// A conversation in AI Chat scrolled to one of its messages (a `chat`
    /// mention on an Inbox idea card), the ⌘K hit path.
    func openChatMessage(conversationID: Int64, messageID: Int64) {
        ensureChatViewModels()
        selectedDestination = .chat
        guard let chat = chatViewModel else { return }
        Task {
            await chat.open(ChatSearchHit(conversationID: conversationID, messageID: messageID, title: "", snippet: ""))
        }
    }
}
