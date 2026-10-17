import Foundation

extension AppState {
    /// The main chat's two view models: the history list follows the chat's
    /// writes, and the landing's first turn becomes the history selection.
    static func wireChat(_ cvm: ChatViewModel, history hvm: ChatHistoryViewModel) {
        cvm.onConversationsChanged = { [weak hvm] in hvm?.load() }
        cvm.onLandingTurnStarted = { [weak hvm] id in hvm?.selectedConversationID = id }
    }

    /// The Inbox strip re-reads when a chat turn ends: a connector call it
    /// shows ran inside that turn, and the card's live "the session holds it"
    /// turned false with it — a stale `approved` row would read "not sent".
    func wireActionStripRefresh(_ cvm: ChatViewModel) {
        cvm.onTurnFinished = { [weak self] _ in self?.actionStripViewModel?.refresh() }
    }
}
