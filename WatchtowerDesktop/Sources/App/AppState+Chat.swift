import Foundation
import WatchtowerCore

extension AppState {
    /// The main chat's two view models: the history list follows the chat's
    /// writes, the landing's first turn becomes the history selection, and
    /// the panel's "Answering" state reads the chat's session pool.
    static func wireChat(_ cvm: ChatViewModel, history hvm: ChatHistoryViewModel) {
        cvm.onConversationsChanged = { [weak hvm] in hvm?.reloadRows() }
        cvm.onLandingTurnStarted = { [weak hvm] id in hvm?.selectedConversationID = id }
        hvm.isAnswering = { [weak cvm] id in cvm?.isAnswering(conversationID: id) ?? false }
        // The panel's quick delete commits through the chat's own path (spec
        // 2026-10-26 §5.3): the session retired, then the row deleted.
        hvm.forgetConversation = { [weak cvm] id in cvm?.forget(conversationID: id) }
        // The landing leaves a project the panel stops showing (spec §4).
        hvm.onLevelChanged = { [weak cvm] level in cvm?.panelLevelChanged(to: level.projectID) }
    }

    /// The chat's two signals, each assigned only here (they are single
    /// closures, spec 2026-10-26 §5.2). The Inbox strip re-reads when a chat
    /// turn ends: a connector call it shows ran inside that turn, and the
    /// card's live "the session holds it" turned false with it — a stale
    /// `approved` row would read "not sent". It also re-reads when a turn
    /// starts waiting on a connector call, so the call can be approved from
    /// the strip while the chat waits.
    func wireActionStripRefresh(_ cvm: ChatViewModel, history hvm: ChatHistoryViewModel) {
        Self.wireChatRefresh(
            cvm, history: hvm,
            isChatOnScreen: { [weak self] in
                guard let self else { return false }
                return self.selectedDestination == .chat || self.isHelpChatShown
            },
            refreshActionStrip: { [weak self] in await self?.actionStripViewModel?.refresh() }
        )
        wireRemember(cvm)
    }

    /// Beside the strip, the Chats panel re-reads its rows on both signals:
    /// the pending proposal and the turn's end were written by the session's
    /// MCP subprocess or by Go, which the panel's observation does not see.
    /// A turn that ends on the chat on screen marks it read (the panel's
    /// observation shows the mark); one that ends elsewhere leaves it unread.
    static func wireChatRefresh(
        _ cvm: ChatViewModel,
        history hvm: ChatHistoryViewModel,
        isChatOnScreen: @escaping @MainActor () -> Bool,
        refreshActionStrip: @escaping @MainActor () async -> Void
    ) {
        cvm.onTurnFinished = { [weak cvm, weak hvm] id in
            Task { await refreshActionStrip() }
            guard let hvm else { return }
            if isChatOnScreen(), cvm?.isShowing(conversationID: id) == true { hvm.markRead(id) }
            hvm.reloadRows()
        }
        cvm.onActionAwaited = { [weak hvm] _ in
            Task { await refreshActionStrip() }
            hvm?.reloadRows()
        }
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
