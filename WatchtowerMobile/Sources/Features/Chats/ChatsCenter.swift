import ChatUI
import ChatWire
import Foundation
import GRDB
import Observation
import os
import UIKit
import WatchtowerChatText
import WatchtowerKit
import WatchtowerSync

/// A chat screen pushed on the Chats tab's stack (iPhone chat spec §6.2): one conversation, or a new chat (`new`).
/// `messageID` is a search hit's message, which the conversation screen scrolls to.
struct ChatRoute: Hashable {
    /// 0 is a new chat, as on the hub (`chat_feed_request` id 0 names no conversation).
    let id: Int64
    var messageID: Int64?

    static let new = Self(id: 0)

    var isNew: Bool { id == 0 }
}

/// Sends one chat action through the hub's outbox and returns its action id (the key its echo comes back under).
/// Chat actions carry no entity (spec §4.5).
struct ChatSender {
    let send: @MainActor (ActionKind, [String: JSONValue]) async throws -> String

    @MainActor
    @discardableResult
    func callAsFunction<P: ActionParams>(_ params: P) async throws -> String {
        try await send(P.actionKind, try params.wireParams())
    }

    @MainActor
    static func through(_ outbox: ActionOutbox) -> Self {
        Self { kind, params in
            try await outbox.enqueue(kind: kind, entityRecordName: nil, params: params)
        }
    }
}

/// A chat action the hub refused (its echo's reason and message).
struct ChatActionFailure: Equatable, Sendable {
    let reason: ActionReason?
    let message: String
}

/// One `chat_feed` record as decoded, with the payload the offline copy keeps.
struct ChatFeedEntry: Equatable, Sendable {
    let feed: ChatFeed
    let payload: Data
}

/// One `chat_page` record as decoded, with the payload the offline copy keeps.
struct ChatPageEntry: Equatable, Sendable {
    let page: ChatPage
    let payload: Data
}

/// What the Chats tab reads from this hub's replica in one snapshot: the `chat_list` record, the `chat_search`
/// records by the query they answer, the watched and prefetched feeds and the pages, the chat actions the hub
/// refused, and the newest chat action the hub refused for want of the `chat` grant.
struct ChatsSnapshot: Equatable {
    var list: ChatList?
    var searches: [String: ChatSearch] = [:]
    /// The refusal's message while the newest chat action this phone sent was refused with `device_not_allowed`.
    var refusal: String?
    /// `chat_feed` records by conversation.
    var feeds: [Int64: ChatFeedEntry] = [:]
    /// `chat_page` records by conversation, then by the message they come before.
    var pages: [Int64: [Int64: ChatPageEntry]] = [:]
    /// The chat actions the hub refused, by action id.
    var failures: [String: ChatActionFailure] = [:]
    /// The chat actions still waiting in the outbox (no final echo yet), by action id.
    var queued: [String: QueuedChatAction] = [:]

    nonisolated static func read(
        from db: Database, store: ReplicaStore, cache: ReplicaDecodeCache, records: ChatRecordCache
    ) throws -> Self {
        let versions = try store.kindVersions([.chatList, .chatSearch], from: db)
        var snapshot = Self()
        snapshot.list = try cache.value(ChatList.recordName, version: versions[.chatList] ?? 0) {
            guard let payload = try store.payload(forRecordName: ChatList.recordName, from: db) else { return nil }
            return try? ChatList.decode(payload: payload)
        }
        snapshot.searches = try cache.value(SliceKind.chatSearch.rawValue, version: versions[.chatSearch] ?? 0) {
            let decoded = try store.payloads(of: .chatSearch, from: db).compactMap { try? ChatSearch.decode(payload: $0) }
            return Dictionary(decoded.map { ($0.query, $0) }) { _, newer in newer }
        }
        let seqs = try store.recordSeqs(of: .chatFeed, from: db).merging(try store.recordSeqs(of: .chatPage, from: db)) { $1 }
        try records.refresh(seqs) { name in try store.payload(forRecordName: name, from: db) }
        (snapshot.feeds, snapshot.pages) = records.decoded()
        let pending = try store.pendingActions(from: db)
        snapshot.refusal = Self.refusal(in: pending)
        snapshot.failures = Self.failures(in: pending)
        for row in pending where row.state == .pending && ChatsCenter.chatKinds.contains(row.action.kind) {
            snapshot.queued[row.id] = QueuedChatAction(kind: row.action.kind, params: row.action.params)
        }
        return snapshot
    }

