import Foundation
import GRDB
import os
import WatchtowerCore

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
    /// Where phone recording uploads land as `rec_*.m4a` + `.meta` —
    /// MeetingRecorderCenter's own recordings directory in production,
    /// a temp directory in tests.
    private let recordingsDirectory: URL
    /// Fired after a phone recording was ingested (file + sidecar on disk,
    /// `received` acked): `(audioURL, titleHint)`. AppState wires it to
    /// `MeetingRecorderCenter.ingestPhoneRecording` so the existing job
    /// queue picks the file up immediately; nil (tests, headless) leaves the
    /// recording to the recovered-recordings flow on next launch.
    private let onRecordingIngested: (@Sendable (URL, String?) -> Void)?
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
    /// Buffer-sweep cutoff sits one day past the LONGEST record window, so a
    /// record is only swept locally after hygiene has had a full window of
    /// daily scans (plus margin) to delete it server-side first.
    private static let eventSweepMargin: TimeInterval = 86_400

    /// When the relay last did real work (action applied/failed, chat turn
    /// streamed). Drives the hub's adaptive poll cadence; nil until then.
    var lastActivityAt: Date? { lastActivity.withLock { $0 } }

    init(
        dbPool: DatabasePool,
        transport: any CloudSyncTransport & Sendable,
        sidecar: HubSyncState,
        aiService: any AIServiceProtocol,
        dbPath: String? = nil,
        recordingsDirectory: URL = MeetingRecorderCenter.defaultRecordingsDirectory(),
        onRecordingIngested: (@Sendable (URL, String?) -> Void)? = nil,
        chunkInterval: Duration = .milliseconds(1500),
        streamTimeout: Duration = .seconds(300),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.dbPool = dbPool
        self.transport = transport
        self.sidecar = sidecar
        self.aiService = aiService
        self.dbPath = dbPath
        self.recordingsDirectory = recordingsDirectory
        self.onRecordingIngested = onRecordingIngested
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
            case RelayRecordKind.recordingUpload.rawValue:
                try await processRecordingUpload(record)
            default:
                // Our own write-backs (chat chunks) and future kinds pass through.
                continue
            }
        }

        try persistToken(batch.newToken)
        // The relay buffer intentionally retains history well past consumption:
        // hygiene's aged-record scan calls changes(in: .relay, since: nil) and needs
        // records to have aged 7/30 days before deleting them. Compacting here would
        // silently drop those records before hygiene can find them, disabling
        // server-side retention. The buffer is trimmed only by hygiene's own
        // age sweep (runHygieneIfDue → SweepingTransport), one day past the
        // longest record window.
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

    // MARK: - Phone recording ingest

    /// Ingests one phone `recording_upload`: validates the CKAsset file,
    /// drops `rec_*.m4a` + `.meta` into the recordings directory via
    /// `MeetingRecorderCenter.ingestExternalRecording` (the crash-recovery
    /// family — never a second transcription path), writes back `received`
    /// (or `failed` + message), marks the record processed, and fires
    /// `onRecordingIngested` so the running app enqueues transcription.
    ///
    /// Ordering mirrors `processAction`: ack save FIRST, processed-set mark
    /// second. A crash between the file copy and the mark replays the batch
    /// and re-copies under a fresh unique name — a rare duplicate recording,
    /// accepted over the inverse (marking first): a processed-but-unacked
    /// record would leave the phone re-uploading forever with every retry
    /// silently swallowed.
    private func processRecordingUpload(_ record: CloudRecord) async throws {
        let upload: RecordingUploadPayload
        do {
            upload = try RelayCoder.makeDecoder().decode(RecordingUploadPayload.self, from: record.payload)
        } catch {
            logger.warning("""
                undecodable recording upload record \(record.recordName, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            return
        }
        // Echo of our own status write-back (same recordName, received/failed).
        guard upload.status == .pending else { return }
        guard try !sidecar.isRelayProcessed(record.recordName) else { return }

        var result = upload
        var ingested: URL?
        do {
            let audioURL = try ingestAsset(of: record, titleHint: upload.titleHint)
            ingested = audioURL
            result.status = .received
        } catch {
            result.status = .failed
            result.errorMessage = error.localizedDescription
            logger.warning("""
                recording upload \(record.recordName, privacy: .public) failed: \
                \(error.localizedDescription, privacy: .public)
                """)
        }
        // The write-back carries NO asset — rewriting the record is what
        // drops the audio from iCloud once the file is safe on this Mac.
        try await transport.save([
            try CloudRecordFactory.record(for: result, modifiedAt: now(), assetFileURL: nil)
        ])
        try sidecar.markRelayProcessed(record.recordName, at: now())
        lastActivity.withLock { $0 = now() }
        if let ingested {
            // The transport's stashed asset copy is consumed; best-effort.
            if let asset = record.assetFileURL {
                try? FileManager.default.removeItem(at: asset)
            }
            onRecordingIngested?(ingested, upload.titleHint)
        }
    }

    /// Validates the record's asset file and lands it in the recordings
    /// directory. Throws `RelayRecordingError` — whose description becomes
    /// the `failed` echo's message — for a missing or empty asset.
    private func ingestAsset(of record: CloudRecord, titleHint: String?) throws -> URL {
        guard let assetURL = record.assetFileURL,
              FileManager.default.fileExists(atPath: assetURL.path) else {
            throw RelayRecordingError.assetMissing
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: assetURL.path)[.size] as? Int64) ?? 0
        guard size > 0 else { throw RelayRecordingError.assetEmpty }
        return try MeetingRecorderCenter.ingestExternalRecording(
            from: assetURL, title: titleHint, in: recordingsDirectory, date: now()
        )
    }

    // MARK: - Hygiene (relay retention)

    /// Daily retention pass over the relay zone: action records older than
    /// 7 days and chat records older than 30 are deleted via a full zone
    /// scan (`since: nil` — the relay change token is untouched). Guarded by
    /// a hub_meta last-run stamp so it runs at most once per day. After the
    /// server-side record pass, an age sweep trims the LOCAL event buffer
    /// (which otherwise grows forever — even these deletes only append
    /// tombstone events); the ordering is load-bearing, see below.
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
            case RelayRecordKind.recordingUpload.rawValue where age > Self.actionMaxAge:
                // Same guard as actions: a still-pending upload that was never
                // processed must survive for processOnce to ingest — mobile
                // would otherwise wait on an ack that can never come. Our own
                // received/failed write-backs purge by age alone.
                if let upload = try? RelayCoder.makeDecoder().decode(
                    RecordingUploadPayload.self, from: record.payload
                ), upload.status == .pending,
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
        // Local-buffer age sweep — strictly AFTER the record pass above: sweeping
        // first would remove aged events from the `since: nil` scan before their
        // server records were ever deleted, silently disabling retention.
        // AGE-based with a margin past the longest record window, so it cannot
        // re-blind the aged-record scan (anything older than the cutoff has had a
        // daily scan every day it was in-window — the Plan 3 final-review
        // argument). The stored relay token bounds the sweep so an UNCONSUMED
        // event is never swept regardless of age: a desktop that was off for
        // weeks buffers old-modifiedAt records on its first pull, and hygiene
        // runs before processOnce in the relay loop — an unguarded sweep would
        // delete a still-pending mobile action before the processor ever saw it
        // (CKSyncEngine never redelivers fetched records). See
        // TransportStore.sweepEvents for the full walk.
        if let sweeping = transport as? any SweepingTransport {
            do {
                let cutoff = current.addingTimeInterval(-(Self.chatMaxAge + Self.eventSweepMargin))
                let floor = try storedToken() ?? CloudChangeToken(value: 0)
                let swept = try await sweeping.sweepEvents(in: .relay, olderThan: cutoff, upTo: floor)
                if swept > 0 { logger.info("hygiene: swept \(swept) aged relay buffer events") }
            } catch {
                // Local trim only — never fail the hygiene pass over it; the
                // next daily run retries.
                logger.warning("relay event sweep failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        // Retention on the idempotency set: entries older than the longest relay
        // record lifetime (chat) can never guard against a live duplicate again.
        try sidecar.pruneRelayProcessed(olderThan: current.addingTimeInterval(-Self.chatMaxAge))
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

        // Shared with the consumer child task; the group awaits that child
        // before returning, so the error path below never races it.
        let seq = OSAllocatedUnfairLock(initialState: 0)
        do {
            switch message.context?.type {
            case nil:
                try await streamGenericTurn(for: message, seq: seq)
            case "situation":
                try await streamSituationTurn(for: message, situationID: message.context?.id, seq: seq)
            case .some(let unknown):
                throw SituationChatRelayError.unsupportedContext(unknown)
            }
        } catch {
            logger.warning("""
                chat message \(record.recordName, privacy: .public) stream failed: \
                \(error.localizedDescription, privacy: .public)
                """)
            // Covers both error paths — stream failure and the watchdog
            // timeout (streamTurn rethrows RelayChatError.streamTimeout here).
            try await saveChunk(
                for: message, seq: seq, text: "⚠️ " + error.localizedDescription, done: true, isError: true
            )
        }
        try sidecar.markRelayProcessed(record.recordName, at: now())
        lastActivity.withLock { $0 = now() }
    }

    /// The generic secretary chat: no entity context, the CLI session lives in
    /// the sidecar's mobile-session map, and the answer is not persisted
    /// anywhere on the desktop (the phone's replica is the only record) —
    /// today's path, unchanged.
    private func streamGenericTurn(
        for message: ChatMessagePayload,
        seq: OSAllocatedUnfairLock<Int>
    ) async throws {
        // First turn of a mobile session has no CLI session yet and needs the
        // full system prompt; resumed sessions carry their context in the CLI.
        let cliSessionID = try sidecar.cliSessionID(forMobileSession: message.sessionID)
        let systemPrompt: String? = cliSessionID == nil ? ChatViewModel.buildSystemPrompt(dbPool: dbPool) : nil
        _ = try await streamTurn(
            for: message,
            promptText: message.text,
            cliSessionID: cliSessionID,
            systemPrompt: systemPrompt,
            seq: seq
        ) { [sidecar] id in
            // Persist immediately: a crash mid-stream must not orphan the session.
            try sidecar.setCLISessionID(id, forMobileSession: message.sessionID)
        }
    }

    /// A situation's Discuss chat: the turn joins the DESKTOP's conversation
    /// for that situation (see `SituationChatRelay`) — same prompt, same CLI
    /// session, both turns persisted into `chat_messages`.
    private func streamSituationTurn(
        for message: ChatMessagePayload,
        situationID rawID: String?,
        seq: OSAllocatedUnfairLock<Int>
    ) async throws {
        guard let rawID, let situationID = Int(rawID) else {
            throw SituationChatRelayError.situationNotFound(-1)
        }
        let turn = try SituationChatRelay.prepareTurn(
            dbPool: dbPool, situationID: situationID, text: message.text
        )
        let answer = try await streamTurn(
            for: message,
            promptText: turn.promptText,
            cliSessionID: turn.cliSessionID,
            systemPrompt: turn.systemPrompt,
            seq: seq
        ) { [dbPool] id in
            try SituationChatRelay.persistSessionID(
                dbPool: dbPool, conversationID: turn.conversationID, sessionID: id
            )
        }
        try SituationChatRelay.persistAnswer(
            dbPool: dbPool, conversationID: turn.conversationID, text: answer
        )
    }

    /// Consumes one AI stream, racing it against an inactivity watchdog: if
    /// no stream event arrives within `streamTimeout` the group throws
    /// `RelayChatError.streamTimeout`, cancelling the stream task (the
    /// caller then emits the error-path final chunk). Whichever child loses
    /// is cancelled and awaited before the group returns.
    ///
    /// Returns the full answer text for callers that persist it (the
    /// situation path). A throw returns nothing: a partial answer is not an
    /// answer, and the caller's error chunk is what the phone sees.
    @discardableResult
    private func streamTurn(
        for message: ChatMessagePayload,
        promptText: String,
        cliSessionID: String?,
        systemPrompt: String?,
        seq: OSAllocatedUnfairLock<Int>,
        onSessionID: @escaping @Sendable (String) throws -> Void
    ) async throws -> String {
        let lastEvent = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
        let answer = OSAllocatedUnfairLock(initialState: "")
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [self] in
                let stream = aiService.stream(
                    prompt: promptText,
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
                        answer.withLock { $0 += delta }
                        if lastFlush.duration(to: clock.now) >= chunkInterval, !pending.isEmpty {
                            try await saveChunk(for: message, seq: seq, text: pending, done: false)
                            pending = ""
                            lastFlush = clock.now
                        }
                    case .sessionID(let id):
                        try onSessionID(id)
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
        return answer.withLock { $0 }
    }

    /// Saves one chunk record. `seq` advances only after a successful save,
    /// so a transient transport failure retries the same slot instead of
    /// leaving a permanent gap before the error-path flush.
    private func saveChunk(
        for message: ChatMessagePayload,
        seq: OSAllocatedUnfairLock<Int>,
        text: String,
        done: Bool,
        isError: Bool? = nil // swiftlint:disable:this discouraged_optional_boolean
    ) async throws {
        let chunk = ChatChunkPayload(
            sessionID: message.sessionID,
            messageID: message.id,
            seq: seq.withLock { $0 },
            text: text,
            done: done,
            isError: isError
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
        case .situationDone:
            let id = try entityInt(action)
            try requireRow(db, table: "situations", id: id)
            try SituationQueries.done(db, id: id)
        case .situationDismiss:
            let id = try entityInt(action)
            try requireRow(db, table: "situations", id: id)
            try SituationQueries.dismiss(db, id: id)
        case .situationSnooze:
            let id = try entityInt(action)
            try requireRow(db, table: "situations", id: id)
            // Situation snooze stores the raw string, like inbox snooze.
            try SituationQueries.snooze(db, id: id, until: try stringParam(action, "snooze_until"))
        case .situationKeepOpen:
            let id = try entityInt(action)
            try requireRow(db, table: "situations", id: id)
            try SituationQueries.clearSuggestedResolution(db, id: id)
        case .dayPlanItemDone:
            let id = try entityInt(action)
            try requireRow(db, table: "day_plan_items", id: id)
            // Whether finishing the block also finishes its source task is
            // decided HERE from the row's own source_type (the desktop's rule
            // in DayPlanViewModel.markDone), never from a phone-supplied flag.
            try DayPlanQueries.markItemDone(
                db, itemId: Int64(id), cascadeToTask: try isTaskSourced(db, itemID: id)
            )
        case .dayPlanItemSkip:
            let id = try entityInt(action)
            try requireRow(db, table: "day_plan_items", id: id)
            // Skipping does NOT cascade: the block is not happening today, but
            // the underlying task is still open.
            try DayPlanQueries.markItemSkipped(db, itemId: Int64(id))
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

    /// True when the day-plan item came from a task, which is what makes its
    /// completion cascade to that task.
    private func isTaskSourced(_ db: Database, itemID: Int) throws -> Bool {
        try String.fetchOne(
            db,
            sql: "SELECT source_type FROM day_plan_items WHERE id = ?",
            arguments: [itemID]
        ) == "task"
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

/// Why a phone recording upload could not be ingested. `errorDescription`
/// becomes the `errorMessage` echoed back to mobile in the failed status
/// record — the phone keeps its local copy and may retry.
enum RelayRecordingError: Error, LocalizedError, Equatable {
    case assetMissing
    case assetEmpty

    var errorDescription: String? {
        switch self {
        case .assetMissing:
            return "recording asset is missing"
        case .assetEmpty:
            return "recording asset is empty"
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
