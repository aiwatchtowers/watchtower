import Foundation
import os
import WatchtowerSync

/// What the transport follower needs from the app (`AppRoot`): the hub's row, its keys, the relay account, and the
/// route move itself.
@MainActor
protocol TransportFollowerHost: AnyObject {
    /// The hub's registry row's link; nil when it has none (a link being made, a hub being removed).
    func followerLink(hubID: String) -> LinkRecord?
    /// The newest epoch the Keychain holds for the hub; nil while it cannot be read (locked).
    func newestEpoch(hubID: String) -> UInt32?
    /// Whether this phone may use the relay to reach `link`'s Mac, asked at the switch: `.unknown` when the relay
    /// did not answer.
    func relayUse(for link: LinkRecord) async -> RelayUse
    /// The keybox of a `transport_switched`, opened with the hub's session; nil when it does not open.
    func openSwitchKeybox(_ sealed: Data, hubID: String) async -> Keybox?
    /// Merges `keybox`'s epoch keys into the Keychain; false when they could not be stored.
    func mergeSwitchKeys(_ keybox: Keybox, hubID: String) async -> Bool
    /// Saves `link` on its registry row in one write; false when it was not written.
    func persistRoute(_ link: LinkRecord) -> Bool
    /// Puts the hub's session on its row's route once the session's current fetch ended.
    func moveSession(hubID: String)
}

