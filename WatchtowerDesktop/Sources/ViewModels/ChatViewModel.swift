import Foundation
import GRDB
import WatchtowerCore

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    var role: Role
    var text: String
    var timestamp: Date
    var isStreaming: Bool
    var turnID: String?

    enum Role: Equatable {
        case user
        case assistant
        case system
    }
}

enum AIProvider: String, CaseIterable, Identifiable {
    case claude
    case codex
    case ollama

    var id: String { rawValue }

    /// The chat provider for a config.yaml `ai.provider` value: any known
    /// provider as is (ollama included), anything else — unset, unknown — Claude.
    static func fromConfig(_ value: String?) -> Self {
        value.flatMap(Self.init(rawValue:)) ?? .claude
    }

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .ollama: "Ollama"
        }
    }
}

/// The main AI Chat (spec §1.4, §2.3). An action surface (AGENT-04): the Go
/// session mounts the registry's write tools for `--surface main`, and Go
/// builds the system prompt (`internal/chat`) — Swift sends only turns.
///
/// Ownership: running turns live in `ChatSessionPool` (app-wide), which
/// persists them. This view model only starts turns and renders — so it can
/// be released or switched mid-turn without losing a byte (CHAT-01).
///
/// Invariant: a new owner message never sits directly under another owner
/// message. Every turn writes its owner row and its (empty, `partial`)
/// assistant row in one transaction, and a legacy unanswered question gets
/// an empty `partial` reply first — Go's `HistoryBefore` drops one trailing
/// owner row, which must only ever be the question being re-sent.
@MainActor
@Observable
final class ChatViewModel {
    private(set) var conversationID: Int64?
    private(set) var currentConversation: ChatConversation?
    /// Finished rows of the active branch. Never mutated by a streaming
    /// delta — the live message is `liveTurn` (render isolation).
    private(set) var thread: [ChatThreadItem] = []
    var draft = ""
    var errorMessage: String?
    private(set) var selectedProvider: AIProvider
    /// Model override; "" = the provider's resolved strong model (the CLI resolves it).
    var selectedModel = "" {
        didSet { if selectedModel != oldValue { recycleSession() } }
    }
    var scrollTarget: Int64?
    var editingMessageID: Int64?
    /// History list refresh (conversation order, titles written by Go).
    @ObservationIgnored var onConversationsChanged: (() -> Void)?

    let actionFeed: AgentActionFeed
    let pool: ChatSessionPool
    /// The composer's not-yet-sent attachments (Task 21). nil `store` (no
    /// active workspace) still renders — `add`/`addPastedImage` just report
    /// "Attachments need an active workspace".
    let composerAttachments: ComposerAttachments
    /// The composer's @-picker and the current draft's picked mentions
    /// (Task 25).
    let composer: ComposerPickerModel

    /// The artifact side panel for the current conversation; nil = closed.
    /// Survives navigation only within the same conversation — switching or
    /// forgetting a conversation closes it (CHAT-05 storage has no notion of
    /// "panel for a conversation not on screen").
    private(set) var artifactPanel: ArtifactPanelModel?
    /// The sources panel (one finished answer's sources); nil = closed. It
    /// shares the inspector with `artifactPanel` under `ChatInspectorPolicy`
    /// and closes with it on a conversation switch.
    private(set) var sourcesPanel: ChatSourcesSelection?
    /// The inspector tab opened last; see `inspectorMode` for what shows.
    var preferredInspectorMode: ChatInspectorMode = .artifacts
    /// Non-edited version numbers per message, for the card badges — reloaded
    /// with the thread (`reload()`).
    private(set) var artifactVersionsByMessage: [Int64: [String: Int]] = [:]
    private(set) var gmailConnected = false
    private(set) var slackLinks: SlackLinkResolver?
    /// The project page open in the detail area, or nil when a conversation
    /// (or the landing) is shown.
    private(set) var openProjectID: Int64?
    /// The landing (new-chat composer + recent chats) is shown instead of a
    /// thread. It may already hold a fresh, message-less conversation — made
    /// on the first keystroke so its session prewarms — and stays up until
    /// that conversation's first turn starts or another one is opened.
    private(set) var isOnLanding = true
    /// Active (unarchived) projects for the sidebar.
    private(set) var projects: [ChatProject] = []
    /// Keys the owner closed the panel for during the CURRENT turn — a
    /// streaming turn does not reopen a panel the owner just dismissed.
    /// Cleared at the start of every new turn.
    @ObservationIgnored private var dismissedArtifactKeys: Set<String> = []

