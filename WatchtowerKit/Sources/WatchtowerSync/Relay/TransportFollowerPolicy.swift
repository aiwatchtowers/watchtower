import Foundation

/// The transport a hub and its phones talk over.
public enum TransportKind: String, Codable, Sendable {
    case cloudKit = "cloudkit"
    case relay
}

/// Whether this phone may use the relay: it pays (`yes`), it does not (`no`), or it does not know yet (`unknown`, e.g.
/// the entitlement check has not answered). An unknown answer decides nothing.
public enum RelayUse: Sendable {
    case yes, no, unknown
}

/// What the phone knows about one hub's transport (sim rules 12–15).
public struct FollowerState: Equatable, Sendable {
    /// The transport the phone talks to the hub over.
    public var route: TransportKind
    /// The newest epoch the phone adopted.
    public var newestEpoch: UInt32
    public var canUseRelay: RelayUse {
        // Paying again ends the lapse: a later lapse asks again.
        didSet { if canUseRelay == .yes { lapseRequested = false } }
    }
    /// The phone already asked the hub to move it to CloudKit because its subscription lapsed (sim rule 16). Reset by a
    /// move to CloudKit or a `canUseRelay` of `.yes`.
    public var lapseRequested: Bool
    /// A transport the phone left whose mailbox is still to drain (rule 15).
    public var leftTransport: TransportKind?
    /// When the relay stopped answering on route `.relay`; nil while it answers.
    public var relayUnreachableSince: Date?
    /// The last CloudKit mailbox poll of the current relay outage (rule 12).
    public var otherMailboxPolledAt: Date?
    /// This phone's `transport_switch{relay}` waits for the hub's answer while it is on iCloud (the app's upgrade at
    /// `.requested`). A `transport_switched{relay}` in the phone's own epoch is then that answer: the hub already runs on
    /// the relay in that epoch (a lapse moved the phone back to iCloud without a new one), and the phone moves as for a
    /// newer epoch.
    public var relaySwitchRequested: Bool
    /// The link has an iCloud route to fall back to (relay client Phase 5): the hub offers CloudKit. false on a
    /// relay-only link, which `hub_on_relay` cannot reach and which stays on the relay when refused.
    public var hasOtherRoute: Bool
    /// The epoch of a move to iCloud this relay-only link read and could not follow (`LinkRecord.macMoved`, relay client
    /// Phase 5, S59); nil while none. Cleared only by a marker toward the relay in a later epoch.
    public var macMovedEpoch: UInt32?

    public init(
        route: TransportKind,
        newestEpoch: UInt32,
        canUseRelay: RelayUse,
        leftTransport: TransportKind? = nil,
        relayUnreachableSince: Date? = nil,
        otherMailboxPolledAt: Date? = nil,
        relaySwitchRequested: Bool = false,
        lapseRequested: Bool = false,
        hasOtherRoute: Bool = true,
        macMovedEpoch: UInt32? = nil
    ) {
        self.route = route
        self.newestEpoch = newestEpoch
        self.canUseRelay = canUseRelay
        self.leftTransport = leftTransport
        self.relayUnreachableSince = relayUnreachableSince
        self.otherMailboxPolledAt = otherMailboxPolledAt
        self.relaySwitchRequested = relaySwitchRequested
        self.lapseRequested = lapseRequested
        self.hasOtherRoute = hasOtherRoute
        self.macMovedEpoch = macMovedEpoch
    }
}

/// Why the relay refuses a relay-only link (relay client Phase 5, `LinkRecord.relayRefused`): its subscription
/// ended (`lapse`), or its Mac is in none of its slots while the subscription stands (`slot`).
public enum RelayRefusal: String, Codable, Sendable {
    case lapse, slot
}

// The announcements keep every field flat, so each case label names one.
// swiftlint:disable enum_case_associated_values_count
/// One thing the phone read or noticed about its hub's transport.
public enum FollowerInput: Sendable {
    /// A `transport_switched` control read on `on`; `keyboxOpened` says whether its keybox for the new epoch opened.
    case switched(target: TransportKind, epoch: UInt32, by: String, at: Date, keyboxOpened: Bool, controlID: String, on: TransportKind)
    /// The hub's transport marker (rule 12a), read on `on`.
    case marker(target: TransportKind, epoch: UInt32, by: String, at: Date, on: TransportKind)
    /// `hub_on_relay`: the hub is on the relay and believes this phone cannot follow (rule 11.4, R32).
    case hubOnRelay(controlID: String)
    case relayReachable(Bool, at: Date)
    case oldMailboxDrained(TransportKind)
    /// The relay refused the phone because its subscription ended (sim rule 16).
    case relayLapsed
    /// The relay account answered with this hub's Mac in none of this phone's slots while it is on the relay (relay
    /// client Phase 5: a `FORBIDDEN` or `SLOT_REMOVED`, then a read). The hub stops naming it a reader.
    case slotLost
}
// swiftlint:enable enum_case_associated_values_count

