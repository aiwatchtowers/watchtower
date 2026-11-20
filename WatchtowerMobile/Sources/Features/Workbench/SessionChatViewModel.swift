import Foundation
import GRDB
import Observation
import os
import WatchtowerKit
import WatchtowerSync

/// A session's chat: the main feed (the workchat's, `agentID` nil) or one
/// subagent's, pushed from its row.
struct SessionChatRoute: Hashable {
    let sessionID: Int64
    /// nil for the main feed.
    let agentID: String?
    /// The subagent marker's tool_use id (the CLI's selector), nil exactly
    /// when `agentID` is.
    let toolUseID: String?

    init(sessionID: Int64, agentID: String?, toolUseID: String? = nil) {
        self.sessionID = sessionID
        self.agentID = agentID
        self.toolUseID = toolUseID
    }
}

/// Asks the Mac to publish a session's chat (`session_chat_request`): at
/// once on `start`, then every 60 s until `stop`. The Mac watches a chat for
/// five minutes after each request and publishes it only while watched, so
/// the repeat keeps a screen that stays open fed (FEED-05).
@MainActor
final class SessionChatRequester {
    static let interval: TimeInterval = 60
    /// How long a still-queued request counts as covering the repeat: one
    /// minute short of the Mac's five-minute watch.
    nonisolated static let queuedRequestFreshness: TimeInterval = 240

    private let send: (SessionChatRoute) async throws -> Void
    private let ticks: () -> AsyncStream<Void>
    private let now: () -> Date
    private var loop: Task<Void, Never>?
    private var running: SessionChatRoute?
    /// When each chat's last request went out, while the app runs.
    private var sentAt: [SessionChatRoute: Date] = [:]
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "SessionChatRequester")

    /// `ticks` yields once per repeat; the default waits `interval` between
    /// yields, tests feed their own.
    init(
        ticks: @escaping () -> AsyncStream<Void> = SessionChatRequester.clockTicks,
        now: @escaping () -> Date = Date.init,
        send: @escaping (SessionChatRoute) async throws -> Void
    ) {
        self.ticks = ticks
        self.now = now
        self.send = send
    }

    /// The app's requester: one idempotent action through the outbox, the
    /// session's own record as its entity. A request for the same chat that
    /// still waits in the outbox (the Mac was away) is not queued again: the
    /// Mac would otherwise see a backlog of repeats once it is back.
    static func sending(
        through outbox: ActionOutbox,
        store: ReplicaStore,
        ticks: @escaping () -> AsyncStream<Void> = SessionChatRequester.clockTicks
    ) -> SessionChatRequester {
        SessionChatRequester(ticks: ticks) { route in
            let entity = SliceKind.terminalSession.recordName(id: String(route.sessionID))
            let params = try SessionChatRequestParams(
                sessionID: route.sessionID, subagentID: route.agentID, toolUseID: route.toolUseID
            ).wireParams()
            // A queued request older than this would reach the Mac too late
            // to open a watch (it opens none past five minutes), so a fresh
            // one goes out beside it.
            let queued = try store.pendingActions(forEntity: entity).contains {
                $0.state == .pending && $0.action.kind == SessionChatRequestParams.actionKind && $0.action.params == params
                    && Date().timeIntervalSince($0.createdAt) < Self.queuedRequestFreshness
            }
            guard !queued else { return }
            try await outbox.enqueue(kind: SessionChatRequestParams.actionKind, entityRecordName: entity, params: params)
        }
    }

    nonisolated static func clockTicks() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(interval))
                    if Task.isCancelled { break }
                    continuation.yield()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Starts (or restarts) the requests for one chat.
    func start(sessionID: Int64, agentID: String?, toolUseID: String? = nil) {
        cancel()
        let route = SessionChatRoute(sessionID: sessionID, agentID: agentID, toolUseID: toolUseID)
        running = route
        let stream = ticks()
        loop = Task { [weak self] in
            await self?.request(route)
            for await _ in stream {
                if Task.isCancelled { break }
                await self?.request(route)
            }
        }
    }

    /// One request for a chat now, beside its repeat (the live line's Retry):
    /// the hub re-reads a chat whose last read failed on the request.
    func requestNow(sessionID: Int64, agentID: String?, toolUseID: String? = nil) {
        let route = SessionChatRoute(sessionID: sessionID, agentID: agentID, toolUseID: toolUseID)
        Task { [weak self] in await self?.request(route) }
    }

    /// A request for this chat went out within the hub's watch: the hub has
    /// published every change since, so the record the phone holds is current.
    func watchOpen(sessionID: Int64, agentID: String?, toolUseID: String? = nil) -> Bool {
        let route = SessionChatRoute(sessionID: sessionID, agentID: agentID, toolUseID: toolUseID)
        return sentAt[route].map { now().timeIntervalSince($0) < Self.queuedRequestFreshness } ?? false
    }

    /// Stops the requests for one chat; a no-op unless it is the one
    /// running, so a screen leaving after its successor started (SwiftUI
    /// does not order the two) cannot stop the successor.
    func stop(sessionID: Int64, agentID: String?, toolUseID: String? = nil) {
        guard running == SessionChatRoute(sessionID: sessionID, agentID: agentID, toolUseID: toolUseID) else { return }
        cancel()
    }

    private func cancel() {
        loop?.cancel()
        loop = nil
        running = nil
    }

    private func request(_ route: SessionChatRoute) async {
        do {
            try await send(route)
            sentAt[route] = now()
        } catch {
            Self.logger.warning("session chat request failed: \(String(describing: error), privacy: .public)")
        }
    }
}

