import ChatUI
import ChatWire
import Foundation
import GRDB
import Observation
import WatchtowerChatText
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

    /// The provider's name from the Go catalog (A7b).
    @MainActor var displayName: String { AIModelCatalog.shared.displayName(rawValue) }

    /// The providers the chat's menu offers: the catalog's, in its order
    /// (`AIProviderRegistryTests` pins this enum to the catalog's ids); only
    /// `current` before the first read, so no Swift list stands in for it.
    @MainActor static func offered(by catalog: AIModelCatalog, current: Self) -> [Self] {
        let listed = catalog.providerIDs.compactMap(Self.init(rawValue:))
        return listed.isEmpty ? [current] : listed
    }
}

/// The main AI Chat's window shell (unified chat spec §6.2): the chat itself runs in the daemon's engine and reaches
/// the app over chat.sock (`SocketChatClient`); its feed, list, composer and turn operations are ChatUI's models
/// (`ChatConversationModel`, `ChatComposerModel`, `ChatListModel`). What stays here is the window: which chat, the
/// landing or a project page is shown, the inspector (artifact panel, sources), the provider pill and the ⌘/ panel's
/// screen context. Nothing here writes a chat row (D3): every write is an engine operation.
@MainActor
@Observable
final class ChatViewModel {
    @ObservationIgnored let client: any ChatClient
    let list: ChatListModel
    /// The conversation on screen (nil id: the landing or a project page, whose first send creates one).
    private(set) var conversation: ChatConversationModel
    private(set) var composer: ChatComposerModel
    /// The open chat's agent actions (approvals stay on the Mac's `actions approve|reject`, D12).
    let actionFeed: AgentActionFeed
    @ObservationIgnored let artifactWriter: ChatArtifactWriter

    /// The landing (new-chat composer + recent chats) is shown instead of a conversation; a project page is the
    /// landing too, bound to its project.
    private(set) var isOnLanding = true
    private(set) var openProjectID: Int64?
    /// The project the landing's first send makes its chat in (the project page, or `+`/⌘N in the panel's project).
    private(set) var landingProjectID: Int64?
    /// A new value puts the keyboard in the composer.
    private(set) var composerFocusRequest: UUID?
    /// A project New Project… just made: its page opens with the name field focused.
    var projectNameFocusRequest: Int64?
    /// The shell's own error line (a failed project write, an attachment that could not be staged).
    var errorMessage: String? {
        didSet { if errorMessage != nil { isInspectorExpanded = false } }
    }

    // MARK: Routing

    /// The provider/model pill, its lines and fallback card (ChatUI's, shared with the phone): the landing's pick and
    /// an open chat's live with its composer. Its catalog is `ai models` and `ai routing-status`, re-read on a chat
    /// change, on app activation and at a turn's end (`refreshRoutingStatus`).
    let routing: ChatRoutingModel
    @ObservationIgnored private let preferredProviderSource: (() -> AIProvider)?
    @ObservationIgnored private var configuredPreferred: AIProvider
    private var preferredProvider: AIProvider { preferredProviderSource?() ?? configuredPreferred }
    @ObservationIgnored private var readingRoutingStatus = false

    // MARK: Inspector

    private(set) var artifactPanel: ArtifactPanelModel? {
        didSet { collapseInspectorIfClosed() }
    }
    private(set) var sourcesPanel: ChatSourcesSelection? {
        didSet { collapseInspectorIfClosed() }
    }
    var preferredInspectorMode: ChatInspectorMode = .artifacts
    private(set) var isInspectorExpanded = false
    private(set) var gmailConnected = false
    private(set) var slackLinks: SlackLinkResolver?
    /// Keys the owner closed the panel for during the current turn: a streaming turn does not reopen them.
    @ObservationIgnored private var dismissedArtifactKeys: Set<String> = []

