import Foundation
import os
import WatchtowerSync

/// The side mailbox reader's clock and wait (`AppRoot`); tests step both by hand.
struct SideMailboxTiming {
    var now: @MainActor () -> Date = { Date() }
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// Look at once after the boot and on each return to the foreground (tests that step every look turn it off).
    var looksAtWake = true
    /// How long `stop()` waits for the running look (a hung engine fetch or relay call) before it cancels it and
    /// closes the transport anyway, as `HubSession.outboxDrainCap` bounds the outbox.
    var stopLookCap: Duration = .seconds(10)
    /// Waits out `stopLookCap` (cancelled once the look ended); tests replace it.
    var stopLookSleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }

    static let live = Self()
}

/// What the side mailbox readers of one launch share (`AppRoot`'s): the left mailboxes whose drain a relay account
/// refused (sim rule 16: until the next launch), and the ones already read from the start (a CloudKit drain wipes the
/// left store once a launch, not at every rebuild).
@MainActor
final class SideDrainLedger {
    private var refused: Set<String> = []
    private var readFromStart: Set<String> = []

    func isRefused(_ hubID: String, _ kind: TransportKind) -> Bool {
        refused.contains(Self.key(hubID, kind))
    }

    func refuse(_ hubID: String, _ kind: TransportKind) {
        refused.insert(Self.key(hubID, kind))
    }

    func wasReadFromStart(_ hubID: String, _ kind: TransportKind) -> Bool {
        readFromStart.contains(Self.key(hubID, kind))
    }

    func markReadFromStart(_ hubID: String, _ kind: TransportKind) {
        readFromStart.insert(Self.key(hubID, kind))
    }

    private static func key(_ hubID: String, _ kind: TransportKind) -> String {
        "\(hubID)|\(kind.rawValue)"
    }
}

