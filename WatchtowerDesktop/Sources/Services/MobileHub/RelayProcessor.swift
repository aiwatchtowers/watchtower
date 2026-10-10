import Foundation
import os
import WatchtowerCore
import WatchtowerSync

/// Reads phone requests from RelayZone and echoes each outcome into the same
/// record (mobile POC spec §5.2). Background type: decoding, the
/// exactly-once ledger, age and echoes happen here; the work itself hops to
/// the main-actor `MobileHubCommandDispatcher`.
///
/// Exactly-once (§5.2 rule 1): a record the sidecar holds as `done` is
/// never handled again. A non-idempotent kind is committed `begun` before
/// its handler runs and `done` after its echo; a record a later pass finds
/// still `begun` (the hub stopped mid-apply) is never re-applied but echoed
/// `failed` / `outcome_unknown`. Idempotent kinds simply re-run. The ledger
/// keeps each action's echoed outcome and the relay buffer mark (`newToken`)
/// of the pass that marked it: a `done` action that reads `pending` or
/// `received` in a change buffered PAST that mark (a phone save made after
/// the outcome: a lost ack, the phone's save winning over the echo) gets the
/// stored outcome echoed once more, without dispatching. A change at or
/// below the mark is the hub's own stale copy — CloudKit never buffers the
/// hub's own echo, so a re-read (a reset rewinding the cursor, a pass that
/// left a backlog) still shows the phone's first save — and is no work.
/// The same rule gates a `done` upload's `received` re-echo and its failed
/// retry. A re-echo never counts toward `batchLimit`.
///
/// Phone recordings (§5.3, §6.4): a pending `recording_upload` from a linked
/// device is claimed `begun`, its asset handed to `RecordingUploads.ingest` (the
/// transcriber's phone ingest, under its own timeout) and the record
/// rewritten `received` without the asset, or `failed` with a message. A
/// failed upload wrote nothing, so the phone's Retry (the same record name,
/// pending again) is ingested; a `received` one never is again (a phone save
/// that put it back to `pending` only gets `received` echoed again). An upload
/// found still `begun` is echoed `failed` / `outcome_unknown`, not re-ingested.
///
/// Device gate (§5.2 rule 4): an action or upload is applied only when its
/// `device_id` is a linked phone in the sidecar's `devices` table and, in
/// `shared` scope, the record's creator is that phone's iCloud user
/// (`LinkedDevice.accepts(creator:)`); anything else fails
/// `device_not_linked` and is never dispatched. A `device` record (a phone's
/// link request) goes to `deviceRecords`, the link center, unbudgeted.
///
/// Backlog: one pass handles at most `batchLimit` records and reports the
/// rest, so the hub re-runs at once instead of waiting for the next poll.
/// The change token is persisted only once a pass leaves nothing behind.
final class RelayProcessor: Sendable {
    /// Lands one acked upload's audio with the transcriber (spec §6.4).
    typealias RecordingIngest = @MainActor @Sendable (_ upload: RecordingUploadPayload, _ audio: URL) async throws -> Void

    /// What the relay needs to ingest phone recordings. One value, not three
    /// closure parameters, so callers' trailing `now` closure still binds.
    struct RecordingUploads: Sendable {
        let ingest: RecordingIngest
        /// The ingest timeout's clock.
        var sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    }

    /// Where phone `device` records go (`MobileLinkCenter.handleDevice`).
    /// A value, not a closure parameter, like `RecordingUploads`.
    struct DeviceRecords: Sendable {
        let handle: @Sendable (CloudRecord) async throws -> Void
    }

    struct Pass: Equatable, Sendable {
        /// Records handled (applied or ingested, and echoed) in this pass;
        /// re-echoes are not counted.
        let handled: Int
        /// Records still waiting; > 0 means "run again now".
        let remaining: Int
    }