/// What the caller does, in the order given.
public enum FollowerCommand: Equatable, Sendable {
    /// Merge the switch's keybox into the hub's keys.
    case mergeKeybox
    /// The hub answered this phone's request for the transport it is already on: stop waiting for an answer.
    case requestAnswered
    /// Talk to the hub over `to` from now on, in `epoch`; `by` and `at` say who switched and when (empty `by`: the
    /// phone moved because the hub went where it cannot follow).
    case moveRoute(to: TransportKind, epoch: UInt32, by: String, at: Date)
    /// Rule 13: every action without an echo again, the same bytes, in order, only on the new route.
    case resendUnechoedOnNewTransport
    case sendEpochAck(UInt32)
    /// R32: every action without an echo is listed as Not delivered because the hub runs over the relay.
    case listUnechoedAsUndelivered
    /// Rule 15: the mailbox on a transport the phone left: unseen hub records first, then delete the rest.
    case drainMailbox(on: TransportKind)
    /// Rule 12: the relay has been unreachable for more than 60 s; read the mailbox on `on` for controls.
    case pollOtherMailbox(on: TransportKind)
    /// The control is decided: delete it and its copy on the other transport.
    case markHandled(controlID: String)
    /// Ask the hub to move this phone to `target`, with the hub's own `reason` (the lapse: `lapseReason`).
    case requestSwitch(target: TransportKind, reason: String)
    /// Relay client Phase 5: every action without an echo is withdrawn (its own record deleted under the version it
    /// wrote), then listed as Not delivered with `refused`, so a later Retry cannot apply it twice. An echo met on the
    /// way is applied instead; a refused delete leaves the row `sent` for the next event or the 24 h sweep.
    case withdrawUnechoed
    /// An opened `hub_on_relay` proves the hub cleared this phone's relay keys: the private ephemeral keys and every
    /// stored pair go (`HubLinkKeys.droppingEphemeral`).
    case dropEphemeral
    /// A relay-only link the relay refuses: the link's term starts (`LinkRecord.relayRefused`, its `since` kept).
    case markRefused(RelayRefusal)
    /// A relay-only link read that its Mac moved to iCloud in `epoch` (a `transport_switched` or the marker): it cannot
    /// follow, so the route stays and S59 shows (`LinkRecord.macMoved`). No term starts from it.
    case markMoved(epoch: UInt32)
    /// A marker toward the relay in an epoch after the move: the Mac is back on the relay, S59 goes.
    case clearMoved
    /// Nothing to do, and nothing to keep.
    case ignore
}

/// The phone's switch decisions (sim rules 12, 12a, 13, 15 and ruling R32) as one pure function. The app's
/// `TransportFollower` and the sim twins' `SimPhone` both execute its commands. An empty command list means "decide
/// later": a control that got no `markHandled` stays where it is and is read again on a later pass.
public enum TransportFollowerPolicy {
    /// How long the relay must be unreachable before the phone also reads its CloudKit mailbox (rule 12).
    public static let otherMailboxAfter: TimeInterval = 60
    /// How often it reads it while the outage lasts.
    public static let otherMailboxEvery: TimeInterval = 30
    /// The one reason the hub knows for a move to CloudKit that spares the Mac's other phones (`switcher.Request`).
    public static let lapseReason = "entitlement_expired"

