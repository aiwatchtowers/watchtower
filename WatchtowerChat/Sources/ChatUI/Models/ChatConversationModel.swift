import ChatWire
import Foundation
import Observation

/// One conversation on screen (unified chat spec §6.1): its feed store fed by the client's subscription, whether the
/// chat can be reached, and the turn operations of the message rows. Written against `ChatClient` only: the Mac's
/// `SocketChatClient` and the phone's relay client both drive it. The composer (`ChatComposerModel`) sends through it.
@MainActor
@Observable
public final class ChatConversationModel {
    public static let goneLine = "This chat was deleted. Your draft is kept."
    public static let staleLine = "Catching up…"
    public static let busyLine = "An answer is already running in this chat. Your text is kept."
    public static let couldNotSend = "Couldn't send that. Try again."

    public let client: any ChatClient
    public private(set) var conversationID: Int64?
    public var store: ChatFeedStore
    /// Set by the client's reachability stream; tests and the shell may set it too. Back to `.connected`, a send
    /// whose answer was lost goes again with the same key.
    public var reachability: ChatReachability = .connected {
        didSet { if reachability == .connected { resumeWaiters() } }
    }
    public var isGone: Bool { store.isGone }
    /// Starts Watchtower's background service (the Mac's `ensureDaemonRunning` chain); called only when the owner
    /// presses the state line's Retry or Start (D11: never silently after an owner stop).
    public var onStartDaemon: (() -> Void)?
    /// A new conversation was created by the first send: the shell selects it.
    public var onConversationCreated: ((Int64) -> Void)?
    /// The last refusal or failure of a row operation, shown under the feed.
    public internal(set) var notice: String?
    /// Older messages loaded with `loadEarlier`, before the feed's page.
    public private(set) var earlier: [ChatFeed.Message] = []
    public private(set) var isLoadingEarlier = false
    private var ownTurnID: String?
    private var lastRead: Int64 = 0

    @ObservationIgnored private var feedTask: Task<Void, Never>?
    @ObservationIgnored private var reachabilityTask: Task<Void, Never>?
    @ObservationIgnored private var connectedWaiters: [CheckedContinuation<Bool, Never>] = []
    @ObservationIgnored private var running = false

    public init(client: any ChatClient, conversationID: Int64?) {
        self.client = client
        self.conversationID = conversationID
        store = ChatFeedStore()
    }

    // MARK: - Derived state

    public var feed: ChatFeed? { store.feed }

    /// The loaded messages, oldest first: the pages loaded earlier, then the feed's page.
    public var messages: [ChatFeed.Message] {
        let page = feed?.messages ?? []
        let ids = Set(page.map(\.id))
        return earlier.filter { !ids.contains($0.id) } + page
    }

    public var hasEarlier: Bool { feed?.hasMore ?? false }

    /// A turn runs in this conversation, whoever started it (G6): the engine's lock is shown as the lease, and the
    /// running reply is `pending`.
    public var isTurnRunning: Bool {
        feed?.conversation.lease != nil || messages.last { $0.role == "assistant" }?.status == ChatMessageStatus.pending
    }

    /// The running turn's id: the engine's, else the one this client's send got back.
    public var runningTurnID: String? {
        if let lease = feed?.conversation.lease, !lease.turnID.isEmpty { return lease.turnID }
        return isTurnRunning ? ownTurnID : nil
    }

    /// Stop is on for any running turn, this device's or another's (no read-only mode for a remote turn, §6.2).
    public var canStop: Bool { reachability == .connected && runningTurnID != nil }

    public var isStale: Bool { store.isStale }

    /// The line above the composer: why the chat cannot be reached, else that the conversation is gone.
    public var stateLine: ChatStateLine.Content? {
        ChatStateLine.content(for: reachability) ?? (isGone ? ChatStateLine.Content(text: Self.goneLine) : nil)
    }

    /// The reply whose question card can be answered: the latest reply, unanswered, while no turn runs.
    public func isAnswerable(_ messageID: Int64) -> Bool {
        guard !isTurnRunning, let last = messages.last(where: { $0.role == "assistant" }), last.id == messageID else {
            return false
        }
        return ownerReply(after: messageID) == nil
    }

