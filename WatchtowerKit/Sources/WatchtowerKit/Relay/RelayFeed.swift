import Foundation
import os

/// The seam through which RelayFeed hands chat chunks onward. Task 5's
/// `ChatAssembler` conforms; the feed and its tests are written against this
/// protocol so the assembler plugs in without touching RelayFeed.
///
/// Delivery contract: the feed calls `ingest` for every decodable
/// `chat_chunk` record in batch order, BEFORE the relay token is persisted —
/// an `ingest` throw aborts the cycle with the token untouched, so the batch
/// replays next poll. `ingest` must therefore be idempotent per chunk.
public protocol ChatChunkAssembling: Sendable {
    func ingest(_ chunk: ChatChunkPayload) async throws
}

/// The phone's SINGLE relay consumer (Plan 4 decision 3): owns the persisted
/// relay-zone change token (`replica_meta`, key `relay_change_token`) and
/// fans records out in-process —
/// - `action` echoes → `ActionOutbox.applyEcho` (own still-`pending`
///   enqueues reflecting back are skipped),
/// - `chat_chunk` → the `ChatChunkAssembling` seam,
/// - `heartbeat` → `ReplicaStore.setHeartbeat` (liveness),
/// - `chat_message` → ignored (our own outgoing turns; the desktop consumes
///   those), unknown kinds → logged once per kind and ignored.
///
/// Nothing else on the phone may call `changes(in: .relay, …)` — a second
/// consumer would need its own token and would race this one's routing (the
/// Plan 2 Task 6 lesson).
///
/// Token discipline: the token is persisted at batch END, so a mid-batch
/// throw replays the batch next cycle (all routing is idempotent), while an
/// undecodable payload never wedges the feed — it is logged, skipped, and
/// left behind by the advancing token.
public actor RelayFeed {
    /// The desktop refreshes its heartbeat every ~5 minutes; a heartbeat
    /// STRICTLY older than 12 minutes means unreachable (spec §2).
    public static let heartbeatStaleAfter: Duration = .seconds(12 * 60)

    private let transport: any CloudSyncTransport
    private let store: ReplicaStore
    private let outbox: ActionOutbox
    /// `ChatAssembler` in the app (wired by AppEnvironment). SEAM NOTE —
    /// with no assembler, decodable chat chunks are DROPPED: the token still
    /// advances, so they will never replay. Acceptable strictly while no
    /// chat UI exists (nothing on the phone can start a session, so real
    /// chunks addressed to it cannot occur); the Chat tab (Task 7) must not
    /// ship without the assembler wired.
    private let assembler: (any ChatChunkAssembling)?
    /// `RecordingUploader` in the app (wired by AppEnvironment); nil in
    /// environments without phone recording. Unlike the assembler's drop,
    /// missing-uploader echoes are harmless to skip: the ledger row simply
    /// stays `uploading` until a build with the uploader wired polls again
    /// (hub echoes are re-read from scratch only via token reset) — so the
    /// uploader must ship wired wherever the Record UI ships.
    private let uploads: (any RecordingUploadAcking)?
    /// Wraps CloudKitTransport.pull() at composition time; nil in tests
    /// (InMemoryCloudTransport has no engine to nudge).
    private let pull: (@Sendable () async throws -> Void)?
    /// Fired (fire-and-forget, once per batch) after routing at least one
    /// `applied` echo AND persisting the token. AppEnvironment wires it to
    /// `hydrator.hydrateOnce()` (Task 6) so the authoritative slice change
    /// lands right as the optimistic overlay disappears — collapsing the
    /// flicker window. Because it is detached, a slow or hung hook can never
    /// delay `pollOnce`'s return or the next cycle. The fire-and-forget Task
    /// is untracked: `stop()` does not cancel it and it may outlive the feed
    /// — harmless for the hydrate-nudge purpose (a spurious re-hydration is
    /// an idempotent no-op).
    private let onActionApplied: (@Sendable () async -> Void)?
    private var loopTask: Task<Void, Never>?
    /// The currently-running cycle, if any. Concurrent `pollOnce` callers
    /// await this instead of starting their own — see `pollOnce`.
    private var inFlight: Task<(echoes: Int, chunks: Int), Error>?
    /// Unknown record kinds already warned about — log once per kind per feed
    /// instance (a newer desktop may ship kinds this build does not know).
    private(set) var loggedUnknownKinds: Set<String> = []
    private let logger = Logger(subsystem: "WatchtowerKit", category: "RelayFeed")

    public init(
        transport: any CloudSyncTransport,
        store: ReplicaStore,
        outbox: ActionOutbox,
        assembler: (any ChatChunkAssembling)? = nil,
        uploads: (any RecordingUploadAcking)? = nil,
        pull: (@Sendable () async throws -> Void)? = nil,
        onActionApplied: (@Sendable () async -> Void)? = nil
    ) {
        self.transport = transport
        self.store = store
        self.outbox = outbox
        self.assembler = assembler
        self.uploads = uploads
        self.pull = pull
        self.onActionApplied = onActionApplied
    }

    // MARK: - One cycle

    /// One relay cycle: optional engine pull, read relay-zone changes since
    /// the persisted relay token, route every record, persist the new token.
    /// Returns how many desktop echoes and chat chunks were routed.
    ///
    /// Cycles are coalesced exactly like `ReplicaHydrator.hydrateOnce`:
    /// actors are reentrant, so a caller arriving while a cycle is suspended
    /// (at `pull`/`changes`) would otherwise start a second overlapping cycle
    /// that re-routes records and races the token. Concurrent callers await
    /// the running cycle's own result instead. (The store's monotonic
    /// `setRelayToken` guard is the belt to this suspenders.)
    @discardableResult
    public func pollOnce() async throws -> (echoes: Int, chunks: Int) {
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task { try await self.performPoll() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    private func performPoll() async throws -> (echoes: Int, chunks: Int) {
        try await pull?()
        let since = try store.relayToken()
        let batch = try await transport.changes(in: .relay, since: since)
        // Monotonic stale-batch drop, mirroring ReplicaStore.apply — but
        // checked BEFORE routing, because routing has side effects (echo
        // resolution, heartbeat) that a replayed stale batch must not
        // re-fire. Also short-circuits the common empty poll (newToken ==
        // since). Unreachable for genuinely overlapping cycles while
        // pollOnce coalesces; kept as defense in depth.
        if let since, batch.newToken.value <= since.value {
            return (echoes: 0, chunks: 0)
        }

        var echoes = 0
        var chunks = 0
        var appliedEchoRouted = false
        for record in batch.changed {
            let outcome = try await route(record)
            echoes += outcome.echoes
            chunks += outcome.chunks
            if outcome.appliedEcho { appliedEchoRouted = true }
        }

        try store.setRelayToken(batch.newToken)
        if appliedEchoRouted, let onActionApplied {
            // Fire-and-forget AFTER the token is persisted: the hook exists
            // to trigger re-hydration, and it must observe post-batch state —
            // while its execution (however slow) stays off this cycle's and
            // the next cycle's critical path. One fire per batch is enough:
            // the consumer re-hydrates everything anyway.
            Task { await onActionApplied() }
        }
        return (echoes: echoes, chunks: chunks)
    }

    /// Routes ONE relay record to its consumer; every path is idempotent
    /// (the batch replays on a mid-batch throw — see `performPoll`).
    /// `appliedEcho` is true only for a desktop `applied` action verdict —
    /// the trigger for the post-batch hydrate nudge.
    private func route(_ record: CloudRecord) async throws -> (echoes: Int, chunks: Int, appliedEcho: Bool) {
        switch RelayRecordKind(rawValue: record.kind) {
        case .action:
            guard let action = decode(ActionRequestPayload.self, from: record) else { break }
            // A still-pending record is our OWN enqueue reflecting back
            // through the shared zone — not a desktop verdict. Skip.
            guard action.status != .pending else { break }
            try await outbox.applyEcho(action)
            return (echoes: 1, chunks: 0, appliedEcho: action.status == .applied)
        case .chatMessage:
            // Our own outgoing user turns; the desktop is their consumer.
            break
        case .chatChunk:
            guard let chunk = decode(ChatChunkPayload.self, from: record) else { break }
            guard let assembler else {
                // Dropped for good — see the seam note on `assembler`.
                logger.warning("chat chunk dropped, no assembler wired (Task 5): \(record.recordName, privacy: .public)")
                break
            }
            try await assembler.ingest(chunk)
            return (echoes: 0, chunks: 1, appliedEcho: false)
        case .heartbeat:
            guard let heartbeat = decode(HeartbeatPayload.self, from: record) else { break }
            try store.setHeartbeat(updatedAt: heartbeat.updatedAt)
        case .recordingUpload:
            guard let upload = decode(RecordingUploadPayload.self, from: record) else { break }
            // A still-pending record is our OWN upload reflecting back —
            // the hub's verdict is what flips the ledger. Skip.
            guard upload.status != .pending else { break }
            guard let uploads else {
                logger.warning("recording upload echo skipped, no uploader wired: \(record.recordName, privacy: .public)")
                break
            }
            try await uploads.applyEcho(upload)
            return (echoes: 1, chunks: 0, appliedEcho: false)
        case nil:
            if loggedUnknownKinds.insert(record.kind).inserted {
                logger.warning("unknown relay record kind ignored: \(record.kind, privacy: .public)")
            }
        }
        return (echoes: 0, chunks: 0, appliedEcho: false)
    }

    /// Decodes a relay payload of a KNOWN kind; a failure is logged and
    /// returns nil so the caller skips the record (the token still advances —
    /// an undecodable record must never wedge the feed).
    private func decode<P: Decodable>(_ type: P.Type, from record: CloudRecord) -> P? {
        do {
            return try RelayCoder.makeDecoder().decode(type, from: record.payload)
        } catch {
            logger.warning("undecodable \(record.kind, privacy: .public) relay payload skipped: \(record.recordName, privacy: .public)")
            return nil
        }
    }

    // MARK: - Liveness

    /// True while the last desktop heartbeat is at most 12 minutes old
    /// (spec §2); false when none was ever seen. `now` is injectable for
    /// tests and for view models that batch-evaluate against one timestamp.
    nonisolated public func isDesktopReachable(now: Date = Date()) -> Bool {
        // A read error means we cannot prove liveness — report unreachable
        // (try? flattens heartbeatAge's own nil into the same branch).
        guard let age = try? store.heartbeatAge(now: now) else { return false }
        return age <= Self.heartbeatStaleAfter
    }

    // MARK: - Poll loop

    /// Chat needs snappier polling than the hydrator's 30 s, and 5 s against
    /// the in-process demo transport is free. Real-CloudKit cadence tuning
    /// (push nudges, backoff, battery budget) belongs to the packaging plan.
    public func start(interval: Duration = .seconds(5)) {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                do {
                    _ = try await self.pollOnce()
                } catch {
                    self.logger.error("relay poll cycle failed: \(error.localizedDescription, privacy: .public)")
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
    }
}