    public static func decide(
        _ input: FollowerInput, state: FollowerState, now: Date
    ) -> (state: FollowerState, commands: [FollowerCommand]) {
        switch input {
        case let .switched(target, epoch, by, at, keyboxOpened, controlID, _):
            if epoch == state.newestEpoch, target == state.route {
                // Go `handleSwitch`, `target == current`: the hub's answer so the phone stops waiting.
                return (state, [.requestAnswered, .markHandled(controlID: controlID)])
            }
            guard epoch > state.newestEpoch || answersRelayRequest(state, target: target, epoch: epoch) else {
                return (state, [.markHandled(controlID: controlID)])
            }
            if let left = leftBehind(state, target: target, epoch: epoch) {
                return (state, left + [.markHandled(controlID: controlID)])
            }
            if target == .relay, state.canUseRelay != .yes {
                return state.canUseRelay == .no ? withoutHub(state, controlID: controlID, now: now) : (state, [])
            }
            guard keyboxOpened else { return (state, []) }
            let (next, moved) = follow(state, to: target, epoch: epoch, by: by, at: at)
            return (next, [.mergeKeybox] + moved + [.markHandled(controlID: controlID)])
        case let .marker(target, epoch, by, at, _):
            return marker(state, target: target, epoch: epoch, by: by, at: at, now: now)
        case let .hubOnRelay(controlID):
            // The hub may know of a lapse before the phone does (Go `hubWithoutUs` always obeys); only an unknown
            // answer leaves the control for a later pass.
            if state.canUseRelay == .unknown { return (state, []) }
            // Opened, so sealed by the hub: it cleared this phone's relay keys first (relay client Phase 5).
            let (next, commands) = withoutHub(state, controlID: controlID, now: now)
            return (next, insert(.dropEphemeral, before: controlID, in: commands))
        case let .relayReachable(reachable, at):
            return outage(state, reachable: reachable, at: at, now: now)
        case let .oldMailboxDrained(kind):
            var next = state
            if next.leftTransport == kind { next.leftTransport = nil }
            return (next, [])
        case .relayLapsed:
            return relayLapsed(state)
        case .slotLost:
            return slotLost(state, now: now)
        }
    }

    /// The hub's transport marker (rule 12a): a newer epoch is followed; a relay-only link left behind marks the move
    /// (S59), and a marker toward the relay after that move clears it, read ahead of the epoch guard, as the zone
    /// keybox merged first has already raised the epoch to the marker's.
    private static func marker(
        _ state: FollowerState, target: TransportKind, epoch: UInt32, by: String, at: Date, now: Date
    ) -> (state: FollowerState, commands: [FollowerCommand]) {
        let back: [FollowerCommand] = backOnRelay(state, target: target, epoch: epoch) ? [.clearMoved] : []
        guard epoch > state.newestEpoch else { return (state, back + [.ignore]) }
        if let left = leftBehind(state, target: target, epoch: epoch) {
            return (state, left.isEmpty ? [.ignore] : left)
        }
        if target == .relay, state.canUseRelay != .yes {
            guard state.canUseRelay == .no else { return (state, back) }
            let (next, commands) = withoutHub(state, controlID: nil, now: now)
            return (next, back + commands)
        }
        let (next, commands) = follow(state, to: target, epoch: epoch, by: by, at: at)
        return (next, back + commands)
    }

    /// The relay refused this phone because its subscription ended (sim rule 16): ask the hub for iCloud once. A
    /// relay-only link (relay client Phase 5) also withdraws and lists now, since no `hub_on_relay` can reach it; its
    /// route stays and no key is erased (the hub may not have acted yet).
    private static func relayLapsed(_ state: FollowerState) -> (state: FollowerState, commands: [FollowerCommand]) {
        var next = state
        next.canUseRelay = .no
        guard state.route == .relay else { return (next, [.ignore]) }
        let commands: [FollowerCommand] = state.hasOtherRoute ? [] : [.withdrawUnechoed, .markRefused(.lapse)]
        guard !state.lapseRequested else { return (next, commands + [.ignore]) }
        next.lapseRequested = true
        return (next, commands + [.requestSwitch(target: .cloudKit, reason: lapseReason)])
    }

    /// The Mac is in none of this phone's slots (relay client Phase 5, ask #1081): withdraw every unechoed action,
    /// then, with an iCloud route, move as `withoutHub` does without waiting for `hub_on_relay` (its unechoed rows are
    /// listed when that notice comes); with none, stay and start the link's term. No key is erased: a slot given back
    /// before the hub acts must still open a keybox sealed to the offer.
    private static func slotLost(_ state: FollowerState, now: Date) -> (state: FollowerState, commands: [FollowerCommand]) {
        guard state.route == .relay else { return (state, [.ignore]) }
        guard state.hasOtherRoute else { return (state, [.withdrawUnechoed, .markRefused(.slot), .ignore]) }
        var next = state
        next.route = .cloudKit
        next.leftTransport = .relay
        next.lapseRequested = false
        return (next, [
            .withdrawUnechoed, .moveRoute(to: .cloudKit, epoch: state.newestEpoch, by: "", at: now),
            .drainMailbox(on: .relay), .ignore
        ])
    }

