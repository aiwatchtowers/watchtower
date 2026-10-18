import Foundation
import GRDB
import Observation
import os
import WatchtowerKit
import WatchtowerSync

/// A session's chat (the main feed, or one subagent's), pushed from the
/// session detail or from a subagent row.
struct SessionChatRoute: Hashable {
    let sessionID: Int64
    /// nil for the main feed.
    let agentID: String?
}

/// Asks the Mac to publish a session's chat (`session_chat_request`): at
/// once on `start`, then every 60 s until `stop`. The Mac watches a chat for
/// five minutes after each request and publishes it only while watched, so
/// the repeat keeps a screen that stays open fed (FEED-05).
@MainActor
final class SessionChatRequester {
    static let interval: TimeInterval = 60

    private let send: (Int64, String?) async throws -> Void
    private let ticks: () -> AsyncStream<Void>
    private var loop: Task<Void, Never>?
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "SessionChatRequester")

    /// `ticks` yields once per repeat; the default waits `interval` between
    /// yields, tests feed their own.
    init(
        ticks: @escaping () -> AsyncStream<Void> = SessionChatRequester.clockTicks,
        send: @escaping (Int64, String?) async throws -> Void
    ) {
        self.ticks = ticks
        self.send = send
    }

    /// The app's requester: one idempotent action through the outbox, the
    /// session's own record as its entity.
    static func sending(through outbox: ActionOutbox) -> SessionChatRequester {
        SessionChatRequester { sessionID, agentID in
            try await outbox.enqueue(
                kind: SessionChatRequestParams.actionKind,
                entityRecordName: SliceKind.terminalSession.recordName(id: String(sessionID)),
                params: try SessionChatRequestParams(sessionID: sessionID, subagentID: agentID).wireParams()
            )
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
    func start(sessionID: Int64, agentID: String?) {
        stop()
        let send = send
        let stream = ticks()
        loop = Task {
            await Self.request(send, sessionID, agentID)
            for await _ in stream {
                if Task.isCancelled { break }
                await Self.request(send, sessionID, agentID)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    nonisolated private static func request(_ send: (Int64, String?) async throws -> Void, _ sessionID: Int64, _ agentID: String?) async {
        do {
            try await send(sessionID, agentID)
        } catch {
            logger.warning("session chat request failed: \(error.localizedDescription, privacy: .public)")
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
    private(set) var chat: SessionChat?
    /// 60 s went by with no record: the Mac may be asleep.
    private(set) var waitingTooLong = false
    private(set) var waitingForKeys = false

    @ObservationIgnored private let store: ReplicaStore
    @ObservationIgnored private let requester: SessionChatRequester
    @ObservationIgnored private let sleep: (TimeInterval) async -> Void
    @ObservationIgnored private var cancellable: ResilientObservation?
    @ObservationIgnored private var patience: Task<Void, Never>?
    @ObservationIgnored let decodeCache = ReplicaDecodeCache()
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "SessionChatViewModel")

    static let waitLimit: TimeInterval = 60

    init(
        sessionID: Int64,
        agentID: String?,
        store: ReplicaStore,
        requester: SessionChatRequester,
        sleep: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
    ) {
        self.sessionID = sessionID
        self.agentID = agentID
        self.store = store
        self.requester = requester
        self.sleep = sleep
    }

    /// "12 earlier messages — open on the Mac" or nil.
    var earlierText: String? { Self.earlierText(chat?.entriesMore ?? 0) }

    static func earlierText(_ more: Int) -> String? {
        guard more > 0 else { return nil }
        return "\(more) earlier \(more == 1 ? "message" : "messages") — open on the Mac"
    }

    /// The screen appeared: observe and ask the Mac for the chat.
    func appeared() {
        observe()
        requester.start(sessionID: sessionID, agentID: agentID)
        if chat == nil, patience == nil {
            let limit = Self.waitLimit
            let sleep = sleep
            patience = Task { [weak self] in
                await sleep(limit)
                guard !Task.isCancelled else { return }
                self?.waitingTooLong = self?.chat == nil
            }
        }
    }

    /// The screen went away: stop asking.
    func disappeared() {
        requester.stop()
        patience?.cancel()
        patience = nil
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
                self?.chat = value
                if value != nil { self?.waitingTooLong = false }
                self?.waitingForKeys = false
            }
        )
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
