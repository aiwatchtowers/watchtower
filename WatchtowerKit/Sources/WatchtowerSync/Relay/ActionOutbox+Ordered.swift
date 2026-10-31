import Foundation
import os

/// What one flush pass did: records written (controls and actions), the refusal it stopped on (the next pass starts
/// again from that record), and the actions it listed as Not delivered.
public struct OutboxFlushReport: Equatable, Sendable {
    public var written: Int
    public var stoppedOn: TransportRefusal?
    public var undelivered: Int

    public init(written: Int = 0, stoppedOn: TransportRefusal? = nil, undelivered: Int = 0) {
        self.written = written
        self.stoppedOn = stoppedOn
        self.undelivered = undelivered
    }
}

// MARK: - The ordered path (relay client Phase 1)
//
// For a hub whose grant carries `ordered_actions` (the replica's sticky flag) over a conditional transport. Each
// action gets the next gapless `action_seq` and is written as `a-<DEVICE_ID>-<seq>`; a flush writes the queued
// controls, then the queued actions by seq, one record per call, and stops at the first non-permanent refusal (sim
// rules 1, 3, 7a). Flushes, `resend_from` handling and the 24 h withdrawal run as operations on one serial chain,
// so actor reentrancy never interleaves them. Echoes (`applyEcho`, from the feed) are not on the chain: their store
// writes are guarded by the row's delivery state, so they compose with a flush in flight.
extension ActionOutbox {
    static let refusedMessage = "Not delivered to your Mac."
    static let noAnswerMessage = "No answer from your Mac for 24 hours."
    /// The hosted relay's mailbox TTL: a control unwritten this long is dropped there (sim "Bounded state").
    static let hostedRelayControlTTL: TimeInterval = 14 * 86_400
    /// Seals per enqueue when other enqueues keep drawing the seq (Ruling 2).
    static let sealAttempts = 3
    /// The refusal of a `.seq` write whose record no longer exists.
    static let goneCode = "gone"

    /// The hub's id, stamped as `hub_id` on ordered payloads and on the phone's controls; a blank id is nil.
    public func setHubID(_ hubID: String?) {
        self.hubID = linkedDeviceID(hubID)
    }

    /// The phone's and the hub's ids as set now (nil until linked / set): the feed checks a hub control against them.
    func linkIDs() -> (deviceID: String?, hubID: String?) {
        (deviceID, hubID)
    }

    /// The replica's sticky `ordered_actions` flag (Ruling 3).
    public func orderedActions() throws -> Bool {
        try store.orderedActionsEnabled()
    }

    /// Turns the ordered path on for good (a linked grant carried `ordered_actions`).
    public func enableOrderedActions() throws {
        try store.enableOrderedActions()
    }

    /// The ordered path runs when the flag is on and the transport takes conditional writes.
    func orderedPath() throws -> Bool {
        guard transport.isConditional else { return false }
        return try store.orderedActionsEnabled()
    }

    // MARK: Enqueue

    /// Seals the action under the next seq and stores it `queued` if that seq is still the next one; otherwise
    /// reseals under the new next seq (at most `sealAttempts` seals, then `busy`). Then asks for a flush without
    /// awaiting it: a refused flush never fails the enqueue, the row waits in the queue.
    func enqueueOrdered(
        kind: ActionKind, entityRecordName: String?, params: [String: JSONValue], deviceID: String
    ) async throws -> String {
        guard let device = UUID(uuidString: deviceID) else { throw ActionOutboxError.notLinked }
        let action = ActionRequestPayload(
            id: UUID().uuidString,
            kind: kind,
            entityID: Self.entityID(from: entityRecordName),
            params: params,
            createdAt: now(),
            deviceID: device.uuidString,
            hubID: hubID
        )
        for _ in 0..<Self.sealAttempts {
            let seq = try store.nextActionSeq()
            let sealed = try await transport.seal(try CloudRecordFactory.orderedRecord(
                for: action, actionSeq: seq, deviceID: device, modifiedAt: action.createdAt))
            let epoch = try Envelope.parse(sealed.payload).header.epoch
            if try store.insertOrderedAction(
                action, entityRecordName: entityRecordName, sealed: sealed, epoch: epoch, seq: seq) {
                requestFlush()
                return action.id
            }
        }
        throw ActionOutboxError.busy
    }

    // MARK: The chain