    /// A relay-only link reads that its Mac moved to iCloud (relay client Phase 5, S59, ask #1081): it cannot follow, so
    /// its route stays, the switch's keybox is not merged and the epoch is not adopted; its unechoed actions are
    /// withdrawn and listed (a move made by another phone brings no `relayLapsed`), and the move is marked. Empty when
    /// this move was already marked; nil when the rule does not apply.
    private static func leftBehind(_ state: FollowerState, target: TransportKind, epoch: UInt32) -> [FollowerCommand]? {
        guard target == .cloudKit, state.route == .relay, !state.hasOtherRoute else { return nil }
        if let moved = state.macMovedEpoch, moved >= epoch { return [] }
        return [.withdrawUnechoed, .markMoved(epoch: epoch)]
    }

    /// A marker toward the relay in an epoch after the marked move: the Mac is back on the relay. An older marker, or a
    /// `transport_switched`, clears nothing.
    private static func backOnRelay(_ state: FollowerState, target: TransportKind, epoch: UInt32) -> Bool {
        guard target == .relay, let moved = state.macMovedEpoch else { return false }
        return epoch > moved
    }

    /// `command` placed right before the control's `markHandled` (the control is decided last).
    private static func insert(_ command: FollowerCommand, before controlID: String, in commands: [FollowerCommand]) -> [FollowerCommand] {
        var out = commands
        let at = out.firstIndex(of: .markHandled(controlID: controlID)) ?? out.endIndex
        out.insert(command, at: at)
        return out
    }

    /// A same-epoch `transport_switched{relay}` on iCloud while the phone's own relay request waits: the hub's answer
    /// that it already runs there (`FollowerState.relaySwitchRequested`), followed as a newer epoch.
    private static func answersRelayRequest(_ state: FollowerState, target: TransportKind, epoch: UInt32) -> Bool {
        state.relaySwitchRequested && target == .relay && state.route == .cloudKit && epoch == state.newestEpoch && epoch > 0
    }

    /// Adopts a newer epoch on `target`: move, resend there, confirm the epoch, drain the old mailbox (rule 13, 15).
    private static func follow(
        _ state: FollowerState, to target: TransportKind, epoch: UInt32, by: String, at: Date
    ) -> (state: FollowerState, commands: [FollowerCommand]) {
        var next = state
        next.newestEpoch = epoch
        var commands: [FollowerCommand] = [.moveRoute(to: target, epoch: epoch, by: by, at: at)]
        let left = state.route
        if target != left {
            next.route = target
            next.leftTransport = left
            if target == .cloudKit { next.lapseRequested = false }
            commands.append(.resendUnechoedOnNewTransport)
        }
        commands.append(.sendEpochAck(epoch))
        if target != left { commands.append(.drainMailbox(on: left)) }
        return (next, commands)
    }

    /// The hub is on the relay without this phone (R32): back to CloudKit, unechoed actions listed as Not delivered.
    private static func withoutHub(
        _ state: FollowerState, controlID: String?, now: Date
    ) -> (state: FollowerState, commands: [FollowerCommand]) {
        var next = state
        var commands: [FollowerCommand] = []
        if state.route == .relay {
            next.route = .cloudKit
            next.leftTransport = .relay
            next.lapseRequested = false
            commands.append(.moveRoute(to: .cloudKit, epoch: state.newestEpoch, by: "", at: now))
        }
        commands.append(.listUnechoedAsUndelivered)
        if state.route == .relay { commands.append(.drainMailbox(on: .relay)) }
        if let controlID { commands.append(.markHandled(controlID: controlID)) }
        return (next, commands)
    }

    /// Rule 12: on route `.relay`, an outage longer than 60 s polls the CloudKit mailbox every 30 s.
    private static func outage(
        _ state: FollowerState, reachable: Bool, at: Date, now: Date
    ) -> (state: FollowerState, commands: [FollowerCommand]) {
        var next = state
        guard !reachable else {
            next.relayUnreachableSince = nil
            next.otherMailboxPolledAt = nil
            return (next, [])
        }
        let since = state.relayUnreachableSince ?? at
        next.relayUnreachableSince = since
        guard state.route == .relay, now.timeIntervalSince(since) > otherMailboxAfter else { return (next, []) }
        if let polled = state.otherMailboxPolledAt, now.timeIntervalSince(polled) < otherMailboxEvery {
            return (next, [])
        }
        next.otherMailboxPolledAt = now
        return (next, [.pollOtherMailbox(on: .cloudKit)])
    }
}
