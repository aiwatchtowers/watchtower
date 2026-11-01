import Foundation
import WatchtowerHostedRelay
import WatchtowerRelayProto
import WatchtowerSync

// Port of relay@3a99bd7 `sim/phone.go`: the reference model of a phone's side of the protocol.
// Go functions keep their names (camelCase); the exported ones the tests drive are named as the
// plan's interface has them: `Send` → `act`, `RequestSwitch` → `switchTransport(to:)`,
// `Current` → `transport`, `Sync` → `sync`. `Run` (the live loop) is not ported: the Swift
// twins drive every pass themselves.
//
// The switch decisions (rules 12, 12a, 13, 15 and R32) are not ported: the phone hands every
// `transport_switched`, `hub_on_relay`, transport marker and relay outage to the production
// `TransportFollowerPolicy` and executes its commands on the sim's legs, so the switch twins pin
// the app's decision logic.

/// An action the hub did not apply and never will unless the user retries it (Go `Undelivered`).
struct SimUndelivered: Equatable, Sendable {
    let seq: UInt64
    let payload: String
}

/// The last transport switch the hub announced (Go `SwitchInfo`).
struct SimSwitchInfo: Equatable, Sendable {
    var target: SimKind?
    var by = ""
    var at: Date?
}

/// Go `PhoneConfig`.
struct SimPhoneConfig {
    /// Also the envelope sender.
    let id: String
    let clock: any RelayClock
    let transports: [SimKind: any SimTransport]
    /// The phone's mailbox zone with its hub on each transport it can use.
    let mailbox: [SimKind: String]
    /// The transport the phone starts on, in epoch 1.
    let current: SimKind
    /// The hub's data zone on the relay, which holds its transport marker.
    let dataZone: String
}

enum SimPhoneError: Error, Equatable {
    case notUndelivered(UInt64)
}