    @ObservationIgnored private let dbManager: DatabaseManager
    @ObservationIgnored private let cliRunner: CLIRunnerProtocol?
    @ObservationIgnored private let makeTurnID: () -> String
    @ObservationIgnored private var titleRequests: Set<Int64> = []
    @ObservationIgnored private var applyingConversationSettings = false

    init(
        dbManager: DatabaseManager,
        pool: ChatSessionPool,
        provider: AIProvider = .claude,
        cliRunner: CLIRunnerProtocol? = nil,
        makeTurnID: @escaping () -> String = { UUID().uuidString }
    ) {
        self.dbManager = dbManager
        self.pool = pool
        self.selectedProvider = provider
        self.cliRunner = cliRunner
        self.makeTurnID = makeTurnID
        self.actionFeed = AgentActionFeed(dbPool: dbManager.dbPool, cliRunner: cliRunner)
        self.composerAttachments = ComposerAttachments(
            store: ChatAttachmentStore.defaultRootDir().map { ChatAttachmentStore(db: dbManager.dbPool, rootDir: $0) }
        )
        let dbPool = dbManager.dbPool
        self.composer = ComposerPickerModel(
            searchMentions: { query in
                do {
                    return try dbPool.read { try MentionSearch.search($0, query: query) }
                } catch {
                    NSLog("ChatViewModel: mention search failed: %@", error.localizedDescription)
                    return []
                }
            },
            skills: { SkillsCatalog.pickerSkills(contextType: "main") }
        )
        pool.onTurnFinished = { [weak self] id in self?.turnFinished(conversationID: id) }
        reloadProjects()
    }

    /// The streaming message of the shown conversation — its own observable,
    /// throttled to ~30 fps (`LiveTurn`); only the row showing it re-renders.
    var liveTurn: LiveTurn? { pool.client(for: conversationID)?.liveTurn }
    /// A turn is running — or held by the pool waiting for a session.
    var isStreaming: Bool { liveTurn?.isRunning == true }
    /// Every live session is busy with another conversation's turn: this
    /// turn is held (not lost) until one finishes. The UI says so.
    var isWaitingForSession: Bool {
        guard let client = pool.client(for: conversationID) else { return false }
        return client.isPending && client.isBusy
    }

    // MARK: - Conversations

    func select(conversationID id: Int64) {
        openProjectID = nil
        isOnLanding = false
        let switching = id != conversationID
        conversationID = id
        editingMessageID = nil
        reload()
        guard switching else { return }
        errorMessage = nil
        artifactPanel = nil
        sourcesPanel = nil
        dismissedArtifactKeys = []
        applyConversationSettings()
        actionFeed.start(conversationID: id)
        prewarm()
    }

    @discardableResult
    func newConversation(projectID: Int64? = nil) -> Int64? {
        do {
            let conv = try dbManager.dbPool.write { db in try ChatConversationQueries.create(db, projectID: projectID) }
            select(conversationID: conv.id)
            reloadConversations()
            return conv.id
        } catch {
            errorMessage = "Couldn't start a new chat: \(error.localizedDescription)"
            return nil
        }
    }

    /// A conversation is being deleted: close its session; stop showing it
    /// (the landing takes its place).
    func forget(conversationID id: Int64) {
        pool.close(conversationID: id)
        guard id == conversationID else { return }
        isOnLanding = true
        clearShownConversation()
    }

