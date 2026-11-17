import WatchtowerCore

extension AppState {
    /// The main chat (and Ask Watchtower, which uses the same view model):
    /// the marks of remember and the knowledge prefixes, which Go ran in the
    /// turn's start.
    func wireRemember(_ chat: ChatViewModel) {
        chat.onOwnerMessageStarted = { [weak self] started, text in
            self?.embeddedChats.ownerMessageStarted(started, text: text)
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
