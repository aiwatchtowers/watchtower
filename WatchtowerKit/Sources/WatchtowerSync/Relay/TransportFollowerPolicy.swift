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
    public var canUseRelay: RelayUse
    /// A transport the phone left whose mailbox is still to drain (rule 15).
    public var leftTransport: TransportKind?
    /// When the relay stopped answering on route `.relay`; nil while it answers.
    public var relayUnreachableSince: Date?
    /// The last CloudKit mailbox poll of the current relay outage (rule 12).
    public var otherMailboxPolledAt: Date?

    public init(
        route: TransportKind,
        newestEpoch: UInt32,
        canUseRelay: RelayUse,
        leftTransport: TransportKind? = nil,
        relayUnreachableSince: Date? = nil,
        otherMailboxPolledAt: Date? = nil
    ) {
        self.route = route
        self.newestEpoch = newestEpoch
        self.canUseRelay = canUseRelay
        self.leftTransport = leftTransport
        self.relayUnreachableSince = relayUnreachableSince
        self.otherMailboxPolledAt = otherMailboxPolledAt
    }
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
}
// swiftlint:enable enum_case_associated_values_count

/// What the caller does, in the order given.
public enum FollowerCommand: Equatable, Sendable {
    /// Merge the switch's keybox into the hub's keys.
    case mergeKeybox
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

    public static func decide(
        _ input: FollowerInput, state: FollowerState, now: Date
    ) -> (state: FollowerState, commands: [FollowerCommand]) {
        switch input {
        case let .switched(target, epoch, by, at, keyboxOpened, controlID, _):
            guard epoch > state.newestEpoch else { return (state, [.markHandled(controlID: controlID)]) }
            if target == .relay, state.canUseRelay != .yes {
                return withoutHub(state, controlID: controlID, now: now)
            }
            guard keyboxOpened else { return (state, []) }
            let (next, moved) = follow(state, to: target, epoch: epoch, by: by, at: at)
            return (next, [.mergeKeybox] + moved + [.markHandled(controlID: controlID)])
        case let .marker(target, epoch, by, at, _):
            guard epoch > state.newestEpoch else { return (state, [.ignore]) }
            if target == .relay, state.canUseRelay != .yes {
                return withoutHub(state, controlID: nil, now: now)
            }
            return follow(state, to: target, epoch: epoch, by: by, at: at)
        case let .hubOnRelay(controlID):
            if state.canUseRelay == .yes { return (state, [.markHandled(controlID: controlID)]) }
            return withoutHub(state, controlID: controlID, now: now)
        case let .relayReachable(reachable, at):
            return outage(state, reachable: reachable, at: at, now: now)
        case let .oldMailboxDrained(kind):
            var next = state
            if next.leftTransport == kind { next.leftTransport = nil }
            return (next, [])
        }
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
            commands.append(.resendUnechoedOnNewTransport)
        }
        commands.append(.sendEpochAck(epoch))
        if target != left { commands.append(.drainMailbox(on: left)) }
        return (next, commands)
    }

    /// The hub is on the relay and this phone cannot follow (R32). With an unknown answer nothing is decided.
    private static func withoutHub(
        _ state: FollowerState, controlID: String?, now: Date
    ) -> (state: FollowerState, commands: [FollowerCommand]) {
        guard state.canUseRelay == .no else { return (state, []) }
        var next = state
        var commands: [FollowerCommand] = []
        if state.route == .relay {
            next.route = .cloudKit
            next.leftTransport = .relay
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