    /// The whole text of a reply the feed cut at its 40 000-character cap (`textCut`): the Mac shows whole answers,
    /// as before the engine. Read from the database once the reply is final.
    private(set) var fullTexts: [Int64: String] = [:]
    /// The last read of cut replies' whole texts (tests await it).
    @ObservationIgnored private(set) var fullTextLoad: Task<Void, Never>?
    /// Drafts of the chats left with text in the composer.
    @ObservationIgnored private var drafts: [Int64: String] = [:]
    @ObservationIgnored private var landingDraftText = ""
    /// The chat the landing made on its first keystroke (so its session warms up) and has not sent in yet: it is
    /// discarded (deleted only while untouched) when the landing leaves it. Kept per workspace, so one abandoned by
    /// quitting goes at the next launch.
    private(set) var landingDraftID: Int64? {
        didSet {
            if let landingDraftID {
                defaults.set(Int(landingDraftID), forKey: landingDraftKey)
            } else {
                defaults.removeObject(forKey: landingDraftKey)
            }
        }
    }
    @ObservationIgnored private var makingLandingDraft = false
    @ObservationIgnored private var engineCalls: [Task<Void, Never>] = []
    @ObservationIgnored private var turnIDLoad: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults
    private var landingDraftKey: String { "chat.landingDraft.engine.\(dbPool.path)" }
    /// Draft chats left behind whose discard the engine has not answered yet (kept per workspace, so neither a
    /// quit nor a crash leaves an empty chat): sent again on every `.connected` and at the next start.
    private(set) var draftsToDiscard: Set<Int64> {
        get { Set((defaults.array(forKey: draftsToDiscardKey) as? [Int] ?? []).map(Int64.init)) }
        set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: draftsToDiscardKey)
            } else {
                defaults.set(newValue.sorted().map(Int.init), forKey: draftsToDiscardKey)
            }
        }
    }
    private var draftsToDiscardKey: String { "chat.landingDraftsToDiscard.engine.\(dbPool.path)" }
    /// The latest discard pass; the next one starts after it, so passes never overlap and none is skipped.
    @ObservationIgnored private var discardFlush: Task<Void, Never>?
    @ObservationIgnored private var reachabilityWatch: Task<Void, Never>?

    /// The reply whose actions "Review actions" shows, and those actions' ids.
    private(set) var reviewedMessageID: Int64?
    private(set) var reviewedActionIDs: [Int64] = []
    /// The turn ids of the chat's stored messages: a proposal whose turn has none is from an interrupted turn.
    private(set) var messageTurnIDs: Set<String> = []

    @ObservationIgnored private let dbPool: DatabasePool
    @ObservationIgnored private let cliRunner: CLIRunnerProtocol?
    @ObservationIgnored private let uiClock: any ChatUIClock
    /// Retry / Start on the state line: the app's start chain.
    @ObservationIgnored var onStartDaemon: (() -> Void)? {
        didSet { conversation.onStartDaemon = onStartDaemon }
    }

    init(
        client: any ChatClient,
        dbPool: DatabasePool,
        provider: AIProvider = .claude,
        cliRunner: CLIRunnerProtocol? = nil,
        preferredProviderSource: (() -> AIProvider)? = nil,
        clock: any ChatUIClock = ContinuousChatUIClock(),
        defaults: UserDefaults = .standard
    ) {
        self.client = client
        self.defaults = defaults
        self.dbPool = dbPool
        self.cliRunner = cliRunner
        self.uiClock = clock
        self.configuredPreferred = provider
        self.preferredProviderSource = preferredProviderSource
        list = ChatListModel(client: client, clock: clock)
        let conversation = ChatConversationModel(client: client, conversationID: nil, clock: clock)
        self.conversation = conversation
        let composer = ChatComposerModel(conversation: conversation)
        self.composer = composer
        let owner = ChatViewModelRef()
        routing = ChatRoutingModel(client: client, composer: { owner.vm?.composer ?? composer },
                                   onRefresh: { await owner.vm?.refreshRoutingStatus() })
        actionFeed = AgentActionFeed(dbPool: dbPool, cliRunner: cliRunner)
        artifactWriter = ChatArtifactWriter(client: client)
        owner.vm = self
        routing.configuredPreferred = preferredProvider.rawValue
        routing.catalog = routingCatalog(status: nil, statusError: nil)
        wire(conversation)
    }

    // MARK: - Derived state

    var conversationID: Int64? { conversation.conversationID }

    /// The list's row of the chat on screen.
    var currentConversation: ChatList.Conversation? {
        guard let id = conversationID else { return nil }
        return list.store.list?.conversations.first { $0.id == id }
    }

    /// The chat on screen's title: the feed's, else the list's.
    var title: String? {
        let feedTitle = conversation.feed?.conversation.title ?? ""
        return feedTitle.isEmpty ? currentConversation?.title : feedTitle
    }

    var projects: [ChatList.Project] { list.store.list?.projects ?? [] }

    /// A turn runs in the chat on screen (whoever started it), or a send is on its way.
    var isBusy: Bool { conversation.isTurnRunning || composer.isSending }

    /// The feed's messages, a cut reply's whole text put back.
    var messages: [ChatFeed.Message] {
        conversation.messages.map { message in
            guard message.textCut, let full = fullTexts[message.id] else { return message }
            return Self.replacingText(of: message, with: full)
        }
    }

    /// A turn of `id` runs now (the panel's answering state, the Inbox strip's "the session holds it").
    func isAnswering(conversationID id: Int64) -> Bool {
        if id == conversationID, conversation.isTurnRunning { return true }
        return list.store.list?.conversations.first { $0.id == id }?.state == .answering
    }

    /// The running turn's id of `id`'s chat: the feed's for the chat on screen, else the engine's list row (every
    /// main chat with a turn running names it).
    func runningTurnID(conversationID id: Int64) -> String? {
        if id == conversationID, let turn = conversation.runningTurnID { return turn }
        return list.store.list.flatMap { AppState.runningTurns(in: $0)[id] }
    }

    /// Whether the live session that proposed `action` still holds it: its chat runs that very turn.
    func holdsSessionCall(_ action: AgentAction) -> Bool {
        ConnectorCallProposal.sessionHolds(action, runningTurnID: runningTurnID(conversationID: action.conversationID))
    }

    /// The conversation is the one on screen: shown, not the landing or a project page.
    func isShowing(conversationID id: Int64) -> Bool {
        !isOnLanding && openProjectID == nil && conversationID == id
    }

    /// Text, quotes or attachments typed but not sent.
    var hasUnsentInput: Bool {
        !composer.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !composer.attachments.isEmpty
            || !composer.quotes.isEmpty
    }

    // MARK: - Lifecycle

    /// Starts the list and the open chat's subscriptions (the window opened).
    func start() {
        list.start()
        conversation.start()
        // A landing draft abandoned by quitting: gone, unless a message or a file was added since.
        // A landing draft left by a quit or a crash: discarded first (the engine deletes it only while it has no
        // message and no attachment); its id is dropped only once the engine answered.
        if let stale = defaults.object(forKey: landingDraftKey) as? Int {
            defaults.removeObject(forKey: landingDraftKey)
            draftsToDiscard.insert(Int64(stale))
        }
        let reachability = client.reachability
        reachabilityWatch?.cancel()
        reachabilityWatch = Task { [weak self] in
            for await state in reachability where state == .connected {
                guard let self else { return }
                await self.flushDiscards()
            }
        }
        // Only a leftover from an earlier run: a discard queued later starts its own pass.
        if !draftsToDiscard.isEmpty {
            engineCalls.append(Task { [weak self] in await self?.flushDiscards() })
        }
    }

    /// The first keystroke (or an open chat): the landing makes its chat now and the engine starts its session, so
    /// the first answer does not wait for a spawn; an open chat's session is warmed too. Never evicts anything.
    func draftStarted() async {
        if let id = conversationID {
            if !isOnLanding || id == landingDraftID { warm(id) }
            return
        }
        guard isOnLanding, !makingLandingDraft else { return }
        makingLandingDraft = true
        defer { makingLandingDraft = false }
        composer.projectID = landingProjectID
        composer.routing = routing.request
        guard let id = await composer.prepareConversation() else { return }
        landingDraftID = id
        warm(id)
    }

    private func warm(_ id: Int64) {
        let request = conversationID == nil || id == landingDraftID ? routing.request : nil
        fireAndForget(.warm(conversationID: id, routing: request))
    }

    /// The landing's draft chat, left without a send: discarded by the engine while it is untouched.
    private func discardLandingDraft(except keep: Int64? = nil) {
        guard let draft = landingDraftID, draft != keep else { return }
        draftsToDiscard.insert(draft)
        landingDraftID = nil
        engineCalls.append(Task { [weak self] in await self?.flushDiscards() })
    }

    /// Sends every pending discard; an id leaves the list once the engine answered it (applied, or the chat is
    /// gone already). A lost connection keeps it for the next `.connected`. A pass already under way is awaited
    /// first, then this one runs over what is still pending: returning means every earlier pass has finished.
    func flushDiscards() async {
        let previous = discardFlush
        let pass = Task { [weak self] in
            await previous?.value
            await self?.sendDiscards()
        }
        discardFlush = pass
        await pass.value
    }

    private func sendDiscards() async {
        for id in draftsToDiscard.sorted() {
            switch try? await client.send(.manage(conversationID: id, op: .discard, title: nil, projectID: nil)) {
            case .applied?, .refused("not_found", _)?:
                draftsToDiscard.remove(id)
            case .refused?, nil:
                continue
            }
        }
    }

    /// An engine operation nobody waits for (a warm-up, a draft's discard); a failure changes nothing on screen.
    private func fireAndForget(_ op: ChatOperation) {
        let client = client
        engineCalls.append(Task { _ = try? await client.send(op) })
    }

    /// Returns once every fire-and-forget operation so far was answered (tests).
    func engineCallsSettled() async {
        let calls = engineCalls
        engineCalls = []
        for call in calls { await call.value }
        await turnIDLoad?.value
        if !engineCalls.isEmpty { await engineCallsSettled() }
    }

    // MARK: - Conversations

    /// Shows `id`; the composer's draft of the chat left behind is kept for it.
    func select(conversationID id: Int64) {
        discardLandingDraft(except: id)
        openProjectID = nil
        isOnLanding = false
        landingProjectID = nil
        guard id != conversationID else { return }
        show(id)
        warm(id)
    }

    /// A new chat now (the Inbox's Discuss): created by the engine, then shown.
    @discardableResult
    func newConversation(projectID: Int64? = nil) async -> Int64? {
        do {
            switch try await client.send(.new(projectID: projectID, routing: routing.request)) {
            case .applied(.conversation(let id)):
                select(conversationID: id)
                return id
            case let .refused(_, message):
                errorMessage = "Couldn't start a new chat: \(message)"
            case .applied:
                errorMessage = "Couldn't start a new chat."
            }
        } catch {
            errorMessage = "Couldn't start a new chat: \(error.localizedDescription)"
        }
        return nil
    }

    /// The landing: ⌘N, New Chat, and a tab entry outside the resume window. `projectID` is where its first send
    /// makes the chat.
    func showLanding(inProject projectID: Int64? = nil) {
        if let draft = landingDraftID, conversationID == draft, composer.projectID == projectID {
            // The landing's own draft in this project stays its draft.
            openProjectID = nil
            isOnLanding = true
            return
        }
        discardLandingDraft()
        openProjectID = nil
        isOnLanding = true
        landingProjectID = projectID
        guard conversationID != nil else {
            composer.projectID = projectID
            return
        }
        show(nil)
    }

    /// A project page; its composer is the landing's, in this project.
    func openProject(_ id: Int64) {
        let keepsDraft = conversationID != nil && conversationID == landingDraftID && composer.projectID == id
        if !keepsDraft {
            discardLandingDraft()
            if conversationID != nil { show(nil) }
        }
        openProjectID = id
        isOnLanding = true
        landingProjectID = id
        composer.projectID = id
        artifactPanel = nil
        sourcesPanel = nil
    }

    /// The Chats panel's level changed: a landing or project page in another project gives way to the plain landing.
    func panelLevelChanged(to projectID: Int64?) {
        guard let landing = landingProjectID, landing != projectID else { return }
        if isOnLanding {
            showLanding(inProject: nil)
        } else {
            landingProjectID = nil
        }
    }

    /// Entering the Chat tab (owner decision 2026-09-28): reopen the last conversation when `ChatLandingPolicy` says
    /// so, otherwise the landing. An open project page, and a landing with unsent input, stay.
    func enterTab(rememberedConversationID: Int64?, lastViewedAt: Date?, now: Date) {
        guard openProjectID == nil else { return }
        let unsent = hasUnsentInput
        if isOnLanding, unsent { return }
        let id = conversationID ?? rememberedConversationID
        let viewedAt = id == rememberedConversationID ? lastViewedAt : nil
        let last = id.flatMap { id in
            list.store.list?.conversations.first { $0.id == id }.map {
                ChatLandingPolicy.LastConversation($0, isStreaming: isAnswering(conversationID: id))
            }
        }
        switch ChatLandingPolicy.decide(last: last, lastViewedAt: viewedAt, hasUnsentInput: unsent, now: now) {
        case .resume(let id): select(conversationID: id)
        case .landing: showLanding(inProject: landingProjectID)
        }
    }

    /// The ⌘/ popup opens over this chat: outside any project, then the tab's resume decision.
    func enterHelpPopup(rememberedConversationID: Int64?, lastViewedAt: Date?, now: Date) {
        if isOnLanding, landingProjectID != nil { showLanding(inProject: nil) }
        guard conversationID == nil else { return }
        enterTab(rememberedConversationID: rememberedConversationID, lastViewedAt: lastViewedAt, now: now)
    }

    /// A conversation was deleted or archived: stop showing it (the landing takes its place).
    func forget(conversationID id: Int64) {
        drafts[id] = nil
        guard id == conversationID else { return }
        isOnLanding = true
        show(nil)
    }

    /// Opens a search hit's chat and brings its message into view: the conversation's focus (ChatUI's
    /// `followFocus`, run by the thread view whenever the loaded messages change) pages back until it is loaded.
    func open(_ hit: ChatSearch.Hit) {
        select(conversationID: hit.conversationID)
        conversation.focusMessageID = hit.messageID
    }

    // MARK: - Turns

    /// Sends the composer (its model sends the picked mentions still in the text and the `/` skill); the ⌘/ panel's
    /// `screen` is prefixed to the provider text only and never stored.
    func sendDraft(screen: ScreenContext? = nil) async {
        let wasLanding = isOnLanding
        if conversationID == nil { composer.routing = routing.request }
        let before = conversation
        let sent = await composer.send(screenContext: screen?.block)
        guard sent else { return }
        if conversationID == landingDraftID { landingDraftID = nil }
        dismissedArtifactKeys = []
        if wasLanding, before === conversation, let id = conversationID {
            // The landing's first send made the chat: it is the one on screen now.
            isOnLanding = false
            openProjectID = nil
            landingProjectID = nil
            onConversationCreated?(id)
        }
    }

    /// The chat on screen was made by the landing's first send (the panel selects it).
    @ObservationIgnored var onConversationCreated: ((Int64) -> Void)?

    /// The composer's Stop.
    func stop() {
        Task { await conversation.cancelTurn() }
    }

    /// ↑ in an empty field: edits the last owner message.
    func beginEditingLast() {
        composer.beginEditingLast()
    }

    func requestComposerFocus() {
        composerFocusRequest = UUID()
    }

    /// "Ask about this" on a selected passage: it joins the next message's quotes.
    func addQuote(_ quote: String) {
        composer.addQuote(quote)
        requestComposerFocus()
    }

    /// Files from the open panel or a drop: the engine copies each one it takes.
    func attachFiles(_ urls: [URL]) {
        Task {
            for url in urls { await composer.attach(.path(url.path)) }
        }
    }

    /// A paste (or an Inbox card) as a file: written to a private temp file the engine copies (`attach` takes a
    /// path, spec §5.2), then removed. Whether the engine took it.
    func attachPasted(_ data: Data, name: String) async -> Bool {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wt-chat-paste-\(UUID().uuidString)")
        let file = dir.appendingPathComponent(name.isEmpty ? "pasted.txt" : name)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            errorMessage = "Couldn't attach the pasted text: \(error.localizedDescription)"
            return false
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = composer.attachments.count
        await composer.attach(.path(file.path))
        return composer.attachments.count > before
    }

    // MARK: - Projects

    @discardableResult
    func createProject(name: String) async -> Int64? {
        do {
            switch try await client.send(.project(ChatProjectRequest(op: .create, name: name))) {
            case .applied(.id(let id)):
                projectNameFocusRequest = id
                openProject(id)
                return id
            case let .refused(_, message):
                errorMessage = "Couldn't create the project: \(message)"
            case .applied:
                errorMessage = "Couldn't create the project."
            }
        } catch {
            errorMessage = "Couldn't create the project: \(error.localizedDescription)"
        }
        return nil
    }

    /// The project page deleted its project: a landing in it leaves it.
    func projectDeleted(_ id: Int64) {
        if landingProjectID == id { landingProjectID = nil }
        if composer.projectID == id { composer.projectID = nil }
        if openProjectID == id { showLanding() }
    }

    func moveConversation(_ conversationID: Int64, toProject projectID: Int64?) async {
        await list.move(conversationID, toProject: projectID)
        if let notice = list.notice { errorMessage = notice }
    }

    // MARK: - Routing

    /// Why the composer cannot attach a file to the provider the chat runs (or would run) on; nil before `ai models`
    /// is read.
    var attachUnavailableReason: String? { routing.capabilities?.attachUnavailableReason }
    var pdfUnavailableReason: String? { routing.capabilities?.pdfUnavailableReason }

    /// Reads the local provider availability (`ai routing-status`; never an upstream probe) and puts it, with the
    /// `ai models` catalog, under the routing pill.
    func refreshRoutingStatus() async {
        var status = routing.catalog?.status
        var statusError = routing.catalog?.statusError
        if let cliRunner, !readingRoutingStatus {
            readingRoutingStatus = true
            defer { readingRoutingStatus = false }
            do {
                let data = try await cliRunner.run(args: ["ai", "routing-status"], timeout: 5)
                let read = try ChatRoutingStatus.parse(data)
                if let provider = AIProvider(rawValue: read.preferredProvider) { configuredPreferred = provider }
                status = read
                statusError = nil
            } catch {
                status = nil
                statusError = "Couldn't read provider availability: \(error.localizedDescription)"
            }
        }
        routing.configuredPreferred = preferredProvider.rawValue
        routing.catalog = routingCatalog(status: status, statusError: statusError)
    }

    /// The Mac's routing catalog: the providers the chat's menu offers, from `ai models`.
    private func routingCatalog(status: ChatRoutingStatus?, statusError: String?) -> ChatRoutingCatalog {
        let models = AIModelCatalog.shared
        let current = AIProvider(rawValue: routing.provider) ?? preferredProvider
        return ChatRoutingCatalog(models: models, offered: AIProvider.offered(by: models, current: current).map(\.rawValue),
                                  status: status, statusError: statusError)
    }

    // MARK: - Artifacts

    /// Opens (or re-focuses) the panel for `key` in the chat on screen.
    func openArtifact(key: String) {
        guard let conversationID else { return }
        preferredInspectorMode = .artifacts
        guard artifactPanel?.key != key else { return }
        artifactPanel = ArtifactPanelModel(db: dbPool, writer: artifactWriter, conversationID: conversationID, key: key)
    }

    /// The owner closed the panel: a still-streaming turn does not reopen it.
    func closeArtifactPanel() {
        if let key = artifactPanel?.key { dismissedArtifactKeys.insert(key) }
        artifactPanel = nil
    }

    /// "Send N comments": the unsent comments go as the owner's message (CHAT-05); the engine composes them and
    /// marks exactly those sent with the owner row. A refused send leaves them unsent.
    func sendArtifactComments() async {
        guard let comments = artifactPanel?.comments, let outgoing = comments.outgoing() else { return }
        isInspectorExpanded = false
        guard !isBusy else {
            errorMessage = "Wait for the current answer to finish, then send the comments."
            return
        }
        if await composer.sendArtifactComments(outgoing.ids) { comments.reload() }
    }

    // MARK: - Inspector

    var inspectorMode: ChatInspectorMode? {
        ChatInspectorPolicy.visibleMode(preferred: preferredInspectorMode, artifactOpen: artifactPanel != nil,
                                        sourcesOpen: sourcesPanel != nil)
    }

    func openSources(messageID: Int64, sources: [ChatSource]) {
        guard !sources.isEmpty else { return }
        sourcesPanel = ChatSourcesSelection(messageID: messageID, sources: sources)
        preferredInspectorMode = .sources
    }

    func closeSourcesPanel() {
        sourcesPanel = nil
    }

    func closeInspector() {
        closeArtifactPanel()
        closeSourcesPanel()
    }

    func toggleInspectorExpanded() {
        isInspectorExpanded = inspectorMode != nil && !isInspectorExpanded
    }

    var showsInspectorColumn: Bool { inspectorMode != nil && !isInspectorExpanded }

    func inspectorColumnDismissed() {
        guard !isInspectorExpanded else { return }
        closeInspector()
    }

    private func collapseInspectorIfClosed() {
        if inspectorMode == nil { isInspectorExpanded = false }
    }

    /// The feed changed: a streaming reply's artifact opens the panel and feeds it its draft; a reply that ended
    /// shows the stored version; a cut reply's whole text is read; the sources panel follows the active branch.
    func feedChanged() {
        let messages = conversation.messages
        if let live = messages.last(where: { $0.role == "assistant" && $0.status == ChatMessageStatus.pending }) {
            let drafts = ArtifactParser.parse(live.text, final: false).artifacts
            if let key = ArtifactPanelModel.keyToAutoOpen(drafts: drafts, currentKey: artifactPanel?.key,
                                                          dismissedKeys: dismissedArtifactKeys) {
                openArtifact(key: key)
            }
            artifactPanel?.applyStreaming(drafts)
        } else if artifactPanel?.liveDraft != nil {
            artifactPanel?.turnFinished()
        } else {
            artifactPanel?.reload()
        }
        if let selection = sourcesPanel, !messages.contains(where: { $0.id == selection.messageID }) {
            sourcesPanel = nil
        }
        loadFullTexts(messages)
        loadMessageTurnIDs()
    }

    private func loadFullTexts(_ messages: [ChatFeed.Message]) {
        let cut = messages.filter { $0.textCut && $0.status != ChatMessageStatus.pending && fullTexts[$0.id] == nil }
        guard !cut.isEmpty else { return }
        let ids = cut.map(\.id)
        let pool = dbPool
        fullTextLoad = Task { [weak self] in
            let rows = try? await pool.read { db in
                try Row.fetchAll(db, sql: "SELECT id, text FROM chat_messages WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ",")))",
                                 arguments: StatementArguments(ids))
            }
            guard let self, let rows else { return }
            for row in rows { self.fullTexts[row["id"]] = row["text"] }
        }
    }

    /// Re-reads the Gmail and Slack facts the artifact actions need.
    func loadArtifactContext() async {
        let read = try? await dbPool.read { db in
            (try GoogleAccountQueries.hasConnectedGmailAccount(db), try SlackLinkResolver.load(db))
        }
        if let read {
            gmailConnected = read.0
            slackLinks = read.1
        }
    }

    // MARK: - Private

    /// Puts `id` (nil: the landing) on screen with its own models; the left chat's draft is kept for it.
    private func show(_ id: Int64?) {
        if let old = conversationID {
            drafts[old] = composer.draft
        } else {
            landingDraftText = composer.draft
        }
        let routing = composer.routing
        conversation.stop()
        let next = ChatConversationModel(client: client, conversationID: id, clock: uiClock)
        conversation = next
        composer = ChatComposerModel(conversation: next)
        composer.draft = id.map { drafts[$0] ?? "" } ?? landingDraftText
        composer.projectID = id == nil ? landingProjectID : nil
        composer.routing = id == nil ? routing : nil
        wire(next)
        next.start()
        artifactPanel = nil
        sourcesPanel = nil
        dismissedArtifactKeys = []
        errorMessage = nil
        fullTexts = [:]
        reviewedMessageID = nil
        reviewedActionIDs = []
        messageTurnIDs = []
        if let id { actionFeed.start(conversationID: id) }
    }

    // MARK: - Agent actions (the Mac's cards, D12)

    /// "Review actions" on a reply the quota stopped: its turn's actions show under it.
    func reviewActions(messageID: Int64) async {
        let turn = try? await dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT turn_id FROM chat_messages WHERE id = ?", arguments: [messageID])
        }
        guard let turn else { return }
        actionFeed.refresh()
        reviewedMessageID = messageID
        reviewedActionIDs = actionFeed.rows.filter { $0.turnID == turn }.map(\.id)
        isInspectorExpanded = false
        conversation.focusMessageID = messageID
    }

    /// The proposals of a turn that stored no message (an interrupted turn): no approval part shows them.
    var unattachedActions: [AgentAction] {
        AgentActionFeed.unattached(rows: actionFeed.rows, messageTurnIDs: messageTurnIDs)
    }

    /// A card a running turn waits on (its action is pending in the turn that runs): outlined.
    func isAwaited(_ action: AgentAction) -> Bool {
        (action.isPending && !action.turnID.isEmpty && action.turnID == conversation.runningTurnID)
            || reviewedActionIDs.contains(action.id)
    }

    private func loadMessageTurnIDs() {
        guard let id = conversationID else { return }
        let pool = dbPool
        turnIDLoad = Task { [weak self] in
            let turns = try? await pool.read { db in
                try String.fetchSet(db, sql: "SELECT DISTINCT turn_id FROM chat_messages WHERE conversation_id = ? AND turn_id != ''",
                                    arguments: [id])
            }
            guard let self, let turns, self.conversationID == id else { return }
            if turns != self.messageTurnIDs { self.messageTurnIDs = turns }
        }
    }

    private func wire(_ model: ChatConversationModel) {
        model.onStartDaemon = onStartDaemon
        model.onConversationCreated = { [weak self] id in
            guard let self else { return }
            self.actionFeed.start(conversationID: id)
            self.landingDraftText = ""
        }
    }

    static func replacingText(of message: ChatFeed.Message, with text: String) -> ChatFeed.Message {
        let parts = message.parts?.map { part -> ChatPart in
            guard part.kind == ChatPartKind.text else { return part }
            return ChatPart(kind: ChatPartKind.text,
                            payload: .object(["text": .string(text), "text_cut": .bool(false)]),
                            fallback: ChatPartFallback(text: text))
        }
        return ChatFeed.Message(
            id: message.id, role: message.role, text: text, textCut: false, status: message.status,
            errorCode: message.errorCode, errorMessage: message.errorMessage, createdAt: message.createdAt,
            siblings: message.siblings, attachments: message.attachments, steps: message.steps, parts: parts
        )
    }
}

/// The routing model's way back to the chat's current composer and refresh, without a strong cycle.
@MainActor
private final class ChatViewModelRef {
    weak var vm: ChatViewModel?
}
