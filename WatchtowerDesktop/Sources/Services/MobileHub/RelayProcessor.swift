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
/// skipped. A non-idempotent kind is committed `begun` before its handler
/// runs and `done` after its echo; a record a later pass finds still
/// `begun` (the hub stopped mid-apply) is never re-applied but echoed
/// `failed` / `outcome_unknown`. Idempotent kinds simply re-run.
///
/// Backlog: one pass handles at most `batchLimit` records and reports the
/// rest, so the hub re-runs at once instead of waiting for the next poll.
/// The change token is persisted only once a pass leaves nothing behind.
final class RelayProcessor: Sendable {
    struct Pass: Equatable {
        /// Records handled (echoed) in this pass.
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

    private let transport: any CloudSyncTransport & Sendable
    private let sidecar: HubSyncState
    private let dispatcher: MobileHubCommandDispatcher
    private let hubID: String
    private let batchLimit: Int
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
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.sidecar = sidecar
        self.dispatcher = dispatcher
        self.hubID = hubID
        self.batchLimit = batchLimit
        self.now = now
    }

    /// When the relay last handled a phone action; drives the hub's
    /// adaptive poll cadence. nil until then.
    var lastActivityAt: Date? { lastActivity.withLock { $0 } }

    /// Unprocessed relay records left by the last pass (the heartbeat's
    /// `relay_backlog`).
    var relayBacklog: Int { backlog.withLock { $0 } }

    // MARK: - Processing

    /// One pass over the relay zone. One bad action becomes its own failed
    /// echo and never stops the rest; a transport error aborts the pass
    /// (the token stays, so the next pass re-reads, and the ledger keeps
    /// that safe).
    func processOnce() async throws -> Pass {
        let batch = try await transport.changes(in: .relay, since: try storedToken())
        var handled = 0
        var remaining = 0
        for record in batch.changed where record.kind == RelayRecordKind.action.rawValue {
            guard let action = try pendingAction(in: record) else { continue }
            guard handled < batchLimit else {
                remaining += 1
                continue
            }
            try await handle(action)
            handled += 1
        }
        let left = remaining
        backlog.withLock { $0 = left }
        if remaining == 0 {
            try persistToken(batch.newToken)
        }
        return Pass(handled: handled, remaining: remaining)
    }

    /// The record's action when it still needs work: decodable, not yet
    /// moved past `received` by an echo, and not `done` in the ledger.
    private func pendingAction(in record: CloudRecord) throws -> ActionRequestPayload? {
        let action: ActionRequestPayload
        do {
            action = try RelayCoder.makeDecoder().decode(ActionRequestPayload.self, from: record.payload)
        } catch {
            // No decodable id, so no echo can be written: log and move on.
            logger.warning("undecodable action record \(record.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard action.status == .pending || action.status == .received else { return nil }
        guard try sidecar.relayPhase(action.recordName) != .done else { return nil }
        return action
    }

    private func handle(_ action: ActionRequestPayload) async throws {
        lastActivity.withLock { $0 = now() }
        let outcome: ActionOutcome
        if try sidecar.relayPhase(action.recordName) == .begun {
            outcome = .failed(.outcomeUnknown, message: "The Mac restarted while applying this")
        } else if isExpired(action) {
            outcome = .expired
        } else {
            outcome = try await run(action)
        }
        try await echo(action, outcome)
        try sidecar.markRelayDone(action.recordName, outcome: Self.ledgerOutcome(outcome), at: now())
    }

    private func isExpired(_ action: ActionRequestPayload) -> Bool {
        let maxAge = Self.sessionRequestKinds.contains(action.kind) ? Self.sessionRequestMaxAge : Self.actionMaxAge
        return now().timeIntervalSince(action.createdAt) > maxAge
    }

    private func run(_ action: ActionRequestPayload) async throws -> ActionOutcome {
        if action.kind == .probe { return probeOutcome(action) }
        guard !Self.refusedKinds.contains(action.kind), await dispatcher.handles(action.kind) else {
            return .failed(.unsupportedInPOC)
        }
        if Self.nonIdempotentKinds.contains(action.kind) {
            try sidecar.markRelayBegun(action.recordName, at: now())
        }
        if Self.receivedEchoKinds.contains(action.kind), action.status == .pending {
            try await echo(action, ActionOutcome(status: .received, reason: nil, result: nil, errorMessage: nil))
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
    private func echo(_ action: ActionRequestPayload, _ outcome: ActionOutcome) async throws {
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

    // MARK: - Hygiene (relay retention)

    /// Daily retention pass over the relay zone, guarded by a hub_meta stamp:
    /// action and recording-upload records older than 7 days are deleted
    /// through a full zone scan (`since: nil`; the change token is
    /// untouched), except a still-unhandled pending one, which waits for
    /// its `expired` echo. Then the local event buffer is swept (strictly
    /// after the record pass, and never past the stored token, so an
    /// unconsumed event survives) and the ledger is pruned.
    func runHygieneIfDue() async throws {
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