/// One open chat: observes its `session_chat` record and keeps the Mac
/// asked while the screen is up. An undecodable record reads as absent.
@MainActor
@Observable
final class SessionChatViewModel {
    let sessionID: Int64
    let agentID: String?
    let toolUseID: String?
    private(set) var chat: SessionChat?
    /// 60 s went by with no record: the Mac may be asleep.
    private(set) var waitingTooLong = false
    private(set) var waitingForKeys = false
    /// Lines this phone sent whose outbox row is gone (the Mac applied
    /// them) and that the feed does not show yet.
    private(set) var sentLines: [SentLine] = []
    /// The record shown came from the hub since the screen appeared, or the
    /// hub's watch from an earlier visit was still open (it then published
    /// every change, so the record held is current). Until then the live line
    /// says Loading rather than a step from an expired watch (#2112 C9).
    private(set) var recordArrivedSinceOpen = false

    @ObservationIgnored private let store: ReplicaStore
    @ObservationIgnored private let requester: SessionChatRequester
    @ObservationIgnored private let sleep: (TimeInterval) async -> Void
    @ObservationIgnored private var cancellable: ResilientObservation?
    @ObservationIgnored private var patience: Task<Void, Never>?
    @ObservationIgnored private var shown = false
    /// The observation's first value is the stored record, not an arrival.
    @ObservationIgnored private var awaitingStored = false
    /// The hub's watch was open when the screen appeared.
    @ObservationIgnored private var watchWasOpen = false
    @ObservationIgnored private var tracked: [String: SentLine] = [:]
    @ObservationIgnored private var expiries: [String: Task<Void, Never>] = [:]
    @ObservationIgnored let decodeCache = ReplicaDecodeCache()
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "SessionChatViewModel")

    static let waitLimit: TimeInterval = 60
    /// How long a sent line keeps its bubble while the feed catches up.
    static let sentLimit: TimeInterval = 90

    /// One line the phone sent, as its bubble.
    struct SentLine: Identifiable, Equatable {
        let id: String
        let text: String
        let sentAt: Date

        /// The feed shows it once an owner entry with its text is dated at or
        /// after the send.
        func isShown(in chat: SessionChat) -> Bool {
            chat.entries.contains {
                $0.kind == .owner
                    && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == text.trimmingCharacters(in: .whitespacesAndNewlines)
                    && ($0.at ?? .distantPast) >= sentAt
            }
        }
    }

    init(
        sessionID: Int64,
        agentID: String?,
        toolUseID: String? = nil,
        store: ReplicaStore,
        requester: SessionChatRequester,
        sleep: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
    ) {
        self.sessionID = sessionID
        self.agentID = agentID
        self.toolUseID = toolUseID
        self.store = store
        self.requester = requester
        self.sleep = sleep
    }

    /// "12 earlier messages — open on the Mac" or nil.
    var earlierText: String? { Self.earlierText(chat?.entriesMore ?? 0) }

    static func earlierText(_ more: Int) -> String? {
        guard more > 0 else { return nil }
        return "\(more) earlier \(more == 1 ? "message" : "messages") — open on the tower"
    }

    /// The screen appeared: observe and ask the Mac for the chat.
    func appeared() {
        shown = true
        watchWasOpen = requester.watchOpen(sessionID: sessionID, agentID: agentID, toolUseID: toolUseID)
        recordArrivedSinceOpen = chat != nil && watchWasOpen
        awaitingStored = cancellable == nil
        observe()
        requester.start(sessionID: sessionID, agentID: agentID, toolUseID: toolUseID)
        patience?.cancel()
        patience = nil
        waitingTooLong = false
        if chat == nil { startPatience() }
    }

    /// Asks the hub for the chat at once (Retry on the live line).
    func retry() {
        requester.requestNow(sessionID: sessionID, agentID: agentID, toolUseID: toolUseID)
    }

    /// The screen went away: stop asking.
    func disappeared() {
        shown = false
        requester.stop(sessionID: sessionID, agentID: agentID, toolUseID: toolUseID)
        patience?.cancel()
        patience = nil
    }

    private func startPatience() {
        let limit = Self.waitLimit
        let sleep = sleep
        patience = Task { [weak self] in
            await sleep(limit)
            guard !Task.isCancelled else { return }
            self?.waitingTooLong = self?.chat == nil
        }
    }

    /// A line of the outbox the chat's session is told, as the screen sees it.
    struct Outgoing: Equatable {
        let id: String
        let text: String
        let sentAt: Date
        let failed: Bool

        /// nil for anything but a text line (a Finish request has no bubble).
        init?(_ row: SessionInputModel.LineRow) {
            guard row.pending.action.kind == .sessionInput else { return nil }
            id = row.id
            text = row.text
            sentAt = row.pending.createdAt
            if case .failed = row.state { failed = true } else { failed = false }
        }

        init(id: String, text: String, sentAt: Date, failed: Bool = false) {
            self.id = id
            self.text = text
            self.sentAt = sentAt
            self.failed = failed
        }
    }

    /// The outbox rows now: a text line that leaves the outbox without
    /// having failed was applied, and keeps a bubble until the feed shows it
    /// or 90 s pass.
    func noteOutgoing(_ rows: [Outgoing]) {
        let current = Set(rows.map(\.id))
        for row in rows {
            tracked[row.id] = row.failed ? nil : SentLine(id: row.id, text: row.text, sentAt: row.sentAt)
        }
        for (id, line) in tracked where !current.contains(id) {
            tracked[id] = nil
            guard !sentLines.contains(where: { $0.id == id }), !(chat.map(line.isShown) ?? false) else { continue }
            sentLines.append(line)
            let sleep = sleep
            expiries[id] = Task { [weak self] in
                await sleep(Self.sentLimit)
                guard !Task.isCancelled else { return }
                self?.dropSent(id)
            }
        }
    }

    private func dropSent(_ id: String) {
        sentLines.removeAll { $0.id == id }
        expiries[id]?.cancel()
        expiries[id] = nil
    }

    private func dropShownSent() {
        guard let chat else { return }
        for line in sentLines where line.isShown(in: chat) { dropSent(line.id) }
    }

    private func observe() {
        guard cancellable == nil else { return }
        let recordName = SessionChat.recordName(sessionID: sessionID, agentID: agentID)
        let store = store
        let cache = decodeCache
        cancellable = ResilientObservation(
            name: "session chat",
            reader: store.reader,
            observation: {
                ValueObservation.tracking(regions: [ReplicaStore.kindVersionsRegion]) { db in
                    try Self.read(recordName: recordName, from: db, store: store, cache: cache)
                }
                .removeDuplicates()
            },
            onWaitingForKeys: { [weak self] in self?.waitingForKeys = true },
            onChange: { [weak self] value in
                self?.noteArrival(value)
                self?.chat = value
                if value != nil {
                    self?.waitingTooLong = false
                    self?.patience?.cancel()
                    self?.patience = nil
                    self?.dropShownSent()
                } else if self?.shown == true, self?.patience == nil {
                    // The record went away under an open screen.
                    self?.startPatience()
                }
                self?.waitingForKeys = false
            }
        )
    }

    private func noteArrival(_ value: SessionChat?) {
        if value == nil {
            recordArrivedSinceOpen = false
        } else if awaitingStored {
            recordArrivedSinceOpen = watchWasOpen
        } else if shown {
            recordArrivedSinceOpen = true
        }
        awaitingStored = false
    }

    /// Reads from an already-open database, inside the observation.
    nonisolated static func read(
        recordName: String,
        from db: Database,
        store: ReplicaStore,
        cache: ReplicaDecodeCache = ReplicaDecodeCache()
    ) throws -> SessionChat? {
        let versions = try store.kindVersions([SessionChat.sliceKind], from: db)
        return try cache.value(recordName, version: versions[SessionChat.sliceKind] ?? 0) {
            guard let payload = try store.payload(forRecordName: recordName, from: db) else { return nil }
            do {
                return try SessionChat.decode(payload: payload)
            } catch {
                logger.warning("undecodable \(recordName, privacy: .public) skipped")
                return nil
            }
        }
    }
}
