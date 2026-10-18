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
/// device is claimed `begun`, its asset — sealed with the chunked cipher, its
/// key in the record's frame — decrypted to a temporary plaintext file
/// beside the stash and handed to `RecordingUploads.ingest` (the
/// transcriber's phone ingest, under its own timeout; the plaintext is
/// removed whatever the outcome), and the record rewritten `received`
/// without the asset, or `failed` with a message. A failed upload wrote
/// nothing, so the phone's Retry (the same record name,
/// pending again) is ingested; a `received` one never is again (a phone save
/// that put it back to `pending` only gets `received` echoed again). An upload
/// found still `begun` is echoed `failed` / `outcome_unknown`, not re-ingested.
///
/// Hub addressing (multi-hub spec §3.5): a record whose `hub_id` names another
/// hub fails `wrong_hub`, ledgered `done` like any refusal, so a re-save is
/// re-echoed, never dispatched.
///
/// End-to-end (mobile E2E spec §2.2, D4, D9): the processor reads RelayZone
/// through the hub's `SecureTransport`, so only records that opened under a
/// linked phone's pairwise relay key (current epoch, or the previous one for
/// 7 days, D10) and the hub's own echoes reach it; anything else is dropped
/// and reported by the transport, never echoed (the hub holds no key to
/// answer it with). Every echo carries the opened record's `sealed` info, so
/// the transport seals it to the authenticated sender (F16).
///
/// Device gate (§5.2 rule 4): an action or upload is applied only when the
/// phone whose key opened it (`sealed.senderID`) is the payload's
/// `device_id` and a linked phone in the sidecar's `devices` table, and, in
/// `shared` scope, the record's creator is that phone's iCloud user
/// (`LinkedDevice.accepts(creator:)`, kept as defense in depth); anything
/// else fails `device_not_linked`, echoed to the sender, never dispatched.
/// The authenticated `created_at` then decides the age. The sender's
/// `devices.last_seq` is raised as a high-water mark for diagnostics only
/// (D4: no ordering gate, CloudKit delivers out of order). A `device` record
/// (unbudgeted) and a sealed `hello` (a link request, F4; budgeted, so a
/// flood of them spreads over passes) go to `deviceRecords`, the link center.
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
        /// The sealed asset size past which an upload is refused undecrypted: the phone's own cap.
        var maxSealedBytes: Int64 = RecordingUploader.maximumSealedAssetBytes
    }

    /// Where phone `device` records go (`MobileLinkCenter.handleDevice`), and
    /// hellos, still sealed (`MobileLinkCenter.handleHello`, F4). A value, not
    /// a closure parameter, like `RecordingUploads`.
    struct DeviceRecords: Sendable {
        let handle: @Sendable (CloudRecord) async throws -> Void
        /// nil: hellos are left for a hub that links phones.
        var hello: (@Sendable (CloudRecord) async throws -> Void)?
    }

    struct Pass: Equatable, Sendable {
        /// Records handled (applied or ingested, and echoed, or hellos
        /// handed to the link center) in this pass; re-echoes are not counted.
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
    /// How far ahead of the Mac's clock a phone's `created_at` may be before the action counts as expired.
    static let maxClockSkew: TimeInterval = 300
    private static let hygieneInterval: TimeInterval = 86_400
    /// The buffer sweep and the ledger prune sit one day past the longest
    /// record window, so hygiene has had a full window of daily scans first.
    private static let retentionMargin: TimeInterval = 86_400

    /// Applied more than once they would write twice (spec §5.2 table). A
    /// permission answer is a guarded write, claimed anyway so a replay is
    /// `outcome_unknown`, never a misleading `not_pending`; an interrupt
    /// replayed would send a second Esc (#517).
    static let nonIdempotentKinds: Set<ActionKind> = [
        .boardCommentAdd, .boardCommentReply, .boardTargetCreate,
        .sessionStart, .sessionInput, .sessionFinishRequest,
        .permissionAnswer, .sessionInterrupt
    ]
    /// Echoed `received` as soon as they are dequeued (§5.2 rule 6).
    static let receivedEchoKinds: Set<ActionKind> = [.sessionStart, .sessionInput, .boardTargetCreate]
    private static let sessionRequestKinds: Set<ActionKind> = [
        .sessionInput, .sessionFinishRequest, .sessionStart, .sessionChatRequest
    ]
    /// The pre-POC Today/task kinds: refused until sub-project D.
    static let refusedKinds: Set<ActionKind> = [.targetDone, .targetSnooze, .taskCreate]
    /// The recording ingest's own deadline (copying ≤ 90 MB plus a main-actor
    /// hop): a hub stop waits for the record being applied.
    static let recordingIngestTimeout: Duration = .seconds(300)

    /// nil: the hub has no E2E keys (no CloudKit entitlement); nothing is read
    /// or written, never in the clear.
    private let transport: SecureTransport?
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
    private let warnedNoKeys = OSAllocatedUnfairLock(initialState: false)

    init(
        transport: SecureTransport?,
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
        guard let transport = keyedTransport() else { return Pass(handled: 0, remaining: 0) }
        let since = try storedToken()
        // A locked keychain throws `keysUnavailable` here: the token stays, the next pass replays.
        let batch = try await transport.changes(in: .relay, since: since)
        var window = RelayWindow(since: since?.value ?? 0, mark: batch.newToken.value)
        var handled = 0
        var remaining = 0
        for record in batch.changed {
            guard let work = try await pendingWork(in: record, transport: transport, window: &window) else { continue }
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

    /// The transport, or nil (warned once) when the hub has no keys.
    private func keyedTransport() -> SecureTransport? {
        if let transport { return transport }
        let first = warnedNoKeys.withLock { warned in
            defer { warned = true }
            return !warned
        }
        if first { logger.warning("relay: this Mac has no encryption keys; phone requests are not read") }
        return nil
    }

    /// Who sent a record, as `SecureTransport` authenticated it, and its
    /// CloudKit creator (the shared-scope check).
    private struct Origin: Sendable {
        let sealed: SealedInfo?
        let creator: String?

        init(_ record: CloudRecord) {
            sealed = record.sealed
            creator = record.creatorUserRecordName
        }
    }

    private struct Work {
        let run: @Sendable () async throws -> Void
        /// Counts toward `batchLimit`: an apply, an ingest or a hello, not a re-echo.
        let budgeted: Bool
    }

    /// The work a record still needs; nil when there is none.
    private func pendingWork(
        in record: CloudRecord, transport: SecureTransport, window: inout RelayWindow
    ) async throws -> Work? {
        let mark = window.mark
        let origin = Origin(record)
        switch record.kind {
        case RelayRecordKind.action.rawValue:
            switch try await pendingAction(in: record, transport: transport, window: &window) {
            case nil:
                return nil
            case .apply(let action):
                return Work(run: {
                    try await self.processAction(action, origin: origin, transport: transport, doneSeq: mark)
                }, budgeted: true)
            case let .reEcho(action, outcome):
                return Work(run: {
                    try await self.reEchoAction(action, outcome, origin: origin, transport: transport)
                }, budgeted: false)
            }
        case RelayRecordKind.recordingUpload.rawValue:
            guard let uploads = recordingUploads,
                  let pending = try await pendingUpload(in: record, transport: transport, window: &window) else {
                return nil
            }
            let asset = SealedAsset(file: record.assetFileURL, descriptor: record.asset)
            switch pending {
            case .ingest(let upload):
                let context = UploadContext(origin: origin, transport: transport, uploads: uploads, doneSeq: mark)
                return Work(run: { try await self.processUpload(upload, asset: asset, context: context) }, budgeted: true)
            case .reEchoReceived(let upload):
                return Work(run: {
                    try await self.reEchoReceived(upload, asset: asset.file, origin: origin, transport: transport)
                }, budgeted: false)
            }
        case RelayRecordKind.device.rawValue:
            guard let deviceRecords, isFromItsOwnPhone(record) else { return nil }
            return Work(run: {
                // Phone activity: the grant traffic that follows runs at the active cadence.
                self.lastActivity.withLock { $0 = self.now() }
                try await deviceRecords.handle(record)
            }, budgeted: false)
        case RelayRecordKind.hello.rawValue:
            // A link request; the link center opens it. Budgeted (target 168): anyone holding a code can write
            // hellos at will, and each costs public-key work, so a flood waits for the next pass.
            guard let hello = deviceRecords?.hello else { return nil }
            return Work(run: {
                self.lastActivity.withLock { $0 = self.now() }
                try await hello(record)
            }, budgeted: true)
        default:
            // Future kinds have no relay work.
            return nil
        }
    }

    /// A sealed `device` record acts only for the phone whose key opened it:
    /// its payload's `device_id` is the authenticated sender. Otherwise (one
    /// linked phone writing another's unlink or start-sessions choice, or a
    /// payload that does not decode) it is dropped and logged, never echoed.
    private func isFromItsOwnPhone(_ record: CloudRecord) -> Bool {
        let payload: DevicePayload
        do {
            payload = try RelayCoder.makeDecoder().decode(DevicePayload.self, from: record.payload)
        } catch {
            logger.warning("undecodable device record \(record.recordName, privacy: .public): dropped")
            return false
        }
        guard let sender = record.sealed?.senderID, UUID(uuidString: payload.deviceID) == sender else {
            logger.warning("device record \(record.recordName, privacy: .public) names another phone than its sender: dropped")
            return false
        }
        return true
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
    private func pendingAction(
        in record: CloudRecord, transport: SecureTransport, window: inout RelayWindow
    ) async throws -> PendingAction? {
        let action: ActionRequestPayload
        do {
            action = try RelayCoder.makeDecoder().decode(ActionRequestPayload.self, from: record.payload)
        } catch {
            // No decodable id, so no echo can be written: log and move on.
            logger.warning("undecodable action record \(record.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        // The ledger, the claim and the echo key on the payload's name: it must be the name the envelope
        // authenticated, or one record could claim, answer or re-echo another.
        guard action.recordName == record.recordName else {
            logger.warning("action record \(record.recordName, privacy: .public) names another record: dropped")
            return nil
        }
        guard action.status == .pending || action.status == .received else { return nil }
        guard try sidecar.relayPhase(action.recordName) == .done else { return .apply(action) }
        guard try await phoneChanged(action.recordName, transport: transport, window: &window),
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
    private func reEchoAction(
        _ action: ActionRequestPayload, _ outcome: ActionOutcome, origin: Origin, transport: SecureTransport
    ) async throws {
        lastActivity.withLock { $0 = now() }
        try await writeEcho(action, outcome, origin: origin, transport: transport)
        logger.info("action \(action.recordName, privacy: .public) read \(action.status.rawValue, privacy: .public) after its echo: echoed again")
    }

    /// Whether the buffered change of a `done` record came after the pass
    /// that marked it (a phone save), not the hub's own stale copy.
    private func phoneChanged(
        _ recordName: String, transport: SecureTransport, window: inout RelayWindow
    ) async throws -> Bool {
        try await window.changedAfter(try sidecar.relayDoneSeq(recordName), recordName, in: transport)
    }

    private func processAction(
        _ action: ActionRequestPayload, origin: Origin, transport: SecureTransport, doneSeq: Int
    ) async throws {
        lastActivity.withLock { $0 = now() }
        let outcome: ActionOutcome
        if try sidecar.relayPhase(action.recordName) == .begun {
            outcome = .failed(.outcomeUnknown, message: "The Mac restarted while applying this")
        } else if let target = action.hubID, target != hubID {
            outcome = .failed(.wrongHub, message: Self.wrongHubMessage)
        } else if try !admitsDevice(action.deviceID, origin: origin) {
            outcome = .failed(.deviceNotLinked, message: Self.notLinkedMessage)
        } else if let expired = expiry(action) {
            outcome = expired
        } else {
            try noteSeq(origin)
            guard let applied = try await applyAction(action, origin: origin, transport: transport) else { return }
            outcome = applied
        }
        try await writeEcho(action, outcome, origin: origin, transport: transport)
        try sidecar.markRelayDone(
            action.recordName, outcome: Self.ledgerOutcome(outcome), echo: try JSONEncoder().encode(outcome),
            doneSeq: doneSeq, at: now()
        )
    }

    static let notLinkedMessage = "This phone is not linked to this Mac."
    static let wrongHubMessage = "This was sent to another Mac."

    /// The device gate (§5.2 rule 4, E2E): the phone whose relay key opened
    /// the record is the payload's `device_id` and a linked phone, and its
    /// creator check passes (defense in depth). No side effects.
    private func admitsDevice(_ deviceID: String?, origin: Origin) throws -> Bool {
        guard let sealed = origin.sealed, let deviceID, UUID(uuidString: deviceID) == sealed.senderID,
              let device = try sidecar.linkedDevice(sealed.senderID.uuidString) else { return false }
        return device.accepts(creator: origin.creator)
    }

    /// Raises the sender's `last_seq` high-water mark once a record passed
    /// every gate (D4: diagnostics, never a gate).
    private func noteSeq(_ origin: Origin) throws {
        guard let sealed = origin.sealed else { return }
        try sidecar.raiseDeviceLastSeq(sealed.senderID.uuidString, to: sealed.seq)
    }

    /// Either clock may be the wrong one (a Mac behind looks like a phone ahead), so it names both.
    static let clockAheadMessage =
        "Your iPhone's and Mac's clocks differ by more than 5 minutes — check Date & Time on both."

    /// The `expired` outcome of an action past its window, or dated more than `maxClockSkew` ahead (a future
    /// `created_at` would otherwise stretch the window at will; the phone is told to check its clock). nil: in time.
    private func expiry(_ action: ActionRequestPayload) -> ActionOutcome? {
        let maxAge = Self.sessionRequestKinds.contains(action.kind) ? Self.sessionRequestMaxAge : Self.actionMaxAge
        let age = now().timeIntervalSince(action.createdAt)
        if age < -Self.maxClockSkew {
            return ActionOutcome(status: .expired, reason: .expired, result: nil, errorMessage: Self.clockAheadMessage)
        }
        return age > maxAge ? .expired : nil
    }

    /// nil when another pass already claimed the record (it echoes it).
    private func applyAction(
        _ action: ActionRequestPayload, origin: Origin, transport: SecureTransport
    ) async throws -> ActionOutcome? {
        if action.kind == .probe { return probeOutcome(action) }
        guard !Self.refusedKinds.contains(action.kind), await dispatcher.handles(action.kind) else {
            return .failed(.unsupportedInPOC)
        }
        if Self.nonIdempotentKinds.contains(action.kind) {
            guard try sidecar.claimRelay(action.recordName, at: now()) else { return nil }
        }
        if Self.receivedEchoKinds.contains(action.kind), action.status == .pending {
            try await writeEcho(
                action, ActionOutcome(status: .received, reason: nil, result: nil, errorMessage: nil),
                origin: origin, transport: transport)
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

    /// Rewrites the phone's record with the outcome (§5.2 rule 6), sealed to
    /// the record's authenticated sender (F16).
    private func writeEcho(
        _ action: ActionRequestPayload, _ outcome: ActionOutcome, origin: Origin, transport: SecureTransport
    ) async throws {
        try await transport.save([Self.echo(try Self.echoRecord(action, outcome, at: now()), origin: origin)])
    }

    private static func echoRecord(_ action: ActionRequestPayload, _ outcome: ActionOutcome, at date: Date) throws -> CloudRecord {
        var echoed = action
        echoed.status = outcome.status
        echoed.reason = outcome.reason
        echoed.result = outcome.result
        echoed.errorMessage = outcome.errorMessage
        return try CloudRecordFactory.record(for: echoed, modifiedAt: date)
    }

    /// The echo record carrying the opened record's `sealed` info: `SecureTransport` seals it `.relayToPhone` to
    /// `sealed.senderID` (F16), so a `device_not_linked` answer to a payload naming another phone goes to the
    /// phone that sent it.
    private static func echo(_ record: CloudRecord, origin: Origin) -> CloudRecord {
        CloudRecord(
            recordName: record.recordName, zone: record.zone, kind: record.kind, modifiedAt: record.modifiedAt,
            payload: record.payload, notifyLevel: record.notifyLevel, assetFileURL: record.assetFileURL,
            sealed: origin.sealed)
    }

    /// A later outcome of an action already echoed and `done`: a held phone
    /// line that went, failed, expired or was cancelled (spec §6.6).
    typealias LateEcho = @Sendable (ActionRequestPayload, ActionOutcome) async throws -> Void

    /// The late echo over `transport` and `sidecar`: it rewrites the
    /// record and the ledger's stored echo (a lost ack re-echoes the final
    /// outcome), inside the relay gate — so it lands after the pass that
    /// echoed `held` for the same record. Never awaited from inside a
    /// handler's dispatch (the gate is not re-entrant).
    ///
    /// E2E: sealed `.relayToPhone` like every echo, never written in the
    /// clear. The held line kept no `sealed` info, so `SecureTransport` seals
    /// it to the payload's `device_id` (F16 fallback) — the sender the device
    /// gate admitted (`admitsDevice`: `device_id` == the authenticated sender).
    /// A removed phone has no relay key any more: the seal throws and the
    /// caller logs it (D9: a removed phone is never echoed). nil `transport`
    /// (no hub keys): throws `keysUnavailable`, nothing is written.
    static func lateEcho(
        transport: SecureTransport?,
        sidecar: HubSyncState,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> LateEcho {
        { action, outcome in
            guard let transport else { throw SecureTransportError.keysUnavailable }
            try await sidecar.relayGate.exclusively {
                try await transport.save([try echoRecord(action, outcome, at: now())])
                try sidecar.replaceRelayEcho(
                    action.recordName, outcome: ledgerOutcome(outcome), echo: try JSONEncoder().encode(outcome), at: now()
                )
            }
        }
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
    private func pendingUpload(
        in record: CloudRecord, transport: SecureTransport, window: inout RelayWindow
    ) async throws -> PendingUpload? {
        let upload: RecordingUploadPayload
        do {
            upload = try RelayCoder.makeDecoder().decode(RecordingUploadPayload.self, from: record.payload)
        } catch {
            logger.warning("undecodable recording upload \(record.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        // Same binding as an action's: the ledger and the echo key on the authenticated name.
        guard upload.recordName == record.recordName else {
            logger.warning("recording upload \(record.recordName, privacy: .public) names another record: dropped")
            return nil
        }
        guard upload.status == .pending else { return nil }
        guard try sidecar.relayPhase(upload.recordName) == .done else { return .ingest(upload) }
        guard try await phoneChanged(upload.recordName, transport: transport, window: &window) else { return nil }
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
    private func reEchoReceived(
        _ upload: RecordingUploadPayload, asset: URL?, origin: Origin, transport: SecureTransport
    ) async throws {
        lastActivity.withLock { $0 = now() }
        var echoed = upload
        echoed.status = .received
        echoed.errorMessage = nil
        let record = try CloudRecordFactory.record(for: echoed, modifiedAt: now(), assetFileURL: nil)
        try await transport.save([Self.echo(record, origin: origin)])
        logger.info("recording upload \(upload.recordName, privacy: .public) re-saved pending after its ingest: echoed received again")
        removeConsumedAsset(asset)
    }

    /// The stashed sealed audio of an upload and the descriptor (`K_asset` +
    /// header) its frame carried.
    private struct SealedAsset: Sendable {
        let file: URL?
        let descriptor: AssetDescriptor?
    }

    /// The pass's facts one upload's processing needs.
    private struct UploadContext: Sendable {
        let origin: Origin
        let transport: SecureTransport
        let uploads: RecordingUploads
        let doneSeq: Int
    }

    private func processUpload(_ upload: RecordingUploadPayload, asset: SealedAsset, context: UploadContext) async throws {
        lastActivity.withLock { $0 = now() }
        let name = upload.recordName
        let outcome: ActionOutcome
        if try sidecar.relayPhase(name) == .begun {
            outcome = .failed(.outcomeUnknown, message: "Your Mac restarted while saving this recording. Send it again.")
        } else if let target = upload.hubID, target != hubID {
            outcome = .failed(.wrongHub, message: Self.wrongHubMessage)
        } else if try !admitsDevice(upload.deviceID, origin: context.origin) {
            outcome = .failed(.deviceNotLinked, message: Self.notLinkedMessage)
        } else {
            // Uploads have no age window: the ledger row outlives the record's accepted epochs instead
            // (`pruneRelayProcessed`). A failed attempt is claimable again: the phone's Retry re-sends the
            // identical envelope (Task 9).
            try noteSeq(context.origin)
            guard try sidecar.claimRelayRetryingFailure(name, at: now()) else { return }
            if try sidecar.hasPhoneRecording(uploadID: upload.id) {
                // Ingested before its ledger row was pruned (a re-seal after a rotation's grace, final review
                // Desktop M-1): answered `received` again, never a second recording.
                logger.notice("recording upload \(name, privacy: .public) was ingested already: echoed received")
                outcome = .applied()
            } else {
                outcome = await ingestUpload(upload, asset: asset, uploads: context.uploads)
            }
        }
        var echoed = upload
        echoed.status = outcome.status == .applied ? .received : .failed
        echoed.errorMessage = outcome.errorMessage
        // The rewrite carries no asset: that is what frees the iCloud storage.
        let record = try CloudRecordFactory.record(for: echoed, modifiedAt: now(), assetFileURL: nil)
        try await context.transport.save([Self.echo(record, origin: context.origin)])
        let ledger = echoed.status == .received ? RecordingUploadStatus.received.rawValue : Self.ledgerOutcome(outcome)
        try sidecar.markRelayDone(name, outcome: ledger, doneSeq: context.doneSeq, at: now())
        guard echoed.status == .received else {
            logger.warning("recording upload \(name, privacy: .public) failed: \(ledger, privacy: .public)")
            return
        }
        removeConsumedAsset(asset.file)
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

    static let missingAudioMessage = "The recording's audio did not reach your Mac. Send it again."
    static let tooLargeMessage = RecordingUploader.tooLargeMessage

    /// Decrypts the sealed asset, validates it and runs the ingest under its
    /// timeout. A failure leaves nothing behind (the transcriber's phone
    /// ingest removes what it created; the plaintext copy is removed here),
    /// so the phone keeps its file and may retry. An asset that does not
    /// open under the frame's key (tampered, truncated, or restaged under a
    /// new key while this envelope was in flight) is `not_found`: retry, not
    /// poison.
    private func ingestUpload(
        _ upload: RecordingUploadPayload, asset: SealedAsset, uploads: RecordingUploads
    ) async -> ActionOutcome {
        guard let sealed = asset.file, let descriptor = asset.descriptor,
              FileManager.default.fileExists(atPath: sealed.path) else {
            return .failed(.notFound, message: Self.missingAudioMessage)
        }
        // The phone's own cap, sealed: anything larger is never decrypted (disk and time a linked phone could
        // otherwise spend at will).
        // An unreadable size is refused too (fail closed).
        guard let sealedSize = (try? FileManager.default.attributesOfItem(atPath: sealed.path)[.size] as? NSNumber)?.int64Value
        else {
            return .failed(.notFound, message: Self.missingAudioMessage)
        }
        guard sealedSize <= uploads.maxSealedBytes else {
            logger.warning("recording upload \(upload.recordName, privacy: .public) is \(sealedSize) sealed bytes: refused")
            return .failed(.invalidParams, message: Self.tooLargeMessage)
        }
        // Beside the stash (the same volume, cleaned with it); hidden, created owner-only (0600) before the first
        // plaintext byte (`ChunkedAssetCipher.decryptFile`), removed below on every path. On an ingest timeout the
        // abandoned ingest may still be copying it: removing it then fails that copy, the safe direction.
        let plain = sealed.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).m4a")
        defer { removePlaintext(plain) }
        do {
            try ChunkedAssetCipher.decryptFile(at: sealed, to: plain, descriptor: descriptor)
        } catch {
            // Publicly only a code: a cipher case, or a file error's domain and number (its text can hold a path).
            logger.warning("""
                recording upload \(upload.recordName, privacy: .public) did not decrypt: \
                \(Self.errorCode(error), privacy: .public) \(error.localizedDescription, privacy: .private)
                """)
            return .failed(.notFound, message: Self.missingAudioMessage)
        }
        let size: Int64
        do {
            size = (try FileManager.default.attributesOfItem(atPath: plain.path)[.size] as? Int64) ?? 0
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
                try await uploads.ingest(upload, plain)
                return .applied()
            }
        } catch {
            return .failed(.writeFailed, message: "Your Mac could not save this recording: \(error.localizedDescription)")
        }
    }

    /// The decrypted copy never outlives its ingest. A missing file is the
    /// decrypt-failure path (nothing was written); any other failure is logged.
    private func removePlaintext(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            logger.error("""
                decrypted recording copy not removed: \(Self.errorCode(error), privacy: .public) \
                \(error.localizedDescription, privacy: .private)
                """)
        }
    }

    /// A loggable code for an error: an `AssetCipherError` case (no key material, no path), else the error's
    /// domain and number.
    static func errorCode(_ error: any Error) -> String {
        if let cipher = error as? AssetCipherError { return "cipher.\(cipher)" }
        let ns = error as NSError
        return "\(ns.domain).\(ns.code)"
    }

    // MARK: - Hygiene (relay retention)

    /// Daily retention pass over the relay zone, guarded by a hub_meta stamp:
    /// action and recording-upload records older than 7 days are deleted
    /// through a full zone scan (`relayHygieneScan`; the change token is
    /// untouched), except a still-unhandled pending one, which waits for
    /// its `expired` echo. The scan opens the hub's own echoes too (F2);
    /// records nobody here can open (a removed phone's, a stranger's, another
    /// hub's leftovers, an older version the rollback guard refused) are
    /// deleted by wire name once older than 7 days. Age is the server's
    /// `serverModifiedAt` (`CKRecord.modificationDate`), never the sender's
    /// own `modifiedAt` claim, which falls in only for an event buffered
    /// before the server date was kept. Then the local event buffer is swept (strictly
    /// after the record pass, and never past the stored token, so an
    /// unconsumed event survives) and the ledger is pruned.
    func runHygieneIfDue() async throws {
        try await sidecar.relayGate.exclusively { try await self.runHygienePass() }
    }

    private func runHygienePass() async throws {
        guard let transport = keyedTransport() else { return }
        let current = now()
        if let raw = try sidecar.metaValue(forKey: Self.hygieneStampKey),
           let last = TimeInterval(raw),
           current.timeIntervalSince1970 - last < Self.hygieneInterval {
            return
        }
        let scan = try await transport.relayHygieneScan()
        // A hello passes through sealed (F4): its record name is its wire name.
        let staleOpened = try scan.opened.filter { try isStale($0, at: current) }.compactMap { record in
            record.sealed?.wireName ?? (record.kind == RelayRecordKind.hello.rawValue ? record.recordName : nil)
        }
        let staleUnopenable = scan.unopenable
            .filter { current.timeIntervalSince($0.serverModifiedAt ?? $0.modifiedAt) > Self.actionMaxAge }
            .map(\.wireName)
        let stale = staleOpened + staleUnopenable
        if !stale.isEmpty {
            try await transport.deleteWire(wireNames: stale, in: .relay)
            logger.info("hygiene: deleted \(staleOpened.count) stale and \(staleUnopenable.count) unopenable relay records")
        }
        let cutoff = current.addingTimeInterval(-(Self.actionMaxAge + Self.retentionMargin))
        await sweepBuffer(olderThan: cutoff, transport: transport)
        try sidecar.pruneRelayProcessed(olderThan: cutoff, now: current)
        try sidecar.setMetaValue(String(current.timeIntervalSince1970), forKey: Self.hygieneStampKey)
    }

    private func isStale(_ record: CloudRecord, at current: Date) throws -> Bool {
        guard current.timeIntervalSince(record.serverModifiedAt ?? record.modifiedAt) > Self.actionMaxAge else { return false }
        switch record.kind {
        case RelayRecordKind.action.rawValue:
            let action = try? RelayCoder.makeDecoder().decode(ActionRequestPayload.self, from: record.payload)
            guard let action, action.status == .pending || action.status == .received else { return true }
            return try sidecar.relayPhase(record.recordName) == .done
        case RelayRecordKind.recordingUpload.rawValue:
            let upload = try? RelayCoder.makeDecoder().decode(RecordingUploadPayload.self, from: record.payload)
            guard let upload, upload.status == .pending else { return true }
            return try sidecar.relayPhase(record.recordName) == .done
        case RelayRecordKind.hello.rawValue:
            // A link request outlives every code it can carry (600 s): a week-old one is answered or unanswerable.
            return true
        default:
            // Device records and future kinds are kept.
            return false
        }
    }

    /// Through `SecureTransport`'s `SweepingTransport` conformance (F1): it
    /// forwards to a buffering inner transport, else sweeps nothing.
    private func sweepBuffer(olderThan cutoff: Date, transport: SecureTransport) async {
        do {
            let floor = try storedToken() ?? CloudChangeToken(value: 0)
            let swept = try await transport.sweepEvents(in: .relay, olderThan: cutoff, upTo: floor)
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
