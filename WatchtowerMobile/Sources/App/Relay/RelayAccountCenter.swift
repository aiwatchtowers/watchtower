import Foundation
import Observation
import os
import WatchtowerHostedRelay
import WatchtowerSync

/// One hub's session as the center sees it: what a lapse asks of it, and whether it runs over the relay.
protocol RelayLapseTarget: AnyObject {
    @MainActor func lapseRelay() async
    @MainActor var isOnRelay: Bool { get }
    /// The entitlement came back: a lapse's kept request is withdrawn. No-op on a session with none.
    @MainActor func lapseEnded() async
}

extension HubSession: RelayLapseTarget {
    var isOnRelay: Bool {
        if case .hostedRelay = route { return true }
        return false
    }
}

/// What the center needs of the process's relay session. Nothing here creates an identity but `account`, so the
/// center calls it only after `hasIdentity` or on an owner's press.
struct RelayAccountLink {
    /// Whether this phone holds a `relay_auth` key. Reads the Keychain, creates nothing.
    var hasIdentity: @MainActor () throws -> Bool
    /// The relay account; builds the session and the identity on first use. nil while the relay is off.
    var account: @MainActor () throws -> HostedRelayAccount?
    /// The session's account-level signals, for one reader; nil while the relay is off.
    var events: @MainActor () throws -> AsyncStream<HostedRelayEvent>?

    static func live(_ relay: SharedRelaySession) -> Self {
        Self(
            hasIdentity: { try relay.hasIdentity() },
            account: { try relay.account() },
            events: { try relay.session()?.events }
        )
    }
}

/// The phone's Relay subscription: the relay's word on the account, and an owner's purchase or restore on its way
/// from Apple to the relay. Built only while the relay is available (`AppRoot.wireRelayAccount`). A transaction is
/// finished only on an entitlement answer and comes from StoreKit each time, so a kill, an unreachable relay or a
/// refusal leaves the row in `Transaction.unfinished` for the next sweep. Nothing here is persisted but `wasPaying`.
@MainActor @Observable
final class RelayAccountCenter {
    enum Phase: Equatable {
        case checking
        /// The relay gave no answer.
        case unknown
        /// None, or expired/revoked.
        case free(ended: Bool)
        case paying(grace: Bool, macs: [String])
        case moved
    }

    enum PurchaseState: Equatable {
        case idle, loadingProduct, productFailed
        case ready(RelayProduct)
        case buying, confirming, pending
        /// Apple yes, the relay not reached.
        case boughtNotConfirmed
        /// No account id: nothing bought yet.
        case accountFailed
        case restoring, noSubscriptionFound
        case refused, transferLimit, notImplemented, updateRequired
        /// The App Store call threw for a reason other than the owner's cancel. It says nothing about a charge.
        case storeFailed
        case done
    }

    enum UnconfirmedPurchase: Equatable {
        case confirming, notReached
        case refused, transferLimit, notImplemented, updateRequired
    }

    private enum Press { case buy, restore }

    /// What one `get_account_state` came to.
    private enum ReadOutcome {
        /// No answer.
        case failed
        /// An answer a newer read or a control overtook: nothing written.
        case superseded
        /// Written, no lapse.
        case kept
        /// Written, and the relay Macs were asked to lapse.
        case lapsed
    }

    /// What one `submit_transaction` came to. A refusal is a definite answer; anything else that is no entitlement,
    /// a raw error included, is like an unreachable relay.
    private enum SubmitAnswer: Equatable {
        case entitled
        case refused(UnconfirmedPurchase)
        case unreachable
    }

    private(set) var phase: Phase = .checking
    /// The last product a load found, for the frames with **Subscribe** that carry none of their own (S45, S57).
    private(set) var product: RelayProduct?
    /// What an owner's press is doing.
    private(set) var purchase: PurchaseState = .idle
    private(set) var updateRequired = false
    /// A current period Apple sold with no entitlement answer. Written only by the submit path; nil when no such row is left.
    private(set) var unconfirmed: UnconfirmedPurchase?
    /// This phone was seen paying and has not dismissed the loss (`relay.wasPaying`): the moved and ended banners.
    private(set) var wasPaying: Bool

    /// `TransportFollowerPolicy.lapseReason` on `.free` and `.moved`; nil while paying or unknown.
    var switchReason: String? {
        switch phase {
        case .free, .moved: TransportFollowerPolicy.lapseReason
        case .checking, .unknown, .paying: nil
        }
    }