    /// Queues `body` behind every operation already on the chain.
    func onChain<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) -> Task<T, Error> {
        let previous = chainTail
        let task = Task {
            await previous?.value
            return try await body()
        }
        chainTail = Task { _ = await task.result }
        return task
    }

    /// One flush pass on the chain. A call while a flush is queued joins it; a call while one runs queues one more
    /// after it (or joins the one already queued), so at most one waits and every caller's rows are attempted.
    public func flush() async throws -> OutboxFlushReport {
        try await requestFlush().value
    }

    @discardableResult
    func requestFlush() -> Task<OutboxFlushReport, Error> {
        if let queuedFlush { return queuedFlush }
        let task = onChain { try await self.startQueuedFlush() }
        queuedFlush = task
        return task
    }

    private func startQueuedFlush() async throws -> OutboxFlushReport {
        // This is the queued flush starting: a request from now on queues the next one.
        queuedFlush = nil
        do {
            return try await reportedFlush()
        } catch {
            logger.error("outbox flush failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    // MARK: resend_from

    /// The hub asked for every action from `seq` on (sim rules 5–6), run on the chain after any flush in flight:
    /// `sent` rows at or above it go back to `queued` and are written again as new versions (never listed); when
    /// the first row still held is past `seq`, a `skip_to(first)` is queued ahead of them. Then a flush.
    public func resendFrom(_ seq: UInt64) async throws {
        _ = try await onChain { try await self.performResend(from: seq) }.value
    }

    private func performResend(from seq: UInt64) async throws -> OutboxFlushReport {
        // Checked before anything moves: a lost skip would stall the order (the hub asks once per gap).
        guard let device = deviceID.flatMap(UUID.init(uuidString:)) else { throw ActionOutboxError.notLinked }
        guard let hub = hubID.flatMap(UUID.init(uuidString:)) else { throw ActionOutboxError.noHubID }
        // Seqs in [seq, first) are settled, already Not delivered (each keeps its first reason) or gone (an
        // `applied` echo or the owner's Dismiss): nothing to list (Ruling 1).
        let first = try store.requeue(fromSeq: seq) ?? store.nextActionSeq()
        if first > seq {
            let control = ControlPayload.skipTo(first, deviceID: device, hubID: hub)
            let at = now()
            let sealed = try await transport.seal(try CloudRecordFactory.record(for: control, modifiedAt: at))
            try store.enqueueControl(QueuedControl(
                id: control.id, kind: control.kind, wireName: sealed.recordName, envelope: sealed.payload,
                queuedAt: at))
        }
        return try await reportedFlush()
    }

    // MARK: Retry and Dismiss All

    /// A new action with the failed row's kind, entity and params at the end of the queue (new id, now, next seq,
    /// current epoch), then the old row's Dismiss. Only a failed row (settled, Not delivered, or a legacy failed
    /// row) can be retried. A locked keychain throws before anything changes. nil: a Retry of this row is already
    /// running (pressed on another screen), so this one does nothing.
    public func retry(id: String) async throws -> String? {
        guard retrying.insert(id).inserted else { return nil }
        defer { retrying.remove(id) }
        guard let old = try store.pendingActions().first(where: { $0.id == id }), old.state == .failed else {
            throw ActionOutboxError.notRetryable
        }
        let newID = try await enqueue(
            kind: old.action.kind, entityRecordName: old.entityRecordName, params: old.action.params)
        try store.dismissAction(id: id)
        return newID
    }

    /// Dismiss All on the Not delivered list; returns how many rows went. A later `resend_from` skips their seqs.
    public func dismissAllUndelivered() throws -> Int {
        try store.dismissAllUndelivered()
    }

    // MARK: Echoes

    /// An ordered echo: any echo moves a `queued` row to `sent`; `held` without a reason changes no overlay (it only
    /// means "ahead of a gap", Ruling 4); `held` with a reason and `received` are recorded as on the legacy path;
    /// `applied` removes the row in any delivery state (observer fired); `failed`, `expired` and `cancelled` mark
    /// it failed and `settled`, which also takes a Not delivered row off the list. Returns whether it was final.
    @discardableResult
    func applyOrderedEcho(_ action: ActionRequestPayload) throws -> Bool {
        guard action.status != .pending else { return false }
        // Only a `queued` row moves; the echo carries no version of the phone's write, so none is kept.
        try store.markSent(actionID: action.id, recordSeq: nil, at: now())
        switch action.status {
        case .pending:
            return false
        case .received, .held:
            if action.status == .received || action.reason != nil {
                try store.markPendingActionEcho(id: action.id, status: action.status, reason: action.reason)
            }
            return false
        case .applied:
            if try store.removeAppliedAction(id: action.id) {
                appliedObserver?(action)
            }
            return true
        case .failed, .expired, .cancelled:
            try store.settleFailedAction(
                id: action.id, errorMessage: action.errorMessage ?? Self.noMessageFallback, reason: action.reason,
                result: action.result)
            return true
        }
    }

    /// The hub's echo of this row (an `action` frame with the row's id and seq, any status but `pending`), or nil.
    private func hubEcho(_ opened: CloudRecord, of row: OutboxRow) -> ActionRequestPayload? {
        guard opened.kind == RelayRecordKind.action.rawValue,
              let echo = try? RelayCoder.makeDecoder().decode(ActionRequestPayload.self, from: opened.payload),
              echo.id == row.actionID, echo.actionSeq == row.actionSeq, echo.status != .pending
        else { return nil }
        return echo
    }

    // MARK: The flush pass

    /// One pass, then its report to the observer.
    private func reportedFlush() async throws -> OutboxFlushReport {
        let report = try await performFlush()
        flushReportObserver?(report)
        return report
    }

    /// One pass (sim rules 1, 3, 7a): queued controls in order, then queued actions by seq, one record per call.
    /// The first non-permanent refusal stops the pass. A permanent refusal never does: the control stays queued for
    /// the next pass, the action is listed as Not delivered, and the records after it go on.
    func performFlush() async throws -> OutboxFlushReport {
        var report = OutboxFlushReport()
        guard transport.isConditional else { return report }
        for control in try store.queuedControls() {
            if case .hostedRelay = route, now().timeIntervalSince(control.queuedAt) >= Self.hostedRelayControlTTL {
                // The relay would have purged any copy by now. On CloudKit there is no such TTL and a control is
                // never dropped: a lost `skip_to` could stall every later action.
                try store.controlWritten(id: control.id)
                logger.error(
                    "control \(control.id, privacy: .public) (\(control.kind.rawValue, privacy: .public)) unwritten for 14 days, dropped")
                continue
            }
            let record = CloudRecord(
                recordName: control.wireName, zone: .relay, kind: WireKind.envelope, modifiedAt: control.queuedAt,
                payload: control.envelope)
            switch try await saveOne(record, expect: .absent) {
            case .saved, .conflict:
                // A conflict is the control itself: it sits under its unique `c-<uuid>` name already.
                try store.controlWritten(id: control.id)
                report.written += 1
            case .refused(let refusal) where refusal.isPermanent:
                logger.warning("control \(control.id, privacy: .public) refused for good, kept for the next pass")
            case .refused(let refusal):
                report.stoppedOn = refusal
                return report
            }
        }
        for row in try store.outboxRows([.queued]) {
            switch try await deliver(row) {
            case .written:
                report.written += 1
            case .undelivered:
                report.undelivered += 1
            case .left:
                break
            case .stopped(let refusal):
                report.stoppedOn = refusal
                return report
            }
        }
        return report
    }

    private enum Delivered {
        case written
        case undelivered
        /// Left for the next pass, the feed, the next `resend_from` or the 24 h rule.
        case left
        case stopped(TransportRefusal)
    }

    /// Writes one queued row with `.seq(record_seq)`, or `.absent` when no version is known. A row `resend_from`
    /// put back is a resend: the same envelope must land as a new version, so the hub's `changes` lists it again;
    /// when its conflict holds our own bytes at another version or a non-final echo, it is overwritten once under
    /// that version, whatever `record_seq` held. At most two writes per row (Task 6 point 2): the second one's
    /// conflict is read, never written over.
    private func deliver(_ row: OutboxRow) async throws -> Delivered {
        let record = CloudRecord(
            recordName: row.wireName, zone: .relay, kind: WireKind.envelope, modifiedAt: row.createdAt,
            payload: row.envelope)
        // A queued row with a `sent_at` was written before and put back by `requeue` (nothing else moves a row
        // back to `queued`): the requeue is what makes it a resend, not whether a version is known.
        let isResend = row.sentAt != nil
        var expect: WriteExpectation = row.recordSeq.map { .seq($0) } ?? .absent
        var rewritingEcho = false
        for attempt in 0..<2 {
            let canWriteAgain = attempt == 0
            switch try await saveOne(record, expect: expect) {
            case .saved(let version):
                try written(row, version: version, rewritingEcho: rewritingEcho)
                return .written
            case .refused(.permanent(let code)) where code == Self.goneCode && canWriteAgain && expect != .absent:
                // The record is gone (the hub or hygiene deleted it, the TTL purged it): written again as new.
                expect = .absent
            case .refused(let refusal) where refusal.isPermanent:
                // This record alone: the hub's gap rule asks for it and `resend_from` skips it.
                try store.markUndelivered(actionIDs: [row.actionID], reason: .refused, message: Self.refusedMessage)
                return .undelivered
            case .refused(let refusal):
                return .stopped(refusal)
            case .conflict(let current):
                if current.payload == row.envelope {
                    if isResend, canWriteAgain, let version = current.recordSeq {
                        // Our own bytes at another version: a resend writes them again as a new one.
                        expect = .seq(version)
                        continue
                    }
                    // Our own bytes are there: written (CloudKit's reply was lost, say).
                    try written(row, version: current.recordSeq, rewritingEcho: rewritingEcho)
                    return .written
                }
                // nil = cannot tell what is there (rolled back, garbage, not a RelayZone record): never written over.
                guard let opened = try await transport.openConflict(current) else { return .left }
                if let echo = hubEcho(opened, of: row) {
                    if echo.status.isFinal {
                        if !rewritingEcho { try store.markSent(actionID: row.actionID, recordSeq: current.recordSeq, at: now()) }
                        try applyOrderedEcho(echo)
                        return .written
                    }
                    // A non-final echo (`held`, `received`) never settles the row.
                    if isResend, canWriteAgain, let version = current.recordSeq {
                        // A resend overwrites it once with the action (a hub that lost its held rows reads it again).
                        try applyOrderedEcho(echo)
                        expect = .seq(version)
                        rewritingEcho = true
                        continue
                    }
                    // Sent at the echo's version first, so the next resend rewrites the echo under it.
                    if !rewritingEcho { try store.markSent(actionID: row.actionID, recordSeq: current.recordSeq, at: now()) }
                    try applyOrderedEcho(echo)
                    return .left
                }
                // Anything else (our own earlier copy, an older version): one overwrite of the same bytes.
                guard canWriteAgain, let version = current.recordSeq else { return .left }
                expect = .seq(version)
            }
        }
        return .left
    }

    /// The row's write landed (or its own bytes were found) at `version`.
    private func written(_ row: OutboxRow, version: UInt64?, rewritingEcho: Bool) throws {
        if rewritingEcho, let version {
            try store.markRewritten(actionID: row.actionID, recordSeq: version, at: now())
        } else {
            try store.markSent(actionID: row.actionID, recordSeq: version, at: now())
        }
    }

    private func saveOne(_ record: CloudRecord, expect: WriteExpectation) async throws -> SaveOutcome {
        let outcomes = try await transport.saveSealed([ConditionalSave(record: record, expect: expect)])
        // One item, one outcome (`ConditionalTransport`); a short answer is a transport fault worth a retry.
        return outcomes.first ?? .refused(.transient(code: "noOutcome"))
    }

    // MARK: 24 h without an answer (Ruling 5)

    /// Every ordered row `queued` or `sent` since before `cutoff` (by `sent_at`, else `created_at`) is withdrawn and
    /// listed as Not delivered with `no_answer`. A never-written row is listed at once; a written one first has its
    /// own record deleted under the version it wrote, so a later Retry cannot apply the action twice. An echo met
    /// on the way is applied instead (not listed); a refusal leaves the row for the next sweep.
    func withdrawUnanswered(before cutoff: Date) async throws -> [String] {
        var listed: [String] = []
        for row in try store.outboxRows([.queued, .sent]) where (row.sentAt ?? row.createdAt) < cutoff {
            guard try await withdraw(row) else { continue }
            try store.markUndelivered(actionIDs: [row.actionID], reason: .noAnswer, message: Self.noAnswerMessage)
            listed.append(row.actionID)
        }
        return listed
    }

    /// true once the row's record is gone (or was never written).
    private func withdraw(_ row: OutboxRow) async throws -> Bool {
        if row.delivery == .queued && row.recordSeq == nil { return true }
        // A sent row with no known version (its conflict's record carried none) goes by the first-write rules.
        var expect: WriteExpectation = row.recordSeq.map { .seq($0) } ?? .absent
        for attempt in 0..<2 {
            let outcomes = try await transport.deleteSealed([
                ConditionalDelete(recordName: row.wireName, zone: .relay, expect: expect)
            ])
            switch outcomes.first ?? .refused(.transient(code: "noOutcome")) {
            case .deleted:
                return true
            case .refused(let refusal):
                logger.notice(
                    "withdrawal of action \(row.actionSeq, privacy: .public) refused (\(String(describing: refusal), privacy: .public)), next sweep")
                return false
            case .conflict(let current):
                if attempt == 0, current.payload == row.envelope, let version = current.recordSeq {
                    expect = .seq(version)
                    continue
                }
                if let opened = try await transport.openConflict(current), let echo = hubEcho(opened, of: row) {
                    try applyOrderedEcho(echo)
                }
                return false
            }
        }
        return false
    }
}

extension ActionStatus {
    /// The hub's last word on an action: only such an echo settles an ordered row.
    var isFinal: Bool {
        switch self {
        case .applied, .failed, .expired, .cancelled: return true
        case .pending, .received, .held: return false
        }
    }
}
