import ChatUI
import ChatWire
import Foundation
import WatchtowerCore
import WatchtowerInterface

extension AppState {
    /// The chat writes no engine op covers (embedded chats, drafts, meetings,
    /// code questions) go to Go through the tower (mobile Inbox spec §8).
    var chatWrites: ChatWrites { ChatWrites(tower: towerClient) }

    /// The asks' "Not clear?" chats (spec 2026-11-24) live in the app's
    /// embedded chat center; they run the assistant through the CLI, so a
    /// host without one gets none.
    func wireAskExplain(_ asks: OwnerAsksViewModel, hasCLI: Bool) {
        guard hasCLI else { return }
        asks.chats = embeddedChatCenter
        asks.chatWrites = chatWrites
    }

    /// The main chat's window shell over the engine's client. A new automatic
    /// chat reads the current saved provider preference.
    func makeMainChatViewModel(_ db: DatabaseManager, client: any ChatClient) -> ChatViewModel {
        let currentProvider = { AIProvider.fromConfig(Constants.aiProviderID()) }
        return ChatViewModel(client: client, dbPool: db.dbPool,
                             provider: AIProvider.fromConfig(ConfigService().aiProvider),
                             cliRunner: ProcessCLIRunner.makeDefault(), preferredProviderSource: currentProvider)
    }

    /// The chat and its panel: the landing's first send becomes the panel's
    /// selection, and the landing leaves a project the panel stops showing
    /// (spec 2026-10-26 §4).
    static func wireChat(_ cvm: ChatViewModel, panel: ChatPanelModel) {
        cvm.onConversationCreated = { [weak panel] id in panel?.selectedConversationID = id }
        panel.onLevelChanged = { [weak cvm] level in cvm?.panelLevelChanged(to: level.projectID) }
    }

    /// The Inbox strip re-reads when any chat starts or stops answering or
    /// waiting: a connector call it shows runs inside that chat's turn, and a
    /// call waiting for approval can be approved from the strip.
    func followChatForActionStrip(_ client: any ChatClient) {
        chatActionStripWatch?.cancel()
        let updates = client.list()
        chatActionStripWatch = Task { [weak self] in
            var last: [Int64: ChatList.State] = [:]
            for await update in updates {
                guard case .snapshot(let list) = update else { continue }
                self?.chatRunningTurns = Self.runningTurns(in: list)
                let states = Dictionary(list.conversations.map { ($0.id, $0.state) }) { first, _ in first }
                guard states != last else { continue }
                last = states
                await self?.actionStripViewModel?.refresh()
            }
        }
    }

    /// Each chat's running turn in the engine's list: a chat answering or waiting on an approval with its turn
    /// still held (an older engine sends no turn id: none).
    nonisolated static func runningTurns(in list: ChatList) -> [Int64: String] {
        var out: [Int64: String] = [:]
        for conv in list.conversations where conv.leaseOwner != nil {
            if let turn = conv.turnID { out[conv.id] = turn }
        }
        return out
    }

    /// Whether the live chat session that proposed `action` still holds it (its chat runs that very turn): the
    /// Inbox strip's Approve and its "session ended" line.
    func chatHoldsSessionCall(_ action: AgentAction) -> Bool {
        let running = chatViewModel?.runningTurnID(conversationID: action.conversationID)
            ?? chatRunningTurns[action.conversationID]
        return ConnectorCallProposal.sessionHolds(action, runningTurnID: running)
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
        // The engine reads the list when it starts a session: every warm one
        // is retired (a running turn finishes first), so none keeps the old tools.
        model.onSwitched = { [weak self] in
            guard let client = self?.chatClient else { return }
            Task { _ = try? await client.send(.retireSessions) }
        }
        return model
    }
}

extension AppState {
    /// The app's one provider catalog. Read-only: every chat surface reads
    /// `AIModelCatalog.shared`, so a second instance here could only drift.
    var aiModelCatalog: AIModelCatalog { AIModelCatalog.shared }

    /// Reads the provider catalog at launch, tray-only launches included
    /// (not when a window opens): the capability rows, the fallback pair and
    /// AGENT-04's tool access need it. Not awaited by the launch; a failed
    /// read is logged and tried again a few times (`loadRetrying`), and a
    /// second read while one runs waits for it (`AIModelCatalog.load`).
    /// Tests replace the read with `modelCatalogLaunchOverride`.
    func loadModelCatalogAtLaunch() {
        if let modelCatalogLaunchOverride {
            Task { await modelCatalogLaunchOverride() }
            return
        }
        Task { await AIModelCatalog.shared.loadRetrying() }
    }
}