/// The hub's mailbox on the transport this phone is not on (relay client Phase 3 Task 12; sim rules 12, 15, 16).
/// It exists only while the hub has both routes (`LinkRecord.otherRoute`): a link to a hub that offers only the relay
/// has no CloudKit route and never polls one. It looks once after the session's boot, on each return to the
/// foreground and every `SessionCadence.otherMailboxInterval` while the app is active:
/// - **rule 15:** with `leftTransport` set, the mailbox there is drained once that transport answers (the hub's
///   unseen records handled first, then everything left deleted, the phone's `device` record kept on CloudKit), and
///   `leftTransport` is cleared in one registry write. A relay account that refuses the read or the deletes
///   (`ENTITLEMENT_INACTIVE`, `FORBIDDEN`; rule 16: a lapsed account may still read and delete its mailbox while the
///   relay lets it) is logged and the drain stops until the next launch.
/// - **rule 12:** on route `.relay`, once the relay has not answered for more than 60 s (from the session's first
///   unanswered fetch), the CloudKit `RelayZone` is read every 30 s for controls only, which go through the session's
///   own `TransportFollower`.
/// - **an open request toward iCloud** (`LinkRecord.transportRequest`, relay client Phase 4 Task 5): the hub answers in
///   the mailbox where it read the request, and a lapsed relay's refusal counts as an answer, so rule 12's outage test
///   would never start; the CloudKit mailbox is read every `TransportFollowerPolicy.otherMailboxEvery` while the
///   request is open, even when the relay answers.
///
/// Its transport is the other route's, built by the factory (`HubSessionFactory.makeSide`, `TransportFactory`) on
/// that route's own store: a relay one attaches to the process's one relay session and reads over HTTPS, so it never
/// dials a socket of its own; a CloudKit one runs its engine for the pulls. It is built on first use and stopped,
/// its store closed, whenever nothing needs it: after the relay mailbox is drained, when the outage ends, when the
/// app leaves the foreground (unless a drain is still owed), and at `stop()` (the session's shutdown).
/// It never writes on that transport: the outbox stays the session's (a held one stays held).
///
/// One look at a time (`tick` joins a running one). `stop()` fences it: every step returns once stopped, a control
/// read after it is left undecided, and `stop()` waits for the running look (`stopLookCap` at most, then it cancels
/// it) before it closes the transport, so a look that resumes after a route move never builds on, or deletes
/// through, a store the next session owns. A close is one task (`closing`) that `stop()` and a new build wait for, so
/// the next session never opens the same store while a stand-down is still closing it.
@MainActor
final class SideMailboxReader {
    let hubID: String
    private weak var session: HubSession?
    private let follower: TransportFollower
    private weak var host: (any TransportFollowerHost)?
    private let ledger: SideDrainLedger
    private let timing: SideMailboxTiming
    private let makeTransport: @MainActor (HubRoute) throws -> SideTransport
    /// The outage bookkeeping (`relayUnreachableSince`, `otherMailboxPolledAt`) the policy keeps.
    private var outage: FollowerState?
    /// The last read of the iCloud mailbox for an open request toward iCloud (relay client Phase 4 Task 5).
    private var requestPolledAt: Date?
    /// The other route's transport, sealed with the session's keys, once built.
    private var side: (route: HubRoute, built: SideTransport, secure: SecureTransport)?
    private var loopTask: Task<Void, Never>?
    /// The look running now (`tick`).
    private var running: Task<Void, Never>?
    /// The close of the other transport running now (`closeSide`).
    private var closing: Task<Void, Never>?
    /// The latest look or stand-down the boot or a scene change started; tests await it.
    private(set) var wake: Task<Void, Never>?
    private var stopped = false
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "TransportFollower")

    init(
        session: HubSession,
        follower: TransportFollower,
        host: any TransportFollowerHost,
        ledger: SideDrainLedger,
        timing: SideMailboxTiming = .live,
        makeTransport: @escaping @MainActor (HubRoute) throws -> SideTransport
    ) {
        hubID = session.hubID
        self.session = session
        self.follower = follower
        self.host = host
        self.ledger = ledger
        self.timing = timing
        self.makeTransport = makeTransport
    }

    /// Looks once the session's boot ended (when `looksAtWake`), then every `SessionCadence.otherMailboxInterval`.
    func start() {
        let looks = timing.looksAtWake
        let boot = Task { [weak self] in
            await self?.session?.waitForBoot()
            if looks { await self?.tick() }
        }
        wake = boot
        let sleep = timing.sleep
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            await boot.value
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

    /// The session's scene phase: a look on the return to the foreground; on leaving it, the other transport stops
    /// unless a drain is still owed there.
    func activeChanged(_ active: Bool) {
        guard !stopped else { return }
        if active {
            if timing.looksAtWake { wake = Task { await self.tick() } }
        } else {
            wake = Task { await self.standDown() }
        }
    }

    /// Fences and waits for the running look (`stopLookCap` at most: then it is cancelled), then stops the other
    /// transport and closes its store, or waits for a close already running.
    func stop() async {
        stopped = true
        loopTask?.cancel()
        loopTask = nil
        wake?.cancel()
        if let running, !(await Self.wait(for: running, cap: timing.stopLookCap, sleep: timing.stopLookSleep)) {
            Self.logger.notice("side mailbox look cut off at stop")
            running.cancel()
        }
        await closeSide()
    }

    /// Waits for `task` up to `cap`; false when the cap passed first.
    private static func wait(
        for task: Task<Void, Never>, cap: Duration, sleep: @escaping @Sendable (Duration) async -> Void
    ) async -> Bool {
        // `decided`: the first watcher has answered; `ended`: it was the task, not the cap.
        let outcome = OSAllocatedUnfairLock(initialState: (decided: false, ended: false))
        var watchers: [Task<Void, Never>] = []
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let finish: @Sendable (Bool) -> Void = { ended in
                let first = outcome.withLock { state in
                    guard !state.decided else { return false }
                    state = (true, ended)
                    return true
                }
                if first { continuation.resume() }
            }
            watchers.append(Task { await task.value; finish(true) })
            watchers.append(Task {
                await sleep(cap)
                finish(false)
            })
        }
        for watcher in watchers { watcher.cancel() }
        return outcome.withLock { $0.ended }
    }

    /// One look at the other transport: the drain owed there, then the outage poll. Only while the app is active.
    /// A look already running is joined, not repeated.
    func tick() async {
        if let running {
            await running.value
            return
        }
        guard !stopped else { return }
        let look = Task { await self.look() }
        running = look
        await look.value
        running = nil
    }

    private func look() async {
        guard let session, session.isActive, let link = currentLink(), let other = link.otherRoute else { return }
        let kind = HubSession.transportKind(of: other)
        if link.leftTransport == kind {
            await drain(kind, on: other)
        }
        // Read again: the drain may have moved the hub (a switch decided there), or a stop came meanwhile.
        guard !stopped, let link = currentLink(), let other = link.otherRoute else { return }
        if link.transport == .relay, session.route == link.route {
            let polled = await pollIfRelayDown(other, session: session)
            if !polled { await pollForRequest(other, session: session) }
        } else {
            outage = nil
            requestPolledAt = nil
        }
        guard !stopped, let link = currentLink() else { return }
        if !needsSide(link) { await closeSide() }
    }

    private func currentLink() -> LinkRecord? {
        guard !stopped else { return nil }
        return host?.followerLink(hubID: hubID)
    }

    /// The other transport stays open only for a drain still owed or an outage going on.
    private func needsSide(_ link: LinkRecord) -> Bool {
        if let other = link.otherRoute, drainOwed(link, HubSession.transportKind(of: other)) { return true }
        if link.transportRequest?.awaitsAnswer == true, link.transport == .relay { return true }
        return link.transport == .relay && outage?.relayUnreachableSince != nil
    }

    private func drainOwed(_ link: LinkRecord, _ kind: TransportKind) -> Bool {
        link.leftTransport == kind && !ledger.isRefused(hubID, kind)
    }

    /// Leaving the foreground: the running look ends first; then the transport stops unless a drain is owed there.
    private func standDown() async {
        await running?.value
        guard !stopped, side != nil, let session, !session.isActive else { return }
        if let link = currentLink(), let other = link.otherRoute, drainOwed(link, HubSession.transportKind(of: other)) {
            return
        }
        await closeSide()
    }

    /// A control read on the other transport goes to the follower, unless the reader stopped meanwhile: then it stays
    /// undecided, in the mailbox, for the next session.
    private func decide(_ control: ControlPayload, on kind: TransportKind) async -> Bool {
        guard !stopped else { return false }
        return await follower.handle(control: control, on: kind)
    }

    private func handler(on kind: TransportKind) -> RelayFeed.SideHandler {
        { [weak self] control in await self?.decide(control, on: kind) ?? false }
    }

    // MARK: - Rule 15

    private func drain(_ kind: TransportKind, on route: HubRoute) async {
        guard !ledger.isRefused(hubID, kind), let session else { return }
        let secure: SecureTransport
        do {
            guard let pulled = try await pulled(route, whole: true) else { return }
            secure = pulled
        } catch where SideTransport.refusesTheAccount(error) {
            refuse(kind, Self.describe(error))
            return
        } catch {
            Self.logger.notice("the \(kind.rawValue, privacy: .public) mailbox left is not reachable yet: \(Self.describe(error), privacy: .public)")
            return
        }
        let outcome: RelayFeed.DrainOutcome
        do {
            outcome = try await session.drainOtherMailbox(over: secure, keepingDeviceRecord: kind == .cloudKit, handler: handler(on: kind))
        } catch {
            let reason = Self.describe(error)
            Self.logger.notice("the \(kind.rawValue, privacy: .public) mailbox left is not drained yet: \(reason, privacy: .public)")
            return
        }
        guard !stopped else { return }
        switch outcome {
        case .drained:
            forgetLeft(kind)
        case .incomplete:
            Self.logger.notice("the \(kind.rawValue, privacy: .public) mailbox left keeps records for a later pass")
        case .refused(let refusal) where SideTransport.refusesTheAccount(refusal):
            refuse(kind, Self.describe(refusal))
        case .refused(let refusal):
            let reason = Self.describe(refusal)
            Self.logger.notice("the \(kind.rawValue, privacy: .public) mailbox left refused its deletes for now (\(reason, privacy: .public))")
        }
    }

    /// Rule 16: logged, and no drain of `kind` for this hub until the next launch (`leftTransport` stays).
    private func refuse(_ kind: TransportKind, _ reason: String) {
        ledger.refuse(hubID, kind)
        Self.logger.error(
            "the \(kind.rawValue, privacy: .public) mailbox left refused the account (\(reason, privacy: .public)): next launch")
    }

    /// Clears `leftTransport` on the hub's row as it stands now, in one registry write (the row may have moved since).
    private func forgetLeft(_ kind: TransportKind) {
        guard let host, var link = currentLink(), link.leftTransport == kind else { return }
        link.leftMailboxDrained(kind)
        if host.persistRoute(link) {
            Self.logger.notice("the \(kind.rawValue, privacy: .public) mailbox left is drained")
        }
    }

    // MARK: - Rule 12

    /// true when it read the CloudKit mailbox.
    @discardableResult
    private func pollIfRelayDown(_ cloudKit: HubRoute, session: HubSession) async -> Bool {
        guard let availability = await session.relayAvailability(), !stopped else { return false }
        let now = timing.now()
        let reachable = availability == .available
        // The outage starts at the session's first unanswered fetch when it knows one (never in the future).
        let at = reachable ? now : min(session.relayUnansweredSince ?? now, now)
        var state = outage ?? FollowerState(route: .relay, newestEpoch: 0, canUseRelay: .unknown)
        state.route = .relay
        let (next, commands) = TransportFollowerPolicy.decide(.relayReachable(reachable, at: at), state: state, now: now)
        outage = next
        guard commands.contains(.pollOtherMailbox(on: .cloudKit)) else { return false }
        do {
            guard let secure = try await pulled(cloudKit, whole: false) else { return false }
            let read = try await session.readOtherControls(over: secure, handler: handler(on: .cloudKit))
            Self.logger.notice("relay down: \(read, privacy: .public) controls read on CloudKit")
        } catch {
            Self.logger.notice("relay down: the CloudKit mailbox was not read: \(Self.describe(error), privacy: .public)")
        }
        return true
    }

    /// An open request toward iCloud: the CloudKit mailbox is read every `otherMailboxEvery`, the relay answering or
    /// not; the controls found go to the follower, a rejection to the request.
    private func pollForRequest(_ cloudKit: HubRoute, session: HubSession) async {
        guard currentLink()?.transportRequest?.awaitsAnswer == true else {
            requestPolledAt = nil
            return
        }
        let now = timing.now()
        if let polled = requestPolledAt, now.timeIntervalSince(polled) < TransportFollowerPolicy.otherMailboxEvery { return }
        requestPolledAt = now
        do {
            guard let secure = try await pulled(cloudKit, whole: false) else { return }
            let read = try await session.readOtherControls(over: secure, handler: handler(on: .cloudKit))
            Self.logger.notice("a request toward iCloud is open: \(read, privacy: .public) controls read on CloudKit")
        } catch {
            Self.logger.notice("a request toward iCloud is open: the CloudKit mailbox was not read: \(Self.describe(error), privacy: .public)")
        }
    }

    // MARK: - The other transport

    /// The other route's transport, built on first use and pulled now; nil once stopped or when it cannot be built.
    /// `whole`: the mailbox is read from the start once this launch (a drain), before a CloudKit engine starts.
    /// Throws what the pull throws.
    private func pulled(_ route: HubRoute, whole: Bool) async throws -> SecureTransport? {
        let kind = HubSession.transportKind(of: route)
        let fromStart = whole && !ledger.wasReadFromStart(hubID, kind)
        if let side, side.route != route || fromStart { await closeSide() }
        // A stand-down's close still running: the build opens the same store only after it.
        await closing?.value
        guard !stopped, let session else { return nil }
        if side == nil {
            let built: SideTransport
            do {
                built = try makeTransport(route)
            } catch {
                Self.logger.error("the other transport cannot be built: \(Self.describe(error), privacy: .public)")
                return nil
            }
            side = (route, built, session.sealing(built.transport))
            if fromStart {
                try await built.readFromStart()
                ledger.markReadFromStart(hubID, kind)
            }
            // CloudKit pulls through its engine; a relay transport pulls over HTTPS and wants no socket.
            if !stopped, route.cloudKitScope != nil, let live = built.transport as? any LiveTransport { await live.start() }
        }
        guard !stopped, let side else { return nil }
        try await side.built.pullMailbox()
        return stopped ? nil : side.secure
    }

    /// Stops the other transport and closes its store as one task (`closing`), after any close before it; with no
    /// transport open, waits for a close still running.
    private func closeSide() async {
        if let open = side {
            side = nil
            let previous = closing
            closing = Task {
                await previous?.value
                await (open.built.transport as? any LiveTransport)?.stop()
                do {
                    try open.built.store?.close()
                } catch {
                    Self.logger.error("the other transport's store not closed: \(Self.describe(error), privacy: .public)")
                }
            }
        }
        guard let task = closing else { return }
        await task.value
        if closing == task { closing = nil }
    }

    /// An error's type or a refusal's case only: no payload, no record name.
    nonisolated private static func describe(_ value: Any) -> String {
        if let refusal = value as? TransportRefusal { return String(describing: refusal) }
        return String(describing: type(of: value))
    }
}
