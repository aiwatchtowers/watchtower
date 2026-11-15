import Foundation
import Observation
import os
import WatchtowerChatText
import WatchtowerKit
import WatchtowerSync

/// One conversation on screen (iPhone chat spec §6.2–§6.4, mockups 2a–2i): the feed the hub publishes while the
/// screen watches it (`chat_feed_request open`, repeated every 60 s), or the phone's own copy while it has none;
/// older history page by page (`chat_page`, "Load earlier messages"); the read mark; and every action the screen
/// sends — Send, Stop, Retry, Regenerate, Edit, ‹ i/n ›, Approve and Reject. The rows are diffed by message id, so
/// a record replaced after a reconnect renders whole, whatever its text did.
@MainActor
@Observable
final class ChatConversationModel {
    /// The top row's state (mockup 2i).
    enum Earlier: Equatable {
        case more
        case loading
        case noAnswer
    }

    enum Paging: Equatable {
        case idle
        case loading(before: Int64)
        case noAnswer(before: Int64)
    }

    /// What the screen shows instead of the feed while it has none (mockups 2g, 2e).
    enum Placeholder: Equatable {
        /// A new chat (mockup 2h).
        case newChat
        /// The request went; no record yet.
        case loading
        /// 30 s without a record: "The Mac did not answer" + Retry.
        case noAnswer
        /// The hub sleeps and the phone never held this chat.
        case neverLoaded
    }

    static let patience: Duration = .seconds(30)
    static let repeatInterval: TimeInterval = 60
    static let waitingForSlot = "Waiting for a free slot"
    static let newChatLine = "It answers with your Slack, mail, Jira, meetings and memory."
    static let newChatTitle = "New chat"

    private(set) var conversationID: Int64
    let focusMessageID: Int64?
    /// The phone's own copy, read once when the screen opens.
    private(set) var held: ChatHeldCopy?
    private(set) var timedOut = false
    private(set) var paging = Paging.idle
    private(set) var expandedSteps: Set<Int64> = []
    /// The newest answer this screen marked read.
    private(set) var lastRead: Int64 = 0
    private(set) var isVisible = false
    private(set) var online = false
    /// Approvals sent and waiting for their echo: agent action id → outbox action id.
    private(set) var answering: [Int64: String] = [:]
    /// The turn a Stop went out for.
    private(set) var stopping: String?