    /// The owner's message right after `messageID`.
    public func ownerReply(after messageID: Int64) -> String? {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return nil }
        return messages[(index + 1)...].first { $0.role == "user" }?.text
    }

    // MARK: - Lifecycle

    /// Subscribes to reachability and, for a saved conversation, its feed. Idempotent.
    public func start() {
        guard !running else { return }
        running = true
        let reachability = client.reachability
        reachabilityTask = Task { [weak self] in
            for await state in reachability {
                guard let self else { return }
                self.reachability = state
            }
        }
        subscribeFeed()
    }

    /// Ends the subscriptions (the screen went away); a send waiting to resend gives up.
    public func stop() {
        running = false
        feedTask?.cancel()
        reachabilityTask?.cancel()
        feedTask = nil
        reachabilityTask = nil
        let waiters = connectedWaiters
        connectedWaiters = []
        waiters.forEach { $0.resume(returning: false) }
    }

    private func subscribeFeed() {
        guard running, let conversationID else { return }
        feedTask?.cancel()
        let updates = client.feed(conversationID)
        feedTask = Task { [weak self] in
            for await update in updates {
                guard let self else { return }
                self.store.apply(update)
            }
        }
    }

    /// The first send created this conversation: follow it.
    func adopt(_ id: Int64) {
        conversationID = id
        subscribeFeed()
        onConversationCreated?(id)
    }

    /// The state line's button: Retry or Start runs the start chain.
    public func performStateAction() {
        guard ChatStateLine.content(for: reachability)?.action != nil else { return }
        onStartDaemon?()
    }

    // MARK: - Turn operations

    /// Stops the running turn (the composer's Stop) — distinct from `stop()`, which ends the subscriptions.
    public func cancelTurn() async {
        guard let conversationID, let turnID = runningTurnID else { return }
        report(try? await client.send(.cancel(conversationID: conversationID, turnID: turnID)))
    }

    public func regenerate(_ id: Int64) async {
        await turn(.regenerate, messageID: id)
    }

    public func edit(_ id: Int64, text: String) async {
        await turn(.edit, messageID: id, text: text)
    }

    public func retry(_ id: Int64) async {
        await turn(.retry, messageID: id)
    }

    public func continueStopped(_ id: Int64) async {
        await turn(.continue, messageID: id)
    }

    public func selectBranch(_ id: Int64) async {
        report(try? await client.send(.branchSelect(messageID: id)))
    }

    /// Marks the newest complete reply read (the list's unread dot).
    public func markRead() async {
        guard let conversationID, reachability == .connected,
              let newest = messages.last(where: { $0.role == "assistant" && $0.status == ChatMessageStatus.complete })?.id,
              newest > lastRead else { return }
        lastRead = newest
        _ = try? await client.send(.read(conversationID: conversationID, messageID: newest))
    }

    /// Loads the page before the oldest loaded message.
    public func loadEarlier() async {
        guard let conversationID, !isLoadingEarlier, let oldest = messages.first?.id else { return }
        isLoadingEarlier = true
        defer { isLoadingEarlier = false }
        guard case .applied(.page(let page))? = try? await client.send(.page(conversationID: conversationID, beforeMessageID: oldest))
        else { return }
        let known = Set(messages.map(\.id))
        earlier = page.messages.filter { !known.contains($0.id) } + earlier
    }

    private func turn(_ mode: ChatTurnMode, messageID: Int64, text: String = "") async {
        guard let conversationID else { return }
        let request = ChatTurnRequest(conversationID: conversationID, mode: mode, messageID: messageID, text: text,
                                      clientKey: UUID().uuidString)
        report(await sendTurn(request))
    }

    /// Sends a turn. A send whose answer is lost to a dropped connection waits until the chat is reachable again and
    /// goes again with the same `clientKey`, which the engine answers with the first result (never a second turn).
    /// Nil when the screen stopped before an answer came.
    func sendTurn(_ request: ChatTurnRequest) async -> ChatEcho? {
        while true {
            do {
                let echo = try await client.send(.turn(request))
                if case .applied(.turn(let started)) = echo { ownTurnID = started.turnID }
                return echo
            } catch {
                guard await waitUntilConnected() else { return nil }
            }
        }
    }

    /// Records a refusal or failure as the notice; an applied answer clears it.
    func report(_ echo: ChatEcho?) {
        switch echo {
        case .applied?: notice = nil
        case .refused(let code, let message)?: notice = Self.refusalLine(code: code, message: message)
        case nil: notice = Self.couldNotSend
        }
    }

    static func refusalLine(code: String, message: String) -> String {
        if code == "busy" { return busyLine }
        return message.isEmpty ? couldNotSend : message
    }

    /// Suspends until the chat is reachable (true) or the screen stops (false). The first wait happens even when the
    /// state still reads connected: the send just failed, so the client's next state is what counts.
    private func waitUntilConnected() async -> Bool {
        guard running else { return false }
        return await withCheckedContinuation { connectedWaiters.append($0) }
    }

    /// A send is waiting for the chat to be reachable again (tests).
    var isWaitingToResend: Bool { !connectedWaiters.isEmpty }

    private func resumeWaiters() {
        let waiters = connectedWaiters
        connectedWaiters = []
        waiters.forEach { $0.resume(returning: true) }
    }
}