/// Driven one pass at a time: the twins never call into it concurrently (`SimWorld.syncAll`).
/// The actor only keeps its state safe; a second pass entering at an `await` is not modelled.
actor SimPhone {
    private final class OutItem {
        let seq: UInt64
        let epoch: UInt64
        let payload: String
        let sealed: Data
        /// Written to the current transport.
        var sent = false

        init(seq: UInt64, epoch: UInt64, payload: String, sealed: Data) {
            self.seq = seq
            self.epoch = epoch
            self.payload = payload
            self.sealed = sealed
        }
    }

    private struct PendingSwitch {
        let id: String
        let target: SimKind
        let reason: String
        var written: Set<SimKind> = []
    }

    nonisolated let id: String
    private let cfg: SimPhoneConfig

    /// Route, epoch, whether the phone may use the relay, the mailbox left behind, the relay outage.
    private var follower: FollowerState
    private var nextSeq: UInt64 = 1
    /// By seq; kept until the hub's echo.
    private var outItems: [OutItem] = []
    private var history: [UInt64: String] = [:]
    /// Echoed by the hub.
    private var delivered: Set<UInt64> = []
    private(set) var undelivered: [SimUndelivered] = []
    private var cursors: [SimKind: UInt64] = [:]
    private var dataCursor: UInt64 = 0
    /// Control ids handled.
    private var seen: Set<String> = []
    private var pending: PendingSwitch?
    /// Control records not written yet, in order.
    private var controls: [SimEnvelope] = []
    private var rejected: TimeInterval = 0
    private(set) var lastSwitch = SimSwitchInfo()
    private(set) var hubOnRelay = false
    private var nextCtl = 0
    private var offline = false
    private var loseNext = false
    private var progress = false

    init(_ cfg: SimPhoneConfig) {
        self.cfg = cfg
        self.id = cfg.id
        self.follower = FollowerState(
            route: TransportKind(cfg.current), newestEpoch: 1, canUseRelay: cfg.mailbox[.relay] != nil ? .yes : .no)
    }

    // MARK: - State

    /// The transport the phone uses (Go `Current`).
    var transport: SimKind {
        current
    }

    /// The newest epoch the phone adopted.
    var epoch: UInt64 {
        UInt64(follower.newestEpoch)
    }

    private var current: SimKind {
        SimKind(follower.route)
    }

    /// The seqs still waiting for the hub's echo.
    var outbox: [UInt64] {
        outItems.map(\.seq)
    }

    /// Whether a transport switch waits for the hub's answer.
    var switchPending: Bool {
        pending != nil
    }

    /// The retry_after of the last rejected switch (0 if none since the last request).
    var switchRejected: TimeInterval {
        rejected
    }

    // MARK: - Test knobs

    /// The phone does no I/O (switched off or no network).
    func setOffline(_ off: Bool) {
        offline = off
    }

    /// The next action write vanishes on the way; the action stays in the outbox.
    func loseNextWrite() {
        loseNext = true
    }

    /// Drops an action from the outbox (reinstall or a cleared outbox).
    func forgetOutbox(_ seq: UInt64) {
        outItems.removeAll { $0.seq == seq }
    }

    // MARK: - Actions

    /// Queues a user action as the next seq, sealed in the current epoch, and writes it to the
    /// current transport if it is reachable (Go `Send`). It stays in the outbox until the echo.
    @discardableResult
    func act(_ payload: String) async -> UInt64 {
        await sendLocked(payload)
    }

    private func sendLocked(_ payload: String) async -> UInt64 {
        let seq = nextSeq
        nextSeq += 1
        history[seq] = payload
        outItems.append(seal(seq, payload))
        await flush()
        return seq
    }

    private func seal(_ seq: UInt64, _ payload: String) -> OutItem {
        let env = SimEnvelope(kind: SimEnvelope.kindAction, sender: id, epoch: epoch, seq: seq, payload: payload)
        return OutItem(seq: seq, epoch: epoch, payload: payload, sealed: env.marshal())
    }

    /// Sends an undelivered action again as a new action at the end of the queue.
    @discardableResult
    func retry(_ seq: UInt64) async throws -> UInt64 {
        guard let index = undelivered.firstIndex(where: { $0.seq == seq }) else { throw SimPhoneError.notUndelivered(seq) }
        let item = undelivered.remove(at: index)
        return await sendLocked(item.payload)
    }

    /// Asks the hub to move to `target` (Go `RequestSwitch`): transport_switch goes to the
    /// phone's mailbox on both transports, wherever reachable; the phone stays on its transport
    /// until the hub answers.
    func switchTransport(to target: SimKind) async {
        await requestSwitch(target, SimEnvelope.reasonUser)
    }

    private func requestSwitch(_ target: SimKind, _ reason: String) async {
        nextCtl += 1
        pending = PendingSwitch(id: "\(id)-\(nextCtl)", target: target, reason: reason)
        rejected = 0
        await writePendingSwitch()
    }

    /// The relay refused a write because the subscription ended: back to CloudKit (§6).
    private func lapsed() async {
        follower.canUseRelay = .no
        if current == .relay, pending == nil {
            await requestSwitch(.cloudkit, SimEnvelope.reasonEntitlementExpired)
        }
    }

    /// Writes the pending transport_switch to every transport that lacks it.
    private func writePendingSwitch() async {
        guard let switching = pending, !offline else { return }
        let env = SimEnvelope(
            kind: SimEnvelope.kindSwitch, sender: id, epoch: epoch, id: switching.id, target: switching.target, reason: switching.reason)
        for kind in kinds() where !switching.written.contains(kind) {
            let outcome = await transport(kind).saveOne(mailbox(kind), Sim.saveItem(Sim.controlName(switching.id), env))
            if Sim.failure(outcome) == nil, pending?.id == switching.id {
                pending?.written.insert(kind)
                progress = true
            }
        }
    }

    /// The transports the phone has a mailbox on, current first.
    private func kinds() -> [SimKind] {
        [current] + [SimKind.relay, .cloudkit].filter { $0 != current && cfg.mailbox[$0] != nil && cfg.transports[$0] != nil }
    }

    private func transport(_ kind: SimKind) -> any SimTransport {
        guard let transport = cfg.transports[kind] else { preconditionFailure("sim phone: no \(kind) transport") }
        return transport
    }

    private func mailbox(_ kind: SimKind) -> String {
        cfg.mailbox[kind] ?? ""
    }

    /// Queues a control record for the hub and writes the queue.
    private func writeControl(_ env: SimEnvelope) async {
        nextCtl += 1
        var env = env
        env.sender = id
        env.id = "\(id)-\(nextCtl)"
        controls.append(env)
        await flushControls()
    }

    /// Writes queued control records, in order, to the current transport. A record stays queued
    /// until written; one the server refuses for good is dropped.
    private func flushControls() async {
        guard !offline else { return }
        let kind = current
        while let env = controls.first {
            let failure = Sim.failure(await transport(kind).saveOne(mailbox(kind), Sim.saveItem(Sim.controlName(env.id), env)))
            if Sim.retryable(failure) { return }
            controls.removeFirst()
            progress = progress || failure == nil
        }
    }

    /// Writes the outbox items not yet on the current transport, in seq order; stops at the
    /// first one that could not be written, which keeps the order.
    private func flush() async {
        guard !offline else { return }
        for item in outItems where !item.sent {
            if loseNext {
                loseNext = false
                item.sent = true
                continue
            }
            guard await writeAction(item) else { return }
            item.sent = true
        }
    }

    /// Puts the action into its record on the current transport, conditionally. Reports whether
    /// the action is now there (written, or found already there or answered).
    private func writeAction(_ item: OutItem) async -> Bool {
        let kind = current
        let zone = mailbox(kind)
        var write = SimSaveItem(name: Sim.actionName(item.seq), envelope: item.sealed, expect: .absent)
        for _ in 0..<3 {
            let outcome = await transport(kind).saveOne(zone, write)
            if let failure = Sim.failure(outcome) {
                if failure == .entitlementInactive { await lapsed() }
                return false
            }
            progress = true
            guard case .conflict(let cur) = outcome else {
                if case .saved = outcome { return true }
                continue // deleted meanwhile
            }
            let env = try? SimEnvelope.open(cur.payload)
            if env?.kind == SimEnvelope.kindEcho, env?.seq == item.seq { // the hub already answered here
                await handle(kind, cur)
                return true
            }
            if cur.payload == item.sealed { return true } // the same bytes are already there
            // An older copy (another epoch): replace it.
            write = Sim.overwriteItem(Sim.actionName(item.seq), item.sealed, cur.recordSeq ?? 0)
        }
        return false
    }

    // MARK: - Sync

    /// One pass: server control events, the current mailbox, the hub's transport marker (on the
    /// relay), the outbox and queued controls, the other transport when needed, and the cleanup
    /// of a transport the phone left. Reports whether anything was read or written.
    @discardableResult
    func sync() async -> Bool {
        progress = false
        guard !offline else { return false }
        for kind in kinds() {
            for control in await transport(kind).takeControls() where control.kind == .entitlementExpired {
                await lapsed() // the subscription ended: back to CloudKit (§6)
            }
        }
        await writePendingSwitch()
        let reached = await read(current)
        if current == .relay {
            await follow(.relayReachable(reached, at: cfg.clock.now())) // rule 12: may poll CloudKit
        }
        await readMarker()
        await flush()
        await flushControls()
        for kind in kinds().dropFirst() {
            if follower.leftTransport == TransportKind(kind) {
                await cleanup(kind)
            } else if pending != nil {
                await read(kind)
            }
        }
        return progress
    }

    /// Follows a switch announced by the hub's transport marker that the phone missed. Only
    /// phones on the relay read it.
    private func readMarker() async {
        guard current == .relay, !cfg.dataZone.isEmpty, let relay = cfg.transports[.relay],
              let res = try? await relay.changes(cfg.dataZone, since: dataCursor)
        else { return }
        dataCursor = res.newSeq
        for rec in res.changed where rec.recordName == Sim.markerName {
            guard let env = try? SimEnvelope.open(rec.payload), env.kind == SimEnvelope.kindSwitched else { continue }
            let marker = FollowerInput.marker(
                target: target(env), epoch: UInt32(clamping: env.epoch), by: env.by, at: switchedAt(env), on: .relay)
            if await follow(marker) != [.ignore] { progress = true }
        }
    }

    /// Processes the records written to the mailbox on `kind` since the last read. Reports
    /// whether the transport answered (an error other than an outage is an answer).
    @discardableResult
    private func read(_ kind: SimKind) async -> Bool {
        let res: SimChanges
        do {
            res = try await transport(kind).changes(mailbox(kind), since: cursors[kind] ?? 0)
        } catch {
            return !(error is SimUnavailable)
        }
        if !res.changed.isEmpty || !res.deleted.isEmpty { progress = true }
        for rec in res.changed {
            await handle(kind, rec)
        }
        cursors[kind] = res.newSeq
        return true
    }

    /// Processes one record of the mailbox on `kind`. The phone's own records are left alone.
    private func handle(_ kind: SimKind, _ rec: CloudRecord) async {
        guard let env = try? SimEnvelope.open(rec.payload), env.sender != id else { return }
        let transport = transport(kind)
        let zone = mailbox(kind)
        if !env.id.isEmpty, seen.contains(env.id) {
            await Sim.deleteRecord(transport, zone, rec) // the second copy of a control already handled
            return
        }
        switch env.kind {
        case SimEnvelope.kindEcho:
            delivered.insert(env.seq)
            outItems.removeAll { $0.seq == env.seq }
        case SimEnvelope.kindResendFrom:
            await resendFrom(env.seq)
        case SimEnvelope.kindSwitched:
            let input = FollowerInput.switched(
                target: target(env), epoch: UInt32(clamping: env.epoch), by: env.by, at: switchedAt(env),
                keyboxOpened: true, controlID: env.id, on: TransportKind(kind))
            // Undecided (unknown paying, keybox not opened): the record stays for a later pass.
            guard await follow(input).contains(.markHandled(controlID: env.id)) else { return }
        case SimEnvelope.kindSwitchRejected:
            pending = nil
            rejected = TimeInterval(env.retryAfterMs) / 1000
        case SimEnvelope.kindHubOnRelay:
            guard await follow(.hubOnRelay(controlID: env.id)).contains(.markHandled(controlID: env.id)) else { return }
        default:
            break
        }
        if !env.id.isEmpty {
            seen.insert(env.id)
            await deleteOtherCopy(kind, env.id)
        }
        await Sim.deleteRecord(transport, zone, rec) // the recipient deletes what it read (§7.2)
    }

    /// R32: the hub is on the relay and this phone cannot follow (the policy already moved it to
    /// CloudKit); every action without an echo is listed as undelivered.
    private func listUndelivered() async {
        hubOnRelay = true
        pending = nil
        for item in outItems {
            markUndelivered(item.seq)
            if current != .relay {
                // Its copy (if any) on this transport will never be read: remove it.
                _ = await transport(current).delete(mailbox(current), [SimDeleteItem(name: Sim.actionName(item.seq), expect: .none)])
            }
        }
        outItems = []
    }

    private func markUndelivered(_ seq: UInt64) {
        if !undelivered.contains(where: { $0.seq == seq }) {
            undelivered.append(SimUndelivered(seq: seq, payload: history[seq] ?? ""))
        }
    }

    /// Removes the copy of a control record on the other transport, if reachable.
    private func deleteOtherCopy(_ kind: SimKind, _ id: String) async {
        for other in kinds() where other != kind {
            _ = await transport(other).delete(mailbox(other), [SimDeleteItem(name: Sim.controlName(id), expect: .none)])
        }
    }

    /// Answers resend_from(n): every outbox action from n is written again in order — the same
    /// bytes, or resealed in the current epoch (same seq) when it was sealed in an older one.
    /// Seqs the phone no longer has are answered with skip_to and shown as undelivered.
    private func resendFrom(_ first: UInt64) async {
        let next = outItems.first { $0.seq >= first }?.seq ?? nextSeq
        var lost = false
        for seq in Swift.stride(from: first, to: next, by: 1) where !delivered.contains(seq) {
            lost = true
            markUndelivered(seq)
        }
        if lost {
            await writeControl(SimEnvelope(kind: SimEnvelope.kindSkipTo, epoch: epoch, seq: next))
        }
        for index in outItems.indices where outItems[index].seq >= first {
            if outItems[index].epoch < epoch {
                outItems[index] = seal(outItems[index].seq, outItems[index].payload)
            }
            outItems[index].sent = false
        }
        await flush()
    }

    /// Hands `input` to `TransportFollowerPolicy` and executes its commands on the sim's legs.
    /// Returns the commands, so the caller sees whether the control was handled.
    @discardableResult
    private func follow(_ input: FollowerInput) async -> [FollowerCommand] {
        let (next, commands) = TransportFollowerPolicy.decide(input, state: follower, now: cfg.clock.now())
        follower = next
        for command in commands {
            switch command {
            case .mergeKeybox, .markHandled, .ignore:
                break // no keys in the sim; the caller deletes a handled control
            case let .moveRoute(target, _, by, at):
                pending = nil
                if !by.isEmpty { lastSwitch = SimSwitchInfo(target: SimKind(target), by: by, at: at) }
                if target == .cloudKit { hubOnRelay = false }
            case .resendUnechoedOnNewTransport:
                for item in outItems { item.sent = false }
                await flush()
            case let .sendEpochAck(epoch):
                await writeControl(SimEnvelope(kind: SimEnvelope.kindEpochAck, epoch: UInt64(epoch)))
            case .listUnechoedAsUndelivered:
                await listUndelivered()
            case .drainMailbox:
                break // `sync` drains `follower.leftTransport` at the end of every pass
            case let .pollOtherMailbox(on):
                await read(SimKind(on))
            }
        }
        return commands
    }

    /// The switch target an announcement names (none: the transport the phone is on).
    private func target(_ env: SimEnvelope) -> TransportKind {
        env.target.map(TransportKind.init) ?? follower.route
    }

    private func switchedAt(_ env: SimEnvelope) -> Date {
        Date(timeIntervalSince1970: TimeInterval(env.atMs) / 1000)
    }

    /// Empties the mailbox on a transport the phone left: hub records not seen yet are handled
    /// first, then every remaining record is deleted (§4.2 p. 7).
    private func cleanup(_ kind: SimKind) async {
        let transport = transport(kind)
        let zone = mailbox(kind)
        guard let res = try? await transport.changes(zone, since: 0) else { return }
        var done = true
        for rec in res.changed {
            let env = try? SimEnvelope.open(rec.payload)
            if env?.sender != id {
                await handle(kind, rec)
            } else if await !Sim.deleteRecord(transport, zone, rec) {
                done = false
            }
            progress = true
        }
        if done {
            cursors[kind] = res.newSeq
            await follow(.oldMailboxDrained(TransportKind(kind)))
        }
    }
}

private extension SimKind {
    init(_ kind: TransportKind) {
        self = kind == .relay ? .relay : .cloudkit
    }
}

private extension TransportKind {
    init(_ kind: SimKind) {
        self = kind == .relay ? .relay : .cloudKit
    }
}
