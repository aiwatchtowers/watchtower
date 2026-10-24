extension AppState {
    /// The main chat (and Ask Watchtower, which uses the same view model).
    func wireRemember(_ chat: ChatViewModel) {
        chat.onOwnerMessageStored = { [weak self] text, conversationID, messageID in
            self?.embeddedChats.rememberCenter?.ownerMessageSent(text: text, conversationID: conversationID, messageID: messageID)
        }
    }

    /// Settings → Profile, where the owner's Instructions live (the "Open in
    /// Settings" of a remembered line). The Instructions section itself is
    /// not scrolled to yet.
    func openInstructionsSettings() {
        settingsTab = .profile
        openSettingsWindow?()
    }
}