    /// The pass (sweep, then read) running; nil once it ended. A test awaits it.
    @ObservationIgnored private(set) var passTask: Task<Void, Never>?

    static let wasPayingKey = "relay.wasPaying"
    private static let foregroundInterval: TimeInterval = 60
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "RelayAccount")

    @ObservationIgnored private let link: RelayAccountLink
    @ObservationIgnored private let store: any RelaySubscriptionStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let targets: @MainActor () -> [any RelayLapseTarget]

    /// The event loop, the updates task and the first pass have been started.
    @ObservationIgnored private var running = false
    /// When a pass last reached the relay: a pass that did not leaves the next foreground free to try.
    @ObservationIgnored private var lastPassAt: Date?
    /// The `lapseEnded()` calls still out, one per hub: none holds an answer, a loop or another hub.
    @ObservationIgnored private var lapseEnds: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var nextLapseEnd = 0
    /// One flight per transaction id.
    @ObservationIgnored private var flights: [UInt64: Task<SubmitAnswer, Never>] = [:]
    /// Definitely refused in this process: the automatic paths do not send these again; a press reads past it.
    @ObservationIgnored private var refusedIDs: Set<UInt64> = []
    /// Answered with an entitlement and finished in this process.
    @ObservationIgnored private var settledIDs: Set<UInt64> = []
    /// The press `retryAccount()` repeats.
    @ObservationIgnored private var lastPress = Press.buy
    /// Only the newest read writes: a slower older answer, or one a control overtook, is dropped.
    @ObservationIgnored private var readGeneration = 0

    init(
        link: RelayAccountLink,
        store: any RelaySubscriptionStore,
        defaults: UserDefaults,
        now: @escaping @MainActor () -> Date = { Date() },
        targets: @escaping @MainActor () -> [any RelayLapseTarget]
    ) {
        self.link = link
        self.store = store
        self.defaults = defaults
        self.now = now
        self.targets = targets
        wasPaying = defaults.bool(forKey: Self.wasPayingKey)
    }

    /// Returns once the `lapseEnded()` calls started so far ended.
    func lapseEndsFinished() async {
        for task in Array(lapseEnds.values) { await task.value }
    }

    // MARK: - Starting

    /// The event loop and the updates task; nothing at all without an identity (no session, register, attestation, read
    /// or `Transaction` stream). The first sweep and read wait for `foreground()`: a push launch stays frugal, and a launch
    /// in the foreground runs them at once.
    func start() {
        guard !running else { return }
        do {
            guard try link.hasIdentity() else {
                phase = .free(ended: false)
                return
            }
            begin()
        } catch {
            // A locked Keychain: the next foreground looks again.
            Self.logger.error("relay account: identity unreadable: \(Self.code(error), privacy: .public)")
            phase = .unknown
        }
    }

    /// Runs what `start()` held back, with its first pass: an owner's press or a link got here. Idempotent, and nothing
    /// while there still is no identity.
    func identityAppeared() {
        guard !running, (try? link.hasIdentity()) == true else { return }
        begin()
        startPass()
    }

    /// The app is active: a pass at most once a minute, the first at once. Returns the pass it started or joined.
    @discardableResult
    func foreground() -> Task<Void, Never>? {
        if !running { start() }
        guard running else { return nil }
        if let lastPassAt, abs(now().timeIntervalSince(lastPassAt)) < Self.foregroundInterval { return nil }
        return startPass()
    }

    private func begin() {
        running = true
        phase = .checking
        startEventLoop()
        let updates = store.updates()
        Task { [weak self] in
            for await transaction in updates {
                await self?.update(transaction)
            }
        }
    }

    private func startEventLoop() {
        let events: AsyncStream<HostedRelayEvent>?
        do {
            events = try link.events()
        } catch {
            Self.logger.error("relay account: no event loop: \(Self.code(error), privacy: .public)")
            return
        }
        guard let events else { return }
        Task { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
        }
    }

    /// One pass at a time from the foreground: a second activation joins it.
    @discardableResult
    private func startPass() -> Task<Void, Never> {
        if let passTask { return passTask }
        let task = Task {
            await pass()
            passTask = nil
        }
        passTask = task
        return task
    }

    /// The unfinished rows are submitted, then the account is read.
    private func pass() async {
        await sweep()
        if await read() != .failed { lastPassAt = now() }
    }

    // MARK: - The owner's presses

    private var pressRunning: Bool {
        switch purchase {
        case .buying, .confirming, .restoring: true
        default: false
        }
    }

    /// Resets a finished press's state. A running press stays, and so does `.pending` until an approval arrives.
    func screenClosed() {
        switch purchase {
        case .done, .noSubscriptionFound, .accountFailed, .refused, .transferLimit, .notImplemented, .updateRequired,
             .boughtNotConfirmed, .productFailed, .storeFailed:
            purchase = .idle
        default:
            break
        }
    }

    /// Writes only from a state with no press result in it: a Restore that ended before the screen opened stays.
    func loadProduct() async {
        switch purchase {
        case .idle, .loadingProduct, .productFailed, .ready: break
        default: return
        }
        purchase = .loadingProduct
        var found: RelayProduct?
        do {
            found = try await store.product()
        } catch {
            Self.logger.error("relay account: no product: \(Self.code(error), privacy: .public)")
        }
        if let found { product = found }
        guard purchase == .loadingProduct else { return }
        purchase = found.map(PurchaseState.ready) ?? .productFailed
    }

    /// **Retry**: S22, and S45 and S57 with no price, where `loadProduct()` alone would leave the result standing. The press
    /// replaces the result. A running press stays: `screenClosed()` and `loadProduct()` both leave it.
    func reloadProduct() async {
        screenClosed()
        await loadProduct()
    }

    /// `accountID` (the press is the first use) → the App Store → `submit` → `finish` on an entitlement → the read.
    func buy() async {
        guard !pressRunning else { return }
        lastPress = .buy
        purchase = .buying
        guard let token = await pressAccountID() else { return }
        do {
            switch try await store.purchase(accountToken: token) {
            case .purchased(let transaction):
                purchase = .confirming
                await confirm([transaction])
            case .pending:
                purchase = .pending
            case .cancelled:
                purchase = product.map(PurchaseState.ready) ?? .idle
            case .unverified:
                purchase = .refused
            }
        } catch {
            Self.logger.error("relay account: purchase failed: \(Self.code(error), privacy: .public)")
            purchase = .storeFailed
        }
    }

    /// A first use too: nothing is asked of Apple when the account fails. The restored transaction keeps its original
    /// account's token and the relay moves it. Exempt from the refused set: the same id can come back with a new signature.
    /// The owner's cancel returns to the state before the press, with no message.
    func restore() async {
        guard !pressRunning else { return }
        let prior = purchase
        lastPress = .restore
        purchase = .restoring
        guard await pressAccountID() != nil else { return }
        do {
            guard let transaction = try await store.restore(), !transaction.revoked else {
                purchase = .noSubscriptionFound
                return
            }
            await confirm([transaction])
        } catch RelayStoreError.cancelled {
            // A load does not write during a press, so S21 would stay with none running; and the account just answered, so
            // S46 would no longer be true. `.idle`: the open screen loads.
            let stale = prior == .loadingProduct || prior == .accountFailed
            purchase = stale ? product.map(PurchaseState.ready) ?? .idle : prior
        } catch {
            Self.logger.error("relay account: restore failed: \(Self.code(error), privacy: .public)")
            purchase = .storeFailed
        }
    }

    /// **Try Again** on S46: the press that stopped at the account, run again. A failed Restore never becomes a purchase.
    func retryAccount() async {
        guard purchase == .accountFailed else { return }
        switch lastPress {
        case .buy: await buy()
        case .restore: await restore()
        }
    }

    /// **Try Again**: what StoreKit holds now, sent past the refused set.
    func retryConfirm() async {
        guard !pressRunning, running else { return }
        purchase = .confirming
        let rows = await currentRows()
        recomputeUnconfirmed(current: rows)
        guard !rows.isEmpty else {
            await read()
            purchase = Self.isPaying(phase) ? .done : product.map(PurchaseState.ready) ?? .idle
            return
        }
        await confirm(rows)
    }

    /// The account id for a press, the state written on a failure.
    private func pressAccountID() async -> UUID? {
        do {
            guard let account = try link.account() else {
                purchase = .accountFailed
                return nil
            }
            let id = try await account.accountID()
            identityAppeared()
            return id
        } catch RelaySubmitRefusal.updateRequired {
            purchase = .updateRequired
        } catch {
            Self.logger.error("relay account: no account id: \(Self.code(error), privacy: .public)")
            purchase = .accountFailed
        }
        return nil
    }

    /// Submits for a press and ends it: on an entitlement once the read has answered too; else the state says why.
    private func confirm(_ transactions: [RelayTransaction]) async {
        var outcome = SubmitAnswer.unreachable
        for transaction in transactions {
            let answer = await submit(transaction, byPress: true)
            if answer == .entitled || outcome != .entitled { outcome = answer }
        }
        switch outcome {
        case .entitled:
            await read()
            purchase = .done
        case .refused(let refusal):
            purchase = Self.pressState(refusal)
            await read()
        case .unreachable:
            purchase = .boughtNotConfirmed
            await read()
        }
    }

    private static func pressState(_ refusal: UnconfirmedPurchase) -> PurchaseState {
        switch refusal {
        case .transferLimit: .transferLimit
        case .notImplemented: .notImplemented
        case .updateRequired: .updateRequired
        case .refused, .confirming, .notReached: .refused
        }
    }

    // MARK: - The account

    /// `get_account_state`. Without an identity nothing runs: a read would create one.
    func refresh() async {
        guard running else { return }
        await read()
    }

    /// A failed read is `.unknown`, never free: no paying phone is sent back to iCloud on a network failure.
    @discardableResult
    private func read() async -> ReadOutcome {
        readGeneration += 1
        let generation = readGeneration
        let state: RelayAccountState
        do {
            guard let account = try link.account() else {
                phase = .unknown
                return .failed
            }
            state = try await account.state()
        } catch {
            Self.logger.notice("relay account: read failed: \(Self.code(error), privacy: .public)")
            if generation == readGeneration { phase = .unknown }
            return .failed
        }
        guard generation == readGeneration else { return .superseded }
        return await apply(state)
    }

    private func apply(_ state: RelayAccountState) async -> ReadOutcome {
        let previous = phase
        if state.moved {
            phase = .moved
        } else if state.paying {
            phase = .paying(grace: state.entitlement == .grace, macs: state.macs)
            markPaying()
            settle()
            if !Self.isPaying(previous) { endLapses() }
            return .kept
        } else {
            phase = .free(ended: state.entitlement == .expired || state.entitlement == .revoked)
        }
        await lapseRelayMacs()
        return .lapsed
    }

    /// The entitlement came back: each hub's kept lapse request is withdrawn on its own, which can mean an iCloud call,
    /// so it holds neither this answer, a press, a loop nor another hub.
    private func endLapses() {
        for target in targets() {
            let key = nextLapseEnd
            nextLapseEnd += 1
            lapseEnds[key] = Task {
                await target.lapseEnded()
                lapseEnds[key] = nil
            }
        }
    }

    private static func isPaying(_ phase: Phase) -> Bool {
        if case .paying = phase { return true }
        return false
    }

    private func markPaying() {
        guard !wasPaying else { return }
        wasPaying = true
        defaults.set(true, forKey: Self.wasPayingKey)
    }

    /// The moved or ended banner's **OK**.
    func clearWasPaying() {
        wasPaying = false
        defaults.removeObject(forKey: Self.wasPayingKey)
    }

    private func lapseRelayMacs() async {
        for target in targets() where target.isOnRelay {
            await target.lapseRelay()
        }
    }

    /// An entitlement answer settles the screen. A running press ends on the same answer by itself.
    private func settle() {
        switch purchase {
        case .pending, .boughtNotConfirmed, .refused, .transferLimit, .notImplemented, .updateRequired, .noSubscriptionFound,
             .storeFailed:
            purchase = .done
        default:
            break
        }
    }

    // MARK: - Events

    private func handle(_ event: HostedRelayEvent) async {
        switch event {
        case .control(.entitlementExpired, _), .entitlementInactive:
            await sweepReadThenLapse()
        case .control(.subscriptionMoved, _):
            readGeneration += 1
            phase = .moved
            await lapseRelayMacs()
        case .control(.slotRemoved, _):
            await read()
        case .unsupportedVersion, .attestation(.updateRequired):
            updateRequired = true
        case .attestation(.notSupported):
            phase = .unknown
        case .reachable(true):
            updateRequired = false
            await pass()
        case .control, .attestation(.retryLater), .forbidden, .reachable(false):
            break
        }
    }

    /// The relay said the entitlement ended. A renewal Apple sold and the relay has not seen goes first (past the refused
    /// ids), so the billing boundary sends no Mac back. The read corrects the phase: if it answers paying, its answer is
    /// the newer one and no Mac goes back to iCloud. A failed read leaves the relay's word standing.
    private func sweepReadThenLapse() async {
        await sweep()
        let outcome = await read()
        if outcome != .lapsed, !Self.isPaying(phase) { await lapseRelayMacs() }
    }

    // MARK: - The submit path

    private func isCurrent(_ transaction: RelayTransaction) -> Bool {
        !transaction.revoked && transaction.expiresAt > now()
    }

    /// The rows that still count: current, and not answered in this process.
    private func currentRows() async -> [RelayTransaction] {
        await store.unfinished().filter { isCurrent($0) && !settledIDs.contains($0.id) }
    }

    /// StoreKit is the truth after a restart: a state with no row behind it goes, so **Subscribe** returns when the paid
    /// period ends. A renewal never holds `.confirming` or `.notReached`.
    private func recomputeUnconfirmed(current: [RelayTransaction]) {
        switch unconfirmed {
        case nil:
            break
        case .confirming, .notReached:
            if !current.contains(where: { !$0.isRenewal }) { unconfirmed = nil }
        case .refused, .transferLimit, .notImplemented, .updateRequired:
            if !current.contains(where: { refusedIDs.contains($0.id) }) { unconfirmed = nil }
        }
    }

    /// `Transaction.unfinished` submitted, past the refused ones. Writes no `purchase` but the settling rule.
    private func sweep() async {
        let rows = await currentRows()
        recomputeUnconfirmed(current: rows)
        for row in rows {
            if refusedIDs.contains(row.id) {
                if row.isRenewal { Self.logger.notice("relay account: refused renewal held until the next launch") }
                continue
            }
            _ = await submit(row, byPress: false)
        }
    }

    /// One `Transaction.updates` delivery. A revoked row is not sent and clears at once; the read decides the phase.
    private func update(_ transaction: RelayTransaction) async {
        if transaction.revoked {
            unconfirmed = nil
            await read()
            return
        }
        guard isCurrent(transaction), !refusedIDs.contains(transaction.id), !settledIDs.contains(transaction.id) else { return }
        _ = await submit(transaction, byPress: false)
        await read()
    }

    /// One flight per transaction id: a second caller joins. A press that joined a flight ending in a refusal sends its
    /// own JWS once, which can carry a newer signature.
    private func submit(_ transaction: RelayTransaction, byPress: Bool) async -> SubmitAnswer {
        if let flight = flights[transaction.id] {
            let answer = await flight.value
            guard byPress, case .refused = answer else { return answer }
            if let next = flights[transaction.id] { return await next.value }
        }
        return await fly(transaction).value
    }

    private func fly(_ transaction: RelayTransaction) -> Task<SubmitAnswer, Never> {
        let counts = isCurrent(transaction)
        if counts, !transaction.isRenewal, unconfirmed == nil { unconfirmed = .confirming }
        let flight = Task { [self] in
            let answer = await send(transaction)
            flights[transaction.id] = nil
            await take(answer, for: transaction, counts: counts)
            return answer
        }
        flights[transaction.id] = flight
        return flight
    }

    private func send(_ transaction: RelayTransaction) async -> SubmitAnswer {
        do {
            guard let account = try link.account() else { return .unreachable }
            switch try await account.submit(jws: transaction.jws) {
            case .active, .grace: return .entitled
            case .none, .expired, .revoked: return .refused(.refused)
            }
        } catch let refusal as RelaySubmitRefusal {
            Self.logger.notice("relay account: submit: \(String(describing: refusal), privacy: .public)")
            switch refusal {
            case .invalidTransaction: return .refused(.refused)
            case .transferLimit: return .refused(.transferLimit)
            case .notImplemented: return .refused(.notImplemented)
            case .updateRequired: return .refused(.updateRequired)
            case .unreachable, .attestationBackoff: return .unreachable
            }
        } catch {
            Self.logger.notice("relay account: submit failed: \(Self.code(error), privacy: .public)")
            return .unreachable
        }
    }

    private func take(_ answer: SubmitAnswer, for transaction: RelayTransaction, counts: Bool) async {
        switch answer {
        case .entitled:
            refusedIDs.remove(transaction.id)
            unconfirmed = nil
            settle()
            if settledIDs.insert(transaction.id).inserted { await store.finish(transaction) }
        case .refused(let refusal):
            refusedIDs.insert(transaction.id)
            if counts { unconfirmed = refusal }
        case .unreachable:
            if counts, !transaction.isRenewal { unconfirmed = .notReached }
        }
    }

    /// An error's type for logs: never a JWS, an id or a relay message.
    nonisolated private static func code(_ error: any Error) -> String {
        String(describing: type(of: error))
    }
}