    /// The newest chat action's refusal for the grant; nil when that action went or waits.
    nonisolated static func refusal(in pending: [PendingAction]) -> String? {
        guard let newest = pending.filter({ ChatsCenter.chatKinds.contains($0.action.kind) }).max(by: { $0.createdAt < $1.createdAt }),
              newest.state == .failed, newest.reason == .deviceNotAllowed
        else { return nil }
        return newest.errorMessage ?? ""
    }

    nonisolated static func failures(in pending: [PendingAction]) -> [String: ChatActionFailure] {
        var failures: [String: ChatActionFailure] = [:]
        for row in pending where row.state == .failed && ChatsCenter.chatKinds.contains(row.action.kind) {
            failures[row.id] = ChatActionFailure(reason: row.reason, message: row.errorMessage ?? "")
        }
        return failures
    }
}

/// The decoded chat feeds and pages by record name, each kept while its envelope's seq holds: a streaming feed
/// re-opens only itself, never the twenty prefetched ones beside it. Names gone from the replica leave with it.
final class ChatRecordCache: @unchecked Sendable {
    private enum Entry {
        case feed(Int64, ChatFeedEntry)
        case page(Int64, Int64, ChatPageEntry)
        case undecodable
    }

    private let lock = NSLock()
    private var entries: [String: (seq: Int64, entry: Entry)] = [:]
    private let notifications: NotificationCenter
    private var observers: [any NSObjectProtocol] = []

    /// Decoded chat text does not outlive the unlocked foreground (`ReplicaDecodeCache`'s rule): every entry goes
    /// at the lock and in the background, and the next read opens the records again.
    init(notifications: NotificationCenter = .default) {
        self.notifications = notifications
        observers = [
            UIApplication.protectedDataWillBecomeUnavailableNotification, UIApplication.didEnterBackgroundNotification
        ].map { name in
            notifications.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.dropAll() }
        }
    }

    deinit {
        for observer in observers {
            notifications.removeObserver(observer)
        }
    }

    func dropAll() {
        lock.withLock { entries = [:] }
    }

    /// Opens every name in `seqs` whose seq moved; drops the names no longer there.
    func refresh(_ seqs: [String: Int64], payload: (String) throws -> Data?) throws {
        let known = lock.withLock { entries.mapValues(\.seq) }
        var fresh: [String: (seq: Int64, entry: Entry)] = [:]
        for (name, seq) in seqs where known[name] != seq {
            guard let data = try payload(name) else { continue }
            fresh[name] = (seq, Self.decode(name: name, data: data))
        }
        lock.withLock {
            entries = entries.filter { seqs[$0.key] != nil }.merging(fresh) { $1 }
        }
    }

    func decoded() -> (feeds: [Int64: ChatFeedEntry], pages: [Int64: [Int64: ChatPageEntry]]) {
        lock.withLock {
            var feeds: [Int64: ChatFeedEntry] = [:]
            var pages: [Int64: [Int64: ChatPageEntry]] = [:]
            for (_, value) in entries {
                switch value.entry {
                case let .feed(id, entry): feeds[id] = entry
                case let .page(id, before, entry): pages[id, default: [:]][before] = entry
                case .undecodable: break
                }
            }
            return (feeds, pages)
        }
    }

    /// `chat_feed-<conversation>` and `chat_page-<conversation>-<before>`.
    private static func decode(name: String, data: Data) -> Entry {
        let parts = name.split(separator: "-").dropFirst().compactMap { Int64($0) }
        if name.hasPrefix(SliceKind.chatFeed.rawValue + "-"), parts.count == 1, let feed = try? ChatFeed.decode(payload: data) {
            return .feed(parts[0], ChatFeedEntry(feed: feed, payload: data))
        }
        if name.hasPrefix(SliceKind.chatPage.rawValue + "-"), parts.count == 2, let page = try? ChatPage.decode(payload: data) {
            return .page(parts[0], parts[1], ChatPageEntry(page: page, payload: data))
        }
        return .undecodable
    }
}

