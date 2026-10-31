import Foundation
import WatchtowerHostedRelay
import WatchtowerRelayProto
import WatchtowerSync

// Port of relay@3a99bd7 `sim/hub.go`: the reference model of the Mac's side. It applies each
// phone's actions strictly in seq order, exactly once, and owns the transport and the key
// epochs. Go functions keep their names (camelCase); `Current` → `transport`, `Sync` → `sync`,
// `Applied` → `appliedActions` (and `applied(from:)`, the Go test helper). `Run` is not ported.

/// A phone linked to the hub with its mailbox zone on each transport (Go `PhoneLink`). A phone
/// without a relay mailbox has no subscription: it can only use CloudKit.
struct SimPhoneLink: Sendable {
    let id: String
    let mailbox: [SimKind: String]
}

/// Go `HubConfig`.
struct SimHubConfig {
    /// Also the envelope sender.
    let id: String
    let clock: any RelayClock
    let transports: [SimKind: any SimTransport]
    let phones: [SimPhoneLink]
    /// The transport the hub starts on, in epoch 1.
    let current: SimKind
    /// The hub's data zone on the relay, where it keeps its transport marker.
    let dataZone: String
}

/// An action the hub applied (Go `Applied`).
struct SimApplied: Equatable, Sendable {
    let phone: String
    let seq: UInt64
    /// The epoch it was sealed in.
    let epoch: UInt64
    let payload: String
}

