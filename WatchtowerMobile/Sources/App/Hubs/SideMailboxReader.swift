import Foundation
import os
import WatchtowerSync

/// The side mailbox reader's clock and wait (`AppRoot`); tests step both by hand.
struct SideMailboxTiming {
    var now: @MainActor () -> Date = { Date() }
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    static let live = Self()
}

/// The hubs whose left mailbox drain a relay account refused (sim rule 16): `AppRoot`'s, for this launch.
@MainActor
final class SideDrainRefusals {
    private var refused: Set<String> = []

    func contains(_ hubID: String, _ kind: TransportKind) -> Bool {
        refused.contains(Self.key(hubID, kind))
    }

    func insert(_ hubID: String, _ kind: TransportKind) {
        refused.insert(Self.key(hubID, kind))
    }

    private static func key(_ hubID: String, _ kind: TransportKind) -> String {
        "\(hubID)|\(kind.rawValue)"
    }
}

/// The hub's mailbox on the transport this phone is not on (relay client Phase 3 Task 12; sim rules 12, 15, 16).
/// It exists only while the hub has both routes (`LinkRecord.otherRoute`): a link to a hub that offers only the relay
/// has no CloudKit route and never polls one. Every `SessionCadence.otherMailboxInterval` while the app is active:
/// - **rule 15:** with `leftTransport` set, the mailbox there is drained once that transport answers (the hub's
///   unseen records handled first, then everything left deleted), and `leftTransport` is cleared in one registry
///   write. A relay account that refuses the deletes (`ENTITLEMENT_INACTIVE`, `FORBIDDEN`: a lapsed or forbidden
///   account may still read and delete its mailbox, rule 16) is logged and the drain stops until the next launch.
/// - **rule 12:** on route `.relay`, once the relay has not answered for more than 60 s, the CloudKit `RelayZone` is
///   read every 30 s for controls only, which go through the session's own `TransportFollower`.
///
/// Its transport is the other route's, built by the factory (`HubSessionFactory.makeSide`, `TransportFactory`) on
/// that route's own store: a relay one attaches to the process's one relay session and reads over HTTPS, so it never
/// dials a socket of its own; a CloudKit one runs its engine for the pulls. Built on first use, stopped and closed by
/// `stop()` (the session's shutdown) and after a drain on CloudKit, where nothing else needs the relay.
/// It never writes on that transport: the outbox stays the session's (a held one stays held).
@MainActor
final class SideMailboxReader {
    let hubID: String
    private weak var session: HubSession?
    private let follower: TransportFollower
    private weak var host: (any TransportFollowerHost)?
    private let refusals: SideDrainRefusals
    private let timing: SideMailboxTiming
    private let makeTransport: @MainActor (HubRoute) throws -> SideTransport
    /// The outage bookkeeping (`relayUnreachableSince`, `otherMailboxPolledAt`) the policy keeps.
    private var outage: FollowerState?
    /// The other route's transport, sealed with the session's keys, once built.
    private var side: (route: HubRoute, built: SideTransport, secure: SecureTransport, whole: Bool)?
    private var loopTask: Task<Void, Never>?
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "TransportFollower")

    init(
        session: HubSession,
        follower: TransportFollower,
        host: any TransportFollowerHost,
        refusals: SideDrainRefusals,
        timing: SideMailboxTiming = .live,
        makeTransport: @escaping @MainActor (HubRoute) throws -> SideTransport
    ) {
        hubID = session.hubID
        self.session = session
        self.follower = follower
        self.host = host
        self.refusals = refusals
        self.timing = timing
        self.makeTransport = makeTransport
    }

    /// Ticks every `SessionCadence.otherMailboxInterval` once the session's boot ended.
    func start() {
        loopTask?.cancel()
        let sleep = timing.sleep
        loopTask = Task { [weak self] in
            await self?.session?.waitForBoot()
            while !Task.isCancelled {
                do {
                    try await sleep(SessionCadence.otherMailboxInterval)
                } catch {
                    return
                }
                await self?.tick()
            }
        }
    }

    /// Stops the loop, then the other transport, and closes its store.
    func stop() async {
        loopTask?.cancel()
        loopTask = nil
        await closeSide()
    }

    /// One look at the other transport: the drain owed there, then the outage poll. Only while the app is active.
    func tick() async {
        guard let session, session.isActive, let link = host?.followerLink(hubID: hubID),
              let other = link.otherRoute else { return }
        let kind = HubSession.transportKind(of: other)
        if link.leftTransport == kind {
            await drain(kind, on: other)
        }
        if link.transport == .relay {
            await pollIfRelayDown(other, session: session)
        }
    }

    // MARK: - Rule 15

    private func drain(_ kind: TransportKind, on route: HubRoute) async {
        guard !refusals.contains(hubID, kind) else { return }
        guard let session, let secure = await pulled(route, whole: true) else { return }
        let follower = follower
        let outcome: RelayFeed.DrainOutcome
        do {
            outcome = try await session.drainOtherMailbox(over: secure) { control in
                await follower.handle(control: control, on: kind)
            }
        } catch {
            let reason = Self.describe(error)
            Self.logger.notice("the \(kind.rawValue, privacy: .public) mailbox left is not drained yet: \(reason, privacy: .public)")
            return
        }
        switch outcome {
        case .drained:
            forgetLeft(kind)
            if kind == .relay { await closeSide() }
        case .incomplete:
            Self.logger.notice("the \(kind.rawValue, privacy: .public) mailbox left keeps records for a later pass")
        case .refused(let refusal) where Self.stopsTheDrain(refusal):
            refusals.insert(hubID, kind)
            let reason = Self.describe(refusal)
            Self.logger.error(
                "the \(kind.rawValue, privacy: .public) mailbox left refused its deletes (\(reason, privacy: .public)): next launch")
        case .refused(let refusal):
            let reason = Self.describe(refusal)
            Self.logger.notice("the \(kind.rawValue, privacy: .public) mailbox left refused its deletes for now (\(reason, privacy: .public))")
        }
    }

    /// Clears `leftTransport` on the hub's row as it stands now, in one registry write (the row may have moved since).
    private func forgetLeft(_ kind: TransportKind) {
        guard let host, var link = host.followerLink(hubID: hubID), link.leftTransport == kind else { return }
        link.leftMailboxDrained(kind)
        if host.persistRoute(link) {
            Self.logger.notice("the \(kind.rawValue, privacy: .public) mailbox left is drained")
        }
    }

    /// Rule 16: a lapsed or forbidden relay account; anything else may clear on a later pass.
    private static func stopsTheDrain(_ refusal: TransportRefusal) -> Bool {
        refusal == .entitlementInactive || refusal == .permanent(code: "forbidden")
    }

    // MARK: - Rule 12

    private func pollIfRelayDown(_ cloudKit: HubRoute, session: HubSession) async {
        guard let availability = await session.relayAvailability() else { return }
        let reachable = availability == .available
        let now = timing.now()
        var state = outage ?? FollowerState(route: .relay, newestEpoch: 0, canUseRelay: .unknown)
        state.route = .relay
        let (next, commands) = TransportFollowerPolicy.decide(.relayReachable(reachable, at: now), state: state, now: now)
        outage = next
        guard commands.contains(.pollOtherMailbox(on: .cloudKit)), let secure = await pulled(cloudKit) else { return }
        let follower = follower
        do {
            let read = try await session.readOtherControls(over: secure) { control in
                await follower.handle(control: control, on: .cloudKit)
            }
            Self.logger.notice("relay down: \(read, privacy: .public) controls read on CloudKit")
        } catch {
            Self.logger.notice("relay down: the CloudKit mailbox was not read: \(Self.describe(error), privacy: .public)")
        }
    }

    // MARK: - The other transport

    /// The other route's transport, built on first use and pulled now; nil while it cannot be built or reached.
    /// `whole`: the pull reads the whole mailbox (a drain), not only what came after the store's last reader.
    private func pulled(_ route: HubRoute, whole: Bool = false) async -> SecureTransport? {
        if let side, side.route != route || (whole && !side.whole) { await closeSide() }
        if side == nil {
            guard let session else { return nil }
            do {
                let built = try makeTransport(route)
                side = (route, built, session.sealing(built.transport), whole)
                if whole { try await built.readFromStart() }
                // CloudKit pulls through its engine; a relay transport pulls over HTTPS and wants no socket.
                if route.cloudKitScope != nil, let live = built.transport as? any LiveTransport { await live.start() }
            } catch {
                Self.logger.error("the other transport cannot be built: \(Self.describe(error), privacy: .public)")
                await closeSide()
                return nil
            }
        }
        guard let side else { return nil }
        do {
            try await (side.built.transport as? any LiveTransport)?.pull()
        } catch {
            Self.logger.notice("the other transport is not reachable: \(Self.describe(error), privacy: .public)")
            return nil
        }
        return side.secure
    }

    private func closeSide() async {
        guard let closing = side else { return }
        side = nil
        await (closing.built.transport as? any LiveTransport)?.stop()
        do {
            try closing.built.store?.close()
        } catch {
            Self.logger.error("the other transport's store not closed: \(Self.describe(error), privacy: .public)")
        }
    }

    /// An error's type or a refusal's case only: no payload, no record name.
    nonisolated private static func describe(_ value: Any) -> String {
        if let refusal = value as? TransportRefusal { return String(describing: refusal) }
        return String(describing: type(of: value))
    }
}
