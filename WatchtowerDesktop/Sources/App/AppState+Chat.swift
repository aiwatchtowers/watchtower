import Foundation
import WatchtowerCore

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
    /// It also re-reads when a turn starts waiting on a connector call, so
    /// the call can be approved from the strip while the chat waits.
    func wireActionStripRefresh(_ cvm: ChatViewModel) {
        cvm.onTurnFinished = { [weak self] _ in self?.actionStripViewModel?.refresh() }
        cvm.onActionAwaited = { [weak self] _ in self?.actionStripViewModel?.refresh() }
    }

    /// The claude.ai list is beside the database (Go: the db path's
    /// directory); a written switch retires the main chat's idle sessions so
    /// the next turn starts with it. Embedded chats get none of these tools.
    func makeClaudeAIConnectors() -> ClaudeAIConnectorsModel {
        let model = ClaudeAIConnectorsModel { [weak self] in
            let dir = self?.databaseManager.map { ($0.dbPool.path as NSString).deletingLastPathComponent }
                ?? Constants.activeWorkspaceDir()
            return dir.map { ($0 as NSString).appendingPathComponent(ClaudeAIConnectorsFile.fileName) }
        }
        model.onSwitched = { [weak self] in self?.chatSessionPool?.retireIdleSessions() }
        return model
    }
}