    @ObservationIgnored let center: ChatsCenter
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let ticks: () -> AsyncStream<Void>
    @ObservationIgnored private var openTimer: Task<Void, Never>?
    @ObservationIgnored private var repeats: Task<Void, Never>?
    @ObservationIgnored private var pageTimer: Task<Void, Never>?
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "ChatConversation")

    init(
        route: ChatRoute,
        center: ChatsCenter,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        ticks: @escaping () -> AsyncStream<Void>
    ) {
        conversationID = route.id
        focusMessageID = route.messageID
        self.center = center
        self.sleep = sleep
        self.ticks = ticks
        if route.id != 0 { held = try? center.copy.held(conversationID: route.id) }
    }

    nonisolated static func clockTicks() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(repeatInterval))
                    if Task.isCancelled { break }
                    continuation.yield()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - What the screen shows

    var isNew: Bool { conversationID == 0 }
    /// The record the hub publishes for this screen now.
    var live: ChatFeed? { center.snapshot.feeds[conversationID]?.feed }
    var feed: ChatFeed? { live ?? held?.feed }
    /// A turn runs: only the live record knows (a held lease would read as running forever).
    var lease: ChatFeed.Lease? { live?.conversation.lease }

    var title: String {
        if let title = feed?.conversation.title, !title.isEmpty { return title }
        if isNew { return Self.newChatTitle }
        return center.snapshot.list?.conversations.first { $0.id == conversationID }?.title ?? ""
    }

    var placeholder: Placeholder? {
        if isNew { return center.sending.pending[0] == nil ? .newChat : nil }
        guard feed == nil else { return nil }
        if !online { return .neverLoaded }
        return timedOut ? .noAnswer : .loading
    }

    /// The pages under the feed by the message each comes before; the live records win over the copy's.
    var pages: [Int64: ChatPage] {
        var pages = held?.pages ?? [:]
        for (before, entry) in center.snapshot.pages[conversationID] ?? [:] {
            pages[before] = entry.page
        }
        return pages
    }

    /// The active branch on screen, oldest first: the feed, then each page under the oldest message so far.
    var messages: [ChatFeed.Message] {
        guard let feed else { return [] }
        var messages = feed.messages
        let pages = pages
        var seen = Set(messages.map(\.id))
        while let oldest = messages.first?.id, let page = pages[oldest] {
            let older = page.messages.filter { $0.id < oldest && seen.insert($0.id).inserted }
            guard !older.isEmpty else { break }
            messages.insert(contentsOf: older, at: 0)
        }
        return messages
    }

    /// Older messages exist above the first one shown.
    var hasMore: Bool {
        guard let feed, let oldest = messages.first?.id else { return false }
        if oldest == feed.messages.first?.id { return feed.hasMore }
        let pages = pages
        let lowest = pages.values.filter { $0.messages.contains { $0.id == oldest } }
        return lowest.contains { $0.hasMore }
    }

    var earlier: Earlier? {
        guard hasMore, let oldest = messages.first?.id else { return nil }
        switch paging {
        case let .loading(before) where before == oldest: return .loading
        case let .noAnswer(before) where before == oldest: return .noAnswer
        default: return .more
        }
    }

    /// The newest complete answer on screen: what a read mark names.
    var newestCompleteAnswer: Int64? {
        messages.last { $0.role == "assistant" && $0.status == "complete" }?.id
    }

    /// The line over the composer for a turn the hub does not run here: on the Mac, or waiting for a hub slot.
    func leaseLine(_ host: TowerHost) -> String? {
        guard let lease else { return nil }
        if lease.owner == "desktop" { return ChatText.answeringElsewhere(host) }
        return lease.waitingSlot ? Self.waitingForSlot : nil
    }

    func items(permissions: Bool, host: TowerHost) -> [ChatFeedItem] {
        let failures = center.snapshot.failures
        let approvals = (feed?.actions ?? []).map { action in
            ChatApprovalCardModel(
                action: action, permissions: permissions, online: online,
                inFlight: answering[action.id].map { failures[$0] == nil } ?? false,
                failure: answering[action.id].flatMap { failures[$0] }, host: host
            )
        }
        return ChatFeedItems.build(ChatFeedItems.Inputs(
            messages: messages, lease: lease, earlier: earlier, pending: center.sending.pending[conversationID],
            approvals: approvals, versions: Dictionary((feed?.artifacts ?? []).map { ($0.key, $0.version) }) { $1 },
            provider: feed?.conversation.actualProvider
        ))
    }

    /// The artifact a card opens: its latest content and the attributes its newest fence carries.
    func artifact(_ key: String) -> ChatArtifactContent? {
        let drafts = messages.flatMap { ArtifactParser.parse($0.text, final: $0.status == "complete").artifacts }.filter { $0.key == key }
        let stored = feed?.artifacts.first { $0.key == key }
        let bare = stored.map { ArtifactDraft(key: $0.key, kind: $0.kind, title: $0.title, meta: [:], content: "", isComplete: true) }
        guard let draft = drafts.last ?? bare else { return nil }
        return ChatArtifactContent(
            key: key, kind: stored?.kind ?? draft.kind, title: stored?.title ?? draft.title, version: stored?.version ?? 1,
            meta: draft.meta, content: stored?.content ?? draft.content, contentCut: stored?.contentCut ?? false
        )
    }

    // MARK: - Opening and watching

    func appear(online: Bool) {
        isVisible = true
        self.online = online
        if !isNew {
            do {
                try center.copy.markOpened(conversationID: conversationID)
            } catch {
                Self.logger.warning("chat copy open not marked: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
        requestFeed()
        startRepeats()
        markRead()
        followFocus()
    }

    func disappear() {
        isVisible = false
        openTimer?.cancel()
        repeats?.cancel()
        pageTimer?.cancel()
        repeats = nil
    }

    func setOnline(_ online: Bool) {
        guard online != self.online else { return }
        self.online = online
        if online, isVisible { requestFeed() }
    }

    /// The 2g Retry: asks again and waits another 30 s.
    func retryOpen() {
        requestFeed()
    }

    /// Sends `chat_feed_request open` and starts the 30 s patience; nothing while the hub does not answer.
    private func requestFeed() {
        guard !isNew, online, isVisible else { return }
        timedOut = false
        send(ChatFeedRequestParams(conversationID: conversationID, purpose: .open), what: "feed request")
        openTimer?.cancel()
        openTimer = Task { [weak self, sleep] in
            do { try await sleep(Self.patience) } catch { return }
            guard let self, !Task.isCancelled else { return }
            if self.live == nil { self.timedOut = true }
        }
    }

    private func startRepeats() {
        guard repeats == nil else { return }
        let stream = ticks()
        repeats = Task { [weak self] in
            for await _ in stream {
                guard let self, self.isVisible else { return }
                if self.online, !self.isNew {
                    self.send(ChatFeedRequestParams(conversationID: self.conversationID, purpose: .open), what: "feed repeat")
                }
            }
        }
    }

    /// Marks the newest complete answer read while the screen shows it: on open, and when a turn finishes on screen.
    /// Never an older id than the last one sent, never from the phone's copy alone.
    func markRead() {
        guard isVisible, online, live != nil, let newest = newestCompleteAnswer, newest > lastRead else { return }
        lastRead = newest
        send(ChatReadParams(conversationID: conversationID, messageID: newest), what: "read mark")
    }

    /// The feed moved: a search hit's message keeps the pages coming until it is on screen.
    func followFocus() {
        guard let focusMessageID, !messages.contains(where: { $0.id == focusMessageID }), hasMore, paging == .idle || isSettled else { return }
        loadEarlier()
    }

    private var isSettled: Bool {
        switch paging {
        case let .loading(before): before != messages.first?.id
        case .idle, .noAnswer: false
        }
    }

    // MARK: - Paging

    /// "Load earlier messages": the 60 messages before the oldest one shown.
    func loadEarlier() {
        guard online, let oldest = messages.first?.id else { return }
        paging = .loading(before: oldest)
        send(ChatPageParams(conversationID: conversationID, beforeMessageID: oldest), what: "page request")
        pageTimer?.cancel()
        pageTimer = Task { [weak self, sleep] in
            do { try await sleep(Self.patience) } catch { return }
            guard let self, !Task.isCancelled, self.paging == .loading(before: oldest) else { return }
            if self.pages[oldest] == nil { self.paging = .noAnswer(before: oldest) }
        }
    }

    func toggleSteps(_ messageID: Int64) {
        if expandedSteps.contains(messageID) { expandedSteps.remove(messageID) } else { expandedSteps.insert(messageID) }
    }

    // MARK: - Turn actions

    /// Retry on an error card and Regenerate on the last answer: `chat_turn mode regenerate` of that answer.
    func regenerate(_ messageID: Int64) {
        guard online else { return }
        let request = ChatSendCoordinator.Request(conversationID: conversationID, mode: .regenerate, messageID: messageID, text: "")
        Task { await center.sending.send(request) }
    }

    /// ‹ or › under an answer: shows that sibling's branch.
    func selectBranch(_ message: ChatFeed.Message, step: Int) {
        guard online, let sibling = message.siblings.neighbour(step) else { return }
        send(ChatBranchSelectParams(messageID: sibling), what: "branch select")
    }

    /// Stop, whoever runs the turn: the hub cancels through the lease.
    func stop() {
        guard online, let lease, !lease.turnID.isEmpty else { return }
        stopping = lease.turnID
        send(ChatCancelParams(conversationID: conversationID, turnID: lease.turnID), what: "stop")
    }

    /// Approve or Reject with the hash of the args the card shows.
    func answer(_ action: ChatFeed.Action, _ decision: ChatActionDecision) {
        guard online else { return }
        let params = ChatActionAnswerParams(actionID: action.id, decision: decision, argsSHA256: action.argsSHA256)
        Task {
            do {
                answering[action.id] = try await center.sender(params)
            } catch {
                Self.logger.warning("chat approval not queued: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    // MARK: - The composer

    var draft: ChatDraft { center.drafts.draft(conversationID) }

    func composer(list: ChatList?) -> ChatComposerModel {
        ChatComposerModel(
            draft: draft, isNew: isNew, online: online, lease: lease, sending: center.sending.isSending(conversationID),
            list: list, conversation: feed?.conversation
        )
    }

    func setText(_ text: String) {
        center.drafts.update(conversationID) { $0.text = text }
    }

    /// Edit from an owner bubble's long-press: its text in the composer, Send replaces it (`mode edit`).
    func startEdit(_ messageID: Int64, text: String) {
        center.drafts.update(conversationID) { draft in
            draft.editing = messageID
            draft.text = text
            draft.notice = nil
        }
    }

    func cancelEdit() {
        center.drafts.update(conversationID) { draft in
            draft.editing = nil
            draft.text = ""
        }
    }

    /// Ask about this (mockup 2i): the passage joins the quote batch.
    func addQuote(_ passage: String) {
        let quote = passage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty else { return }
        center.drafts.update(conversationID) { $0.quotes.append(ChatQuoteDraft(quote: quote, comment: "")) }
    }

    func removeQuote(_ id: UUID) {
        center.drafts.update(conversationID) { $0.quotes.removeAll { $0.id == id } }
    }

    func setRouting(_ routing: ChatRouting?) {
        center.drafts.update(conversationID) { $0.routing = routing }
    }

    func setProject(_ projectID: Int64?) {
        center.drafts.update(conversationID) { $0.projectID = projectID }
    }

    /// A picked file, prepared; refused with the Mac's reason when it breaks a limit or the message's 30 MB.
    func attach(data: Data, fileName: String) {
        switch ChatAttachmentPrep.prepare(data: data, fileName: fileName) {
        case let .failure(rejection):
            center.drafts.setNotice(rejection.message, conversation: conversationID)
        case let .success(prepared):
            let all = draft.attachments.map { (mime: $0.mime, size: $0.size) } + [(mime: prepared.mime, size: Int64(prepared.data.count))]
            guard ChatAttachmentLimits.fitsMessage(all) else {
                return center.drafts.setNotice(ChatAttachmentLimits.Rejection.overMessage.message, conversation: conversationID)
            }
            do {
                let staged = try ChatAttachmentPrep.stage(prepared, in: center.staging)
                center.drafts.update(conversationID) { draft in
                    draft.attachments.append(staged)
                    draft.notice = nil
                }
            } catch {
                center.drafts.setNotice(ChatSendCoordinator.couldNotSend, conversation: conversationID)
            }
        }
    }

    func removeAttachment(_ id: String) {
        if let file = draft.attachments.first(where: { $0.id == id }) { ChatAttachmentPrep.discard(file.file) }
        center.drafts.update(conversationID) { $0.attachments.removeAll { $0.id == id } }
    }

    /// Retry on a refused pill: the same file under a fresh upload id.
    func retryAttachment(_ id: String) {
        center.drafts.update(conversationID) { draft in
            if let index = draft.attachments.firstIndex(where: { $0.id == id }) { draft.attachments[index] = draft.attachments[index].retried() }
        }
    }

    /// Send: `chat_new` for a new chat, the uploads, then `chat_turn`. The composer empties at once; a refusal
    /// brings the text back.
    func send(list: ChatList?) {
        let composer = composer(list: list)
        guard composer.canSend else { return }
        let draft = draft
        let request = ChatSendCoordinator.Request(
            conversationID: conversationID, mode: draft.editing == nil ? .send : .edit, messageID: draft.editing,
            text: composer.sendText ?? "", attachments: draft.attachments, projectID: isNew ? draft.projectID : nil,
            routing: isNew ? draft.routing : nil, draft: draft
        )
        center.drafts.update(conversationID) { draft in
            draft.text = ""
            draft.quotes = []
            draft.editing = nil
            draft.notice = nil
        }
        Task {
            await center.sending.send(request) { [weak self] created in self?.adopt(created) }
        }
    }

    /// A new chat got its conversation: the screen now watches it.
    private func adopt(_ created: Int64) {
        conversationID = created
        requestFeed()
    }

    private func send<P: ActionParams>(_ params: P, what: StaticString) {
        let sender = center.sender
        Task {
            do {
                try await sender(params)
            } catch {
                Self.logger.warning("chat \(what, privacy: .public) not queued: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }
}

/// An artifact as its sheet shows it (mockup 3b).
struct ChatArtifactContent: Equatable, Identifiable {
    let key: String
    let kind: String
    let title: String
    let version: Int
    let meta: [String: String]
    let content: String
    /// The feed cap cut the content: open it on the hub's own screen.
    let contentCut: Bool

    var id: String { key }
}