    /// Entering the Chat tab (owner decision 2026-09-28): reopen the last
    /// conversation when `ChatLandingPolicy` says so, otherwise the landing.
    /// `rememberedConversationID`/`lastViewedAt` are what the view stored on
    /// leaving — they matter after a relaunch, when nothing is shown yet. An
    /// open project page is left as it is.
    func enterTab(rememberedConversationID: Int64?, lastViewedAt: Date?, now: Date) {
        guard openProjectID == nil else { return }
        let id = conversationID ?? rememberedConversationID
        let viewedAt = id == rememberedConversationID ? lastViewedAt : nil
        let last = id.flatMap(landingSnapshot(conversationID:))
        switch ChatLandingPolicy.decide(last: last, lastViewedAt: viewedAt, now: now) {
        case .resume(let id): select(conversationID: id)
        case .landing: showLanding()
        }
    }

    /// The landing: ⌘N, New Chat, and a tab entry outside the resume
    /// window. The session of the conversation left behind stays warm
    /// (the pool's idle TTL). A still-untouched conversation outside any
    /// project stays the landing's own, so no second empty row is made.
    func showLanding() {
        openProjectID = nil
        isOnLanding = true
        if let conv = currentConversation, conv.activeLeafMessageID == nil, conv.projectID == nil, !isStreaming {
            return
        }
        clearShownConversation()
    }

    /// The composer's first keystroke: prewarm the session. On the landing
    /// that first needs a conversation, made without leaving the landing.
    func draftStarted() {
        if conversationID == nil {
            _ = conversationIDCreatingIfNeeded()
        } else {
            prewarm()
        }
    }

    private func landingSnapshot(conversationID id: Int64) -> ChatLandingPolicy.LastConversation? {
        do {
            guard let conv = try dbManager.dbPool.read({ try ChatConversationQueries.fetchByID($0, id: id) }) else {
                return nil // deleted
            }
            return ChatLandingPolicy.LastConversation(conv, isStreaming: pool.client(for: id)?.isBusy == true)
        } catch {
            // Unreadable: the landing is the safe place; the chat is still in the history.
            NSLog("ChatViewModel: reading the last chat failed: %@", error.localizedDescription)
            return nil
        }
    }

    private func clearShownConversation() {
        conversationID = nil
        currentConversation = nil
        thread = []
        editingMessageID = nil
        errorMessage = nil
        artifactPanel = nil
        sourcesPanel = nil
        dismissedArtifactKeys = []
        actionFeed.stop()
    }

    func reloadConversations() {
        onConversationsChanged?()
    }

    // MARK: - Projects

