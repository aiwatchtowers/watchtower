import ChatUI
import ChatWire
import Foundation
import Observation
import os
import WatchtowerKit
import WatchtowerSync

/// The phone's `ChatClient` (unified chat spec §6.3): the `ChatUI` screens run on the Mac's engine through the hub's
/// relay adapter. A turn goes through `ChatSendCoordinator` (kept in `chat_outgoing` until applied, CHAT-01's phone
/// half); every other operation is its relay action kind, its echo awaited; `chat_page` and `chat_search` answer with a
/// record the replica receives. A feed is the conversation's `chat_feed` record, each one a snapshot, the offline copy's
/// first while the hub sends none; a feed request refused `not_found` is the conversation gone. Reachability follows
/// the Chats tab's gate, its copy unchanged.
///
/// No operation throws `ChatConnectionError`: the outbox sends an action at most once and a send the patience gives up
/// on is one the outbox took back (never on the hub), so it is a refusal with the text kept, never a resend.
@MainActor
@Observable
final class RelayChatClient: ChatClient {
    static let unsupportedLine = "This works in Watchtower on your Mac."
    static let noAnswerLine = "No answer came from your Mac. Try again."
    static let answeringLine = "Sending your answer…"
    static let changedLine = "The action changed — look again"
    /// The open feed's request goes again this often while a screen shows it (the hub watches a feed for a while).
    static let repeatInterval: Duration = .seconds(60)
    /// How long a page or a search waits for its record.
    static let recordPatience: Duration = .seconds(30)

    /// What the last Approve or Reject came to (nil once applied): the line the conversation shows over the feed.
    private(set) var approvalNotice: String?

    @ObservationIgnored private unowned let center: ChatsCenter
    @ObservationIgnored private let sender: ChatSendCoordinator
    @ObservationIgnored private let replica: ReplicaStore?
    @ObservationIgnored private let offline: ChatOfflineCopy
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var current: ChatReachability = .offline(reason: "")
    @ObservationIgnored private var reachabilityWatches: [UUID: AsyncStream<ChatReachability>.Continuation] = [:]
    @ObservationIgnored private var feedWatches: [UUID: FeedWatch] = [:]
    @ObservationIgnored private var listWatches: [UUID: ListWatch] = [:]
    /// Streams that ended before they were registered.
    @ObservationIgnored private var ended: Set<UUID> = []
    /// The newest `chat_feed_request` per conversation (its outbox id): refused `not_found`, the chat is gone.
    @ObservationIgnored private var feedRequests: [Int64: String] = [:]
    @ObservationIgnored private var repeats: [Int64: Task<Void, Never>] = [:]
    @ObservationIgnored private var recordWaiters: [UUID: RecordWaiter] = [:]
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
        self.sender = sender
        self.replica = replica
        self.offline = offline
        self.sleep = sleep
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