/// Executes `TransportFollowerPolicy`'s commands for one hub (sim rules 12a, 13 and R32; relay client Phase 3 Task 11).
/// It hears the hub's `transport_switched` and `hub_on_relay` controls (from `RelayFeed`) and its transport marker
/// (from `ReplicaHydrator`); the policy decides, this class acts on the hub's session and registry row.
///
/// State: the route and the transport left are the registry row's (`LinkRecord.transport`, `leftTransport`, with
/// `switchedBy` and `switchedAt`); the newest epoch is the Keychain's. A move is made crash-safe by its order:
/// 1. the outbox stops writing (`holdFlushes`), then its unechoed actions are queued again for the new transport
///    (rule 13) or listed as Not delivered (R32);
/// 2. the new route is written to the row, in one registry write;
/// 3. the switch's keybox is merged;
/// 4. only then is the control reported handled (the feed marks and deletes it), and the session is rebuilt on the
///    new route's own store once its fetch ended (`TransportFollowerHost.moveSession`): a new session on the same
///    replica, whose tokens reset at open (`ReplicaStore.adoptRoute`), so the outbox, controls, keys and the alert
///    watermark stay.
/// A kill before step 2 leaves the phone on its route with its actions queued there (sent again as written); after
/// it, the control read again answers `requestAnswered` (same epoch, same route) and changes nothing twice.
@MainActor
final class TransportFollower {
    let hubID: String
    private let outbox: ActionOutbox
    private weak var host: (any TransportFollowerHost)?
    private let now: () -> Date
    /// The opened keybox of each `transport_switched` being decided, by control id.
    private var keyboxes: [String: Keybox] = [:]
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "TransportFollower")

    init(hubID: String, outbox: ActionOutbox, host: any TransportFollowerHost, now: @escaping () -> Date = Date.init) {
        self.hubID = hubID
        self.outbox = outbox
        self.host = host
        self.now = now
    }

    // MARK: - Inputs

    /// A `transport_switched` or `hub_on_relay` this session's feed read on `on`: true once decided (the feed marks it
    /// handled and deletes it), false to read it again later. A malformed one is decided as dropped.
    func handle(control: ControlPayload, on transport: TransportKind) async -> Bool {
        switch control.kind {
        case .hubOnRelay:
            return await handle(.hubOnRelay(controlID: control.id))
        case .transportSwitched:
            guard let raw = control.target, let target = TransportKind(rawValue: raw), let epoch = control.epoch,
                  let by = control.by, let at = control.at else {
                Self.logger.warning("transport_switched \(control.id, privacy: .public) malformed, dropped")
                return true
            }
            var opened = false
            if let text = control.keybox, let sealed = WireBytes.fromBase64URL(text),
               let keybox = await host?.openSwitchKeybox(sealed, hubID: hubID) {
                keyboxes[control.id] = keybox
                opened = true
            }
            defer { keyboxes[control.id] = nil }
            return await handle(.switched(
                target: target, epoch: epoch, by: by, at: at, keyboxOpened: opened, controlID: control.id, on: transport))
        default:
            return false
        }
    }

    /// The hub's transport marker read on `on`: true once decided.
    func handle(marker: TransportMarker, on transport: TransportKind) async -> Bool {
        await handle(.marker(target: marker.target, epoch: marker.epoch, by: marker.by, at: marker.at, on: transport))
    }

    /// One input through the policy, its commands executed: true once decided (a control's `markHandled`, or a
    /// marker's decision), false when the policy leaves it for later or a step could not be done.
    func handle(_ input: FollowerInput) async -> Bool {
        guard let host, let link = host.followerLink(hubID: hubID) else { return false }
        guard let epoch = host.newestEpoch(hubID: hubID) else {
            Self.logger.notice("transport input waits for the Keychain")
            return false
        }
        let state = FollowerState(
            route: link.transport ?? .cloudKit, newestEpoch: epoch, canUseRelay: await relayUse(input, link, host),
            leftTransport: link.leftTransport)
        let (next, commands) = TransportFollowerPolicy.decide(input, state: state, now: now())
        guard !commands.isEmpty else {
            Self.logger.notice("transport input left for a later pass")
            return false
        }
        return await execute(commands, next: next, link: link, input: input, host: host)
    }

    /// Asked only when the input could lead to the relay (the policy reads it nowhere else).
    private func relayUse(_ input: FollowerInput, _ link: LinkRecord, _ host: any TransportFollowerHost) async -> RelayUse {
        switch input {
        case .switched(target: .relay, _, _, _, _, _, _), .marker(target: .relay, _, _, _, _), .hubOnRelay:
            return await host.relayUse(for: link)
        default:
            return .unknown
        }
    }

    // MARK: - Commands

    /// What one decision asks for, gathered so it runs in the crash-safe order.
    private struct Plan {
        var merge = false
        var move: (to: TransportKind, by: String, at: Date)?
        var resend = false
        var ack: UInt32?
        var listUndelivered = false
        var handled = false
        var decided = false
    }

    /// The commands gathered into one plan.
    private static func plan(_ commands: [FollowerCommand]) -> Plan {
        var plan = Plan()
        for command in commands {
            switch command {
            case .mergeKeybox: plan.merge = true
            case .requestAnswered: logger.notice("the hub answered on the transport the phone is on")
            case let .moveRoute(to, _, by, at): plan.move = (to, by, at)
            case .resendUnechoedOnNewTransport: plan.resend = true
            case .sendEpochAck(let epoch): plan.ack = epoch
            case .listUnechoedAsUndelivered: plan.listUndelivered = true
            case .drainMailbox(let kind): logger.notice("the \(kind.rawValue, privacy: .public) mailbox is left to drain")
            case .pollOtherMailbox: break
            case .markHandled: plan.handled = true
            case .ignore: plan.decided = true
            }
        }
        return plan
    }

    private func execute(
        _ commands: [FollowerCommand],
        next: FollowerState,
        link: LinkRecord,
        input: FollowerInput,
        host: any TransportFollowerHost
    ) async -> Bool {
        let plan = Self.plan(commands)
        let moves = plan.move.map { $0.to != (link.transport ?? .cloudKit) } ?? false
        guard await moveOutbox(plan, moves: moves) else { return false }
        if let move = plan.move, !persist(move, next: next, link: link, host: host) { return false }
        if plan.merge {
            guard case let .switched(_, _, _, _, _, controlID, _) = input, let keybox = keyboxes[controlID],
                  await host.mergeSwitchKeys(keybox, hubID: hubID) else { return false }
        }
        if let ack = plan.ack, let newest = host.newestEpoch(hubID: hubID), newest >= ack {
            await acknowledge(ack)
        }
        if moves {
            Self.logger.notice("the hub moved to \(next.route.rawValue, privacy: .public) in epoch \(next.newestEpoch, privacy: .public)")
            host.moveSession(hubID: hubID)
        }
        if case .marker = input { return true }
        return plan.handled || plan.decided
    }

    /// Step 1: on a move the outbox stops writing; unechoed actions go back to the queue for the new transport, or
    /// to Not delivered. false when the replica could not be written.
    private func moveOutbox(_ plan: Plan, moves: Bool) async -> Bool {
        do {
            if moves { await outbox.holdFlushes() }
            if plan.resend, let target = plan.move?.to { try await outbox.resendUnechoed(onNewTransport: target) }
            if plan.listUndelivered { try await outbox.listUnechoedAsUndelivered(reason: .hubOnRelay) }
            return true
        } catch {
            Self.logger.error("outbox not moved: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Queued in the replica: on a move, the new session's outbox writes it on the new transport.
    private func acknowledge(_ epoch: UInt32) async {
        do {
            try await outbox.enqueueEpochAck(epoch: epoch)
        } catch {
            Self.logger.warning("epoch_ack not queued: \(String(describing: error), privacy: .public)")
        }
    }

    /// The row takes the route, who switched and when, and the transport left, in one write. A move to the relay
    /// needs the Mac's relay id (`relayUse` is `.no` without it, so the policy never asks); a move to CloudKit needs a
    /// hub that offers it.
    private func persist(
        _ move: (to: TransportKind, by: String, at: Date),
        next: FollowerState,
        link: LinkRecord,
        host: any TransportFollowerHost
    ) -> Bool {
        var moved = link
        switch move.to {
        case .relay:
            guard let mac = link.relayMacDeviceID else {
                Self.logger.error("a move to the relay without the Mac's relay id")
                return false
            }
            moved.setRelay(mac: mac)
            moved.leftTransport = next.leftTransport
        case .cloudKit:
            moved.setCloudKit(left: next.leftTransport)
        }
        if !move.by.isEmpty {
            moved.switchedBy = move.by
            moved.switchedAt = move.at
        }
        guard moved != link else { return true }
        return host.persistRoute(moved)
    }
}