    func reloadProjects() {
        do {
            projects = try dbManager.dbPool.read { try ChatProjectQueries.fetchActive($0) }
        } catch {
            errorMessage = "Couldn't load projects: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func createProject(name: String) -> Int64? {
        do {
            let project = try dbManager.dbPool.write { try ChatProjectQueries.create($0, name: name) }
            reloadProjects()
            openProject(project.id)
            return project.id
        } catch {
            errorMessage = "Couldn't create the project: \(error.localizedDescription)"
            return nil
        }
    }

    /// Shows a project page; the chat's artifact panel closes with the chat.
    func openProject(_ id: Int64) {
        openProjectID = id
        isOnLanding = false
        artifactPanel = nil
        sourcesPanel = nil
    }

    /// Called by the project page after it deleted its project: its chats
    /// are detached (`ON DELETE SET NULL`), so the shown one reloads too.
    func projectDeleted(_ id: Int64) {
        if openProjectID == id { openProjectID = nil }
        reloadProjects()
        reload()
        reloadConversations()
    }

    /// Moves a chat into a project (or out, with nil). The next turn gets a
    /// session spawned for the new project (`ChatSessionConfig.projectID` is
    /// part of `isCompatible`), and the stored Claude session is dropped so
    /// that turn starts fresh with the new project prompt and replays.
    func moveConversation(_ conversationID: Int64, toProject projectID: Int64?) {
        do {
            try dbManager.dbPool.write {
                try ChatConversationQueries.setProject($0, id: conversationID, projectID: projectID)
            }
            if conversationID == self.conversationID { reload() }
            reloadConversations()
        } catch {
            errorMessage = "Couldn't move the chat: \(error.localizedDescription)"
        }
    }

    func reload() {
        guard let id = conversationID else {
            thread = []
            currentConversation = nil
            artifactVersionsByMessage = [:]
            return
        }
        do {
            let (conv, items, versions, gmail, slack) = try dbManager.dbPool.read { db in
                let conv = try ChatConversationQueries.fetchByID(db, id: id)
                let items = try ChatTreeQueries.thread(db, conversationID: id)
                let versions = try ChatArtifactQueries.versionsByMessage(db, messageIDs: items.map(\.id))
                let gmail = try GoogleAccountQueries.hasConnectedGmailAccount(db)
                let slack = try SlackLinkResolver.load(db)
                return (conv, items, versions, gmail, slack)
            }
            currentConversation = conv
            if items != thread { thread = items }
            let refreshedSources = sourcesPanel?.refreshed(in: items)
            if refreshedSources != sourcesPanel { sourcesPanel = refreshedSources }
            artifactVersionsByMessage = versions
            gmailConnected = gmail
            slackLinks = slack
        } catch {
            errorMessage = "Couldn't load the conversation: \(error.localizedDescription)"
        }
    }

    /// Opening a conversation or the first keystroke: spawn the session now.
    func prewarm() {
        guard let id = conversationID else { return }
        pool.prewarm(conversationID: id, config: sessionConfig(conversationID: id))
    }

    func switchProvider(_ provider: AIProvider) {
        guard provider != selectedProvider else { return }
        selectedProvider = provider
        selectedModel = ""
        recycleSession()
    }

    // MARK: - Artifacts

    /// Opens (or re-focuses) the panel for `key` in the current conversation.
    func openArtifact(key: String) {
        guard let conversationID else { return }
        preferredInspectorMode = .artifacts
        guard artifactPanel?.key != key else { return }
        artifactPanel = ArtifactPanelModel(db: dbManager.dbPool, conversationID: conversationID, key: key)
    }

    /// The owner closed the panel: remember the key so a still-streaming turn
    /// does not reopen it for the rest of this turn.
    func closeArtifactPanel() {
        if let key = artifactPanel?.key { dismissedArtifactKeys.insert(key) }
        artifactPanel = nil
    }

    // MARK: - Inspector

    /// The panel the inspector shows, or nil when it is closed.
    var inspectorMode: ChatInspectorMode? {
        ChatInspectorPolicy.visibleMode(preferred: preferredInspectorMode, artifactOpen: artifactPanel != nil,
                                        sourcesOpen: sourcesPanel != nil)
    }

    /// Shows one finished answer's sources; an open artifact stays open
    /// behind its tab.
    func openSources(messageID: Int64, sources: [ChatSource]) {
        guard !sources.isEmpty else { return }
        sourcesPanel = ChatSourcesSelection(messageID: messageID, sources: sources)
        preferredInspectorMode = .sources
    }

    func closeSourcesPanel() {
        sourcesPanel = nil
    }

    /// The whole inspector was dismissed: both panels close.
    func closeInspector() {
        closeArtifactPanel()
        closeSourcesPanel()
    }

    /// Fed by the thread view whenever `liveTurn?.text` changes (the view
    /// observes `LiveTurn` directly — there is no per-delta VM hook, deltas
    /// go straight from the pool into `LiveTurn`, preflight A38): opens the
    /// panel for a block that just started streaming and forwards the latest
    /// draft to it.
    func updateLiveArtifacts(streamingText: String) {
        guard conversationID != nil else { return }
        let drafts = ArtifactParser.parse(streamingText, final: false).artifacts
        if let key = ArtifactPanelModel.keyToAutoOpen(drafts: drafts, currentKey: artifactPanel?.key,
                                                      dismissedKeys: dismissedArtifactKeys) {
            openArtifact(key: key)
        }
        artifactPanel?.applyStreaming(drafts)
    }

    // MARK: - Turns

    /// Sends the composer text + any pending attachments; clears both only
    /// when the turn really started (a failed send keeps them for retry).
    func sendDraft() {
        let attachments = composerAttachments.pending
        if send(text: draft, attachments: attachments, mentions: composer.mentions, skill: composer.skill) {
            draft = ""
            _ = composerAttachments.takeForSend()
        }
    }

    func attachFiles(_ urls: [URL]) {
        guard let id = conversationIDCreatingIfNeeded() else { return }
        composerAttachments.add(urls: urls, conversationID: id)
    }

    func attachPastedImage(_ png: Data) {
        guard let id = conversationIDCreatingIfNeeded() else { return }
        composerAttachments.addPastedImage(png, conversationID: id)
    }

    /// `mentions` are the composer's picked candidates (Task 25); only those
    /// still present as `@Label` in `text` are kept (`liveMentions`) and
    /// composed into the stored/sent owner text along with `skill`
    /// (`ChatTurnComposer`, spec §4.3, preflight A31). Clears the composer's
    /// pending mentions/skill once the turn actually starts.
    @discardableResult
    func send(
        text: String, attachments: [ChatAttachment] = [], mentions: [MentionCandidate] = [], skill: String? = nil
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let live = MentionTokenizer.liveMentions(text: text, mentions: mentions)
        let turnText = ChatTurnComposer.compose(text: text, skill: skill, mentions: live)
        // A message may carry only attachments (no text) — the ChatInput canSend twin.
        guard !turnText.isEmpty || !attachments.isEmpty, !isStreaming else { return false }
        guard let id = conversationIDCreatingIfNeeded() else { return false }
        composer.reset()
        // The floor is the PREVIOUS owner message, and it alone: codex never
        // emits a session id, so gating on the session would exclude it.
        let outcomes = actionFeed.outcomesBlock(after: thread.last { $0.message.isUser }?.message.createdDate)
        let started = startTurn(TurnPlan(conversationID: id, historyTipID: thread.last?.message.id, userText: turnText,
                                         reuseUserMessageID: nil, attachments: attachments, outcomes: outcomes,
                                         forceReplay: false, titleText: trimmed))
        // The landing's first turn: the thread takes over.
        if started { isOnLanding = false }
        return started
    }

    /// The conversation a turn/attachment writes into, creating one on first
    /// use (a paperclip click before any text still needs somewhere to land).
    /// Made from the landing, it keeps the landing up until the first turn.
    private func conversationIDCreatingIfNeeded() -> Int64? {
        if let conversationID { return conversationID }
        let landing = isOnLanding
        let id = newConversation()
        if id != nil { isOnLanding = landing }
        return id
    }

    func stop() {
        pool.client(for: conversationID)?.cancel()
    }

    func retry(messageID: Int64) {
        regenerate(messageID: messageID)
    }

    /// "Stopped" + Continue: asks the model to carry on from its partial reply.
    func continueStopped(messageID: Int64) {
        guard let last = thread.last?.message, last.id == messageID, last.isAssistant, last.status == "partial" else { return }
        send(text: "Continue")
    }

    /// A new assistant sibling under the same owner message (spec §2.3). The
    /// provider session's transcript holds the old answer, so it replays.
    /// Replay is text-only, so the owner message's files are sent again with
    /// it — a retried/regenerated turn about an image or PDF still sees it.
    func regenerate(messageID: Int64) {
        guard !isStreaming, let id = conversationID,
              let index = thread.firstIndex(where: { $0.message.id == messageID }), index > 0,
              thread[index].message.isAssistant, thread[index - 1].message.isUser else { return }
        let owner = thread[index - 1]
        startTurn(TurnPlan(conversationID: id, historyTipID: owner.message.parentID, userText: owner.message.text,
                           reuseUserMessageID: owner.message.id, attachments: owner.attachments, outcomes: nil,
                           forceReplay: true))
    }

    /// A new owner sibling under the original's parent, then a fresh reply.
    /// The edited body keeps the original message's skill line and REFERENCED
    /// tokens (`ChatTurnComposer.recompose`, Review Focus 3), and its files are
    /// sent again (the edit changes only the text). The attachment rows stay
    /// linked to the original message — the edited sibling does not show them
    /// (v1 limit).
    func edit(messageID: Int64, newText: String) {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming, let id = conversationID,
              let item = thread.first(where: { $0.message.id == messageID }), item.message.isUser else { return }
        editingMessageID = nil
        let turnText = ChatTurnComposer.recompose(stored: item.message.text, newBody: trimmed)
        startTurn(TurnPlan(conversationID: id, historyTipID: item.message.parentID, userText: turnText,
                           reuseUserMessageID: nil, attachments: item.attachments, outcomes: nil, forceReplay: true))
    }

    /// ↑ in an empty composer (spec §3.5).
    func beginEditingLast() {
        editingMessageID = thread.last { $0.message.isUser }?.message.id
    }

    func selectVariant(messageID: Int64) {
        guard let id = conversationID else { return }
        do {
            try dbManager.dbPool.write { db in try ChatTreeQueries.selectSibling(db, conversationID: id, siblingID: messageID) }
            reload()
        } catch {
            errorMessage = "Couldn't switch the variant: \(error.localizedDescription)"
        }
    }

    /// ⌘K hit: open the conversation, make the hit's branch active, scroll to it.
    func open(_ hit: ChatSearchHit) {
        select(conversationID: hit.conversationID)
        guard let messageID = hit.messageID else { return }
        selectVariant(messageID: messageID)
        scrollTarget = messageID
    }

    /// Called by the thread view once it has jumped to `scrollTarget`, so
    /// reopening the same hit changes the target again and jumps again.
    func consumeScrollTarget() {
        scrollTarget = nil
    }

    /// The sibling `offset` steps from `messageID` (‹ = -1, › = +1), nil at an
    /// end. A read failure also answers nil: the arrow simply does nothing.
    func variant(of messageID: Int64, offset: Int) -> Int64? {
        guard let siblings = try? dbManager.dbPool.read({ db in try ChatTreeQueries.siblings(db, messageID: messageID) }),
              let index = siblings.firstIndex(where: { $0.id == messageID }) else { return nil }
        let target = index + offset
        return siblings.indices.contains(target) ? siblings[target].id : nil
    }

    // MARK: - Private

    private struct TurnPlan {
        let conversationID: Int64
        /// The parent of the owner message this turn answers.
        let historyTipID: Int64?
        let userText: String
        /// Regenerate reuses the existing owner message.
        let reuseUserMessageID: Int64?
        /// The files sent with the turn: the composer's for a new message, the
        /// original owner message's for regenerate/edit. Carries `.id` so
        /// `persistTurnStart` can link freshly imported rows to the message it
        /// writes (CHAT-01); rows already linked elsewhere stay where they are.
        let attachments: [ChatAttachment]
        /// The actions-outcome block, prefixed at send time only (never stored).
        let outcomes: String?
        /// Regenerate/edit branch away from what the provider session saw.
        let forceReplay: Bool
        /// The prefix-title source: the owner's own words, without the
        /// skill/REFERENCED lines the stored text carries. nil = `userText`.
        var titleText: String?
    }

    private struct PersistedTurn {
        let assistant: ChatMessageRecord
        /// The parent of the owner message actually written: `historyTipID`,
        /// or the empty reply added under a legacy unanswered question.
        let historyTipID: Int64?
        /// The thread tip a `--resume`d session last saw.
        let seenTipID: Int64?
    }

    @discardableResult
    private func startTurn(_ plan: TurnPlan) -> Bool {
        let config = sessionConfig(conversationID: plan.conversationID)
        let turnID = makeTurnID()
        // An unreadable check only costs a replay, which is always correct.
        let resumeIsContinuous = (try? storedSessionSawTip(plan.conversationID)) ?? false
        let persisted: PersistedTurn
        do {
            // CHAT-01: the owner's text is on disk before anything is sent.
            persisted = try persistTurnStart(plan, turnID: turnID, config: config)
        } catch {
            errorMessage = "Your message wasn't sent because it couldn't be saved: \(error.localizedDescription)"
            return false
        }
        errorMessage = nil
        dismissedArtifactKeys = []
        reload()
        let client = pool.session(for: plan.conversationID, config: config)
        client.adoptInitialContinuity(resumeIsContinuous
            ? ChatContinuity.initialLeaf(resumeSessionID: config.resumeSessionID, activeLeafID: persisted.seenTipID)
            : nil)
        let replay = plan.forceReplay
            || ChatContinuity.replayNeeded(historyTipID: persisted.historyTipID, continuousLeafID: client.continuousLeafID)
        let command = ChatTurnCommand(
            turnID: turnID,
            text: ChatTurnText.compose(userText: plan.userText, outcomes: plan.outcomes),
            attachments: plan.attachments.map { ChatCommandAttachment(path: $0.path, mime: $0.mime, name: $0.name) },
            replay: replay)
        client.startTurn(ChatTurnRequest(command: command, assistantMessageID: persisted.assistant.id))
        reloadConversations()
        return true
    }

    private func persistTurnStart(_ plan: TurnPlan, turnID: String, config: ChatSessionConfig) throws -> PersistedTurn {
        let seenTip = thread.last?.message.id
        return try dbManager.dbPool.write { db in
            var historyTip = plan.historyTipID
            var answeredTip: Int64?
            let userID: Int64
            if let reuse = plan.reuseUserMessageID {
                userID = reuse
            } else {
                if let tip = historyTip, let placeholder = try Self.answerIfOwnerMessage(db, messageID: tip, config: config) {
                    historyTip = placeholder
                    answeredTip = placeholder
                }
                userID = try ChatTreeQueries.insertUser(db, conversationID: plan.conversationID, parentID: historyTip,
                                                        text: plan.userText, turnID: turnID).id
                // CHAT-01: attachments are linked in the SAME transaction that
                // persists the owner's message — never a separate write.
                try ChatAttachmentQueries.link(db, attachmentIDs: plan.attachments.map(\.id), messageID: userID)
                try ChatConversationQueries.setPrefixTitle(db, id: plan.conversationID, text: plan.titleText ?? plan.userText)
            }
            try ChatConversationQueries.setProviderModel(db, id: plan.conversationID, provider: config.provider, model: config.model)
            let assistant = try ChatTreeQueries.insertAssistant(db, conversationID: plan.conversationID, parentID: userID,
                                                                turnID: turnID, provider: config.provider,
                                                                model: config.model ?? "")
            return PersistedTurn(assistant: assistant, historyTipID: historyTip, seenTipID: answeredTip ?? seenTip)
        }
    }

    /// A legacy owner question that never got a reply (the pre-session chat
    /// persisted a reply only when one streamed) gets an empty `partial`
    /// reply, so the new owner message never sits right under it. Returns
    /// the new row's id, or nil when `messageID` is not an owner message.
    private static func answerIfOwnerMessage(_ db: Database, messageID: Int64, config: ChatSessionConfig) throws -> Int64? {
        guard let tip = try ChatMessageRecord.fetchOne(db, sql: "SELECT * FROM chat_messages WHERE id = ?",
                                                       arguments: [messageID]),
              tip.isUser else { return nil }
        return try ChatTreeQueries.insertAssistant(db, conversationID: tip.conversationID, parentID: tip.id,
                                                   turnID: tip.turnID, provider: config.provider, model: "").id
    }

    /// Whether a stored claude session (`--resume`) has seen the current
    /// thread tip: only when that tip is the conversation's newest message
    /// and no other provider wrote it — the session holds exactly the branch
    /// of the last turn it ran, so after a variant switch or a codex turn it
    /// must replay instead. The tip must also be a reply that provably
    /// reached the provider: an `error` row, an empty `partial` (a turn
    /// stopped or cut before any text) or an unanswered owner message may
    /// never have been sent, and resuming past it would lose the question.
    private func storedSessionSawTip(_ conversationID: Int64) throws -> Bool {
        guard let tip = thread.last?.message, tip.isAssistant,
              tip.status == "complete" || (tip.status == "partial" && !tip.text.isEmpty) else { return false }
        let newest = try dbManager.dbPool.read { db in try ChatTreeQueries.newestMessage(db, conversationID: conversationID) }
        guard let newest, newest.id == tip.id else { return false }
        return newest.provider == nil || newest.provider == AIProvider.claude.rawValue
    }

    private func sessionConfig(conversationID id: Int64) -> ChatSessionConfig {
        // Only claude sessions resume; codex/ollama replay every turn (spec §1.1).
        let resume = selectedProvider == .claude ? currentConversation?.sessionID : nil
        return ChatSessionConfig(conversationID: id, provider: selectedProvider.rawValue,
                                 model: selectedModel.isEmpty ? nil : selectedModel, resumeSessionID: resume,
                                 projectID: currentConversation?.projectID)
    }

    /// A conversation remembers the provider/model it last ran with; a new
    /// one keeps the current picker selection.
    private func applyConversationSettings() {
        guard let conv = currentConversation, let raw = conv.provider else { return }
        applyingConversationSettings = true
        defer { applyingConversationSettings = false }
        if let provider = AIProvider(rawValue: raw) { selectedProvider = provider }
        selectedModel = conv.model ?? ""
    }

    /// The live process was spawned for the old provider/model: close it; the
    /// next turn spawns a matching one (Claude keeps `--resume`, the others
    /// replay). Never mid-turn — the picker is disabled while streaming.
    private func recycleSession() {
        guard !applyingConversationSettings, !isStreaming, let id = conversationID else { return }
        pool.close(conversationID: id)
    }

    private func turnFinished(conversationID id: Int64) {
        if id == conversationID {
            reload()
            // Proposals were written by the MCP subprocess, which the feed's
            // ValueObservation cannot see — the turn boundary surfaces them.
            actionFeed.refresh()
            // The terminal write (ChatTurnStore.finalizeTurn) already
            // versioned this turn's artifacts in the same transaction as the
            // message; drop the live draft and show what was actually stored.
            artifactPanel?.turnFinished()
        }
        reloadConversations()
        requestTitleIfNeeded(conversationID: id)
    }

    /// Fire-and-forget `watchtower chat title` after the first completed
    /// exchange (spec §4.4). Go writes the title; the list reloads after.
    private func requestTitleIfNeeded(conversationID id: Int64) {
        guard let cliRunner, !titleRequests.contains(id) else { return }
        let needed: Bool
        do {
            needed = try dbManager.dbPool.read { db in try ChatConversationQueries.needsAITitle(db, id: id) }
        } catch {
            return // an unreadable count only skips the optional AI title; the prefix title stands
        }
        guard needed else { return }
        // At most once per conversation per app run: a failed call is not
        // retried on later turns (the prefix title stands).
        titleRequests.insert(id)
        Task { [weak self] in
            // ProcessCLIRunner logs a failure (CLILog); the prefix title stays, which is still correct.
            _ = try? await cliRunner.run(args: ["chat", "title", String(id)])
            guard let self else { return }
            self.reloadConversations()
            if self.conversationID == id { self.reload() }
        }
    }
}
