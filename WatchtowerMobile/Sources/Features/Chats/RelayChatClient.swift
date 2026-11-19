import ChatUI
import ChatWire
import Foundation
import Observation
import os
import WatchtowerChatText
import WatchtowerKit
import WatchtowerSync

/// The phone's `ChatClient` (unified chat spec §6.3): the `ChatUI` screens run on the Mac's engine through the hub's
/// relay adapter. A turn goes through `ChatSendCoordinator` (kept in `chat_outgoing` until applied, CHAT-01's phone
/// half); every other operation is its relay action kind, its echo awaited; `chat_page` and `chat_search` answer with a
/// record the replica receives. A feed is the conversation's `chat_feed` record, each one a snapshot, the offline copy's
/// first while the hub sends none; a feed request refused `not_found` is the conversation gone. Reachability follows
/// the Chats tab's gate, its copy unchanged.
///
/// A turn whose echo did not come within the patience, and that the outbox took back, throws `ChatConnectionError`
/// (`RelayAnswerLost`): the shared model resends it under the same client key, which the hub hands to the engine
/// (`chat_messages.client_key`), so it is applied once whatever reached the Mac. A turn the outbox could not take back
/// waits for its echo, "Waiting for your Mac…" (`ChatsCenter.hold`). A new chat is created by its first turn
/// (`createsConversationOnTurn`), so the send is kept in `chat_outgoing` from the start.
@MainActor
@Observable
final class RelayChatClient: ChatClient {
    static let answeringLine = "Sending your answer…"
    static let changedLine = "The action changed — look again"
    /// The relay's cap on a search query (Go `MaxChatSearchQuery`, runes).
    static let maxSearchQuery = 200
    /// The open feed's request goes again this often while a screen shows it (the hub watches a feed for a while).
    static let repeatInterval: Duration = .seconds(60)
    /// How long a page or a search waits for its record, and an opened chat for its feed ("The Mac did not answer").
    static let recordPatience: Duration = .seconds(30)

    /// The approvals whose answer is on its way (agent action ids): their buttons are off.
    private(set) var answering: Set<Int64> = []
    /// The last refusal of an answer, by agent action id.
    private(set) var approvalFailures: [Int64: ScopedFailure] = [:]

    /// An answer's failure, kept only while the action is as it was when the answer went (its status, error and
    /// dismissal): once the feed moves, "Didn't confirm" or the refusal clears and the card offers what the action
    /// offers now (mobile Inbox spec §12.9).
    struct ScopedFailure: Equatable {
        let failure: ChatActionFailure
        let fingerprint: String
    }

    /// What an answer's failure is scoped to.
    static func fingerprint(status: String, error: String, dismissedAt: String) -> String {
        "\(status)|\(dismissedAt)|\(error)"
    }

    /// A stored failure goes for good once the feed shows its action in another state (§12.9): a later return to the
    /// same status and error is a new state of the action, not the one the answer failed on.
    private func dropMovedFailures(_ snapshot: ChatsSnapshot) {
        guard !approvalFailures.isEmpty else { return }
        for entry in snapshot.feeds.values {
            for action in entry.feed.actions {
                guard let scoped = approvalFailures[action.id] else { continue }
                let now = Self.fingerprint(status: action.status, error: action.error, dismissedAt: action.dismissedAt)
                if now != scoped.fingerprint { approvalFailures[action.id] = nil }
            }
        }
    }

    /// The action's failure while the feed still shows it as it was when the answer went.
    func failure(for payload: ChatApprovalPayload) -> ChatActionFailure? {
        guard let scoped = approvalFailures[payload.id],
              scoped.fingerprint == Self.fingerprint(status: payload.status, error: payload.error, dismissedAt: payload.dismissedAt)
        else { return nil }
        return scoped.failure
    }
    /// The opened chats whose feed did not come within `recordPatience` of their request.
    private(set) var unanswered: Set<Int64> = []

