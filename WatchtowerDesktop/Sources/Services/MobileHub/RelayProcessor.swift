import Foundation
import GRDB
import os

/// Applies mobile-originated relay actions to the local DB through the
/// existing Queries, then writes an applied/failed status record back to
/// the relay zone so mobile sees the outcome.
///
/// Idempotency: the sidecar's `relay_processed` set absorbs duplicate
/// deliveries, and the relay change token is persisted only after a fully
/// processed batch — a crash mid-batch re-reads the whole batch, and the
/// processed set makes the replay safe.
final class RelayProcessor: Sendable {
    private let dbPool: DatabasePool
    private let transport: any CloudSyncTransport & Sendable
    private let sidecar: HubSyncState
    private let aiService: any AIServiceProtocol
    /// Main DB path handed to the AI CLI so chat can query it; nil in tests.
    private let dbPath: String?
    /// Minimum spacing between non-final chat chunks (pseudo-streaming cadence).
    private let chunkInterval: Duration
    /// Watchdog window: max silence between stream events before the chat
    /// turn is aborted with an error chunk — a hung CLI must not wedge the
    /// relay pipeline (actions later in the batch, the change token).
    private let streamTimeout: Duration
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: Constants.bundleID, category: "RelayProcessor")
    private let lastActivity = OSAllocatedUnfairLock<Date?>(initialState: nil)

    static let relayTokenKey = "relay_change_token"
    static let hygieneStampKey = "hygiene_last_run"
    private static let hygieneInterval: TimeInterval = 86_400
    private static let actionMaxAge: TimeInterval = 7 * 86_400
    private static let chatMaxAge: TimeInterval = 30 * 86_400

    /// When the relay last did real work (action applied/failed, chat turn
    /// streamed). Drives the hub's adaptive poll cadence; nil until then.
    var lastActivityAt: Date? { lastActivity.withLock { $0 } }

    init(
        dbPool: DatabasePool,
        transport: any CloudSyncTransport & Sendable,
        sidecar: HubSyncState,
        aiService: any AIServiceProtocol,
        dbPath: String? = nil,
        chunkInterval: Duration = .milliseconds(1500),
        streamTimeout: Duration = .seconds(300),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.dbPool = dbPool
        self.transport = transport
        self.sidecar = sidecar
        self.aiService = aiService
        self.dbPath = dbPath
        self.chunkInterval = chunkInterval
        self.streamTimeout = streamTimeout
        self.now = now
    }

    // MARK: - Processing

    /// One poll cycle over the relay zone. Returns the number of actions applied.
    /// One bad action (missing entity, unknown id, unparseable date, …) becomes
    /// a `.failed` status record and never stops the rest of the batch.
    /// Chat messages are relayed to the AI service and answered as chunk
    /// records; they never count toward the returned total.
    func processOnce() async throws -> Int {
        let token = try storedToken()
        let batch = try await transport.changes(in: .relay, since: token)
        var applied = 0

        for record in batch.changed {
            switch record.kind {
            case RelayRecordKind.action.rawValue:
                if try await processAction(record) { applied += 1 }
            case RelayRecordKind.chatMessage.rawValue:
                try await processChatMessage(record)
            default:
                // Our own write-backs (chat chunks) and future kinds pass through.
                continue
            }
        }

        try persistToken(batch.newToken)
        return applied
    }

    /// Returns true when the action was applied to the local DB.
    private func processAction(_ record: CloudRecord) async throws -> Bool {
        let action: ActionRequestPayload
        do {
            action = try RelayCoder.makeDecoder().decode(ActionRequestPayload.self, from: record.payload)
        } catch {
            // No decodable id → no status record to write back; log and move on.
            logger.warning("""
                undecodable action record \(record.recordName, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            return false
        }
        // Echo of our own status write-back (same recordName, applied/failed).
        guard action.status == .pending else { return false }
        // Duplicate delivery of an already-applied action (spec Section 4).
        guard try !sidecar.isRelayProcessed(record.recordName) else { return false }

        var result = action
        var applied = true
        do {
            try await dbPool.write { [self] db in try apply(action, db: db) }
            result.status = .applied
        } catch {
            applied = false
            result.status = .failed
            result.errorMessage = error.localizedDescription
            logger.warning("""
                action \(record.recordName, privacy: .public) failed: \
                \(error.localizedDescription, privacy: .public)
                """)
        }
        try await transport.save([CloudRecordFactory.record(for: result, modifiedAt: now())])
        try sidecar.markRelayProcessed(record.recordName, at: now())
        lastActivity.withLock { $0 = now() }
        return applied
    }

    // MARK: - Hygiene (relay retention)

    /// Daily retention pass over the relay zone: action records older than
    /// 7 days and chat records older than 30 are deleted via a full zone
    /// scan (`since: nil` — the relay change token is untouched). Guarded by
    /// a hub_meta last-run stamp so it runs at most once per day.
    ///
    /// Note: the full-zone scan may not yet see records authored by this desktop
    /// (status echoes, chat chunks, heartbeat) if the CloudKit engine has not
    /// re-fetched them — hygiene of self-authored records is best-effort until
    /// the Plan 3 transport work that provides read-your-writes guarantees.
    func runHygieneIfDue() async throws {
        let current = now()
        if let raw = try sidecar.metaValue(forKey: Self.hygieneStampKey),
           let last = TimeInterval(raw),
           current.timeIntervalSince1970 - last < Self.hygieneInterval {
            return
        }
        let batch = try await transport.changes(in: .relay, since: nil)
        var stale: [String] = []
        for record in batch.changed {
            let age = current.timeIntervalSince(record.modifiedAt)
            switch record.kind {
            case RelayRecordKind.action.rawValue where age > Self.actionMaxAge:
                // Never delete a still-pending action that was never processed: it
                // must survive for processOnce to apply/fail first so mobile hears
                // the outcome. Applied/failed echoes (our own write-backs) are safe
                // to purge by age alone.
                if let action = try? RelayCoder.makeDecoder().decode(
                    ActionRequestPayload.self, from: record.payload
                ), action.status == .pending,
                   !(try sidecar.isRelayProcessed(record.recordName)) {
                    break
                }
                stale.append(record.recordName)
            case RelayRecordKind.chatMessage.rawValue, RelayRecordKind.chatChunk.rawValue:
                if age > Self.chatMaxAge { stale.append(record.recordName) }
            default:
                // Heartbeat (perpetually rewritten) and future kinds are kept.
                break
            }
        }
        if !stale.isEmpty {
            try await transport.delete(recordNames: stale, in: .relay)
            logger.info("hygiene: deleted \(stale.count) stale relay records")
        }
        try sidecar.setMetaValue(String(current.timeIntervalSince1970), forKey: Self.hygieneStampKey)
    }

    // MARK: - Chat relay

    /// Streams one mobile chat turn through the AI service, publishing the
    /// response as monotonic chunk records (flushed at most every
    /// `chunkInterval`). A stream failure — including the `streamTimeout`
    /// watchdog tripping — becomes the final chunk's text; the message is
    /// marked processed either way, so there is no retry loop.
    private func processChatMessage(_ record: CloudRecord) async throws {
        let message: ChatMessagePayload
        do {
            message = try RelayCoder.makeDecoder().decode(ChatMessagePayload.self, from: record.payload)
        } catch {
            logger.warning("""
                undecodable chat message record \(record.recordName, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            return
        }
        guard try !sidecar.isRelayProcessed(record.recordName) else { return }
        lastActivity.withLock { $0 = now() }

        // First turn of a mobile session has no CLI session yet and needs the
        // full system prompt; resumed sessions carry their context in the CLI.
        let cliSessionID = try sidecar.cliSessionID(forMobileSession: message.sessionID)
        let systemPrompt: String? = cliSessionID == nil ? ChatViewModel.buildSystemPrompt(dbPool: dbPool) : nil

        // Shared with the consumer child task; the group awaits that child
        // before returning, so the error path below never races it.
        let seq = OSAllocatedUnfairLock(initialState: 0)
        do {
            try await streamTurn(for: message, cliSessionID: cliSessionID, systemPrompt: systemPrompt, seq: seq)
        } catch {
            logger.warning("""
                chat message \(record.recordName, privacy: .public) stream failed: \
                \(error.localizedDescription, privacy: .public)
                """)
            try await saveChunk(for: message, seq: seq, text: "⚠️ " + error.localizedDescription, done: true)
        }
        try sidecar.markRelayProcessed(record.recordName, at: now())
        lastActivity.withLock { $0 = now() }
    }

    /// Consumes one AI stream, racing it against an inactivity watchdog: if
    /// no stream event arrives within `streamTimeout` the group throws
    /// `RelayChatError.streamTimeout`, cancelling the stream task (the
    /// caller then emits the error-path final chunk). Whichever child loses
    /// is cancelled and awaited before the group returns.
    private func streamTurn(
        for message: ChatMessagePayload,
        cliSessionID: String?,
        systemPrompt: String?,
        seq: OSAllocatedUnfairLock<Int>
    ) async throws {
        let lastEvent = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [self] in
                let stream = aiService.stream(
                    prompt: message.text,
                    systemPrompt: systemPrompt,
                    sessionID: cliSessionID,
                    dbPath: dbPath
                )
                var pending = ""
                let clock = ContinuousClock()
                var lastFlush = clock.now
                for try await event in stream {
                    lastEvent.withLock { $0 = clock.now }
                    switch event {
                    case .text(let delta):
                        pending += delta
                        if lastFlush.duration(to: clock.now) >= chunkInterval, !pending.isEmpty {
                            try await saveChunk(for: message, seq: seq, text: pending, done: false)
                            pending = ""
                            lastFlush = clock.now
                        }
                    case .sessionID(let id):
                        // Persist immediately: a crash mid-stream must not orphan the session.
                        try sidecar.setCLISessionID(id, forMobileSession: message.sessionID)
                    case .turnComplete, .done:
                        // .turnComplete duplicates the accumulated .text deltas for
                        // WatchtowerAIService — revisit if a provider ever emits only
                        // turnComplete, whose text would be dropped here.
                        break
                    }
                }
                // A cancelled stream ends by returning nil — don't let the
                // watchdog's loser flush a bogus done-chunk on its way out.
                try Task.checkCancellation()
                try await saveChunk(for: message, seq: seq, text: pending, done: true)
            }
            group.addTask { [streamTimeout] in
                while true {
                    let deadline = lastEvent.withLock { $0 }.advanced(by: streamTimeout)
                    if ContinuousClock.now >= deadline { throw RelayChatError.streamTimeout }
                    try await Task.sleep(until: deadline, clock: .continuous)
                }
            }
            defer { group.cancelAll() }
            // First child to finish decides: stream done (watchdog cancelled,
            // its CancellationError discarded) or timeout/stream error rethrown.
            // Duplicate-done edge: if the consumer's final done-chunk save stalls
            // past the watchdog budget but ultimately succeeds while the watchdog's
            // throw wins the race, the error-path in processChatMessage emits a
            // second done chunk ("⚠️ chat stream timed out") after a complete
            // answer has already landed — an extremely narrow race, accepted;
            // do NOT reorder the save-then-seq-increment to "fix" this, the
            // seq-after-save ordering is load-bearing for gap-free delivery.
            try await group.next()
        }
    }

    /// Saves one chunk record. `seq` advances only after a successful save,
    /// so a transient transport failure retries the same slot instead of
    /// leaving a permanent gap before the error-path flush.
    private func saveChunk(
        for message: ChatMessagePayload,
        seq: OSAllocatedUnfairLock<Int>,
        text: String,
        done: Bool
    ) async throws {
        let chunk = ChatChunkPayload(
            sessionID: message.sessionID,
            messageID: message.id,
            seq: seq.withLock { $0 },
            text: text,
            done: done
        )
        try await transport.save([try CloudRecordFactory.record(for: chunk, modifiedAt: now())])
        seq.withLock { $0 += 1 }
    }

    // MARK: - Action → Query mapping

    private func apply(_ action: ActionRequestPayload, db: Database) throws {
        switch action.kind {
        case .targetDone:
            let id = try entityInt(action)
            try requireRow(db, table: "targets", id: id)
            try TargetQueries.updateStatus(db, id: id, status: "done")
        case .targetSnooze:
            let id = try entityInt(action)
            try requireRow(db, table: "targets", id: id)
            try TargetQueries.snooze(db, id: id, until: try dateParam(action, "snooze_until"))
        case .inboxResolve:
            let id = try entityInt(action)
            try requireRow(db, table: "inbox_items", id: id)
            try InboxQueries.resolve(db, id: id, reason: "Resolved from mobile")
        case .inboxDismiss:
            let id = try entityInt(action)
            try requireRow(db, table: "inbox_items", id: id)
            try InboxQueries.dismiss(db, id: id)
        case .inboxSnooze:
            let id = try entityInt(action)
            try requireRow(db, table: "inbox_items", id: id)
            // Inbox snooze stores the raw string; target snooze wants a Date.
            try InboxQueries.snooze(db, id: id, until: try stringParam(action, "snooze_until"))
        case .taskCreate:
            let text = try stringParam(action, "text")
            let today = Self.dayFormatter.string(from: now())
            try TargetQueries.create(db, text: text, periodStart: today, periodEnd: today)
        case .trackRead:
            let id = try entityInt(action)
            try requireRow(db, table: "tracks", id: id)
            try TrackQueries.markRead(db, id: id)
        }
    }

    // MARK: - Payload helpers

    private func entityInt(_ action: ActionRequestPayload) throws -> Int {
        guard let raw = action.entityID, !raw.isEmpty else {
            throw RelayActionError.missingEntityID(action.kind)
        }
        guard let id = Int(raw) else {
            throw RelayActionError.invalidEntityID(raw)
        }
        return id
    }

    private func stringParam(_ action: ActionRequestPayload, _ key: String) throws -> String {
        guard case .string(let value)? = action.params[key], !value.isEmpty else {
            throw RelayActionError.missingParam(key)
        }
        return value
    }

    private func dateParam(_ action: ActionRequestPayload, _ key: String) throws -> Date {
        let raw = try stringParam(action, key)
        // Try the plain formatter first (no fractional seconds), then one that
        // accepts sub-second precision (e.g. "2026-07-10T12:00:00.500Z").
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: raw) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: raw) else {
            throw RelayActionError.unparseableDate(raw)
        }
        return date
    }

    /// The mutation Queries are plain UPDATEs that succeed on 0 rows, so an
    /// unknown id must be detected up front to surface as `.failed`.
    private func requireRow(_ db: Database, table: String, id: Int) throws {
        let exists = try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM \(table) WHERE id = ?)",
            arguments: [id]
        ) ?? false
        guard exists else {
            throw RelayActionError.entityNotFound(table: table, id: id)
        }
    }

    // MARK: - Token persistence

    private func storedToken() throws -> CloudChangeToken? {
        guard let raw = try sidecar.metaValue(forKey: Self.relayTokenKey) else { return nil }
        guard let token = try? JSONDecoder().decode(CloudChangeToken.self, from: Data(raw.utf8)) else {
            // Corrupted token → full re-read; the processed set keeps the replay safe.
            logger.warning("unreadable relay change token, re-reading the zone from scratch")
            return nil
        }
        return token
    }

    private func persistToken(_ token: CloudChangeToken) throws {
        let data = try JSONEncoder().encode(token)
        // JSONEncoder always emits valid UTF-8, so the guard is unreachable;
        // skipping persistence just re-reads the zone next cycle (safe).
        guard let raw = String(bytes: data, encoding: .utf8) else { return }
        try sidecar.setMetaValue(raw, forKey: Self.relayTokenKey)
    }

    private static let dayFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()
}

/// Chat-relay failures. `errorDescription` becomes the final chunk's text
/// (prefixed with "⚠️ ") echoed back to mobile.
enum RelayChatError: Error, LocalizedError, Equatable {
    case streamTimeout

    var errorDescription: String? {
        switch self {
        case .streamTimeout:
            return "chat stream timed out"
        }
    }
}

/// Why an action could not be applied. `errorDescription` becomes the
/// `errorMessage` echoed back to mobile in the failed status record.
enum RelayActionError: Error, LocalizedError, Equatable {
    case missingEntityID(ActionKind)
    case invalidEntityID(String)
    case missingParam(String)
    case unparseableDate(String)
    case entityNotFound(table: String, id: Int)

    var errorDescription: String? {
        switch self {
        case .missingEntityID(let kind):
            return "\(kind.rawValue) requires an entity_id"
        case .invalidEntityID(let raw):
            return "entity_id is not an integer: \(raw)"
        case .missingParam(let key):
            return "missing required param: \(key)"
        case .unparseableDate(let raw):
            return "unparseable ISO8601 date: \(raw)"
        case let .entityNotFound(table, id):
            return "no row in \(table) with id \(id)"
        }
    }
}
