import Foundation
import WatchtowerE2ETesting
@testable import WatchtowerSync

/// A test-only hub for one phone's ordered actions over a shared `InMemoryCloudTransport`: the Go hub's `order.go`
/// and `control.go` rules, nothing more (relay sim rules 2, 4, 5, 6).
///
/// - Every action record it reads is echoed over its own version (`.seq`): the next one (`last + 1`) is applied and
///   echoed `applied`, then the held ones that follow; a repeat (`seq <= last`) is echoed `applied` again; one ahead
///   of a gap is held, echoed `held`, and the gap is asked once: `resend_from(last + 1)`.
/// - A phone `skip_to(m)` naming this phone and this hub, with `m <= last + 1 + 65536`, moves `last` to `m - 1` when
///   that moves it forward, then drains the held actions. Every control it reads is deleted under its version.
///
/// It keeps no seen ids, unlike the Go hub's `RelaySeen`: a second copy of a `skip_to` is honoured again.
///
/// Its records are sealed by the test hub's keys. The Swift hub's `SecureTransport` neither seals nor opens
/// `control` frames (the Desktop hub drops them), so controls go through `EnvelopeSealer` directly, with the same
/// keys, names and envelope class the Go hub uses.
actor OrderedHubFake {
    /// `MaxSkipAhead` of the Go hub (`internal/hub/actions/dispatcher.go`).
    static let maxSkipAhead: UInt64 = 1 << 16

    let inner: InMemoryCloudTransport
    let keys: TestHubKeyProvider
    let hub: SecureTransport
    let device: UUID
    let hubID: UUID

    /// The seqs applied, in the order they were applied.
    private(set) var applied: [UInt64] = []
    private(set) var lastApplied: UInt64 = 0
    /// Every `resend_from` written, by its seq.
    private(set) var resendsWritten: [UInt64] = []
    /// Every `skip_to` honoured, by its seq.
    private(set) var skipsHonoured: [UInt64] = []

    private struct Held {
        let action: ActionRequestPayload
        /// The version of the record holding the hub's `held` echo.
        var version: UInt64?
    }

    private var held: [UInt64: Held] = [:]
    private var resendRequestedFrom: UInt64?
    private var token: CloudChangeToken?

    init(inner: InMemoryCloudTransport, keys: TestHubKeyProvider = TestE2E.hub(), device: UUID = TestE2E.deviceID) {
        self.inner = inner
        self.keys = keys
        self.hub = TestE2E.hubTransport(keys, inner: inner)
        self.device = device
        self.hubID = TestE2E.hubID
    }

    // MARK: - One pass

    /// Reads the mailbox since the last pass and answers every phone record in it.
    func sync() async throws {
        let batch = try await inner.changes(in: .relay, since: token)
        for record in batch.changed {
            guard let frame = try open(record) else { continue }
            switch frame.kind {
            case RelayRecordKind.action.rawValue:
                try await action(frame, record: record)
            case RelayRecordKind.control.rawValue:
                try await control(frame, record: record)
            default:
                continue
            }
        }
        token = batch.newToken
    }

    /// The phone's own records only (p2h, sent by this phone); the hub's own echoes and controls are skipped.
    private func open(_ record: CloudRecord) throws -> InnerFrame? {
        guard record.kind == WireKind.envelope,
              let header = try? Envelope.parse(record.payload).header,
              header.envelopeClass == .relayToHub, header.senderID == device
        else { return nil }
        let keys = keys
        let device = device
        return try EnvelopeSealer.openSymmetric(
            record.payload, accepting: [.relayToHub], context: EnvelopeContext(zone: .relay, wireName: record.recordName),
            verifier: nil
        ) { header in try keys.relayKey(.phoneToHub, deviceID: device, epoch: header.epoch) }.frame
    }

    // MARK: - Actions (order.go)

    private func action(_ frame: InnerFrame, record: CloudRecord) async throws {
        guard let action = try? RelayCoder.makeDecoder().decode(ActionRequestPayload.self, from: frame.payload),
              let seq = action.actionSeq, action.status == .pending
        else { return }
        if seq <= lastApplied {
            _ = try await echo(action, status: .applied, over: record.recordSeq)
        } else if seq > lastApplied + 1 {
            let version = try await echo(action, status: .held, over: record.recordSeq)
            held[seq] = Held(action: action, version: version)
            let from = lastApplied + 1
            if resendRequestedFrom != from {
                try await writeControl(ControlPayload(
                    id: UUID().uuidString, kind: .resendFrom, deviceID: device.uuidString, hubID: hubID.uuidString,
                    seq: from))
                resendRequestedFrom = from
                resendsWritten.append(from)
            }
        } else {
            try await apply(action, seq: seq, over: record.recordSeq)
            try await drainHeld()
        }
    }

    private func apply(_ action: ActionRequestPayload, seq: UInt64, over version: UInt64?) async throws {
        applied.append(seq)
        lastApplied = seq
        held[seq] = nil
        _ = try await echo(action, status: .applied, over: version)
    }

    /// Applies the held actions that are now next. A conflict on the held echo's version (the phone wrote the action
    /// again meanwhile) leaves the record: the hub reads that copy as a repeat and echoes it then.
    private func drainHeld() async throws {
        while let next = held[lastApplied + 1] {
            try await apply(next.action, seq: lastApplied + 1, over: next.version)
        }
    }

    /// Writes the hub's echo over `version` of the action's record; the version it wrote, or nil on a conflict.
    private func echo(_ action: ActionRequestPayload, status: ActionStatus, over version: UInt64?) async throws -> UInt64? {
        var echo = action
        echo.status = status
        guard let seq = action.actionSeq else { return nil }
        let sealed = try await hub.seal(CloudRecordFactory.orderedRecord(
            for: echo, actionSeq: seq, deviceID: device, modifiedAt: action.createdAt))
        let outcome = try await inner.save([ConditionalSave(record: sealed, expect: version.map { .seq($0) } ?? .absent)])
        if case .saved(let written) = outcome.first { return written }
        return nil
    }

    // MARK: - Controls (control.go)

    private func control(_ frame: InnerFrame, record: CloudRecord) async throws {
        if let control = try? RelayCoder.makeDecoder().decode(ControlPayload.self, from: frame.payload),
           control.kind == .skipTo, let m = control.seq, m > 0,
           control.deviceID == device.uuidString, control.hubID == hubID.uuidString,
           m <= lastApplied + 1 + Self.maxSkipAhead {
            if m > lastApplied + 1 { lastApplied = m - 1 }
            skipsHonoured.append(m)
            try await drainHeld()
        }
        guard let version = record.recordSeq else { return }
        _ = try await inner.delete([ConditionalDelete(recordName: record.recordName, zone: .relay, expect: .seq(version))])
    }

    /// Seals `control` to the phone as the Go hub's `sealControl` does and writes it (`.absent` by default; `.none`
    /// writes a second copy of the same id over the first).
    @discardableResult
    func writeControl(
        _ control: ControlPayload, expect: WriteExpectation = .absent, frameID: String? = nil
    ) async throws -> SaveOutcome? {
        let plain = frameID ?? control.recordName
        let wire = try hub.wireName(plain: plain, zone: .relay)
        let frame = InnerFrame(
            kind: RelayRecordKind.control.rawValue, id: plain, payload: try RelayCoder.makeEncoder().encode(control))
        let epoch = try keys.currentEpoch()
        let envelope = try EnvelopeSealer.sealSymmetric(
            frame, envelopeClass: .relayToPhone, key: try keys.relayKey(.hubToPhone, deviceID: device, epoch: epoch),
            hubID: hubID, senderID: hubID, epoch: epoch, seq: try keys.nextSeq(),
            context: EnvelopeContext(zone: .relay, wireName: wire), signer: nil)
        let record = CloudRecord(
            recordName: wire, zone: .relay, kind: WireKind.envelope, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            payload: envelope)
        return try await inner.save([ConditionalSave(record: record, expect: expect)]).first
    }

    /// The hub's control with this phone's and this hub's ids, as the Go hub writes it.
    func control(_ kind: ControlKind, seq: UInt64? = nil, deviceID: String? = nil, hubID: String? = nil) -> ControlPayload {
        ControlPayload(
            id: UUID().uuidString, kind: kind, deviceID: deviceID ?? device.uuidString,
            hubID: hubID ?? self.hubID.uuidString, seq: seq)
    }
}

