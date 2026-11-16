import Foundation
import GRDB
import WatchtowerCore
import WatchtowerChatText
import WatchtowerInterface

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
    /// Quote batches ("Ask about this" on a selection in the feed), per
    /// conversation: quotes wait here (with the
    /// owner's comments) and go out together with the typed text as ONE owner
    /// turn in `sendDraft` — never one by one (owner rule).
    private(set) var quoteBatches: [Int64: [ChatQuoteDraft]] = [:]
    /// A new value puts the keyboard in the composer (a quote was just
    /// added: the owner types the follow-up next).
    private(set) var composerFocusRequest: UUID?
    /// Shown by the thread view only, so an error steps an expanded panel
    /// aside (#786).
    var errorMessage: String? {
        didSet { if errorMessage != nil { isInspectorExpanded = false } }
    }
    private(set) var selectedProvider: AIProvider
    private(set) var automaticRouting = true
    private var configuredPreferred: AIProvider
    @ObservationIgnored private let preferredProviderSource: (() -> AIProvider)?
    private var preferredProvider: AIProvider { preferredProviderSource?() ?? configuredPreferred }
    private(set) var isChangingRouting = false
    private(set) var reviewedActionIDs: [Int64] = []
    private(set) var reviewedMessageID: Int64?
    private(set) var routingStatus: ChatRoutingStatus?
    private(set) var routingStatusError: String?
    private var readingRoutingStatus = false
    @ObservationIgnored private var lastRoutingRevision: String?

    var routingPresentation: ChatRoutingPresentation? {
        let provider = automaticRouting ? preferredProvider : selectedProvider
        let catalog = AIModelCatalog.shared
        // The routing card belongs to a provider with a reserve peer (its
        // capability row, U3); before the catalog is read no pair is known,
        // so the line shows without the card.
        let pair = catalog.fallbackPair(preferred: provider.rawValue)
        let driver = pool.client(for: conversationID)?.driver
        let actualProvider = driver?.actualProvider ?? currentConversation?.actualProvider
        return ChatRoutingPresentation(pair: pair, automatic: automaticRouting,
                                       actualProvider: actualProvider,
                                       actualModel: driver?.actualModel ?? currentConversation?.actualModel,
                                       reason: driver?.routing?.reason ?? currentConversation?.routingReason,
                                       health: routingStatus, busy: isBusy,
                                       actualDisplayName: actualProvider.flatMap { catalog.provider($0)?.displayName },
                                       capabilities: providerCapabilities)
    }

    /// The capability row of the provider this chat runs on: the session's
    /// own (its session_ready), else the catalog's for the provider the next
    /// turn runs on: a pinned chat's choice; an automatic chat's preferred
    /// provider, or its last actual provider when that is the preferred
    /// one's reserve and fallback is not known off (Go keeps a chat on the
    /// reserve until the owner switches or turns fallback off); nil while
    /// neither is known.
    var providerCapabilities: ProviderCapabilities? {
        let driver = pool.client(for: conversationID)?.driver
        if let capabilities = driver?.actualCapabilities { return capabilities }
        let catalog = AIModelCatalog.shared
        guard catalog.isLoaded else { return nil }
        let provider = automaticRouting ? preferredProvider : selectedProvider
        let history = currentConversation?.actualProvider.flatMap { actual in
            automaticRouting && routingStatus?.enabled != false
                && actual == catalog.reservePeer(of: provider.rawValue) ? actual : nil
        }
        let id = driver?.actualProvider ?? history ?? provider.rawValue
        return catalog.capabilities(for: id)
    }

    /// Why the composer takes no images or PDFs here (U1); nil when it does
    /// or the provider's row is not known yet.
    var attachUnavailableReason: String? { providerCapabilities?.attachUnavailableReason }
    /// Why the composer refuses a PDF from a provider that takes images only.
    var pdfUnavailableReason: String? { providerCapabilities?.pdfUnavailableReason }

    /// Refresh only local metadata on chat/lifecycle/turn events; never an upstream probe.
    func refreshRoutingStatus() async {
        guard !readingRoutingStatus, let cliRunner else { return }
        readingRoutingStatus = true
        defer { readingRoutingStatus = false }
        do {
            let data = try await cliRunner.run(args: ["ai", "routing-status"], timeout: 5)
            let status = try ChatRoutingStatus.parse(data)
            if let previous = lastRoutingRevision, previous != status.revision { pool.retireRoutingSessions() }
            lastRoutingRevision = status.revision
            routingStatus = status
            if let provider = AIProvider(rawValue: routingStatus?.preferredProvider ?? "") {
                configuredPreferred = provider
            }
            routingStatusError = nil
        } catch {
            routingStatus = nil
            routingStatusError = "Couldn't read provider availability: \(error.localizedDescription)"
        }
    }
    /// Model override; "" = the provider's resolved strong model (the CLI resolves it).
    var selectedModel = "" {
        didSet {
            if selectedModel != oldValue, !applyingConversationSettings {
                automaticRouting = false
                recycleSession()
            }
        }
    }
    var scrollTarget: Int64?
    var editingMessageID: Int64?
    /// History list refresh (conversation order, titles written by Go).
    @ObservationIgnored var onConversationsChanged: (() -> Void)?
    /// The landing's first turn started in this conversation: the thread
    /// takes over and the view makes it the history selection. Fired only
    /// by `send`, never by other ways of leaving the landing.
    @ObservationIgnored var onLandingTurnStarted: ((Int64) -> Void)?
    /// Any conversation's turn ended, after this VM's own refresh. The Inbox
    /// strip re-reads then: a connector call it shows was claimed and run
    /// inside that turn, and its live "session holds it" just turned false.
    @ObservationIgnored var onTurnFinished: ((Int64) -> Void)?
    /// A turn started with a new owner message: what its prefix commands
    /// did (remember, a knowledge prefix — Go ran them in the start), with
    /// the owner's typed words, for the marks under the message.
    @ObservationIgnored var onOwnerMessageStarted: ((ChatStarted, String) -> Void)?
    /// A turn of that conversation waits on an approval card (`tool_wait`).
    @ObservationIgnored var onActionAwaited: ((Int64) -> Void)?

    let actionFeed: AgentActionFeed
    let pool: ChatSessionPool
    /// The composer's not-yet-sent attachments (Task 21). nil `store` (no
    /// active workspace) still renders — `add`/`addPasted` just report
    /// "Attachments need an active workspace".
    let composerAttachments: ComposerAttachments
    /// The composer's @-picker and the current draft's picked mentions
    /// (Task 25).
    let composer: ComposerPickerModel

    /// The artifact side panel for the current conversation; nil = closed.
    /// Survives navigation only within the same conversation — switching or
    /// forgetting a conversation closes it (CHAT-05 storage has no notion of
    /// "panel for a conversation not on screen").
    private(set) var artifactPanel: ArtifactPanelModel? {
        didSet { collapseInspectorIfClosed() }
    }
    /// The sources panel (one finished answer's sources); nil = closed. It
    /// shares the inspector with `artifactPanel` under `ChatInspectorPolicy`
    /// and closes with it on a conversation switch.
    private(set) var sourcesPanel: ChatSourcesSelection? {
        didSet { collapseInspectorIfClosed() }
    }
    /// The inspector tab opened last; see `inspectorMode` for what shows.
    var preferredInspectorMode: ChatInspectorMode = .artifacts
    /// The open panel takes the chat's whole width in place of the
    /// conversation (#786); it falls back to the column once both panels close.
    private(set) var isInspectorExpanded = false
    /// Non-edited version numbers per message, for the card badges — reloaded
    /// with the thread (`reload()`).
    private(set) var artifactVersionsByMessage: [Int64: [String: Int]] = [:]
    /// Artifact keys of the open chat pinned as knowledge (card badges).
    private(set) var keptArtifactKeys: Set<String> = []
    private(set) var gmailConnected = false
    private(set) var slackLinks: SlackLinkResolver?
    /// The project page open in the detail area, or nil when a conversation
    /// (or the landing) is shown.
    private(set) var openProjectID: Int64?
    /// The landing (new-chat composer + recent chats) is shown instead of a
    /// thread. It may already hold a fresh, message-less conversation — made
    /// on the first keystroke so its session prewarms — and stays up until
    /// that conversation's first turn starts or another one is opened.
    /// A project page is the landing too, bound to its project
    /// (`openProject`): its composer is this one, and the page is shown
    /// in the landing's place while `openProjectID` is set.
    private(set) var isOnLanding = true
    /// The conversation the landing made (or reused) for its draft. Left for
    /// anything but its own first turn, it is deleted while still untouched.
    /// Persisted per workspace database, so a draft abandoned by quitting is
    /// found — and only that one is deleted — at the next launch. Its
    /// `created_at` travels with the id: a database reset at the same path
    /// can reissue the id, never the pair.
    @ObservationIgnored private var landingDraft: LandingDraft? {
        didSet {
            if let landingDraft {
                defaults.set(landingDraft.stored, forKey: landingDraftKey)
            } else {
                defaults.removeObject(forKey: landingDraftKey)
            }
        }
    }
    var landingDraftID: Int64? { landingDraft?.id }
    /// The project the landing's composer makes its conversation in; nil =
    /// outside any project. Only two places set it (controller ruling on
    /// spec 2026-10-26 §4/§7): the project page's composer (`openProject`)
    /// and `+` / ⌘N while the visible panel shows that project
    /// (`showLanding(inProject:)`). It clears on opening any chat, on the
    /// landing's first turn, when the page closes, and when the panel
    /// leaves the project (`panelLevelChanged`, the fallback included).
    private(set) var landingProjectID: Int64?
    @ObservationIgnored private let defaults: UserDefaults
    private var landingDraftKey: String { "chat.landingDraft.\(dbManager.dbPool.path)" }
    private var storedLandingDraft: LandingDraft? {
        (defaults.string(forKey: landingDraftKey)).flatMap(LandingDraft.init(stored:))
    }
    /// Active (unarchived) projects for the sidebar.
    private(set) var projects: [ChatProject] = []
    /// A project New Project… just made (`createProject`): its page opens
    /// with the name field focused, and clears this (spec 2026-10-26 §7).
    var projectNameFocusRequest: Int64?
    /// Keys the owner closed the panel for during the CURRENT turn — a
    /// streaming turn does not reopen a panel the owner just dismissed.
    /// Cleared at the start of every new turn.
    @ObservationIgnored private var dismissedArtifactKeys: Set<String> = []

    /// A send is being handed to its session (its chat made first on the
    /// landing): milliseconds, never the wait for `started`.
    private var isHandingTurn = false
    /// Turns handed to their session and waiting for its `started` (the
    /// session writes their rows, or the turn is held for a free slot), by
    /// conversation, with the owner's message shown meanwhile (nil: none, a
    /// regenerate). Only the shown chat's entry blocks its composer; every
    /// other chat stays usable (ask #1361).
    private var awaitingStart: [Int64: AwaitingStart] = [:]
    private struct AwaitingStart {
        let bubble: String?
    }
    /// The shown chat's turn is being handed over or waits for `started`:
    /// its send is refused meanwhile, so one Enter never sends twice.
    var isStartingTurn: Bool {
        isHandingTurn || conversationID.map { awaitingStart[$0] != nil } == true
    }
    /// The owner's message shown at once while the shown chat's turn waits
    /// for `started` (mobile Inbox spec §8: the bubble never waits for the
    /// write); the stored row replaces it at `started`.
    var pendingOwnerText: String? {
        conversationID.flatMap { awaitingStart[$0]?.bubble }
    }
    /// A sent turn with no `started` by then gives up: the draft comes back
    /// and "session ended" shows (spec §9).
    nonisolated static let startedTimeout: Duration = ChatSessionClient.defaultStartedTimeout
    /// Sends waiting for the files dropped or pasted just before them
    /// (board #670), each with the chat it was pressed in.
    private var attachmentWaits: [UUID: (conversationID: Int64?, fromLanding: Bool)] = [:]
    /// The shown chat's send waits for its files: the composer says so, and
    /// a second Enter there does nothing. Another chat is not affected.
    var isWaitingForAttachments: Bool {
        attachmentWaits.values.contains { wait in
            wait.conversationID == conversationID || (wait.fromLanding && isOnLanding)
        }
    }
    /// A turn is running or about to: what the composer and the actions
    /// that start a turn wait for.
    /// A turn the hub runs for the phone holds the open chat (spec 2026-11-15
    /// §5) counts too: Send is off until its release.
    var isBusy: Bool { isStreaming || isStartingTurn || isFinishingTurn || isChangingRouting || foreignTurn.blocksSend }
    /// The open chat's turn run on the phone, read from its lease
    /// (`refreshForeignTurn`); its `line` stands over the composer.
    private(set) var foreignTurn = ChatForeignTurnModel()
    /// Every write of this view model, one after another (board #670).
    @ObservationIgnored private let writes = SerialWrites()
    /// `chat.recover` of a turn whose session died, per conversation: the
    /// next turn there waits for it, so its lease is free (spec §9).
    @ObservationIgnored private var recovering: [Int64: Task<Void, Never>] = [:]
    /// The composer's conversation being created: one at a time, so a
    /// keystroke, a paperclip and a send in quick succession make one row.
    @ObservationIgnored private var creatingConversation: Task<Int64?, Never>?
    /// Pastes being attached (on the landing, after its conversation).
    @ObservationIgnored private var pastesInFlight: [UUID: Task<Bool, Never>] = [:]
    /// A paste is still being attached.
    var isPasting: Bool { !pastesInFlight.isEmpty }

    @ObservationIgnored private let dbManager: DatabaseManager
    /// Every chat write: the `chat.*` tower commands (Go writes the rows).
    @ObservationIgnored let chatWrites: ChatWrites
    @ObservationIgnored private let cliRunner: CLIRunnerProtocol?
    @ObservationIgnored private let makeTurnID: () -> String
    @ObservationIgnored private let leaseClock: () -> Date
    @ObservationIgnored private var titleRequests: Set<Int64> = []
    /// The last `chat title` request started (a test seam).
    @ObservationIgnored private(set) var titleTask: Task<Void, Never>?
    @ObservationIgnored private var applyingConversationSettings = false

    init(
        dbManager: DatabaseManager,
        pool: ChatSessionPool,
        writes: ChatWrites,
        provider: AIProvider = .claude,
        cliRunner: CLIRunnerProtocol? = nil,
        preferredProviderSource: (() -> AIProvider)? = nil,
        defaults: UserDefaults = .standard,
        attachmentsRoot: URL? = ChatAttachmentStore.defaultRootDir(),
        makeTurnID: @escaping () -> String = { UUID().uuidString },
        leaseClock: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.chatWrites = writes
        self.leaseClock = leaseClock
        self.dbManager = dbManager
        self.pool = pool
        self.selectedProvider = provider
        self.configuredPreferred = provider
        self.preferredProviderSource = preferredProviderSource
        self.cliRunner = cliRunner
        self.makeTurnID = makeTurnID
        self.actionFeed = AgentActionFeed(dbPool: dbManager.dbPool, cliRunner: cliRunner)
        self.composerAttachments = ComposerAttachments(
            store: attachmentsRoot.map { ChatAttachmentStore(db: dbManager.dbPool, rootDir: $0, writes: writes) }
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
        pool.onActionAwaited = { [weak self] id in self?.actionAwaited(conversationID: id) }
        pool.onTurnLost = { [weak self] id, turnID in self?.recover(conversationID: id, turnID: turnID) }
        reloadProjects()
    }

    /// The streaming message of the shown conversation — its own observable,
    /// throttled to ≤30 fps, slower as the text grows (`LiveTurn`); only the
    /// row showing it re-renders.
    var liveTurn: LiveTurn? { pool.client(for: conversationID)?.liveTurn }
    /// A turn is running — or held by the pool waiting for a session.
    var isStreaming: Bool { liveTurn?.isRunning == true }
    /// The shown chat's turn ended and its final state is being written
    /// (board #670): nothing can stop it, and the next send waits for it.
    var isFinishingTurn: Bool { pool.client(for: conversationID)?.driver.isFinishing == true }
    /// The shown chat's session could not save its latest reply: the thread
    /// says so (the reply on disk may be stale or empty).
    var sessionPersistenceError: String? { pool.client(for: conversationID)?.saveError }
    /// Whether the composer offers Stop: never while the turn's end is
    /// being written — nothing could stop it then. A turn waiting for its
    /// `started` (held, or being written) can be stopped: it is stopped at
    /// its start (`ChatSessionClient.cancel`).
    var canStop: Bool { !isHandingTurn && !isFinishingTurn }
    /// Every live session is busy with another conversation's turn: this
    /// turn is held (not lost) until one finishes. The UI says so.
    var isWaitingForSession: Bool {
        guard let client = pool.client(for: conversationID) else { return false }
        return client.isPending && client.isBusy
    }

    // MARK: - Conversations

    func select(conversationID id: Int64) {
        discardLandingDraft(except: id)
        openProjectID = nil
        isOnLanding = false
        landingProjectID = nil
        let switching = id != conversationID
        conversationID = id
        editingMessageID = nil
        reload()
        guard switching else { return }
        errorMessage = nil
        foreignTurn.reset()
        restorePendingAttachments(conversationID: id)
        artifactPanel = nil
        sourcesPanel = nil
        dismissedArtifactKeys = []
        applyConversationSettings()
        actionFeed.start(conversationID: id)
        prewarm()
    }

    @discardableResult
    func newConversation(projectID: Int64? = nil) async -> Int64? {
        do {
            let conv = try await writeNewConversation(projectID: projectID)
            select(conversationID: conv.id)
            reloadConversations()
            return conv.id
        } catch {
            errorMessage = "Couldn't start a new chat: \(error.localizedDescription)"
            return nil
        }
    }

    /// A new conversation row (`chat.new`), in this view model's chain.
    private func writeNewConversation(projectID: Int64?) async throws -> ChatConversation {
        let created: ChatNewResponse = try await write(.chatNew) { ChatNewRequest(requestID: $0, projectID: projectID) }
        guard let conv = try conversation(created.conversationID) else {
            throw ChatWriteError(sentence: "This chat no longer exists.", isGone: true)
        }
        return conv
    }

    /// One row, read at once.
    private func conversation(_ id: Int64) throws -> ChatConversation? {
        try dbManager.dbPool.read { try ChatConversationQueries.fetchByID($0, id: id) }
    }

    /// One chat write in this view model's chain: it is sent once every
    /// write asked for before it finished.
    private func write<Resp: Decodable & Sendable, Params: Encodable & Sendable>(
        _ command: TowerCommand, _ params: @escaping @Sendable (String) -> Params
    ) async throws -> Resp {
        let chatWrites = chatWrites
        return try await writes.runThrowing { try await chatWrites.perform(command, params) }
    }

    /// A conversation is being deleted: close its session; stop showing it
    /// (the landing takes its place).
    func forget(conversationID id: Int64) {
        quoteBatches[id] = nil
        pool.close(conversationID: id)
        if id == landingDraftID { landingDraft = nil }
        guard id == conversationID else { return }
        isOnLanding = true
        clearShownConversation()
    }

    /// Entering the Chat tab (owner decision 2026-09-28): reopen the last
    /// conversation when `ChatLandingPolicy` says so, otherwise the landing.
    /// `rememberedConversationID`/`lastViewedAt` are what the view stored on
    /// leaving — they matter after a relaunch, when nothing is shown yet. An
    /// open project page is left as it is; so is the landing while it holds
    /// unsent text or attachments, which otherwise force a resume.
    func enterTab(rememberedConversationID: Int64?, lastViewedAt: Date?, now: Date) {
        guard openProjectID == nil else { return }
        let unsent = hasUnsentInput
        if isOnLanding, unsent { return }
        let id = conversationID ?? rememberedConversationID
        let viewedAt = id == rememberedConversationID ? lastViewedAt : nil
        let last = id.flatMap(landingSnapshot(conversationID:))
        switch ChatLandingPolicy.decide(last: last, lastViewedAt: viewedAt, hasUnsentInput: unsent, now: now) {
        case .resume(let id): select(conversationID: id)
        case .landing: showLanding(inProject: landingProjectID)
        }
    }

    /// The landing: ⌘N, New Chat, and a tab entry outside the resume
    /// window. The session of the conversation left behind stays warm
    /// (the pool's idle TTL). The landing's own still-untouched draft stays
    /// its draft, so no second empty row is made; any other chat is let go
    /// (never adopted as a draft — it is not the landing's to delete).
    /// `projectID` is where the landing's chat is made; a draft made for
    /// another project is not shown (the next keystroke makes a new one and
    /// the old draft goes when it is selected).
    func showLanding(inProject projectID: Int64? = nil) {
        openProjectID = nil
        isOnLanding = true
        landingProjectID = projectID
        if let id = conversationID, id == landingDraftID, landingDraft?.projectID == projectID { return }
        clearShownConversation()
    }

    /// The conversation is the one on this view model's screen: shown, not
    /// the landing or a project page (whether the Chats tab itself is on
    /// screen is the caller's to know).
    func isShowing(conversationID id: Int64) -> Bool {
        !isOnLanding && openProjectID == nil && conversationID == id
    }

    /// A turn of that conversation is running now (the panel's "Answering"
    /// state). Reads the pool's observable `clients`, so a view asking at
    /// render time follows it.
    func isAnswering(conversationID id: Int64) -> Bool {
        pool.runningTurnID(conversationID: id) != nil
    }

    /// Text or attachments typed but not sent.
    var hasUnsentInput: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !composerAttachments.pending.isEmpty
    }

    /// App launch: drop the draft a landing left behind by quitting, while
    /// it is still untouched. Nothing is shown yet, so it is not on screen;
    /// no other chat is ever swept.
    func cleanUpUntouchedConversations() {
        guard let stale = storedLandingDraft else {
            defaults.removeObject(forKey: landingDraftKey) // unreadable: forget it, delete nothing
            return
        }
        landingDraft = stale
        discardLandingDraft()
    }

    /// Leaving the landing for anything but its own first turn: its draft
    /// conversation goes, unless it gained a message or an attachment (the
    /// delete re-checks that in the same statement), and so does its session.
    private func discardLandingDraft(except keep: Int64? = nil) {
        guard let draft = landingDraft, draft.id != keep else { return }
        landingDraft = nil
        discardIfUntouched(draft)
    }

    /// Deletes a conversation nobody wrote into (in the chain; best effort,
    /// a failure is logged), and its session with it.
    /// Queued right away: the caller (a selection, the launch cleanup) is
    /// synchronous.
    private func discardIfUntouched(_ draft: LandingDraft) {
        let chatWrites = chatWrites
        writes.start { [weak self] in
            do {
                let result: ChatChanged = try await chatWrites.perform(.chatDeleteUntouched) {
                    ChatDeleteUntouchedRequest(requestID: $0, conversationID: draft.id, createdAt: draft.createdAt,
                                               projectID: draft.projectID)
                }
                guard result.changed, let self else { return }
                self.pool.close(conversationID: draft.id)
                self.reloadConversations()
            } catch {
                NSLog("ChatViewModel: discarding the landing's unused chat failed: %@", error.localizedDescription)
            }
        }
    }

    /// Returns once every write queued so far has landed or failed (tests:
    /// a synchronous caller queued one, e.g. a landing draft's discard).
    func writesSettled() async {
        await writes.idle()
    }

    /// The composer's first keystroke: prewarm the session. On the landing
    /// that first needs a conversation, made without leaving the landing.
    func draftStarted() async {
        if conversationID == nil {
            _ = await conversationIDCreatingIfNeeded()
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

    /// Pending files belong to their own conversation: opening another chat
    /// shows that chat's unsent files, never carries the previous ones along.
    private func restorePendingAttachments(conversationID id: Int64?) {
        guard let id else {
            composerAttachments.replacePending(with: [])
            return
        }
        do {
            let pending = try dbManager.dbPool.read { try ChatAttachmentQueries.fetchPending($0, conversationID: id) }
            composerAttachments.replacePending(with: pending, conversationID: id)
        } catch {
            composerAttachments.replacePending(with: [], conversationID: id)
            errorMessage = "Couldn't load this chat's unsent files: \(error.localizedDescription)"
        }
    }

    private func clearShownConversation() {
        restorePendingAttachments(conversationID: nil)
        conversationID = nil
        currentConversation = nil
        applyingConversationSettings = true
        automaticRouting = true
        selectedProvider = preferredProvider
        selectedModel = ""
        applyingConversationSettings = false
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
    func createProject(name: String) async -> Int64? {
        do {
            let project: ChatProjectCreateResponse = try await write(.chatProjectCreate) {
                ChatProjectCreateRequest(requestID: $0, name: name)
            }
            reloadProjects()
            projectNameFocusRequest = project.projectID
            openProject(project.projectID)
            return project.projectID
        } catch {
            errorMessage = "Couldn't create the project: \(error.localizedDescription)"
            return nil
        }
    }

    /// Shows a project page; the chat's artifact panel closes with the chat.
    /// The page's composer is the landing's, in this project (spec
    /// 2026-10-26 §7): its first keystroke makes the conversation there and
    /// the page stays until that chat's first turn starts. A draft the
    /// landing already made in this project stays its draft; any other one
    /// goes, and a chat on screen is let go, so the page's composer never
    /// writes into it.
    func openProject(_ id: Int64) {
        let keepsDraft = conversationID != nil && conversationID == landingDraftID && landingDraft?.projectID == id
        if !keepsDraft {
            discardLandingDraft()
            clearShownConversation()
        }
        openProjectID = id
        isOnLanding = true
        landingProjectID = id
        artifactPanel = nil
        sourcesPanel = nil
    }

    /// The Chats panel's level changed (`ChatHistoryViewModel.onLevelChanged`:
    /// ‹, ⌘[, the switcher, the fallback when the project is gone): a
    /// landing — or project page — in another project gives way to the
    /// landing outside any project, so nothing is made in a project the
    /// panel no longer shows.
    func panelLevelChanged(to projectID: Int64?) {
        guard let landing = landingProjectID, landing != projectID else { return }
        if isOnLanding {
            showLanding(inProject: nil)
        } else {
            landingProjectID = nil
        }
    }

    /// The ⌘/ popup opens over this chat (spec 2026-10-26 §2: it behaves
    /// as before the panel, outside any project): a landing or project page
    /// in a project becomes the plain landing first — the popup's composer
    /// never makes a chat in a project —, then, with nothing shown, the
    /// tab's resume decision runs (`enterTab`).
    func enterHelpPopup(rememberedConversationID: Int64?, lastViewedAt: Date?, now: Date) {
        if isOnLanding, landingProjectID != nil { showLanding(inProject: nil) }
        guard conversationID == nil else { return }
        enterTab(rememberedConversationID: rememberedConversationID, lastViewedAt: lastViewedAt, now: now)
    }

    /// Called by the project page after a write that changes the project's
    /// prompt (instructions, sources, files): the write dropped the chats'
    /// stored sessions, so their warm processes go too and the shown chat
    /// rereads its row — the next turn starts fresh with the new prompt.
    func projectPromptChanged(_ id: Int64) {
        pool.retireSessions(projectID: id, deleted: false)
        if currentConversation?.projectID == id { reload() }
    }

    /// Called by the project page after it deleted its project: its chats
    /// are detached (`ON DELETE SET NULL`), so the shown one reloads too.
    func projectDeleted(_ id: Int64) {
        pool.retireSessions(projectID: id, deleted: true)
        if landingProjectID == id { landingProjectID = nil }
        // The landing's draft in that project now sits outside any project
        // (`ON DELETE SET NULL`): it stays the landing's draft there, so it
        // is still reused or discarded.
        if let draft = landingDraft, draft.projectID == id {
            landingDraft = LandingDraft(id: draft.id, createdAt: draft.createdAt)
        }
        reloadProjects()
        if openProjectID == id { showLanding() }
        // The shown chat — or the landing's kept draft — is detached now.
        reload()
        reloadConversations()
    }

    /// Moves a chat into a project (or out, with nil). The next turn gets a
    /// session spawned for the new project (`ChatSessionConfig.projectID` is
    /// part of `isCompatible`), and the stored Claude session is dropped so
    /// that turn starts fresh with the new project prompt and replays.
    func moveConversation(_ conversationID: Int64, toProject projectID: Int64?) async {
        do {
            let _: ChatDone = try await write(.chatSetProject) {
                ChatSetProjectRequest(requestID: $0, conversationID: conversationID, projectID: projectID)
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
            keptArtifactKeys = []
            return
        }
        do {
            let (conv, items, versions, kept, gmail, slack) = try dbManager.dbPool.read { db in
                let conv = try ChatConversationQueries.fetchByID(db, id: id)
                let items = try ChatTreeQueries.thread(db, conversationID: id)
                let versions = try ChatArtifactQueries.versionsByMessage(db, messageIDs: items.map(\.id))
                let kept = try ChatArtifactQueries.keptKeys(db, conversationID: id)
                let gmail = try GoogleAccountQueries.hasConnectedGmailAccount(db)
                let slack = try SlackLinkResolver.load(db)
                return (conv, items, versions, kept, gmail, slack)
            }
            currentConversation = conv
            if items != thread { thread = items }
            let refreshedSources = sourcesPanel?.refreshed(in: items)
            if refreshedSources != sourcesPanel { sourcesPanel = refreshedSources }
            artifactVersionsByMessage = versions
            keptArtifactKeys = kept
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
        guard !isBusy, !isChangingRouting else { return }
        automaticRouting = false
        guard provider != selectedProvider else { recycleSession(); return }
        selectedProvider = provider
        selectedModel = ""
        recycleSession()
    }

    /// The combined choice explicitly removes BOTH historical pins. No global preference is written.
    func requestAutomaticRouting() { Task { await useAutomaticRouting() } }

    func useAutomaticRouting() async {
        guard !isBusy, !isChangingRouting else { return }
        isChangingRouting = true
        defer { isChangingRouting = false }
        let changedConversationID = conversationID
        if let id = changedConversationID {
            guard await pool.closeIdleAndWait(conversationID: id) else { return }
            do {
                let _: ChatDone = try await write(.chatSetRouting) {
                    ChatSetRoutingRequest(requestID: $0, conversationID: id, routing: ChatRouting(automatic: true))
                }
            } catch {
                errorMessage = "Couldn't change provider choice: \(error.localizedDescription)"
                return
            }
        }
        guard conversationID == changedConversationID else { return }
        applyingConversationSettings = true
        selectedProvider = preferredProvider
        selectedModel = ""
        automaticRouting = true
        applyingConversationSettings = false
        reload()
    }

    func reviewActions(messageID: Int64) {
        guard let item = thread.first(where: { $0.id == messageID }) else { return }
        actionFeed.refresh()
        reviewedMessageID = messageID
        reviewedActionIDs = actionFeed.rows.filter { $0.turnID == item.message.turnID }.map(\.id)
        isInspectorExpanded = false
        scrollTarget = messageID
    }

    // MARK: - Artifacts

    /// Opens (or re-focuses) the panel for `key` in the current conversation.
    func openArtifact(key: String) {
        guard let conversationID else { return }
        preferredInspectorMode = .artifacts
        guard artifactPanel?.key != key else { return }
        let panel = ArtifactPanelModel(db: dbManager.dbPool, writes: chatWrites, conversationID: conversationID, key: key)
        panel.onKnowledgeChanged = { [weak self] in self?.reload() }
        artifactPanel = panel
    }

    /// The owner closed the panel: remember the key so a still-streaming turn
    /// does not reopen it for the rest of this turn.
    func closeArtifactPanel() {
        if let key = artifactPanel?.key { dismissedArtifactKeys.insert(key) }
        artifactPanel = nil
    }

    /// "Send N comments" in the artifact panel: the unsent comments go out as
    /// one ordinary owner turn, and exactly those rows turn `sent` in the
    /// transaction that persists that message — a refused or failed send
    /// leaves them unsent, a sent message never leaves them open. The button
    /// is disabled while an answer streams; a click that races the stream's
    /// start is refused out loud, never silently.
    func sendArtifactComments() async {
        guard let comments = artifactPanel?.comments, let outgoing = comments.outgoing() else { return }
        // The answer — or the reason it was not sent — shows in the
        // conversation, which an expanded panel covers (#786).
        isInspectorExpanded = false
        guard !isBusy else {
            errorMessage = "Wait for the current answer to finish, then send the comments."
            return
        }
        guard await send(text: outgoing.text, quotes: outgoing.ids) else { return }
        comments.reload()
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

    /// The panel's expand button: the open panel takes the chat's width, or
    /// goes back to the inspector column.
    func toggleInspectorExpanded() {
        isInspectorExpanded = inspectorMode != nil && !isInspectorExpanded
    }

    /// The inspector column is on screen: a panel is open and not expanded.
    var showsInspectorColumn: Bool { inspectorMode != nil && !isInspectorExpanded }

    /// The inspector column was dismissed. Expanding hides the column too,
    /// which must not close the panel it moves.
    func inspectorColumnDismissed() {
        guard !isInspectorExpanded else { return }
        closeInspector()
    }

    private func collapseInspectorIfClosed() {
        if inspectorMode == nil { isInspectorExpanded = false }
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

    /// Sends the composer text + the pending quote batch + any pending
    /// attachments as one owner turn; clears them only when the turn really
    /// started (a failed send keeps them for retry). `screen` is the help
    /// popup's per-turn screen block: sent with the turn, never stored.
    ///
    /// The turn's rows are written off the main thread (board #670), so the
    /// text leaves the composer at once, as it always did: what is typed
    /// while they are written is the next message's. A send that fails puts
    /// its text back ahead of it, and only the files that went out leave
    /// the composer.
    func sendDraft(screen: ScreenContext? = nil) async {
        guard !isWaitingForAttachments else { return }
        let shown = conversationID
        let fromLanding = isOnLanding
        // Files dropped, pasted or removed just before Enter land first
        // (board #670); the composer says the send waits for them.
        if composerAttachments.isBusy || !pastesInFlight.isEmpty {
            let wait = UUID()
            attachmentWaits[wait] = (shown, fromLanding)
            for paste in pastesInFlight.values { _ = await paste.value }
            await composerAttachments.settled()
            attachmentWaits[wait] = nil
        }
        // The owner opened another chat meanwhile: nothing goes out, and the
        // text stays where the switch left it, as for a switch before Enter.
        guard conversationID == shown || (fromLanding && isOnLanding) else { return }
        let attachments = composerAttachments.pending
        let batchID = conversationID
        let typed = draft
        let text = ChatQuoteReply.compose(quotes: pendingQuotes, typed: typed) ?? typed
        draft = ""
        if await send(text: text, attachments: attachments, mentions: composer.mentions, skill: composer.skill,
                      screen: screen) {
            composerAttachments.removeSent(attachments.map(\.id))
            if let batchID { quoteBatches[batchID] = nil }
        } else {
            draft = draft.isEmpty ? typed : "\(typed)\n\(draft)"
        }
    }

    /// The current conversation's quote batch (empty on the landing).
    var pendingQuotes: [ChatQuoteDraft] {
        conversationID.flatMap { quoteBatches[$0] } ?? []
    }

    /// "Ask about this" on a selected passage: one more quote in the batch,
    /// and the composer takes the keyboard. Nothing is sent or stored until
    /// the owner sends the draft.
    func addQuote(_ quote: String, comment: String) {
        guard let id = conversationID, !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        quoteBatches[id, default: []].append(ChatQuoteDraft(quote: quote, comment: comment))
        requestComposerFocus()
    }

    /// The composer takes the keyboard (a quote added, ⌘/ on the AI Chat tab).
    func requestComposerFocus() {
        composerFocusRequest = UUID()
    }

    func updateQuoteComment(id quoteID: UUID, comment: String) {
        guard let id = conversationID, let index = quoteBatches[id]?.firstIndex(where: { $0.id == quoteID }) else { return }
        quoteBatches[id]?[index].comment = comment
    }

    func removeQuote(id quoteID: UUID) {
        guard let id = conversationID else { return }
        quoteBatches[id]?.removeAll { $0.id == quoteID }
        if quoteBatches[id]?.isEmpty == true { quoteBatches[id] = nil }
    }

    func attachFiles(_ urls: [URL]) {
        if let conversationID {
            composerAttachments.add(urls: urls, conversationID: conversationID)
            return
        }
        Task {
            guard let id = await conversationIDCreatingIfNeeded() else { return }
            composerAttachments.add(urls: urls, conversationID: id)
        }
    }

    /// A paste the composer turned into a file (screenshot, PDF data, long
    /// text — board #534); true once attached. On the landing its
    /// conversation is written first; a failure there (the chat's error says
    /// why) attaches nothing and answers false, so a long paste stays in the
    /// field.
    ///
    /// A send waits for the pastes under way (`sendDraft`), so a paste
    /// followed at once by Enter goes out with that message.
    @discardableResult
    func attachPasted(_ data: Data, name: String) async -> Bool {
        let key = UUID()
        let paste = Task { [self] () -> Bool in
            guard let id = await conversationIDCreatingIfNeeded() else { return false }
            return await composerAttachments.addPasted(data, name: name, conversationID: id)
        }
        pastesInFlight[key] = paste
        defer { pastesInFlight[key] = nil }
        return await paste.value
    }

    /// `mentions` are the composer's picked candidates (Task 25); only those
    /// still present as `@Label` in `text` are kept (`liveMentions`) and
    /// composed into the stored/sent owner text along with `skill`
    /// (`ChatTurnComposer`, spec §4.3, preflight A31). Clears the composer's
    /// pending mentions/skill once the turn actually starts — unless
    /// `keepsComposer`: a turn sent from elsewhere (a question card's answer)
    /// leaves the owner's half-written draft and its picks alone.
    ///
    /// One at a time (`isStartingTurn`): a send while one is being written
    /// does nothing and returns false.
    @discardableResult
    func send(
        text: String,
        attachments: [ChatAttachment] = [],
        mentions: [MentionCandidate] = [],
        skill: String? = nil,
        keepsComposer: Bool = false,
        quotes: [Int64] = [],
        screen: ScreenContext? = nil
    ) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let live = MentionTokenizer.liveMentions(text: text, mentions: mentions)
        let turnText = ChatTurnComposer.compose(text: text, skill: skill, mentions: live)
        // A message may carry only attachments (no text) — the ChatComposerField canSend twin.
        guard !turnText.isEmpty || !attachments.isEmpty, !isBusy else { return false }
        isHandingTurn = true
        defer { isHandingTurn = false }
        let fromLanding = isOnLanding
        guard let id = await conversationIDCreatingIfNeeded() else { return false }
        if !keepsComposer { composer.reset() }
        // The actions-outcome block is Go's (its start reads it, floored at
        // the previous owner message); the screen block goes as is.
        return await startTurn(conversationID: id, text: turnText, start: ChatTurnStart(
            mode: .send, attachmentIDs: attachments.map(\.id), quotes: quotes, titleText: trimmed,
            screen: screen?.block), bubble: turnText) { [self] in
            isHandingTurn = false
            // The landing's own turn only: a landing left meanwhile is not.
            // It leaves at Send, so the chat shows the owner's message, the
            // waiting line and Stop while the session writes the turn.
            guard fromLanding, isOnLanding, conversationID == id else { return }
            landingDraft = nil
            isOnLanding = false
            openProjectID = nil
            landingProjectID = nil
            onLandingTurnStarted?(id)
        }
    }

    /// The conversation a turn/attachment writes into, creating one on first
    /// use (a paperclip click before any text still needs somewhere to land).
    /// Made from the landing, it keeps the landing up until the first turn.
    /// One creation at a time: callers meanwhile get the same conversation.
    private func conversationIDCreatingIfNeeded() async -> Int64? {
        if let conversationID { return conversationID }
        if let creatingConversation { return await creatingConversation.value }
        let task = Task { [self] in
            defer { creatingConversation = nil }
            return await createConversationForComposer()
        }
        creatingConversation = task
        return await task.value
    }

    private func createConversationForComposer() async -> Int64? {
        guard isOnLanding else { return await newConversation() }
        // The landing's own earlier draft, still untouched and in the same
        // project, is reused rather than a second empty row made.
        let projectID = landingProjectID
        let reusable: Int64?
        do {
            let previous = landingDraft ?? storedLandingDraft
            reusable = try previous.flatMap { draft in
                try dbManager.dbPool.read {
                    try ChatConversationQueries.fetchUntouched(
                        $0, id: draft.id, createdAt: draft.createdAt, projectID: projectID
                    )?.id
                }
            }
        } catch {
            NSLog("ChatViewModel: looking up an untouched chat failed: %@", error.localizedDescription)
            reusable = nil
        }
        let id: Int64
        if let reusable {
            id = reusable
        } else {
            let conv: ChatConversation
            do {
                conv = try await writeNewConversation(projectID: projectID)
            } catch {
                errorMessage = "Couldn't start a new chat: \(error.localizedDescription)"
                return nil
            }
            // The owner left the landing (or moved it to another project)
            // while the row was written: it is not the landing's draft any
            // more, and nobody wrote into it.
            guard isOnLanding, conversationID == nil, landingProjectID == projectID else {
                discardIfUntouched(LandingDraft(id: conv.id, createdAt: conv.createdAt, projectID: conv.projectID))
                return nil
            }
            id = conv.id
            reloadConversations()
        }
        // A project page (and the landing's project) stays until the
        // draft's first turn.
        let page = openProjectID
        select(conversationID: id)
        isOnLanding = true
        openProjectID = page
        landingProjectID = projectID
        landingDraft = currentConversation.map {
            LandingDraft(id: $0.id, createdAt: $0.createdAt, projectID: $0.projectID)
        }
        return id
    }

    /// Stops the open chat's turn: the Mac's own through its session, the
    /// phone's by setting its lease's cancel (the hub stops it within 1 s).
    func stop() {
        guard let turnID = foreignTurn.turnID, let id = conversationID else {
            pool.client(for: conversationID)?.cancel()
            return
        }
        Task {
            do {
                let _: ChatChanged = try await write(.chatStop) {
                    ChatTurnRequest(requestID: $0, conversationID: id, turnID: turnID)
                }
            } catch {
                errorMessage = "Couldn't stop the answer: \(error.localizedDescription)"
            }
        }
    }

    /// One read of the open chat's lease (spec 2026-11-15 §5): while the hub
    /// holds it the thread is re-read, and once more at its release; the
    /// Chats panel follows when it starts or ends.
    func refreshForeignTurn() async {
        guard let id = conversationID else {
            foreignTurn.reset()
            return
        }
        let lease: ChatLease?
        do {
            lease = try await dbManager.dbPool.read { db in try ChatLeaseQueries.fetch(db, conversationID: id) }
        } catch {
            NSLog("ChatViewModel: reading the chat lease failed: %@", error.localizedDescription)
            return
        }
        // Another chat was opened while it was read.
        guard conversationID == id else { return }
        let tick = foreignTurn.observe(lease, nowMS: ChatLease.milliseconds(leaseClock()))
        if tick.reloadThread { reload() }
        if tick.reloadPanel { reloadConversations() }
    }

    /// The chat view's task: reads the open chat's lease every
    /// `ChatForeignTurnModel.pollInterval` until the task ends.
    func watchForeignTurns() async {
        while !Task.isCancelled {
            await refreshForeignTurn()
            do { try await Task.sleep(for: ChatForeignTurnModel.pollInterval) } catch { return }
        }
    }

    func retry(messageID: Int64) async {
        guard let item = thread.first(where: { $0.id == messageID }),
              ChatErrorPresentation.isRetryable(item.message.errorCode) else { return }
        await regenerate(messageID: messageID)
    }

    /// "Stopped" + Continue: asks the model to carry on from its partial reply.
    func continueStopped(messageID: Int64) async {
        guard let last = thread.last?.message, last.id == messageID, last.isAssistant, last.status == "partial",
              last.errorCode != ChatErrorCode.quotaExhausted.rawValue else { return }
        await send(text: "Continue")
    }

    /// A new assistant sibling under the same owner message (spec §2.3). The
    /// provider session's transcript holds the old answer, so it replays.
    /// Replay is text-only, so the owner message's files are sent again with
    /// it — a retried/regenerated turn about an image or PDF still sees it.
    func regenerate(messageID: Int64) async {
        guard !isBusy, let id = conversationID,
              let index = thread.firstIndex(where: { $0.message.id == messageID }), index > 0,
              thread[index].message.isAssistant, thread[index - 1].message.isUser,
              thread[index].message.errorCode != ChatErrorCode.quotaExhausted.rawValue else { return }
        let owner = thread[index - 1]
        await startTurnBusy(conversationID: id, text: owner.message.text,
                            start: ChatTurnStart(mode: .regenerate, parentID: owner.message.id), bubble: nil)
    }

    /// A new owner sibling under the original's parent, then a fresh reply.
    /// The edited body keeps the original message's skill line and REFERENCED
    /// tokens (`ChatTurnComposer.recompose`, Review Focus 3), and its files are
    /// sent again (the edit changes only the text). The attachment rows stay
    /// linked to the original message — the edited sibling does not show them
    /// (v1 limit).
    func edit(messageID: Int64, newText: String) async {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy, let id = conversationID,
              let item = thread.first(where: { $0.message.id == messageID }), item.message.isUser else { return }
        editingMessageID = nil
        // Go keeps the original's skill line and REFERENCED tokens (its
        // `recompose`); the bubble shows the same text meanwhile.
        await startTurnBusy(conversationID: id, text: trimmed,
                            start: ChatTurnStart(mode: .edit, editMessageID: messageID),
                            bubble: ChatTurnComposer.recompose(stored: item.message.text, newBody: trimmed))
    }

    /// ↑ in an empty composer (spec §3.5).
    func beginEditingLast() {
        editingMessageID = thread.last { $0.message.isUser }?.message.id
    }

    func selectVariant(messageID: Int64) async {
        guard let id = conversationID else { return }
        do {
            let _: ChatDone = try await write(.chatBranch) { ChatBranchRequest(requestID: $0, messageID: messageID) }
            // Another chat opened meanwhile keeps its own thread on screen.
            guard conversationID == id else { return }
            reload()
        } catch {
            guard conversationID == id else { return }
            errorMessage = "Couldn't switch the variant: \(error.localizedDescription)"
        }
    }

    /// ⌘K hit: open the conversation, make the hit's branch active, scroll to it.
    func open(_ hit: ChatSearchHit) async {
        // The hit shows in the conversation, which an expanded panel covers.
        isInspectorExpanded = false
        select(conversationID: hit.conversationID)
        guard let messageID = hit.messageID else { return }
        await selectVariant(messageID: messageID)
        guard conversationID == hit.conversationID else { return }
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

    /// `startTurn` for a regenerate or an edit, which `isStartingTurn`
    /// guards like a send.
    @discardableResult
    private func startTurnBusy(conversationID: Int64, text: String, start: ChatTurnStart, bubble: String?) async -> Bool {
        isHandingTurn = true
        defer { isHandingTurn = false }
        return await startTurn(conversationID: conversationID, text: text, start: start, bubble: bubble) { [self] in
            isHandingTurn = false
        }
    }

    /// Sends the turn to the chat's session, which writes its rows and
    /// answers `started` (CHAT-01: the owner row commits before the provider
    /// runs). `bubble` shows at once as the owner's message until then. True
    /// once started; false — nothing was written — when the session refused
    /// it (the phone's turn holds the chat), could not save it, died or
    /// stayed silent for `startedTimeout`: the caller puts the text back.
    /// The turn goes out whichever chat is on screen by then; only the
    /// screen's own state follows the shown conversation.
    @discardableResult
    private func startTurn(
        conversationID id: Int64,
        text: String,
        start: ChatTurnStart,
        bubble: String?,
        handed: () -> Void = {}
    ) async -> Bool {
        let config = sessionConfig(conversationID: id)
        let command = ChatTurnCommand(turnID: makeTurnID(), text: text, attachments: [], replay: false, start: start)
        awaitingStart[id] = AwaitingStart(bubble: bubble)
        defer { awaitingStart[id] = nil }
        handed()
        if let recovery = recovering[id] { await recovery.value }
        let client = pool.session(for: id, config: config)
        switch await client.startTurn(command) {
        case .started(let started):
            awaitingStart[id] = nil
            if conversationID == id {
                errorMessage = nil
                dismissedArtifactKeys = []
                reload()
            }
            if started.ownerMessageID > 0, start.mode != .regenerate {
                // Remember gets the owner's typed words, never the skill/REFERENCED lines.
                onOwnerMessageStarted?(started, ChatTurnComposer.displayParts(bubble ?? text).body)
            }
            reloadConversations()
            return true
        case .refused:
            // The phone's turn holds the chat: nothing was written or sent;
            // the composer shows its line and keeps the text.
            guard conversationID == id else { return false }
            await refreshForeignTurn()
            if conversationID == id, foreignTurn.line == nil {
                errorMessage = ChatBusyError().localizedDescription
            }
            return false
        case .failed(let failure):
            // A held turn the owner stopped is not an error to show.
            if conversationID == id, failure.code != .interrupted { errorMessage = failure.message }
            return false
        }
    }

    /// A session died after `started` without letting go of its turn: the
    /// turn's rows are marked `session_lost` and its lease freed
    /// (`chat.recover`, spec §9). A failed call is logged; the next app
    /// launch's `chat.release_launches` does it then.
    private func recover(conversationID id: Int64, turnID: String) {
        let chatWrites = chatWrites
        let task = Task { [weak self] in
            do {
                let _: ChatRecoverResponse = try await chatWrites.perform(.chatRecover) {
                    ChatTurnRequest(requestID: $0, conversationID: id, turnID: turnID)
                }
            } catch {
                NSLog("ChatViewModel: recovering chat turn %@ failed: %@", turnID, error.localizedDescription)
            }
            self?.recovering[id] = nil
            guard let self, self.conversationID == id else { return }
            self.reload()
        }
        recovering[id] = task
    }

    private func sessionConfig(conversationID id: Int64) -> ChatSessionConfig {
        // No provider resumes a stored session: a new session replays the
        // history from the database (#604 G11).
        ChatSessionConfig(conversationID: id, provider: selectedProvider.rawValue,
                          model: selectedModel.isEmpty ? nil : selectedModel,
                          automatic: automaticRouting, projectID: currentConversation?.projectID)
    }

    /// A conversation remembers the provider/model it last ran with; a new
    /// one keeps the current picker selection.
    private func applyConversationSettings() {
        guard let conv = currentConversation else { return }
        automaticRouting = conv.isAutomatic
        let raw = conv.isAutomatic ? preferredProvider.rawValue : conv.provider ?? preferredProvider.rawValue
        applyingConversationSettings = true
        defer { applyingConversationSettings = false }
        if let provider = AIProvider(rawValue: raw) { selectedProvider = provider }
        selectedModel = conv.isAutomatic ? "" : conv.model ?? ""
    }

    /// The live process was spawned for the old provider/model: close it; the
    /// next turn spawns a matching one, which replays the history. Never
    /// mid-turn — the picker is disabled while streaming.
    private func recycleSession() {
        guard !applyingConversationSettings, !isBusy, let id = conversationID else { return }
        pool.close(conversationID: id)
    }

    /// The turn is blocked on a proposal the session subprocess just wrote:
    /// surface its card now, not at the turn boundary it is waiting for.
    private func actionAwaited(conversationID id: Int64) {
        if id == conversationID { actionFeed.refresh() }
        onActionAwaited?(id)
    }

    private func turnFinished(conversationID id: Int64) {
        if id == conversationID {
            reload()
            // Proposals were written by the MCP subprocess, which the feed's
            // ValueObservation cannot see — the turn boundary surfaces them.
            actionFeed.refresh()
            // The session's terminal write already versioned this turn's
            // artifacts in the same transaction as the message (`turn_saved`
            // came after it); drop the live draft and show what was stored.
            artifactPanel?.turnFinished()
            // A failed or cut-off turn rolls the panel back to the stored
            // version; its error and Retry live in the conversation (#786).
            if thread.last?.message.status != "complete" { isInspectorExpanded = false }
        }
        reloadConversations()
        requestTitleIfNeeded(conversationID: id)
        onTurnFinished?(id)
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
        titleTask = Task { [weak self] in
            // ProcessCLIRunner logs a failure (CLILog); the prefix title stays, which is still correct.
            _ = try? await cliRunner.run(args: ["chat", "title", String(id)])
            guard let self else { return }
            self.reloadConversations()
            if self.conversationID == id { self.reload() }
        }
    }
}

/// The landing's draft as persisted: `"<id>|<created_at>"`, plus
/// `"|<project_id>"` for a draft made in a project (an older two-part value
/// reads as outside any project).
struct LandingDraft: Equatable {
    let id: Int64
    let createdAt: Double
    let projectID: Int64?

    init(id: Int64, createdAt: Double, projectID: Int64? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.projectID = projectID
    }

    init?(stored: String) {
        let parts = stored.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              let id = Int64(parts[0]), let createdAt = Double(parts[1]) else { return nil }
        var projectID: Int64?
        if parts.count == 3 {
            guard let project = Int64(parts[2]) else { return nil }
            projectID = project
        }
        self.init(id: id, createdAt: createdAt, projectID: projectID)
    }

    var stored: String { projectID.map { "\(id)|\(createdAt)|\($0)" } ?? "\(id)|\(createdAt)" }
}