    static let relayTokenKey = "relay_change_token"
    static let hygieneStampKey = "hygiene_last_run"
    static let defaultBatchLimit = 200
    static let actionMaxAge: TimeInterval = 7 * 86_400
    /// Session input, finish and start requests go stale sooner (§5.2 rule 5).
    static let sessionRequestMaxAge: TimeInterval = 86_400
    private static let hygieneInterval: TimeInterval = 86_400
    /// The buffer sweep and the ledger prune sit one day past the longest
    /// record window, so hygiene has had a full window of daily scans first.
    private static let retentionMargin: TimeInterval = 86_400

    /// Applied more than once they would write twice (spec §5.2 table).
    static let nonIdempotentKinds: Set<ActionKind> = [
        .boardCommentAdd, .boardCommentReply, .boardTargetCreate,
        .sessionStart, .sessionInput, .sessionFinishRequest
    ]
    /// Echoed `received` as soon as they are dequeued (§5.2 rule 6).
    static let receivedEchoKinds: Set<ActionKind> = [.sessionStart, .sessionInput, .boardTargetCreate]
    private static let sessionRequestKinds: Set<ActionKind> = [.sessionInput, .sessionFinishRequest, .sessionStart]
    /// The pre-POC Today/task kinds: refused until sub-project D.
    static let refusedKinds: Set<ActionKind> = [.targetDone, .targetSnooze, .taskCreate]
    /// The recording ingest's own deadline (copying ≤ 90 MB plus a main-actor
    /// hop): a hub stop waits for the record being applied.
    static let recordingIngestTimeout: Duration = .seconds(300)