    func setGate(_ gate: ChatsGateModel) {
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
        if let first = center.snapshot.feeds[conversation]?.feed ?? replicaFeed(conversation) ?? heldFeed(conversation) {
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
        let list = center.snapshot.list
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
                feedRequests[conversation] = try await center.sender(ChatFeedRequestParams(conversationID: conversation, purpose: .open))
            } catch {
                Self.logger.warning("chat feed request not queued: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
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
        let snapshot = center.snapshot
        let gone = Set(feedRequests.compactMap { conversation, action in
            snapshot.failures[action]?.reason == .notFound ? conversation : nil
        })
        gone.forEach { feedRequests[$0] = nil }
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
            return await turn(request)
        case let .new(projectID, routing):
            return await request(op, ChatNewParams(clientKey: UUID().uuidString, projectID: projectID, routing: routing))
        case let .cancel(conversationID, turnID):
            return await request(op, ChatCancelParams(conversationID: conversationID, turnID: turnID))
        case let .page(conversationID, before):
            return await awaitRecord(ChatPageParams(conversationID: conversationID, beforeMessageID: before)) { [weak self] in
                self?.page(conversationID, before: before).map { .page($0) }
            }
        case let .search(query):
            return await awaitRecord(ChatSearchParams(query: query)) { [weak self] in
                self?.center.snapshot.searches[query].map { .search($0) }
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
        case .project, .artifact, .attach(_, .path), .attachDiscard, .shutdown:
            // Answered by localAnswer; listed so a new operation is a compile error here.
            return Self.unsupported
        }
    }

    /// What the phone answers itself, connected or not: a held page, a search record already here, and the
    /// operations the relay does not carry (§6.4: project editing, artifact comments, Add to Knowledge and Mac files
    /// are the Mac's shell; `continue` and a move between projects have no relay kind).
    private func localAnswer(_ op: ChatOperation) -> ChatEcho? {
        switch op {
        case let .page(conversationID, before):
            return page(conversationID, before: before).map { .applied(.page($0)) }
        case let .search(query):
            return center.snapshot.searches[query].map { .applied(.search($0)) }
        case .attachDiscard:
            // The hub drops an attachment no turn took; the phone's plaintext went when it was uploaded.
            return .applied(.none)
        case let .turn(request) where request.mode == .continue:
            return Self.unsupported
        case .manage(_, .move, _, _), .project, .artifact, .attach(_, .path), .shutdown:
            return Self.unsupported
        default:
            return nil
        }
    }

    private static var unsupported: ChatEcho { .refused(code: "unsupported", message: unsupportedLine) }

    /// A turn through the coordinator: kept in the hub's copy until its echo is applied; a refusal leaves the text in
    /// the `ChatUI` composer (the draft store is left alone). Retry is the relay's regenerate of that answer.
    private func turn(_ request: ChatTurnRequest) async -> ChatEcho {
        let send = ChatSendCoordinator.Request(
            conversationID: request.conversationID, mode: request.mode == .retry ? .regenerate : request.mode,
            messageID: request.messageID, text: request.text, attachmentIDs: request.attachmentIDs, restoresDraft: false
        )
        switch await sender.sendTurn(send, clientKey: request.clientKey) {
        case let .applied(_, result):
            return .applied(Self.decode(.turn(request), result) ?? .none)
        case let .refused(reason, message):
            return Self.refusal(reason, message)
        }
    }

    private func request<P: ActionParams>(_ op: ChatOperation, _ params: P) async -> ChatEcho {
        switch await sender.request(params) {
        case let .applied(result): .applied(Self.decode(op, result) ?? .none)
        case let .failed(failure): Self.refusal(failure.reason, failure.message)
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
            actionID = try await center.sender(params)
        } catch {
            Self.logger.warning("chat record request not queued: \(String(describing: type(of: error)), privacy: .public)")
            return .refused(code: "unreachable", message: ChatSendCoordinator.couldNotSend)
        }
        if let result = read() { return .applied(result) }
        let id = UUID()
        let timer = Task { [weak self, sleep] in
            do { try await sleep(Self.recordPatience) } catch { return }
            self?.resolve(id, .refused(code: "unreachable", message: Self.noAnswerLine))
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
        if let page = center.snapshot.pages[conversationID]?[before]?.page { return page }
        return (try? offline.held(conversationID: conversationID))?.pages[before]
    }

    // MARK: - Approvals

    /// Approve or Reject (`chat_action_answer` with the hash the card shows; spec §4.5). Without the `permissions`
    /// grant nothing is sent and the line points to the hub; a stale hash comes back as "The action changed".
    func decide(_ payload: ChatApprovalPayload, _ decision: ChatApprovalDecision, permissions: Bool, host: TowerHost) async {
        guard permissions else {
            approvalNotice = ChatText.approveElsewhere(host)
            return
        }
        guard isConnected else {
            if case let .refused(_, line) = offlineRefusal { approvalNotice = line }
            return
        }
        approvalNotice = Self.answeringLine
        let params = ChatActionAnswerParams(
            actionID: payload.id, decision: decision == .approve ? .approve : .reject, argsSHA256: payload.argsSHA256
        )
        switch await sender.request(params) {
        case .applied:
            approvalNotice = nil
        case let .failed(failure):
            approvalNotice = failure.reason == .changed
                ? Self.changedLine : (failure.message.isEmpty ? ChatSendCoordinator.couldNotSend : failure.message)
        }
    }

    // MARK: - Echo mapping

    /// An applied echo's result as `ChatOperation` reads it (the relay results use the chat.sock shapes).
    private static func decode(_ op: ChatOperation, _ result: [String: JSONValue]?) -> ChatEchoResult? {
        guard let result, let data = try? JSONEncoder().encode(result) else { return nil }
        return try? op.decodeResult(data)
    }

    /// A relay refusal as a `ChatEcho` code: busy, not_found, invalid, forbidden, unsupported, internal; no reason
    /// (never sent, or no echo within the patience) is unreachable.
    static func refusal(_ reason: ActionReason?, _ message: String) -> ChatEcho {
        let code = switch reason {
        case .conversationBusy?: "busy"
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