/// Driven one pass at a time: the twins never call into it concurrently (`SimWorld.syncAll`).
/// The actor only keeps its state safe; a second pass entering at an `await` is not modelled.
actor SimHub {
    private struct HeldAction {
        let kind: SimKind
        let rec: CloudRecord
        let env: SimEnvelope
    }

    /// A record the hub owes a phone's mailbox: a control record, or an echo sent over CloudKit.
    /// It stays queued until written to one of `kinds` (or refused for good on all of them).
    private struct HubWrite {
        let kinds: [SimKind]
        let name: String
        let env: SimEnvelope
    }

    private final class HubPhone {
        let link: SimPhoneLink
        var lastApplied: UInt64 = 0
        /// After a gap, waiting for the missing seqs.
        var held: [UInt64: HeldAction] = [:]
        /// The open resend_from request, 0 if none.
        var askedFrom: UInt64 = 0
        var ackedEpoch: UInt64
        /// Its subscription ended: it fell back to CloudKit.
        var lapsed = false
        /// Lapsed while the hub stays on the relay: its actions are not applied.
        var dropped = false
        /// Applied, but the echo was refused (the subscription had just ended).
        var unechoed: [UInt64] = []
        /// In order.
        var out: [HubWrite] = []

        init(link: SimPhoneLink, ackedEpoch: UInt64) {
            self.link = link
            self.ackedEpoch = ackedEpoch
        }
    }

    private struct SwitchRequest {
        let phone: HubPhone
        let env: SimEnvelope
    }

    private static let both: [SimKind] = [.relay, .cloudkit]

    nonisolated let id: String
    private let cfg: SimHubConfig

    private var current: SimKind
    private(set) var epoch: UInt64 = 1
    /// Previous epochs whose receiving keys are kept: retired at.
    private var oldEpochs: [UInt64: Date] = [:]
    private var lastSwitch: Date?
    private var lastBy = ""
    /// The transport marker not written yet.
    private var marker: SimEnvelope?
    private var phones: [HubPhone] = []
    private var cursors: [SimKind: [String: UInt64]] = [.relay: [:], .cloudkit: [:]]
    private(set) var appliedActions: [SimApplied] = []
    /// The seqs of every resend_from the hub decided to send.
    private(set) var resendRequests: [UInt64] = []
    /// Answers made, by record version.
    private var asked: Set<String> = []
    /// Control ids handled.
    private var seen: Set<String> = []
    private var queue: [SwitchRequest] = []
    private var nextCtl = 0
    private var progress = false

    init(_ cfg: SimHubConfig) {
        self.cfg = cfg
        self.id = cfg.id
        self.current = cfg.current
        phones = cfg.phones.map { HubPhone(link: $0, ackedEpoch: 1) }
    }

    /// Links another phone.
    func addPhone(_ link: SimPhoneLink) {
        phones.append(HubPhone(link: link, ackedEpoch: epoch))
    }

    /// The hub's transport (Go `Current`).
    var transport: SimKind {
        current
    }

    /// "seq:payload" of the actions applied from `phone`, in order (the Go tests' `applied`).
    func applied(from phone: SimPhone) -> [String] {
        appliedActions.filter { $0.phone == phone.id }.map { "\($0.seq):\($0.payload)" }
    }

    // MARK: - Sync

    /// One pass: server control events; queued writes; drop expired epoch keys; read every
    /// phone's mailbox on the current transport (everything) and on the other one (controls, and
    /// actions only to tell their sender where the hub is); then act on the switch requests read.
    @discardableResult
    func sync() async -> Bool {
        progress = false
        await takeControls()
        await flushAll()
        expireEpochs()
        await readAll(current, full: true)
        for kind in Self.both where kind != current {
            await readAll(kind, full: false)
        }
        while !queue.isEmpty {
            await handleSwitch(queue.removeFirst())
        }
        return progress
    }

    /// Acts on ENTITLEMENT_EXPIRED: its detail names the lapsed phone (§6), treated like that
    /// phone's own transport_switch to CloudKit.
    private func takeControls() async {
        for kind in Self.both {
            guard let transport = cfg.transports[kind] else { continue }
            for control in await transport.takeControls() where control.kind == .entitlementExpired {
                if let phone = phones.first(where: { $0.link.id == control.detail }), !phone.lapsed {
                    let env = SimEnvelope(kind: SimEnvelope.kindSwitch, target: .cloudkit, reason: SimEnvelope.reasonEntitlementExpired)
                    await handleSwitch(SwitchRequest(phone: phone, env: env))
                }
            }
        }
    }

    /// Forgets an old epoch's keys once every phone confirmed a newer epoch and nothing sealed in
    /// it waits, or at the latest after `oldEpochKeep` (§4.2 p. 6, §7.5).
    private func expireEpochs() {
        let now = cfg.clock.now()
        for (old, retiredAt) in oldEpochs {
            var done = now.timeIntervalSince(retiredAt) >= Sim.oldEpochKeep
            if !done {
                done = true
                for phone in phones where !phone.lapsed && phone.link.mailbox[current] != nil {
                    if phone.ackedEpoch <= old { done = false }
                    if phone.held.values.contains(where: { $0.env.epoch == old }) { done = false }
                }
            }
            if done { oldEpochs[old] = nil }
        }
    }

    private func canOpen(_ sealedIn: UInt64) -> Bool {
        sealedIn == epoch || oldEpochs[sealedIn] != nil
    }

    private func readAll(_ kind: SimKind, full: Bool) async {
        guard cfg.transports[kind] != nil else { return }
        for phone in phones where phone.link.mailbox[kind] != nil {
            await read(kind, phone, full: full)
        }
    }

    /// Processes the records written to the phone's mailbox on `kind` since the last read. With
    /// `full` false actions are not applied there.
    private func read(_ kind: SimKind, _ phone: HubPhone, full: Bool) async {
        guard let transport = cfg.transports[kind], let zone = phone.link.mailbox[kind],
              let res = try? await transport.changes(zone, since: cursors[kind]?[phone.link.id] ?? 0)
        else { return }
        if !res.changed.isEmpty || !res.deleted.isEmpty { progress = true }
        for rec in res.changed {
            await handle(kind, phone, rec, full: full)
        }
        cursors[kind, default: [:]][phone.link.id] = res.newSeq
    }

    private func handle(_ kind: SimKind, _ phone: HubPhone, _ rec: CloudRecord, full: Bool) async {
        // The hub's own records, or garbage.
        guard let env = try? SimEnvelope.open(rec.payload), env.sender == phone.link.id,
              let transport = cfg.transports[kind], let zone = phone.link.mailbox[kind]
        else { return }
        if env.kind == SimEnvelope.kindAction {
            if full, !phone.dropped || kind != .relay {
                await action(kind, phone, rec, env)
            } else {
                await misdirected(kind, phone, rec)
            }
            return
        }
        if !env.id.isEmpty, seen.contains(env.id) {
            await Sim.deleteRecord(transport, zone, rec)
            return
        }
        switch env.kind {
        case SimEnvelope.kindSkipTo:
            if env.seq > phone.lastApplied + 1 {
                phone.lastApplied = env.seq - 1
                phone.askedFrom = 0
                await applyHeld(phone)
            }
        case SimEnvelope.kindEpochAck:
            phone.ackedEpoch = max(phone.ackedEpoch, env.epoch)
        case SimEnvelope.kindSwitch:
            queue.append(SwitchRequest(phone: phone, env: env))
        default:
            break
        }
        if !env.id.isEmpty { seen.insert(env.id) }
        await Sim.deleteRecord(transport, zone, rec)
    }

    /// Answers an action written where the hub does not apply it: the phone missed a switch, so
    /// it is told again where the hub is. The record itself is left to the phone.
    private func misdirected(_ kind: SimKind, _ phone: HubPhone, _ rec: CloudRecord) async {
        let key = "m/\(kind.rawValue)/\(rec.recordName)/\(rec.recordSeq ?? 0)"
        guard !asked.contains(key) else { return }
        asked.insert(key)
        if current == .relay, phone.dropped || phone.link.mailbox[.relay] == nil {
            await writeControl(phone, [.cloudkit], SimEnvelope(kind: SimEnvelope.kindHubOnRelay))
        } else if phone.ackedEpoch < epoch {
            await writeControl(phone, Self.both, switchedEnvelope(current))
        }
    }

    /// Applies, holds or drops one action record (§4 order of actions).
    private func action(_ kind: SimKind, _ phone: HubPhone, _ rec: CloudRecord, _ env: SimEnvelope) async {
        guard canOpen(env.epoch) else {
            // Sealed with keys the hub no longer has: ask for it again, the phone reseals it.
            let key = "r/\(kind.rawValue)/\(rec.recordName)/\(rec.recordSeq ?? 0)"
            if !asked.contains(key) {
                asked.insert(key)
                await resendFrom(phone, env.seq)
            }
            return
        }
        if env.seq <= phone.lastApplied {
            await echo(kind, phone, rec, env, SimEnvelope.statusDupe)
        } else if env.seq == phone.lastApplied + 1 {
            apply(phone, env)
            await echo(kind, phone, rec, env, SimEnvelope.statusApplied)
            await applyHeld(phone)
        } else { // a gap: hold it and ask for the missing ones
            phone.held[env.seq] = HeldAction(kind: kind, rec: rec, env: env)
            if phone.askedFrom != phone.lastApplied + 1 {
                phone.askedFrom = phone.lastApplied + 1
                await resendFrom(phone, phone.askedFrom)
            }
        }
    }

    private func apply(_ phone: HubPhone, _ env: SimEnvelope) {
        appliedActions.append(SimApplied(phone: phone.link.id, seq: env.seq, epoch: env.epoch, payload: env.payload))
        phone.lastApplied = env.seq
        if phone.askedFrom <= env.seq { phone.askedFrom = 0 }
    }

    /// Applies held actions that are next in line now; held repeats are echoed and dropped.
    private func applyHeld(_ phone: HubPhone) async {
        for (seq, held) in phone.held where seq <= phone.lastApplied {
            phone.held[seq] = nil
            await echo(held.kind, phone, held.rec, held.env, SimEnvelope.statusDupe)
        }
        while let held = phone.held[phone.lastApplied + 1] {
            phone.held[held.env.seq] = nil
            apply(phone, held.env)
            await echo(held.kind, phone, held.rec, held.env, SimEnvelope.statusApplied)
        }
    }

    /// Overwrites the action record with the hub's answer: the action's ciphertext leaves the
    /// server now (§7.2). If the server refuses the write for good, the echo is owed and sent
    /// over CloudKit when the phone is let go.
    private func echo(_ kind: SimKind, _ phone: HubPhone, _ rec: CloudRecord, _ env: SimEnvelope, _ status: String) async {
        guard let transport = cfg.transports[kind], let zone = phone.link.mailbox[kind] else { return }
        let answer = SimEnvelope(kind: SimEnvelope.kindEcho, sender: id, epoch: epoch, seq: env.seq, status: status)
        let failure = Sim.failure(
            await transport.saveOne(zone, Sim.overwriteItem(rec.recordName, answer.marshal(), rec.recordSeq ?? 0)))
        if failure == nil {
            progress = true
        } else if !Sim.retryable(failure) {
            phone.unechoed.append(env.seq)
        }
    }

    private func resendFrom(_ phone: HubPhone, _ seq: UInt64) async {
        resendRequests.append(seq)
        await writeControl(phone, [current], SimEnvelope(kind: SimEnvelope.kindResendFrom, epoch: epoch, seq: seq))
    }

    /// Queues one control record, with one id, for the phone's mailbox on `kinds`, then writes the
    /// phone's queue. A newer transport_switched replaces an unwritten older one.
    private func writeControl(_ phone: HubPhone, _ kinds: [SimKind], _ env: SimEnvelope) async {
        nextCtl += 1
        var env = env
        env.sender = id
        env.id = "\(id)-\(nextCtl)"
        if env.kind == SimEnvelope.kindSwitched {
            phone.out.removeAll { $0.env.kind == SimEnvelope.kindSwitched }
        }
        phone.out.append(HubWrite(kinds: kinds, name: Sim.controlName(env.id), env: env))
        await flush(phone)
    }

    /// Writes every queued record and the transport marker.
    private func flushAll() async {
        for phone in phones {
            await flush(phone)
        }
        await flushMarker()
    }

    /// Writes the phone's queued records in order, each to every reachable mailbox among its
    /// kinds. A record is done once written somewhere, or refused for good everywhere; the queue
    /// stops at the first record that is neither, which keeps the order.
    private func flush(_ phone: HubPhone) async {
        while let write = phone.out.first {
            var written = false
            var refused = 0
            var tried = 0
            for kind in write.kinds {
                guard let transport = cfg.transports[kind], let zone = phone.link.mailbox[kind] else { continue }
                tried += 1
                let failure = await save(transport, zone, write)
                if failure == nil {
                    written = true
                } else if !Sim.retryable(failure) {
                    refused += 1
                }
            }
            if !written, tried == 0 || refused < tried { return }
            progress = progress || written
            // A reentrant writeControl may have replaced the queue meanwhile; drop only this record.
            if phone.out.first?.name == write.name { phone.out.removeFirst() }
        }
    }

    /// Writes `write` as a new record; an echo owed over CloudKit replaces whatever holds its name.
    private func save(_ transport: any SimTransport, _ zone: String, _ write: HubWrite) async -> TransportRefusal? {
        let outcome = await transport.saveOne(zone, Sim.saveItem(write.name, write.env))
        guard write.env.kind == SimEnvelope.kindEcho, Sim.failure(outcome) == nil else { return Sim.failure(outcome) }
        switch outcome {
        case .conflict(let cur):
            return Sim.failure(await transport.saveOne(zone, Sim.overwriteItem(write.name, write.env.marshal(), cur.recordSeq ?? 0)))
        case .refused:
            return .permanent(code: "deleted_meanwhile")
        case .saved:
            return nil
        }
    }

    /// Writes the transport marker into the hub's relay data zone: a latest-state record no TTL
    /// removes. It stays pending while the relay is unreachable.
    private func flushMarker() async {
        guard let marker, let relay = cfg.transports[.relay], !cfg.dataZone.isEmpty else { return }
        let failure = Sim.failure(
            await relay.saveOne(cfg.dataZone, SimSaveItem(name: Sim.markerName, envelope: marker.marshal(), expect: .none)))
        if !Sim.retryable(failure) {
            self.marker = nil // written, or refused for good (no paying phone left: nobody reads it)
            progress = progress || failure == nil
        }
    }

    /// Announces the hub's transport and epoch with its last real switch.
    private func switchedEnvelope(_ target: SimKind) -> SimEnvelope {
        SimEnvelope(
            kind: SimEnvelope.kindSwitched, sender: id, epoch: epoch, target: target, by: lastBy,
            atMs: lastSwitch.map(SimEnvelope.unixMilli) ?? 0)
    }

    /// Decides on one transport_switch (§4.2 p. 1, 3; §6).
    private func handleSwitch(_ request: SwitchRequest) async {
        let phone = request.phone
        guard let target = request.env.target else { return }
        let now = cfg.clock.now()
        if request.env.reason == SimEnvelope.reasonEntitlementExpired {
            phone.lapsed = true
            if current == .relay, target == .cloudkit, payingOnRelay() {
                // Another paying phone keeps the hub on the relay; this one falls off like a phone
                // without a subscription. Echoes the relay refused go over CloudKit first.
                phone.dropped = true
                for seq in phone.unechoed {
                    let answer = SimEnvelope(kind: SimEnvelope.kindEcho, sender: id, epoch: epoch, seq: seq, status: SimEnvelope.statusApplied)
                    phone.out.append(HubWrite(kinds: [.cloudkit], name: Sim.actionName(seq), env: answer))
                }
                phone.unechoed = []
                await writeControl(phone, [.cloudkit], SimEnvelope(kind: SimEnvelope.kindHubOnRelay))
                return
            }
        }
        if target == current {
            // Nothing to do; answer with the hub's state so the phone stops waiting.
            await writeControl(phone, Self.both, switchedEnvelope(target))
            return
        }
        if target == .relay, let lastSwitch, now.timeIntervalSince(lastSwitch) < Sim.relayHoldoff {
            let wait = Sim.relayHoldoff - now.timeIntervalSince(lastSwitch)
            await writeControl(
                phone, Self.both, SimEnvelope(kind: SimEnvelope.kindSwitchRejected, target: target, retryAfterMs: Int64(wait * 1000)))
            return
        }
        // Accepted. Finish the old transport's mailboxes first, if it is reachable; never wait.
        await readAll(current, full: true)
        oldEpochs[epoch] = now
        epoch += 1
        current = target
        lastSwitch = now
        lastBy = phone.link.id
        progress = true
        let announcement = switchedEnvelope(target)
        marker = announcement
        await flushMarker()
        for other in phones {
            let onTarget = other.link.mailbox[target] != nil && (target != .relay || !other.lapsed)
            if onTarget {
                await writeControl(other, Self.both, announcement)
            } else if target == .relay {
                // A phone without a subscription gets nothing while the hub is on the relay (§3).
                await writeControl(other, [.cloudkit], SimEnvelope(kind: SimEnvelope.kindHubOnRelay))
            }
        }
    }

    /// Whether a phone with a relay mailbox is still paying.
    private func payingOnRelay() -> Bool {
        phones.contains { $0.link.mailbox[.relay] != nil && !$0.lapsed }
    }
}