    private let transport: any CloudSyncTransport & Sendable
    private let sidecar: HubSyncState
    private let dispatcher: MobileHubCommandDispatcher
    private let hubID: String
    private let batchLimit: Int
    /// nil: uploads are left pending for a hub that can ingest them.
    private let recordingUploads: RecordingUploads?
    /// nil: device records are left for a hub that links phones.
    private let deviceRecords: DeviceRecords?
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: Constants.bundleID, category: "RelayProcessor")
    private let lastActivity = OSAllocatedUnfairLock<Date?>(initialState: nil)
    private let backlog = OSAllocatedUnfairLock(initialState: 0)

    init(
        transport: any CloudSyncTransport & Sendable,
        sidecar: HubSyncState,
        dispatcher: MobileHubCommandDispatcher,
        hubID: String,
        batchLimit: Int = RelayProcessor.defaultBatchLimit,
        recordingUploads: RecordingUploads? = nil,
        deviceRecords: DeviceRecords? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.sidecar = sidecar
        self.dispatcher = dispatcher
        self.hubID = hubID
        self.batchLimit = batchLimit
        self.recordingUploads = recordingUploads
        self.deviceRecords = deviceRecords
        self.now = now
    }

    /// When the relay last handled a phone action or `device` record;
    /// drives the hub's adaptive poll cadence. nil until then.
    var lastActivityAt: Date? { lastActivity.withLock { $0 } }

    /// Unprocessed relay records left by the last pass (the heartbeat's
    /// `relay_backlog`).
    var relayBacklog: Int { backlog.withLock { $0 } }

    // MARK: - Processing

    /// One pass over the relay zone. Passes are single-flight across every
    /// processor sharing this sidecar: a second call waits for the running
    /// one. A handler must never call back into the processor (the gate is
    /// not re-entrant: the pass would wait on itself), and each handler owns
    /// its own timeout — a stop waits for the record being applied. One bad
    /// action becomes its own failed echo and never stops the rest; a transport error or cancellation (checked between records,
    /// never mid-apply) aborts the pass — the token stays, so the next pass
    /// re-reads, and the ledger keeps that safe.
    func processOnce() async throws -> Pass {
        try await sidecar.relayGate.exclusively { try await self.processPass() }
    }

    private func processPass() async throws -> Pass {
        let since = try storedToken()
        let batch = try await transport.changes(in: .relay, since: since)
        var window = RelayWindow(since: since?.value ?? 0, mark: batch.newToken.value)
        var handled = 0
        var remaining = 0
        for record in batch.changed {
            guard let work = try await pendingWork(in: record, window: &window) else { continue }
            if work.budgeted, handled >= batchLimit {
                remaining += 1
                continue
            }
            try Task.checkCancellation()
            // An unstructured task does not inherit the loop's cancellation:
            // stopping the hub ends a pass only between two records, so a
            // handler's cancellation-aware awaits (GRDB, sleeps, URLSession)
            // never turn a stop into a false `write_failed`.
            let run = work.run
            try await Task { try await run() }.value
            if work.budgeted { handled += 1 }
        }
        let left = remaining
        backlog.withLock { $0 = left }
        if remaining == 0 {
            try persistToken(batch.newToken)
        }
        return Pass(handled: handled, remaining: remaining)
    }

    private struct Work {
        let run: @Sendable () async throws -> Void
        /// Counts toward `batchLimit`: an apply or an ingest, not a re-echo.
        let budgeted: Bool
    }

    /// The work a record still needs; nil when there is none.
    private func pendingWork(in record: CloudRecord, window: inout RelayWindow) async throws -> Work? {
        let mark = window.mark
        switch record.kind {
        case RelayRecordKind.action.rawValue:
            switch try await pendingAction(in: record, window: &window) {
            case nil:
                return nil
            case .apply(let action):
                let creator = record.creatorUserRecordName
                return Work(run: { try await self.processAction(action, creator: creator, doneSeq: mark) }, budgeted: true)
            case let .reEcho(action, outcome):
                return Work(run: { try await self.reEchoAction(action, outcome) }, budgeted: false)
            }
        case RelayRecordKind.recordingUpload.rawValue:
            guard let uploads = recordingUploads, let pending = try await pendingUpload(in: record, window: &window) else {
                return nil
            }
            switch pending {
            case .ingest(let upload):
                let asset = record.assetFileURL
                let creator = record.creatorUserRecordName
                return Work(
                    run: { try await self.processUpload(upload, asset: asset, creator: creator, uploads: uploads, doneSeq: mark) },
                    budgeted: true
                )
            case .reEchoReceived(let upload):
                let asset = record.assetFileURL
                return Work(run: { try await self.reEchoReceived(upload, asset: asset) }, budgeted: false)
            }
        case RelayRecordKind.device.rawValue:
            guard let deviceRecords else { return nil }
            return Work(run: {
                // Phone activity: the grant traffic that follows runs at the active cadence.
                self.lastActivity.withLock { $0 = self.now() }
                try await deviceRecords.handle(record)
            }, budgeted: false)
        default:
            // Future kinds have no relay work.
            return nil
        }
    }

    private enum PendingAction {
        /// Not `done` in the ledger: handle it.
        case apply(ActionRequestPayload)
        /// `done`, but the record reads `pending` or `received` again: the
        /// echo was lost or overwritten. Echo the stored outcome again.
        case reEcho(ActionRequestPayload, ActionOutcome)
    }

    /// The work the record's action still needs: nil when it is
    /// undecodable, moved past `received` by an echo, `done` and not changed
    /// by the phone since, or `done` without a readable stored echo (a row
    /// from before echoes were kept).
    private func pendingAction(in record: CloudRecord, window: inout RelayWindow) async throws -> PendingAction? {
        let action: ActionRequestPayload
        do {
            action = try RelayCoder.makeDecoder().decode(ActionRequestPayload.self, from: record.payload)
        } catch {
            // No decodable id, so no echo can be written: log and move on.
            logger.warning("undecodable action record \(record.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard action.status == .pending || action.status == .received else { return nil }
        guard try sidecar.relayPhase(action.recordName) == .done else { return .apply(action) }
        guard try await phoneChanged(action.recordName, window: &window),
              let stored = try sidecar.relayEcho(action.recordName) else { return nil }
        do {
            return .reEcho(action, try JSONDecoder().decode(ActionOutcome.self, from: stored))
        } catch {
            logger.warning("unreadable stored echo \(action.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Rewrites a `done` action with its stored outcome: no claim, no
    /// dispatch, no ledger write. The re-saved echo reads back as past
    /// `received`, so this does not loop.
    private func reEchoAction(_ action: ActionRequestPayload, _ outcome: ActionOutcome) async throws {
        lastActivity.withLock { $0 = now() }
        try await writeEcho(action, outcome)
        logger.info("action \(action.recordName, privacy: .public) read \(action.status.rawValue, privacy: .public) after its echo: echoed again")
    }

    /// Whether the buffered change of a `done` record came after the pass
    /// that marked it (a phone save), not the hub's own stale copy.
    private func phoneChanged(_ recordName: String, window: inout RelayWindow) async throws -> Bool {
        try await window.changedAfter(try sidecar.relayDoneSeq(recordName), recordName, in: transport)
    }

    private func processAction(_ action: ActionRequestPayload, creator: String?, doneSeq: Int) async throws {
        lastActivity.withLock { $0 = now() }
        let outcome: ActionOutcome
        if try sidecar.relayPhase(action.recordName) == .begun {
            outcome = .failed(.outcomeUnknown, message: "The Mac restarted while applying this")
        } else if try !isFromLinkedDevice(action.deviceID, creator: creator) {
            outcome = .failed(.deviceNotLinked, message: Self.notLinkedMessage)
        } else if isExpired(action) {
            outcome = .expired
        } else if let applied = try await applyAction(action) {
            outcome = applied
        } else {
            return
        }
        try await writeEcho(action, outcome)
        try sidecar.markRelayDone(
            action.recordName, outcome: Self.ledgerOutcome(outcome), echo: try JSONEncoder().encode(outcome),
            doneSeq: doneSeq, at: now()
        )
    }

    static let notLinkedMessage = "This phone is not linked to this Mac."

    /// The device gate (§5.2 rule 4).
    private func isFromLinkedDevice(_ deviceID: String?, creator: String?) throws -> Bool {
        guard let deviceID, let device = try sidecar.linkedDevice(deviceID) else { return false }
        return device.accepts(creator: creator)
    }

    private func isExpired(_ action: ActionRequestPayload) -> Bool {
        let maxAge = Self.sessionRequestKinds.contains(action.kind) ? Self.sessionRequestMaxAge : Self.actionMaxAge
        return now().timeIntervalSince(action.createdAt) > maxAge
    }

    /// nil when another pass already claimed the record (it echoes it).
    private func applyAction(_ action: ActionRequestPayload) async throws -> ActionOutcome? {
        if action.kind == .probe { return probeOutcome(action) }
        guard !Self.refusedKinds.contains(action.kind), await dispatcher.handles(action.kind) else {
            return .failed(.unsupportedInPOC)
        }
        if Self.nonIdempotentKinds.contains(action.kind) {
            guard try sidecar.claimRelay(action.recordName, at: now()) else { return nil }
        }
        if Self.receivedEchoKinds.contains(action.kind), action.status == .pending {
            try await writeEcho(action, ActionOutcome(status: .received, reason: nil, result: nil, errorMessage: nil))
        }
        do {
            return try await dispatcher.dispatch(action) ?? .failed(.unsupportedInPOC)
        } catch {
            logger.warning("action \(action.recordName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return .failed(.writeFailed, message: error.localizedDescription)
        }
    }

    /// The link check (§5.2): hub-only, idempotent, `{nonce, hub_id}`.
    private func probeOutcome(_ action: ActionRequestPayload) -> ActionOutcome {
        guard case .string(let nonce)? = action.params["nonce"], !nonce.isEmpty else {
            return .failed(.invalidParams, message: "probe needs a nonce")
        }
        return .applied(["nonce": .string(nonce), "hub_id": .string(hubID)])
    }

    /// Rewrites the phone's record with the outcome (§5.2 rule 6).
    private func writeEcho(_ action: ActionRequestPayload, _ outcome: ActionOutcome) async throws {
        var echoed = action
        echoed.status = outcome.status
        echoed.reason = outcome.reason
        echoed.result = outcome.result
        echoed.errorMessage = outcome.errorMessage
        try await transport.save([try CloudRecordFactory.record(for: echoed, modifiedAt: now())])
    }

    private static func ledgerOutcome(_ outcome: ActionOutcome) -> String {
        guard let reason = outcome.reason else { return outcome.status.rawValue }
        return "\(outcome.status.rawValue):\(reason.rawValue)"
    }

    // MARK: - Phone recordings (spec §5.3, §6.4)

    private enum PendingUpload {
        /// Not ingested yet: no ledger entry, a `begun` one, or a failed
        /// attempt the phone is retrying.
        case ingest(RecordingUploadPayload)
        /// Already ingested, but the record reads `pending` again: the phone
        /// re-saved it (with its asset) before it fetched the `received`
        /// echo, and its save won. Echo `received` once more.
        case reEchoReceived(RecordingUploadPayload)
    }

    /// The work a decodable, still `pending` upload needs; nil for none (a
    /// `done` upload the phone has not saved again since is none).
    private func pendingUpload(in record: CloudRecord, window: inout RelayWindow) async throws -> PendingUpload? {
        let upload: RecordingUploadPayload
        do {
            upload = try RelayCoder.makeDecoder().decode(RecordingUploadPayload.self, from: record.payload)
        } catch {
            logger.warning("undecodable recording upload \(record.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard upload.status == .pending else { return nil }
        guard try sidecar.relayPhase(upload.recordName) == .done else { return .ingest(upload) }
        guard try await phoneChanged(upload.recordName, window: &window) else { return nil }
        let outcome = try sidecar.relayOutcome(upload.recordName)
        if outcome == RecordingUploadStatus.received.rawValue { return .reEchoReceived(upload) }
        return outcome?.hasPrefix(ActionStatus.failed.rawValue) == true ? .ingest(upload) : nil
    }

    /// Rewrites an already-ingested upload `received` without its asset
    /// again: no claim, no ingest, and the stash is never read — only the
    /// re-fetched copy is deleted once the echo is saved (a failed save keeps
    /// it; the next pass retries). The phone's `received` handling marks
    /// its row delivered and deletes only the local audio file (the row
    /// stays); a delivered row is never uploaded again, and this echo reads
    /// back `received`, not `pending`, so this does not loop.
    private func reEchoReceived(_ upload: RecordingUploadPayload, asset: URL?) async throws {
        lastActivity.withLock { $0 = now() }
        var echoed = upload
        echoed.status = .received
        echoed.errorMessage = nil
        try await transport.save([try CloudRecordFactory.record(for: echoed, modifiedAt: now(), assetFileURL: nil)])
        logger.info("recording upload \(upload.recordName, privacy: .public) re-saved pending after its ingest: echoed received again")
        removeConsumedAsset(asset)
    }

    private func processUpload(
        _ upload: RecordingUploadPayload, asset: URL?, creator: String?, uploads: RecordingUploads, doneSeq: Int
    ) async throws {
        lastActivity.withLock { $0 = now() }
        let name = upload.recordName
        let outcome: ActionOutcome
        if try sidecar.relayPhase(name) == .begun {
            outcome = .failed(.outcomeUnknown, message: "Your Mac restarted while saving this recording. Send it again.")
        } else if try !isFromLinkedDevice(upload.deviceID, creator: creator) {
            outcome = .failed(.deviceNotLinked, message: Self.notLinkedMessage)
        } else {
            guard try sidecar.claimRelayRetryingFailure(name, at: now()) else { return }
            outcome = await ingestUpload(upload, asset: asset, uploads: uploads)
        }
        var echoed = upload
        echoed.status = outcome.status == .applied ? .received : .failed
        echoed.errorMessage = outcome.errorMessage
        // The rewrite carries no asset: that is what frees the iCloud storage.
        try await transport.save([try CloudRecordFactory.record(for: echoed, modifiedAt: now(), assetFileURL: nil)])
        let ledger = echoed.status == .received ? RecordingUploadStatus.received.rawValue : Self.ledgerOutcome(outcome)
        try sidecar.markRelayDone(name, outcome: ledger, doneSeq: doneSeq, at: now())
        guard echoed.status == .received else {
            logger.warning("recording upload \(name, privacy: .public) failed: \(ledger, privacy: .public)")
            return
        }
        removeConsumedAsset(asset)
    }

    /// The transport's received copy is consumed. Best-effort: a file left
    /// behind costs disk, never a second ingest (the ledger is `done`).
    private func removeConsumedAsset(_ asset: URL?) {
        guard let asset else { return }
        do {
            try FileManager.default.removeItem(at: asset)
        } catch {
            logger.warning("ingested upload asset not removed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Validates the asset and runs the ingest under its timeout. A failure
    /// leaves nothing behind (the transcriber's phone ingest removes what it
    /// created), so the phone keeps its file and may retry.
    private func ingestUpload(_ upload: RecordingUploadPayload, asset: URL?, uploads: RecordingUploads) async -> ActionOutcome {
        guard let asset, FileManager.default.fileExists(atPath: asset.path) else {
            return .failed(.notFound, message: "The recording's audio did not reach your Mac. Send it again.")
        }
        let size: Int64
        do {
            size = (try FileManager.default.attributesOfItem(atPath: asset.path)[.size] as? Int64) ?? 0
        } catch {
            return .failed(.writeFailed, message: "Your Mac could not read this recording: \(error.localizedDescription)")
        }
        guard size > 0 else {
            return .failed(.notFound, message: "The recording's audio reached your Mac empty. Send it again.")
        }
        do {
            return try await withHandlerTimeout(
                Self.recordingIngestTimeout, sleep: uploads.sleep,
                message: "Your Mac took too long to save this recording. Check Recordings on the Mac before sending it again."
            ) {
                try await uploads.ingest(upload, asset)
                return .applied()
            }
        } catch {
            return .failed(.writeFailed, message: "Your Mac could not save this recording: \(error.localizedDescription)")
        }
    }

    // MARK: - Hygiene (relay retention)

    /// Daily retention pass over the relay zone, guarded by a hub_meta stamp:
    /// action and recording-upload records older than 7 days are deleted
    /// through a full zone scan (`since: nil`; the change token is
    /// untouched), except a still-unhandled pending one, which waits for
    /// its `expired` echo. Then the local event buffer is swept (strictly
    /// after the record pass, and never past the stored token, so an
    /// unconsumed event survives) and the ledger is pruned.
    func runHygieneIfDue() async throws {
        try await sidecar.relayGate.exclusively { try await self.runHygienePass() }
    }

    private func runHygienePass() async throws {
        let current = now()
        if let raw = try sidecar.metaValue(forKey: Self.hygieneStampKey),
           let last = TimeInterval(raw),
           current.timeIntervalSince1970 - last < Self.hygieneInterval {
            return
        }
        let batch = try await transport.changes(in: .relay, since: nil)
        let stale = try batch.changed.filter { try isStale($0, at: current) }.map(\.recordName)
        if !stale.isEmpty {
            try await transport.delete(recordNames: stale, in: .relay)
            logger.info("hygiene: deleted \(stale.count) stale relay records")
        }
        let cutoff = current.addingTimeInterval(-(Self.actionMaxAge + Self.retentionMargin))
        await sweepBuffer(olderThan: cutoff)
        try sidecar.pruneRelayProcessed(olderThan: cutoff)
        try sidecar.setMetaValue(String(current.timeIntervalSince1970), forKey: Self.hygieneStampKey)
    }

    private func isStale(_ record: CloudRecord, at current: Date) throws -> Bool {
        guard current.timeIntervalSince(record.modifiedAt) > Self.actionMaxAge else { return false }
        switch record.kind {
        case RelayRecordKind.action.rawValue:
            let action = try? RelayCoder.makeDecoder().decode(ActionRequestPayload.self, from: record.payload)
            guard let action, action.status == .pending || action.status == .received else { return true }
            return try sidecar.relayPhase(record.recordName) == .done
        case RelayRecordKind.recordingUpload.rawValue:
            let upload = try? RelayCoder.makeDecoder().decode(RecordingUploadPayload.self, from: record.payload)
            guard let upload, upload.status == .pending else { return true }
            return try sidecar.relayPhase(record.recordName) == .done
        default:
            // Device records and future kinds are kept.
            return false
        }
    }

    private func sweepBuffer(olderThan cutoff: Date) async {
        guard let sweeping = transport as? any SweepingTransport else { return }
        do {
            let floor = try storedToken() ?? CloudChangeToken(value: 0)
            let swept = try await sweeping.sweepEvents(in: .relay, olderThan: cutoff, upTo: floor)
            if swept > 0 { logger.info("hygiene: swept \(swept) aged relay buffer events") }
        } catch {
            // Local trim only: never fail the hygiene pass over it.
            logger.warning("relay event sweep failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Token persistence

    private func storedToken() throws -> CloudChangeToken? {
        guard let raw = try sidecar.metaValue(forKey: Self.relayTokenKey) else { return nil }
        guard let token = try? JSONDecoder().decode(CloudChangeToken.self, from: Data(raw.utf8)) else {
            // Corrupted token → full re-read; the ledger keeps the replay safe.
            logger.warning("unreadable relay change token, re-reading the zone from scratch")
            return nil
        }
        return token
    }

    private func persistToken(_ token: CloudChangeToken) throws {
        let data = try JSONEncoder().encode(token)
        guard let raw = String(bytes: data, encoding: .utf8) else { return }
        try sidecar.setMetaValue(raw, forKey: Self.relayTokenKey)
    }
}

/// One pass's view of the relay buffer: tells a phone change made after a
/// record's outcome from the hub's own stale copy of it.
private struct RelayWindow {
    /// The cursor the pass read from.
    let since: Int
    /// The buffer mark the pass read up to (`newToken`), stored with `done`.
    let mark: Int
    /// Mark → the records changed past it, one buffer read per mark.
    private var changedPast: [Int: Set<String>] = [:]

    init(since: Int, mark: Int) {
        self.since = since
        self.mark = mark
    }

    /// True when `recordName`'s buffered change lies past `doneSeq`. Every
    /// change this pass reads lies past `since`, so a mark at or below it
    /// needs no lookup. A row without a mark (written before marks were
    /// kept) keeps the old behaviour: true.
    mutating func changedAfter(
        _ doneSeq: Int?, _ recordName: String, in transport: any CloudSyncTransport & Sendable
    ) async throws -> Bool {
        guard let doneSeq, doneSeq > since else { return true }
        if let names = changedPast[doneSeq] { return names.contains(recordName) }
        let names = Set(try await transport.changes(in: .relay, since: CloudChangeToken(value: doneSeq)).changed.map(\.recordName))
        changedPast[doneSeq] = names
        return names.contains(recordName)
    }
}

/// A FIFO async mutex: one relay pass (or hygiene pass) at a time. A caller
/// arriving while one runs waits for it, then runs its own.
actor RelayPassGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func exclusively<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        do {
            let value = try await operation()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the gate straight to the next waiter (it stays busy).
    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