/// One hub's chats on the phone (iPhone chat spec §6, unified chat spec §6.3): the replica's chat records under one
/// observation, the sender every chat action goes through, the drafts, the sends with their uploads, the offline copy
/// with its prefetch, and the `ChatClient` the `ChatUI` screens run on (`RelayChatClient`) with the list's model.
/// Owned by the `HubSession`, so a pending delete or a send waiting for its echo survive the tab switch.
@MainActor
@Observable
final class ChatsCenter {
    nonisolated static let chatKinds: Set<ActionKind> = [
        .chatNew, .chatTurn, .chatCancel, .chatFeedRequest, .chatPage, .chatSearch, .chatRead, .chatBranchSelect,
        .chatManage, .chatActionAnswer, .chatEntitySearch, .chatSkillsList
    ]

    private(set) var snapshot = ChatsSnapshot()
    @ObservationIgnored let sender: ChatSender
    let drafts = ChatDraftStore()
    let sending: ChatSendCoordinator
    let copy: ChatOfflineCopy
    /// The hub's copy file did not open: the tab runs on an in-memory copy and says so (`copyNotice`).
    let copyUnavailable: Bool
    let prefetch: ChatPrefetcher
    /// Where picked files wait in plaintext until their upload is applied.
    @ObservationIgnored let staging: URL
    /// The Chats list's search field, kept with the hub like the list's model.
    var listQuery = ""
    @ObservationIgnored let decodeCache = ReplicaDecodeCache()
    @ObservationIgnored let recordCache = ChatRecordCache()
    @ObservationIgnored private var cancellable: ResilientObservation?
    /// The replica the observation reads (`start`); the client reads a record from it before the first snapshot.
    @ObservationIgnored private var replica: ReplicaStore?
    @ObservationIgnored private var relayClient: RelayChatClient?
    @ObservationIgnored private var chatList: ChatListModel?
    @ObservationIgnored private var reachability: (@MainActor () -> Bool)?
    /// The copy's writes, one after another: an older snapshot never overwrites a newer one.
    @ObservationIgnored private var copyWrites: Task<Void, Never>?
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "ChatsCenter")

    /// `sleep` times the sends' and the requests' patience, the feed's repeat, the prefetch and the list's Undo window;
    /// tests step it by hand.
    /// `copy` is the hub's offline copy (in memory when nil).
    init(
        sender: ChatSender,
        uploads: ChatUploads = .none,
        copy: ChatOfflineCopy? = nil,
        copyUnavailable: Bool = false,
        withdraw: @escaping ChatWithdraw = { _ in .withdrawn },
        staging: URL = ChatAttachmentPrep.stagingDirectory(hubID: "default"),
        now: @escaping @MainActor () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.sender = sender
        self.sleep = sleep
        let copy = copy ?? ChatOfflineCopy.inMemory()
        self.copy = copy
        self.copyUnavailable = copyUnavailable
        sending = ChatSendCoordinator(sender: sender, uploads: uploads, drafts: drafts, copy: copy, withdraw: withdraw, sleep: sleep)
        self.staging = staging
        prefetch = ChatPrefetcher(sender: sender, copy: copy, now: now, sleep: sleep)
        prefetch.onPatience = { [weak self] in self?.stepPrefetch() }
    }

    /// The Chats tab's line while the copy is off (nil otherwise).
    var copyNotice: String? { copyUnavailable ? ChatText.copyUnavailableLine : nil }

    /// The chat screens' client: the relay through this hub, built once.
    var client: RelayChatClient {
        if let relayClient { return relayClient }
        let client = RelayChatClient(center: self, sender: sending, replica: replica, offline: copy, sleep: sleep)
        relayClient = client
        return client
    }

    /// The Chats list's model, kept with the hub so a delete waiting for its Undo survives the tab switch.
    var listModel: ChatListModel {
        if let chatList { return chatList }
        let model = ChatListModel(client: client, clock: SleepClock(sleep: sleep))
        // The list the center holds now, so the first frame has its rows; the client's stream follows.
        if let list = snapshot.list { model.store.apply(.snapshot(list)) }
        chatList = model
        return model
    }

    /// The models of one conversation screen: a saved chat, or a new one (`ChatRoute.new`). The composer starts from
    /// the conversation's kept draft (what was typed before, or a send a relaunch gave back).
    func conversation(_ route: ChatRoute) -> (ChatConversationModel, ChatComposerModel) {
        let conversation = ChatConversationModel(
            client: client, conversationID: route.isNew ? nil : route.id, clock: SleepClock(sleep: sleep)
        )
        conversation.focusMessageID = route.messageID
        if route.isNew { client.follow(conversation) }
        let composer = ChatComposerModel(conversation: conversation)
        if let list = snapshot.list {
            composer.newChatChoices = ChatNewChatChoices(models: list.models, projects: list.projects)
        }
        let draft = drafts.draft(route.id)
        composer.draft = draft.text
        composer.quotes = draft.quotes
        composer.editing = draft.editing
        composer.routing = draft.routing
        composer.projectID = draft.projectID
        return (conversation, composer)
    }

    /// The composer's text and quotes, kept per conversation while the screen is away; the notice a relaunch left goes
    /// with the next edit.
    func keepDraft(_ conversation: Int64, text: String, quotes: [ChatQuoteDraft]) {
        drafts.update(conversation) { draft in
            if draft.text != text || draft.quotes != quotes { draft.notice = nil }
            draft.text = text
            draft.quotes = quotes
        }
    }

    // MARK: - Files waiting to go with the next send (the composer's pills)

    /// A picked file, prepared and staged into the conversation's draft (0 is a new chat); it uploads with the next
    /// send. Refused with the Mac's reason when it breaks a limit or the message's 30 MB: the reason comes back.
    @discardableResult
    func attach(data: Data, fileName: String, conversation: Int64) -> String? {
        switch ChatAttachmentPrep.prepare(data: data, fileName: fileName) {
        case let .failure(rejection):
            return rejection.message
        case let .success(prepared):
            let held = drafts.draft(conversation).attachments
            let all = held.map { (mime: $0.mime, size: $0.size) } + [(mime: prepared.mime, size: Int64(prepared.data.count))]
            guard ChatAttachmentLimits.fitsMessage(all) else { return ChatAttachmentLimits.Rejection.overMessage.message }
            do {
                let staged = try ChatAttachmentPrep.stage(prepared, in: staging)
                drafts.update(conversation) { $0.attachments.append(staged) }
                return nil
            } catch {
                return ChatSendCoordinator.couldNotSend
            }
        }
    }

    func removeAttachment(_ id: String, conversation: Int64) {
        if let file = drafts.draft(conversation).attachments.first(where: { $0.id == id }) { ChatAttachmentPrep.discard(file.file) }
        drafts.update(conversation) { $0.attachments.removeAll { $0.id == id } }
    }

    /// Retry on a refused pill: the same file under a fresh upload id (a refused upload is a finished record).
    func retryAttachment(_ id: String, conversation: Int64) {
        drafts.update(conversation) { draft in
            if let index = draft.attachments.firstIndex(where: { $0.id == id }) { draft.attachments[index] = draft.attachments[index].retried() }
        }
    }

    /// Why a conversation's composer may not send now: a send of it is still on its way that this composer is not
    /// waiting for — one the outbox could not take back after the patience (the hub may have it), one a previous run
    /// kept, or one sent from this chat before the screen was opened again. "Waiting for your Mac…" until its echo
    /// settles it; Send stays off, so it is never sent twice.
    func hold(_ conversation: Int64?, composerSending: Bool, host: TowerHost) -> String? {
        guard let id = conversation, let turn = sending.pending[id], !turn.isApplied else { return nil }
        guard turn.isStalled || turn.isRecovered || !composerSending else { return nil }
        return ChatText.waitingForHub(host)
    }

    /// The Chats tab's gate as the screen on top computes it: whether the hub answers, and the copy the chat shows
    /// when it does not.
    func setGate(_ gate: ChatsGateModel) {
        client.setGate(gate)
    }

    /// Observes the replica's chat records for the session's lifetime.
    func start(store: ReplicaStore, gate: ReplicaObservationGate? = nil) {
        guard cancellable == nil else { return }
        replica = store
        let (cache, records) = (decodeCache, recordCache)
        cancellable = ResilientObservation(
            name: "chats",
            reader: store.reader,
            gate: gate,
            observation: {
                ValueObservation.tracking(regions: [ReplicaStore.kindVersionsRegion, ReplicaStore.pendingActionsRegion]) { db in
                    try ChatsSnapshot.read(from: db, store: store, cache: cache, records: records)
                }
                .removeDuplicates()
            },
            onChange: { [weak self] value in self?.apply(value) }
        )
    }

    /// A snapshot as the observation delivers it (the screenshot tour and the tests set their own). New feeds and
    /// pages go to the offline copy; refusals reach the sends waiting for them.
    func apply(_ value: ChatsSnapshot) {
        // Before the equality check: the first read after a relaunch settles the sends a previous run kept, even when
        // it reads the same as the empty start.
        sending.recover(failures: value.failures, queued: value.queued)
        guard value != snapshot else { return }
        let previous = snapshot
        snapshot = value
        saveToCopy(value, previous: previous)
        sending.receive(failures: value.failures)
        sending.settle(feeds: value.feeds)
        prefetch.feedsArrived(Set(value.feeds.filter { previous.feeds[$0.key] != $0.value }.keys))
        stepPrefetch()
        relayClient?.snapshotChanged()
    }

    /// An applied echo of any chat action (the session's one applied observer).
    func receiveApplied(_ action: ActionRequestPayload) {
        guard Self.chatKinds.contains(action.kind) else { return }
        sending.receiveApplied(action)
    }

    /// Whether the hub answers now, as the hub session sees it (its heartbeat and the relay), read fresh at every
    /// prefetch step; the session sets it, so the prefetch needs no screen.
    func setReachability(_ reachable: @escaping @MainActor () -> Bool) {
        reachability = reachable
        stepPrefetch()
    }

    /// The app came to the foreground or left it: the prefetch runs in the foreground only.
    func setForeground(_ foreground: Bool) {
        prefetch.setForeground(foreground)
        stepPrefetch()
    }

    /// One prefetch step when the hub answers now (a fetch ended, the app came back, a feed arrived, the patience
    /// of the one in flight ran out).
    func stepPrefetch() {
        prefetch.step(list: snapshot.list, online: reachability?() ?? false)
    }

    /// The error state's Retry (mockup 1h): asks the hub to publish `chat_list` again, `chat_feed_request` with
    /// conversation 0. False when the request could not be queued.
    @discardableResult
    func retryList() async -> Bool {
        do {
            try await sender(ChatFeedRequestParams(conversationID: 0, purpose: .prefetch))
            return true
        } catch {
            Self.logger.warning("chat list retry not queued: \(String(describing: type(of: error)), privacy: .public)")
            return false
        }
    }

    /// Waits for every copy write queued so far (tests).
    func copyWritesDone() async {
        await copyWrites?.value
    }

    private func saveToCopy(_ value: ChatsSnapshot, previous: ChatsSnapshot) {
        let feeds = value.feeds.filter { previous.feeds[$0.key] != $0.value }.mapValues(\.payload)
        var pages: [(Int64, Int64, Data)] = []
        for (id, byBefore) in value.pages {
            for (before, entry) in byBefore where previous.pages[id]?[before] != entry {
                pages.append((id, before, entry.payload))
            }
        }
        guard !feeds.isEmpty || !pages.isEmpty else { return }
        let copy = copy
        let previousWrite = copyWrites
        copyWrites = Task.detached(priority: .utility) {
            await previousWrite?.value
            do {
                for (id, payload) in feeds {
                    try copy.saveFeed(conversationID: id, payload: payload)
                }
                for (id, before, payload) in pages {
                    try copy.savePage(conversationID: id, beforeMessageID: before, payload: payload)
                }
                try copy.evict()
            } catch {
                Self.logger.error("chat copy not saved: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }
}

/// The center's `sleep` as `ChatUI`'s clock (the list's Undo window).
private struct SleepClock: ChatUIClock {
    let sleep: @Sendable (Duration) async throws -> Void

    func sleep(for duration: Duration) async throws {
        try await sleep(duration)
    }
}
