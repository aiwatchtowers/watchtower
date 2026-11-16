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
    public static let reconnectingLine = "Reconnecting…"
    public static let unreachableSendLine = "Couldn't reach Watchtower to send that. Your text is kept."
    /// How long a send whose answer was lost waits for the chat to come back before it gives up (D11's window).
    public static let reconnectPatience: Duration = .seconds(10)

    public let client: any ChatClient
    public private(set) var conversationID: Int64?
    public var store: ChatFeedStore
    /// Set by the client's reachability stream; tests and the shell may set it too. Back to `.connected`, a send
    /// whose answer was lost goes again with the same key.
    public var reachability: ChatReachability = .connected {
        didSet { if reachability == .connected { resumeWaiters(.reconnected) } }
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
    /// A message to show first (a search hit): `followFocus` pages back until it is loaded, and the feed scrolls to it.
    public var focusMessageID: Int64?
    private var ownTurnID: String?
    private var earlierHasMore = false
    private var lastRead: Int64 = 0

    @ObservationIgnored private var feedTask: Task<Void, Never>?
    @ObservationIgnored private var reachabilityTask: Task<Void, Never>?
    /// A send waiting for a lost answer: it is shown as "Reconnecting…".
    public private(set) var isReconnecting = false
    @ObservationIgnored private var reconnectWaiters: [UUID: CheckedContinuation<ReconnectOutcome, Never>] = [:]
    @ObservationIgnored private let clock: any ChatUIClock
    @ObservationIgnored private var running = false

    /// `clock` times how long a send waits for a lost connection to come back (tests inject one).
    public init(client: any ChatClient, conversationID: Int64?, clock: any ChatUIClock = ContinuousChatUIClock()) {
        self.client = client
        self.clock = clock
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
        if let line = ChatStateLine.content(for: reachability) { return line }
        if isReconnecting { return ChatStateLine.Content(text: Self.reconnectingLine) }
        return isGone ? ChatStateLine.Content(text: Self.goneLine) : nil
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
        resumeWaiters(.stopped)
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

    /// The first send created this conversation: follow it. Public for a client that learns the new chat's id
    /// before its turn is answered (the phone's relay hears `chat_new` first).
    public func adopt(_ id: Int64) {
        guard conversationID != id else { return }
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
        // Marked only once the engine applied it, so a lost read is sent again on the next look.
        if case .applied? = try? await client.send(.read(conversationID: conversationID, messageID: newest)) {
            lastRead = max(lastRead, newest)
        }
    }

    /// Loads the page before the oldest loaded message.
    public func loadEarlier() async {
        guard let conversationID, !isLoadingEarlier, let oldest = messages.first?.id else { return }
        isLoadingEarlier = true
        defer { isLoadingEarlier = false }
        let echo = try? await client.send(.page(conversationID: conversationID, beforeMessageID: oldest))
        guard case .applied(.page(let page))? = echo else {
            report(echo)
            return
        }
        let known = Set(messages.map(\.id))
        earlier = page.messages.filter { !known.contains($0.id) } + earlier
        earlierHasMore = page.hasMore
    }

    /// Loads earlier pages until the focused message is among the loaded ones, or there is nothing earlier. Called
    /// whenever the loaded messages change; a page that does not bring it asks for the next one.
    public func followFocus() async {
        guard let focus = focusMessageID, conversationID != nil else { return }
        while !messages.contains(where: { $0.id == focus }), hasEarlierToLoad, !isLoadingEarlier {
            let before = messages.first?.id
            await loadEarlier()
            guard messages.first?.id != before else { return }
        }
    }

    /// More history exists above the loaded messages: the feed's `hasMore` until a page loaded, then the last page's.
    var hasEarlierToLoad: Bool { earlier.isEmpty ? hasEarlier : earlierHasMore }

    private func turn(_ mode: ChatTurnMode, messageID: Int64, text: String = "") async {
        guard let conversationID else { return }
        let request = ChatTurnRequest(conversationID: conversationID, mode: mode, messageID: messageID, text: text,
                                      clientKey: UUID().uuidString)
        report(await sendTurn(request))
    }

    /// Sends a turn. A send whose answer is lost to a dropped connection (`ChatConnectionError`) goes again at once
    /// with the same `clientKey` — the engine answers a repeated key with its first result, never a second turn. Lost
    /// again, it waits for the client's next `.connected` (shown as "Reconnecting…") up to `reconnectPatience`, then
    /// gives up with the text kept. Any other error is the operation's own failure and is reported, not retried. Nil
    /// only when the screen stopped before an answer came.
    func sendTurn(_ request: ChatTurnRequest) async -> ChatEcho? {
        var resendNow = true
        while true {
            do {
                let echo = try await client.send(.turn(request))
                if case .applied(.turn(let started)) = echo { ownTurnID = started.turnID }
                return echo
            } catch is ChatConnectionError {
                if resendNow {
                    resendNow = false
                    continue
                }
                switch await waitForReconnect() {
                case .reconnected: continue
                case .timedOut: return .refused(code: "unreachable", message: Self.unreachableSendLine)
                case .stopped: return nil
                }
            } catch {
                return .refused(code: "internal", message: Self.couldNotSend)
            }
        }
    }

    /// Records a refusal or failure as the notice; an applied answer clears it.
    func report(_ echo: ChatEcho?) {
        switch echo {
        case .applied?: notice = nil
        case let .refused(code, message)?: notice = Self.refusalLine(code: code, message: message)
        case nil: notice = Self.couldNotSend
        }
    }

    static func refusalLine(code: String, message: String) -> String {
        if code == "busy" { return busyLine }
        return message.isEmpty ? couldNotSend : message
    }

    enum ReconnectOutcome {
        case reconnected, timedOut, stopped
    }

    /// Suspends until the client reports `.connected` again, the patience runs out, or the screen stops.
    private func waitForReconnect() async -> ReconnectOutcome {
        guard running else { return .stopped }
        let id = UUID()
        isReconnecting = true
        let timer = Task { [clock] in
            do { try await clock.sleep(for: Self.reconnectPatience) } catch { return }
            self.resume(id, .timedOut)
        }
        let outcome = await withCheckedContinuation { reconnectWaiters[id] = $0 }
        timer.cancel()
        isReconnecting = !reconnectWaiters.isEmpty
        return outcome
    }

    /// A send is waiting for the chat to be reachable again (tests).
    var isWaitingToResend: Bool { !reconnectWaiters.isEmpty }

    private func resume(_ id: UUID, _ outcome: ReconnectOutcome) {
        reconnectWaiters.removeValue(forKey: id)?.resume(returning: outcome)
    }

    private func resumeWaiters(_ outcome: ReconnectOutcome) {
        let waiters = reconnectWaiters
        reconnectWaiters = [:]
        waiters.values.forEach { $0.resume(returning: outcome) }
    }
}