    /// Weak: the center owns this client (a task of the client may outlive a center a test let go).
    @ObservationIgnored private weak var center: ChatsCenter?
    /// The center's sender (the outbox), for the requests a turn does not cover.
    @ObservationIgnored private let actions: ChatSender
    @ObservationIgnored private let sender: ChatSendCoordinator
    @ObservationIgnored private let replica: ReplicaStore?
    @ObservationIgnored private let offline: ChatOfflineCopy
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var current: ChatReachability = .offline(reason: "")
    /// The hub on screen (a Mac or a server tower): the lines that name it say so (`ChatText`).
    @ObservationIgnored private var host = TowerHost.mac
    @ObservationIgnored private var reachabilityWatches: [UUID: AsyncStream<ChatReachability>.Continuation] = [:]
    @ObservationIgnored private var feedWatches: [UUID: FeedWatch] = [:]
    @ObservationIgnored private var listWatches: [UUID: ListWatch] = [:]
    /// Streams that ended before they were registered.
    @ObservationIgnored private var ended: Set<UUID> = []
    /// The newest `chat_feed_request` per conversation (its outbox id): refused `not_found`, the chat is gone.
    @ObservationIgnored private var feedRequests: [Int64: String] = [:]
    @ObservationIgnored private var repeats: [Int64: Task<Void, Never>] = [:]
    @ObservationIgnored private var recordWaiters: [UUID: RecordWaiter] = [:]
    @ObservationIgnored private var feedPatience: [Int64: Task<Void, Never>] = [:]
    /// New-chat screens, which follow the chat their first turn creates as soon as `chat_new` is applied.
    @ObservationIgnored private var newChatScreens: [WeakConversation] = []
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "RelayChatClient")

    private struct FeedWatch {
        let conversation: Int64
        let continuation: AsyncStream<ChatFeedUpdate>.Continuation
        var shown: ChatFeed?
        var gone = false
    }

    private struct ListWatch {
        let continuation: AsyncStream<ChatListUpdate>.Continuation
        var shown: ChatList?
    }

    private struct WeakConversation {
        weak var model: ChatConversationModel?
    }

    private struct RecordWaiter {
        let actionID: String
        let read: @MainActor () -> ChatEchoResult?
        let continuation: CheckedContinuation<ChatEcho, Never>
    }

    /// `replica` is the hub's replica (nil before the session observes one, in the screenshot tour and in tests);
    /// `sleep` times the feed's repeat and the records' patience.
    init(
        center: ChatsCenter,
        sender: ChatSendCoordinator,
        replica: ReplicaStore?,
        offline: ChatOfflineCopy,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.center = center
        actions = center.sender
        self.sender = sender
        self.replica = replica
        self.offline = offline
        self.sleep = sleep
    }

    nonisolated var createsConversationOnTurn: Bool { true }

    /// A new chat's screen: it adopts the chat its first turn creates.
    func follow(_ model: ChatConversationModel) {
        newChatScreens = newChatScreens.filter { $0.model != nil } + [WeakConversation(model: model)]
    }

    /// The center's snapshot now (empty once the center is gone).
    private var snapshot: ChatsSnapshot { center?.snapshot ?? ChatsSnapshot() }

    private func newChatCreated(_ id: Int64) {
        newChatScreens = newChatScreens.filter { $0.model != nil }
        newChatScreens.first { $0.model?.conversationID == nil }?.model?.adopt(id)
    }

    // MARK: - Reachability

    /// The Chats tab's gate as reachability: chat answers while the hub does and the gate lets the tab work; every
    /// other state is `.offline` with the gate's own words — a state that keeps chat off by its title ("Chat is off
    /// for this phone"), the hub away by its banner or its line ("Your Mac is asleep…").
    nonisolated static func reachability(for gate: ChatsGateModel) -> ChatReachability {
        let working: Set<ChatsGateModel.State> = [.ready, .empty, .loading, .error]
        if gate.online, working.contains(gate.state) { return .connected }
        let off: Set<ChatsGateModel.State> = [.needsUpdate, .turnedOff, .needsRelay, .notAllowed, .unavailable]
        let reason = off.contains(gate.state) ? gate.title : gate.banner ?? gate.line
        return .offline(reason: reason ?? "")
    }

    func setGate(_ gate: ChatsGateModel, host: TowerHost = .mac) {
        self.host = host
        let next = Self.reachability(for: gate)
        guard next != current else { return }
        current = next
        reachabilityWatches.values.forEach { $0.yield(next) }
        guard next == .connected else { return }
        // Back: every watched feed is asked for again.
        Set(feedWatches.values.map(\.conversation)).forEach(requestFeed)
    }

    nonisolated var reachability: AsyncStream<ChatReachability> {
        let (stream, continuation) = AsyncStream.makeStream(of: ChatReachability.self)
        let id = UUID()
        continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.endReachability(id) } }
        Task { @MainActor [weak self] in self?.startReachability(id, continuation) }
        return stream
    }

    private func startReachability(_ id: UUID, _ continuation: AsyncStream<ChatReachability>.Continuation) {
        guard ended.remove(id) == nil else { return }
        reachabilityWatches[id] = continuation
        continuation.yield(current)
    }

    private func endReachability(_ id: UUID) {
        if reachabilityWatches.removeValue(forKey: id) == nil { ended.insert(id) }
    }

    private var isConnected: Bool { current == .connected }

    private var offlineRefusal: ChatEcho {
        if case let .offline(reason) = current, !reason.isEmpty { return .refused(code: "unreachable", message: reason) }
        return .refused(code: "unreachable", message: ChatSendCoordinator.couldNotSend)
    }

    // MARK: - Feeds and the list

    nonisolated func feed(_ conversation: Int64) -> AsyncStream<ChatFeedUpdate> {
        let (stream, continuation) = AsyncStream.makeStream(of: ChatFeedUpdate.self)
        let id = UUID()
        continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.endFeed(id) } }
        Task { @MainActor [weak self] in self?.startFeed(id, conversation, continuation) }
        return stream
    }

    nonisolated func list() -> AsyncStream<ChatListUpdate> {
        let (stream, continuation) = AsyncStream.makeStream(of: ChatListUpdate.self)
        let id = UUID()
        continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.endList(id) } }
        Task { @MainActor [weak self] in self?.startList(id, continuation) }
        return stream
    }

    private func startFeed(_ id: UUID, _ conversation: Int64, _ continuation: AsyncStream<ChatFeedUpdate>.Continuation) {
        guard ended.remove(id) == nil else { return }
        var watch = FeedWatch(conversation: conversation, continuation: continuation)
        if let first = snapshot.feeds[conversation]?.feed ?? replicaFeed(conversation) ?? heldFeed(conversation) {
            continuation.yield(.snapshot(first))
            watch.shown = first
        }
        feedWatches[id] = watch
        do {
            try offline.markOpened(conversationID: conversation)
        } catch {
            Self.logger.warning("chat copy open not marked: \(String(describing: type(of: error)), privacy: .public)")
        }
        requestFeed(conversation)
        guard repeats[conversation] == nil else { return }
        repeats[conversation] = Task { [weak self, sleep] in
            while !Task.isCancelled {
                do { try await sleep(Self.repeatInterval) } catch { return }
                self?.requestFeed(conversation)
            }
        }
    }

    private func endFeed(_ id: UUID) {
        guard let watch = feedWatches.removeValue(forKey: id) else {
            ended.insert(id)
            return
        }
        guard !feedWatches.values.contains(where: { $0.conversation == watch.conversation }) else { return }
        repeats.removeValue(forKey: watch.conversation)?.cancel()
    }

    private func startList(_ id: UUID, _ continuation: AsyncStream<ChatListUpdate>.Continuation) {
        guard ended.remove(id) == nil else { return }
        let list = snapshot.list
        if let list { continuation.yield(.snapshot(list)) }
        listWatches[id] = ListWatch(continuation: continuation, shown: list)
    }

    private func endList(_ id: UUID) {
        if listWatches.removeValue(forKey: id) == nil { ended.insert(id) }
    }

    /// `chat_feed_request open`: the hub publishes the feed while the phone watches it. Nothing while the hub is away.
    private func requestFeed(_ conversation: Int64) {
        guard isConnected else { return }
        Task {
            do {
                feedRequests[conversation] = try await actions(ChatFeedRequestParams(conversationID: conversation, purpose: .open))
            } catch {
                Self.logger.warning("chat feed request not queued: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
        guard snapshot.feeds[conversation] == nil, feedPatience[conversation] == nil else { return }
        feedPatience[conversation] = Task { [weak self, sleep] in
            do { try await sleep(Self.recordPatience) } catch { return }
            guard let self else { return }
            self.feedPatience[conversation] = nil
            if self.snapshot.feeds[conversation] == nil { self.unanswered.insert(conversation) }
        }
    }

    /// "The Mac did not answer" → Retry: the feed is asked for again, with a fresh patience.
    func retryFeed(_ conversation: Int64) {
        unanswered.remove(conversation)
        requestFeed(conversation)
    }

    /// The replica's `chat_feed` record, read when the center has not delivered it yet.
    private func replicaFeed(_ conversation: Int64) -> ChatFeed? {
        guard let replica else { return nil }
        let name = ChatFeed.recordName(conversationID: conversation)
        let payload = try? replica.reader.read { db in try replica.payload(forRecordName: name, from: db) }
        return payload.flatMap { try? ChatFeed.decode(payload: $0) }
    }

    private func heldFeed(_ conversation: Int64) -> ChatFeed? {
        do {
            return try offline.held(conversationID: conversation)?.feed
        } catch {
            Self.logger.warning("chat copy not read: \(String(describing: type(of: error)), privacy: .public)")
            return nil
        }
    }

    /// The center's snapshot moved: each feed and the list yield what changed, a refused feed request ends its feed
    /// as gone, and a page or a search waiting for its record hears it.
    func snapshotChanged() {
        let snapshot = self.snapshot
        dropMovedFailures(snapshot)
        let gone = Set(feedRequests.compactMap { conversation, action in
            snapshot.failures[action]?.reason == .notFound ? conversation : nil
        })
        gone.forEach { feedRequests[$0] = nil }
        for conversation in unanswered where snapshot.feeds[conversation] != nil {
            unanswered.remove(conversation)
        }
        for (id, var watch) in feedWatches {
            if gone.contains(watch.conversation), !watch.gone {
                watch.gone = true
                watch.shown = nil
                watch.continuation.yield(.gone)
            } else if let feed = snapshot.feeds[watch.conversation]?.feed, feed != watch.shown {
                watch.gone = false
                watch.shown = feed
                watch.continuation.yield(.snapshot(feed))
            }
            feedWatches[id] = watch
        }
        for (id, var watch) in listWatches {
            guard let list = snapshot.list, list != watch.shown else { continue }
            watch.shown = list
            watch.continuation.yield(.snapshot(list))
            listWatches[id] = watch
        }
        for (id, waiter) in recordWaiters {
            if let result = waiter.read() {
                resolve(id, .applied(result))
            } else if let failure = snapshot.failures[waiter.actionID] {
                resolve(id, Self.refusal(failure.reason, failure.message))
            }
        }
    }

    // MARK: - Operations

    func send(_ op: ChatOperation) async throws -> ChatEcho {
        if let local = localAnswer(op) { return local }
        guard isConnected else { return offlineRefusal }
        switch op {
        case let .turn(request):
            return try await turn(request)
        case let .new(projectID, routing):
            return await request(op, ChatNewParams(clientKey: UUID().uuidString, projectID: projectID, routing: routing))
        case let .cancel(conversationID, turnID):
            return await request(op, ChatCancelParams(conversationID: conversationID, turnID: turnID))
        case let .page(conversationID, before):
            return await awaitRecord(ChatPageParams(conversationID: conversationID, beforeMessageID: before)) { [weak self] in
                self?.page(conversationID, before: before).map { .page($0) }
            }
        case let .search(query):
            let asked = Self.searchQuery(query)
            return await awaitRecord(ChatSearchParams(query: asked)) { [weak self] in
                self?.snapshot.searches[asked].map { .search($0) }
            }
        case let .read(conversationID, messageID):
            return await request(op, ChatReadParams(conversationID: conversationID, messageID: messageID))
        case let .branchSelect(messageID):
            return await request(op, ChatBranchSelectParams(messageID: messageID))
        case let .manage(conversationID, manage, title, _):
            return await request(op, ChatManageParams(conversationID: conversationID, op: manage, title: title))
        case let .attach(conversationID, .sealedUpload(upload)):
            return await attach(upload, conversationID: conversationID)
        case let .entitySearch(query, kinds):
            return await request(op, ChatEntitySearchParams(query: query, kinds: kinds))
        case .skillsList:
            return await request(op, ChatSkillsListParams())
        case .project, .artifact, .attach(_, .path), .attachDiscard, .shutdown, .warm, .retireSessions:
            // Answered by localAnswer; listed so a new operation is a compile error here.
            return unsupported
        }
    }

    /// What the phone answers itself, connected or not: a held page, a search record already here, and the
    /// operations the relay does not carry (§6.4: project editing, artifact comments, Add to Knowledge and Mac files
    /// are the Mac's shell; `continue`, a move between projects, archive, discard, warm and session retire have no relay
    /// kind).
    private func localAnswer(_ op: ChatOperation) -> ChatEcho? {
        switch op {
        case let .page(conversationID, before):
            return page(conversationID, before: before).map { .applied(.page($0)) }
        case let .search(query):
            return snapshot.searches[Self.searchQuery(query)].map { .applied(.search($0)) }
        case .attachDiscard:
            // The hub drops an attachment no turn took; the phone's plaintext went when it was uploaded.
            return .applied(.none)
        case let .turn(request) where request.mode == .continue:
            return unsupported
        case .manage(_, .move, _, _), .manage(_, .archive, _, _), .manage(_, .discard, _, _), .project, .artifact,
             .attach(_, .path), .shutdown:
            return unsupported
        case .warm, .retireSessions:
            // The tower's own session pool; the hub carries neither.
            return unsupported
        default:
            return nil
        }
    }

    /// The query as the relay takes it: trimmed and cut at its cap.
    static func searchQuery(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(String.UnicodeScalarView(trimmed.unicodeScalars.prefix(maxSearchQuery)))
    }

    private var unsupported: ChatEcho { .refused(code: "unsupported", message: ChatText.onlyOnTower(host)) }

    /// A turn through the coordinator: kept in the hub's copy until its echo is applied; a refusal leaves the text in
    /// the `ChatUI` composer (the draft store is left alone). Retry is the relay's regenerate of that answer.
    private func turn(_ request: ChatTurnRequest) async throws -> ChatEcho {
        let mode = request.mode == .retry ? ChatTurnMode.regenerate : request.mode
        // The files staged on the phone (the composer's pills) go with a send or an edit, uploaded first.
        let files = mode == .send || mode == .edit ? center?.drafts.draft(request.conversationID).attachments ?? [] : []
        let draft = request.draft.map { draft in
            ChatDraft(text: draft.text, quotes: draft.quotes.map { ChatQuoteDraft(quote: $0, comment: "") })
        }
        let send = ChatSendCoordinator.Request(
            conversationID: request.conversationID, mode: mode, messageID: request.messageID, text: request.text,
            attachments: files, projectID: request.projectID, routing: request.routing, draft: draft,
            attachmentIDs: request.attachmentIDs, compose: request.compose, restoresDraft: false
        )
        let outcome = await sender.sendTurn(send, clientKey: request.clientKey) { [weak self] id in self?.newChatCreated(id) }
        switch outcome {
        case let .applied(conversation, result):
            guard case .turn(let started)? = Self.decode(.turn(request), result) else { return .applied(.none) }
            return .applied(.turn(ChatTurnStarted(
                userMessageID: started.userMessageID, assistantMessageID: started.assistantMessageID, turnID: started.turnID,
                conversationID: request.conversationID == 0 ? conversation : nil
            )))
        case let .refused(reason, message):
            return Self.refusal(reason, message)
        case .lost:
            throw RelayAnswerLost()
        }
    }

    private func request<P: ActionParams>(_ op: ChatOperation, _ params: P) async -> ChatEcho {
        switch await sender.request(params) {
        case let .applied(result): .applied(Self.decode(op, result) ?? .none)
        case let .failed(failure): Self.refusal(failure.reason, failure.message)
        case .lost: .refused(code: "unreachable", message: ChatSendCoordinator.couldNotSend)
        }
    }

    private func attach(_ upload: ChatSealedUpload, conversationID: Int64) async -> ChatEcho {
        let payload = ChatAttachmentUploadPayload(
            uploadID: upload.uploadID, conversationID: conversationID, name: upload.name, mime: upload.mime, size: upload.size
        )
        guard let echo = await sender.upload(payload, file: upload.file) else {
            return .refused(code: "unreachable", message: ChatSendCoordinator.couldNotSend)
        }
        if echo.status == .applied, let id = echo.attachmentID { return .applied(.attachment(id: id)) }
        return .refused(code: "invalid", message: echo.errorMessage ?? ChatSendCoordinator.couldNotSend)
    }

    /// Asks for a record (a page, a search) and waits for it to reach the replica, for the action's refusal, or for
    /// the patience.
    private func awaitRecord<P: ActionParams>(_ params: P, read: @escaping @MainActor () -> ChatEchoResult?) async -> ChatEcho {
        let actionID: String
        do {
            actionID = try await actions(params)
        } catch {
            Self.logger.warning("chat record request not queued: \(String(describing: type(of: error)), privacy: .public)")
            return .refused(code: "unreachable", message: ChatSendCoordinator.couldNotSend)
        }
        if let result = read() { return .applied(result) }
        let id = UUID()
        let timer = Task { [weak self, sleep] in
            do { try await sleep(Self.recordPatience) } catch { return }
            guard let self else { return }
            self.resolve(id, .refused(code: "unreachable", message: ChatText.noAnswerRetry(self.host)))
        }
        let echo = await withCheckedContinuation { continuation in
            recordWaiters[id] = RecordWaiter(actionID: actionID, read: read, continuation: continuation)
        }
        timer.cancel()
        return echo
    }

    private func resolve(_ id: UUID, _ echo: ChatEcho) {
        recordWaiters.removeValue(forKey: id)?.continuation.resume(returning: echo)
    }

    /// A page the replica or the copy holds: before `before` in `conversationID`.
    private func page(_ conversationID: Int64, before: Int64) -> ChatPage? {
        if let page = snapshot.pages[conversationID]?[before]?.page { return page }
        return (try? offline.held(conversationID: conversationID))?.pages[before]
    }

    // MARK: - Approvals

    /// Approve or Reject (`chat_action_answer` with the hash the card shows; spec §4.5): once per action while its
    /// answer is on its way, never without the `permissions` grant (the card has no buttons then), never while the hub
    /// is away. A stale hash comes back as "The action changed — look again".
    func decide(_ payload: ChatApprovalPayload, _ decision: ChatApprovalDecision, permissions: Bool) async {
        await decide(ChatAgentAction(payload: payload), decision, permissions: permissions)
    }

    /// The shared card's answer: the action it showed, pinned to the digest the hub sent (AGENT-07). Retry and Dismiss
    /// (mobile Inbox spec §12.9) go only to a hub whose heartbeat has `chat_actions` (`retryDismiss`), only on the
    /// action that offers them, and never while the hub is away (nothing queues, ask #1570).
    func decide(_ action: ChatAgentAction, _ decision: ChatApprovalDecision, permissions: Bool, retryDismiss: Bool = false) async {
        guard permissions, isConnected, !answering.contains(action.id),
              Self.mayAnswer(action, decision, retryDismiss: retryDismiss) else { return }
        let digest = action.approveDigest ?? ""
        answering.insert(action.id)
        approvalFailures[action.id] = nil
        defer { answering.remove(action.id) }
        let fingerprint = Self.fingerprint(status: action.status, error: action.error, dismissedAt: action.dismissedAt)
        let params = ChatActionAnswerParams(actionID: action.id, decision: Self.wire(decision), argsSHA256: digest)
        switch await sender.request(params) {
        case .applied:
            break
        case let .failed(failure):
            approvalFailures[action.id] = ScopedFailure(failure: failure, fingerprint: fingerprint)
        case .lost:
            approvalFailures[action.id] = ScopedFailure(
                failure: ChatActionFailure(reason: nil, message: ChatSendCoordinator.couldNotSend), fingerprint: fingerprint)
        }
    }

    /// Whether `decision` may go for `action`: Approve (with a digest to pin) and Reject on a pending action; Retry and
    /// Dismiss where the card offers them, to a hub that takes them.
    static func mayAnswer(_ action: ChatAgentAction, _ decision: ChatApprovalDecision, retryDismiss: Bool) -> Bool {
        switch decision {
        case .approve: action.isPending && action.approveDigest != nil
        case .reject: action.isPending
        case .retry: retryDismiss && AgentActionCard.settledOffer(for: action) == .retry
        case .dismiss: retryDismiss && AgentActionCard.settledOffer(for: action) == .dismiss
        }
    }

    static func wire(_ decision: ChatApprovalDecision) -> ChatActionDecision {
        switch decision {
        case .approve: .approve
        case .reject: .reject
        case .retry: .retry
        case .dismiss: .dismiss
        }
    }

    /// The card of one action as this phone may answer it.
    func approvalCard(_ payload: ChatApprovalPayload, permissions: Bool, host: TowerHost, retryDismiss: Bool = false) -> ChatApprovalCardModel {
        ChatApprovalCardModel(
            payload: payload, permissions: permissions, online: isConnected, inFlight: answering.contains(payload.id),
            failure: failure(for: payload), host: host, retryDismiss: retryDismiss
        )
    }

    /// The shared card's state for the action it shows (its id, status, tool, error and dismissal are what the state
    /// reads).
    func approvalCard(_ action: ChatAgentAction, permissions: Bool, host: TowerHost, retryDismiss: Bool = false) -> ChatApprovalCardModel {
        approvalCard(ChatApprovalPayload(id: action.id, tool: action.tool, title: "", argsDisplay: action.argsJSON,
                                         argsSHA256: action.argsSHA256, status: action.status, error: action.error,
                                         turnID: action.turnID, argsComplete: action.argsComplete,
                                         dismissedAt: action.dismissedAt),
                     permissions: permissions, host: host, retryDismiss: retryDismiss)
    }

    // MARK: - Echo mapping

    /// An applied echo's result as `ChatOperation` reads it (the relay results use the chat.sock shapes).
    private static func decode(_ op: ChatOperation, _ result: [String: JSONValue]?) -> ChatEchoResult? {
        guard let result, let data = try? JSONEncoder().encode(result) else { return nil }
        return try? op.decodeResult(data)
    }

    /// A relay refusal as a `ChatEcho` code: conversation_busy, not_found, invalid, forbidden, unsupported, internal; no reason
    /// (never sent, or no echo within the patience) is unreachable.
    static func refusal(_ reason: ActionReason?, _ message: String) -> ChatEcho {
        let code = switch reason {
        // The hub's own busy message is shown (ChatUI shows its generic line for "busy").
        case .conversationBusy?: "conversation_busy"
        case .notFound?: "not_found"
        case .invalidParams?, .attachmentMissing?, .changed?: "invalid"
        case .deviceNotAllowed?: "forbidden"
        case .notSupported?: "unsupported"
        case nil: "unreachable"
        default: "internal"
        }
        return .refused(code: code, message: message.isEmpty ? ChatSendCoordinator.couldNotSend : message)
    }
}

/// A turn's echo did not come and the outbox took the action back: the shared model sends it again under the same
/// client key.
struct RelayAnswerLost: ChatConnectionError {}