/// The paired test phone (ordered outbox and relay feed over a recording wrapper) and `OrderedHubFake`, over one
/// `InMemoryCloudTransport`.
struct OrderedRig {
    static let base = Date(timeIntervalSince1970: 1_700_000_000)

    let inner: InMemoryCloudTransport
    let recorder: RecordingConditionalTransport
    let phone: SecureTransport
    let store: ReplicaStore
    let outbox: ActionOutbox
    let feed: RelayFeed
    let hub: OrderedHubFake

    static func make(
        ordered: Bool = true, hubID: String? = TestE2E.hubID.uuidString, onHubOnRelay: (@Sendable () async -> Void)? = nil
    ) async throws -> Self {
        let keys = try TestE2E.phoneStore()
        let inner = InMemoryCloudTransport()
        let recorder = RecordingConditionalTransport(inner: inner)
        let phone = TestE2E.phoneTransport(try TestE2E.phone(store: keys), inner: recorder)
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener(store: keys))
        let outbox = ActionOutbox(transport: phone, store: store, deviceID: TestE2E.deviceID.uuidString) { base }
        if ordered { try await outbox.enableOrderedActions() }
        await outbox.setHubID(hubID)
        let clock: @Sendable () -> Date = { base }
        let feed = RelayFeed(transport: phone, store: store, outbox: outbox, onHubOnRelay: onHubOnRelay, now: clock)
        return Self(
            inner: inner, recorder: recorder, phone: phone, store: store, outbox: outbox, feed: feed,
            hub: OrderedHubFake(inner: inner))
    }

    /// Inserts the next ordered row straight into the replica (no flush), sealed as the outbox seals it.
    @discardableResult
    func insert() async throws -> (id: String, seq: UInt64) {
        let seq = try store.nextActionSeq()
        let action = ActionRequestPayload(
            id: UUID().uuidString, kind: .targetDone, entityID: "42", createdAt: Self.base,
            deviceID: TestE2E.deviceID.uuidString, hubID: TestE2E.hubID.uuidString)
        let sealed = try await phone.seal(try CloudRecordFactory.orderedRecord(
            for: action, actionSeq: seq, deviceID: TestE2E.deviceID, modifiedAt: action.createdAt))
        guard try store.insertOrderedAction(action, entityRecordName: "target-42", sealed: sealed, epoch: 1, seq: seq)
        else { throw CocoaError(.fileWriteFileExists) }
        return (action.id, seq)
    }

    /// The wire name of the ordered action `seq`.
    func wire(_ seq: UInt64) throws -> String {
        try phone.wireName(
            plain: ActionRequestPayload.orderedRecordName(deviceID: TestE2E.deviceID, actionSeq: seq), zone: .relay)
    }

    /// The wire name of a control.
    func wire(_ control: ControlPayload) throws -> String {
        try phone.wireName(plain: control.recordName, zone: .relay)
    }

    /// Every record in the mailbox now, by wire name.
    func mailbox() async throws -> [CloudRecord] {
        try await inner.changes(in: .relay, since: nil).changed
    }

    func mailboxNames() async throws -> Set<String> {
        Set(try await mailbox().map(\.recordName))
    }

    /// The overlay rows still known (any delivery state).
    func rows() throws -> [OutboxRow] {
        try store.outboxRows([.queued, .sent, .settled, .undelivered])
    }
}
