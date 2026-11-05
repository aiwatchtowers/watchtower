import Foundation
import os
import WatchtowerSync

/// A request that the hub move this phone to iCloud (relay client Phase 4 Task 5): the owner's choice, or the answer to
/// a subscription that ended (sim rule 16). The model only; `TransportRequester` runs it and `HubSession.requestTransport`
/// starts it.
enum TransportRequest {
    /// How long the phone waits, in wall time from the request, for the hub to answer: a Mac shut overnight comes back
    /// within a day (Open decision 15). The same limit as the upgrade's reader wait.
    static let answerLimit: TimeInterval = RelayUpgrade.readerWaitLimit
    /// A pass started by a fetch runs at most this often (the feed cadence while the app is active).
    static let resumeInterval: TimeInterval = RelayUpgrade.resumeInterval
}

/// Why a request toward iCloud ended without the move.
enum TransportRequestRefusal: String, Codable, Sendable {
    /// The hub's `unavailable`, after the one automatic new request.
    case unavailable
    /// The hub's `not supported yet`: it has one transport.
    case notSupported
    /// The hub reads no controls (today's path): nothing is written.
    case notOrdered
    /// 24 h with no answer to an owner's request.
    case macNoAnswer
    /// 24 h with no answer to a lapse's request: the copy stays, so the Mac moves when it is back.
    case lapseNoAnswer

    /// The text the Mac's Connection section shows.
    func message(macName: String) -> String {
        switch self {
        case .unavailable:
            "\(macName) couldn't switch right now. Try again in a minute."
        case .notSupported:
            "\(macName) can't switch from here. Update Watchtower on the Mac."
        case .notOrdered:
            "Update Watchtower on \(macName) to change how it connects."
        case .macNoAnswer:
            "\(macName) didn't answer for a day, so nothing changed. Try again when it's back."
        case .lapseNoAnswer:
            "\(macName) didn't answer for a day. It moves to iCloud when it's back."
        }
    }
}

/// A request's state on the hub's `LinkRecord` (JSON only: no registry migration). Written first, before any copy of
/// the request leaves the phone.
struct TransportRequestRecord: Codable, Equatable, Sendable {
    let target: TransportKind
    /// The `transport_switch`'s control id: the same one in the outbox, in the iCloud mailbox and on the relay.
    var controlID: String
    /// The hub's own word for a move that spares its other phones (`TransportFollowerPolicy.lapseReason`); nil for a
    /// plain request.
    let reason: String?
    /// When the request started (the 24 h limit counts from it).
    let at: Date
    /// The sealed copy is in the iCloud mailbox (the way past a relay that refuses writes).
    var iCloudWritten: Bool
    /// Why the request ended; nil while it goes on.
    var refusal: TransportRequestRefusal?
    /// The request `controlID` names is in the outbox's queue (or was written from it).
    var outboxQueued: Bool
    /// After a first `unavailable`: when the one automatic new request is due.
    var retryAt: Date?
    /// The one automatic new request after `unavailable` was sent.
    var askedAgain: Bool

    init(
        target: TransportKind,
        controlID: String,
        reason: String?,
        at: Date,
        iCloudWritten: Bool = false,
        refusal: TransportRequestRefusal? = nil,
        outboxQueued: Bool = false,
        retryAt: Date? = nil,
        askedAgain: Bool = false
    ) {
        self.target = target
        self.controlID = controlID
        self.reason = reason
        self.at = at
        self.iCloudWritten = iCloudWritten
        self.refusal = refusal
        self.outboxQueued = outboxQueued
        self.retryAt = retryAt
        self.askedAgain = askedAgain
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decode(TransportKind.self, forKey: .target)
        controlID = try container.decode(String.self, forKey: .controlID)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        at = try container.decode(Date.self, forKey: .at)
        iCloudWritten = try container.decodeIfPresent(Bool.self, forKey: .iCloudWritten) ?? false
        refusal = try container.decodeIfPresent(TransportRequestRefusal.self, forKey: .refusal)
        outboxQueued = try container.decodeIfPresent(Bool.self, forKey: .outboxQueued) ?? false
        retryAt = try container.decodeIfPresent(Date.self, forKey: .retryAt)
        askedAgain = try container.decodeIfPresent(Bool.self, forKey: .askedAgain) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case target, controlID, reason, at, iCloudWritten, refusal, outboxQueued, retryAt, askedAgain
    }

    /// The request still waits for an answer.
    var isOpen: Bool { refusal == nil }

    /// The hub may still answer in the iCloud mailbox: open, or a lapse's copy that stays after the day.
    var awaitsAnswer: Bool { isOpen || refusal == .lapseNoAnswer }
}

/// Where a request stands after a call (`HubSession.requestTransport(reason:)`).
enum TransportRequestOutcome: Equatable, Sendable {
    /// Written and on its way: the hub's answer, the 24 h limit or an unlink ends it.
    case underWay
    /// Ended, or never started (`notOrdered`; `unavailable` also for a call that has nothing to ask: an iCloud route,
    /// an unlinked hub).
    case refused(TransportRequestRefusal)

    /// Why it ended or never started; nil while under way.
    var refusal: TransportRequestRefusal? {
        if case let .refused(refusal) = self { return refusal }
        return nil
    }
}

/// What the requester needs from the app (`AppRoot`): the hub's row and the hub's route on the other transport.
@MainActor
protocol TransportRequestHost: AnyObject {
    /// The hub's registry row's link; nil when it has none.
    func followerLink(hubID: String) -> LinkRecord?
    /// Saves `link` on its registry row in one write; false when it was not written.
    func persistRoute(_ link: LinkRecord) -> Bool
    /// A transport to the hub's other route, on that route's own store, for a short write.
    func makeOtherSide(hubID: String, route: HubRoute) throws -> SideTransport
}

/// Runs one hub's request toward iCloud (relay client Phase 4 Task 5): the owner's, or the lapse's
/// (`TransportFollowerPolicy`'s `requestSwitch`, executed by the follower). It starts only on route `.relay`.
///
/// The record is written first (a compare-and-set on the row), then the same control id goes two ways (rule 9's
/// initiator write): into the outbox, which reaches the hub on the relay when the relay takes writes, and as a sealed
/// copy straight into the iCloud mailbox, which gets through a relay that refuses them (`iCloudWritten`). A pass
/// retries what is missing from the record, so a kill at any point, a failed save and an unreachable iCloud all heal
/// at the next launch, foreground or fetch (the policy asks once per lapse, so the pass is what re-sends a lost
/// request). The hub's answer arrives through the follower (a move, `requestAnswered`, `hub_on_relay`: the record
/// clears), the side mailbox reader (the iCloud mailbox is read every 30 s while a request is open) and the rejection
/// handler (`rejected(_:)`). After `TransportRequest.answerLimit` with no answer the record keeps a refusal; an
/// owner's request is withdrawn (queued row, iCloud copy), a lapse's copy stays.
@MainActor
final class TransportRequester {
    let hubID: String
    private weak var session: HubSession?
    private weak var host: (any TransportRequestHost)?
    private let follower: TransportFollower
    private let now: @MainActor () -> Date
    private var last: Task<Void, Never>?
    private var lastResumeAt: Date?
    private var stopped = false
    /// A test seam: runs between the queue step and the iCloud copy.
    var beforeCopy: (@MainActor () async -> Void)?
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "TransportRequest")

    init(session: HubSession, follower: TransportFollower, host: any TransportRequestHost, now: @escaping @MainActor () -> Date) {
        hubID = session.hubID
        self.session = session
        self.follower = follower
        self.host = host
        self.now = now
        follower.onRequestSwitch = { [weak self] target, reason in await self?.requested(target, reason: reason) }
    }

    /// The hub's row.
    var link: LinkRecord? {
        host?.followerLink(hubID: hubID)
    }

    /// The request on the hub's row, kept or ended.
    var record: TransportRequestRecord? {
        host?.followerLink(hubID: hubID)?.transportRequest
    }

    var hubOnRelayAt: Date? {
        host?.followerLink(hubID: hubID)?.hubOnRelayAt
    }

    // MARK: - Entry points

    /// The owner's request (**Switch to iCloud**, **Try Again**), toward iCloud only: from route `.relay`.
    func request(reason: String?) async -> TransportRequestOutcome {
        await run { await self.begin(reason: reason, lapse: false) }
    }

    /// The relay refused this phone because its subscription ended: the policy decides whether to ask
    /// (`FollowerCommand.requestSwitch`, executed by the follower and handed to `requested(_:reason:)`).
    func lapse() async {
        _ = await follower.handle(.relayLapsed)
    }

    /// The subscription is paying again: a lapse's request (open, or kept after its day) is withdrawn and cleared. An
    /// owner's request is left alone. While a lapse's refusal stays on the record, a later lapse notice asks nothing
    /// new, so Task 6 calls this (`HubSession.lapseEnded()`) when the entitlement returns.
    func lapseEnded() async {
        _ = await run {
            guard let host = self.host, let link = host.followerLink(hubID: self.hubID),
                  let request = link.transportRequest, request.reason == TransportFollowerPolicy.lapseReason,
                  self.update(request, { $0.transportRequest = nil }) != nil else { return .underWay }
            await self.withdraw(request, link: link)
            return .underWay
        }
    }

    /// The follower's `requestSwitch`: only a move to iCloud exists.
    private func requested(_ target: TransportKind, reason: String) async {
        guard target == .cloudKit else { return }
        _ = await run { await self.begin(reason: reason, lapse: true) }
    }

    /// Goes on with an open request (a kill, a failed copy, the 24 h limit): at launch and on the return to the
    /// foreground. None: nothing, no iCloud call.
    func resume() async {
        guard !stopped, hasOpenRequest else { return }
        lastResumeAt = now()
        _ = await run { await self.pass(); return .underWay }
    }

    /// After a fetch: as `resume()`, at most every `TransportRequest.resumeInterval`, not awaited (`idle()` waits).
    func resumeAfterFetch() {
        guard !stopped, hasOpenRequest else { return }
        if let lastResumeAt, now().timeIntervalSince(lastResumeAt) < TransportRequest.resumeInterval { return }
        lastResumeAt = now()
        let previous = last
        last = Task {
            await previous?.value
            await self.pass()
        }
    }

    /// Returns once the passes started so far ended.
    func idle() async {
        await last?.value
    }

    /// The session is going: no pass starts after this, and the running one writes nothing more.
    func stop() {
        stopped = true
    }

    /// A request waits for the hub's answer.
    var hasOpenRequest: Bool {
        record?.isOpen == true
    }

    /// The hub may still answer: open, or a lapse's copy kept after its day. A rejection then belongs to the request.
    var awaitsAnswer: Bool {
        record?.awaitsAnswer == true
    }

    /// `work` after the ones started before it.
    private func run(_ work: @escaping @MainActor () async -> TransportRequestOutcome) async -> TransportRequestOutcome {
        let previous = last
        let box = OutcomeBox()
        let task = Task {
            await previous?.value
            box.outcome = await work()
        }
        last = task
        await task.value
        return box.outcome
    }

    // MARK: - The hub's rejection

    /// A `transport_switch_rejected` (read on either transport): `unavailable` asks once more after `retry_after_s`, a
    /// second one ends it; `not supported yet` ends it; `too_soon` and `not_paying` never answer a request toward
    /// iCloud and leave it waiting. A reason this build does not know is read as `unavailable`. false when no request is
    /// open (the rejection is an upgrade's: `hasOpenRequest` says so first); false when the row could not be written
    /// (the feed hands it again).
    func rejected(_ control: ControlPayload) -> Bool {
        guard let host, let link = host.followerLink(hubID: hubID), let request = link.transportRequest, request.awaitsAnswer else {
            return false
        }
        var next = request
        switch control.reason {
        case RelayUpgrade.tooSoon, RelayUpgrade.notPaying:
            Self.logger.notice("transport_switch_rejected (\(control.reason ?? "", privacy: .public)) does not answer a request toward iCloud")
            return true
        case RelayUpgrade.notSupported:
            next.refusal = .notSupported
        default:
            if control.reason != RelayUpgrade.unavailable {
                Self.logger.notice("transport_switch_rejected with a reason this build does not know: read as unavailable")
            }
            if request.askedAgain || !request.isOpen {
                // A lapse's kept copy answered after its day: no further automatic request, the refusal is the answer.
                next.refusal = .unavailable
            } else {
                next.retryAt = now().addingTimeInterval(TimeInterval(control.retryAfterS ?? 0))
            }
        }
        // An answer proves the request left the phone.
        next.outboxQueued = true
        guard replace(request, with: next) != nil else { return false }
        return true
    }

    // MARK: - Starting

    private func begin(reason: String?, lapse: Bool) async -> TransportRequestOutcome {
        guard !stopped, let host, let session, let link = host.followerLink(hubID: hubID) else { return .refused(.unavailable) }
        guard link.transport == .relay else {
            Self.logger.notice("a request toward iCloud on an iCloud route writes nothing")
            return .refused(.unavailable)
        }
        if let existing = link.transportRequest {
            let lapseReason = TransportFollowerPolicy.lapseReason
            if existing.isOpen, !lapse || existing.reason == lapseReason {
                // One open request per hub: a second press (or a repeated lapse notice) goes on with it.
                await pass()
                return outcome()
            }
            if !existing.isOpen, lapse, existing.reason == lapseReason {
                // The notice repeats at every refusal; a closed answer stays closed until the owner presses Try Again.
                return .refused(existing.refusal ?? .unavailable)
            }
        }
        do {
            guard try await session.outbox.orderedActions() else { return .refused(.notOrdered) }
        } catch {
            return .refused(.unavailable)
        }
        if lapse, link.otherRoute == nil {
            // A relay-only hub has no iCloud to go to: it needs Relay (the screens say so).
            Self.logger.notice("a lapse on a hub that offers only the relay asks nothing")
            return .refused(.notSupported)
        }
        if let existing = link.transportRequest, existing.isOpen {
            // A lapse joins an owner's plain request: it must carry the lapse's reason (and keep its copy), so the
            // plain one is withdrawn and the lapse asks in its place (only once the checks above passed).
            await withdraw(existing, link: link)
        }
        // Read again after the await: an unlink, a move or another press meanwhile wins.
        guard !stopped, var current = host.followerLink(hubID: hubID), current.transport == .relay,
              current.transportRequest == link.transportRequest else { return .refused(.unavailable) }
        current.transportRequest = TransportRequestRecord(
            target: .cloudKit, controlID: UUID().uuidString, reason: reason, at: now())
        if lapse, var upgrade = current.relayUpgrade, upgrade.isPending {
            // The hub's "superseding" rule on our side: the lapse replaces a pending request toward the relay. Its slot
            // is kept (Open decision 5).
            upgrade.refusal = .notPaying
            current.relayUpgrade = upgrade
        }
        guard host.persistRoute(current) else { return .refused(.unavailable) }
        await pass()
        return outcome()
    }

    private func outcome() -> TransportRequestOutcome {
        if let refusal = record?.refusal { return .refused(refusal) }
        return .underWay
    }

    // MARK: - One pass

    private func pass() async {
        guard !stopped, let host, let session, let link = host.followerLink(hubID: hubID),
              var request = link.transportRequest, request.isOpen else { return }
        guard link.transport == .relay else {
            // The route moved meanwhile: nothing is left to ask.
            _ = update(request) { $0.transportRequest = nil }
            return
        }
        if now().timeIntervalSince(request.at) >= TransportRequest.answerLimit {
            await expire(request, link: link, host: host, session: session)
            return
        }
        if let retryAt = request.retryAt {
            guard now() >= retryAt else { return }
            // The hub answered the first request; the one new request is a new control.
            var again = request
            again.controlID = UUID().uuidString
            again.retryAt = nil
            again.askedAgain = true
            again.outboxQueued = false
            again.iCloudWritten = false
            guard replace(request, with: again) != nil else { return }
            request = again
        }
        var queued = request.outboxQueued
        if !queued {
            switch await queue(request, session: session) {
            case .queued: queued = true
            case .legacyPath:
                _ = update(request) { $0.transportRequest?.refusal = .notOrdered }
                return
            case .failed: break
            }
        }
        await beforeCopy?()
        // An unlink or a move during the queue step wins: nothing more is written, no store opened.
        guard !stopped, host.followerLink(hubID: hubID)?.transportRequest == request else { return }
        var written = request.iCloudWritten
        if !written, let other = link.otherRoute {
            written = await writeCopy(request, to: other, host: host, session: session)
        }
        guard queued != request.outboxQueued || written != request.iCloudWritten else { return }
        _ = update(request) {
            $0.transportRequest?.outboxQueued = queued
            $0.transportRequest?.iCloudWritten = written
        }
    }

    private enum Queued {
        case queued, legacyPath, failed
    }

    /// The control in the session's ordered outbox (idempotent by id): the relay way.
    private func queue(_ request: TransportRequestRecord, session: HubSession) async -> Queued {
        do {
            _ = try await session.outbox.enqueueSwitchRequest(
                target: request.target, id: request.controlID, reason: request.reason)
            return .queued
        } catch ActionOutboxError.legacyPath {
            return .legacyPath
        } catch {
            Self.logger.warning("the request was not queued: \(String(describing: type(of: error)), privacy: .public)")
            return .failed
        }
    }

    /// The sealed copy in the iCloud mailbox (`expect: .absent`, the same control id): the way past a relay that
    /// refuses writes. true once it is there (a copy already there counts).
    private func writeCopy(
        _ request: TransportRequestRecord, to route: HubRoute, host: any TransportRequestHost, session: HubSession
    ) async -> Bool {
        let at = now()
        let written = await withSide(route, host: host, session: session) { secure in
            do {
                let control = try await session.outbox.switchRequest(
                    target: request.target, id: request.controlID, reason: request.reason)
                let sealed = try await secure.seal(try CloudRecordFactory.record(for: control, modifiedAt: at))
                let outcomes = try await secure.saveSealed([ConditionalSave(record: sealed, expect: .absent)])
                switch outcomes.first {
                case .saved?, .conflict?: return true
                default:
                    Self.logger.notice("the request's iCloud copy was not written; the next pass tries again")
                    return false
                }
            } catch {
                Self.logger.notice("the request's iCloud copy was not written: \(String(describing: type(of: error)), privacy: .public)")
                return false
            }
        }
        return written ?? false
    }

    // MARK: - The day

    /// No answer within the limit: the record keeps the refusal. An owner's request is withdrawn (best effort: if the
    /// hub read it first it still answers and the follower follows); a lapse's copy stays, because the phone cannot use
    /// the relay either way.
    private func expire(
        _ request: TransportRequestRecord, link: LinkRecord, host: any TransportRequestHost, session: HubSession
    ) async {
        let lapse = request.reason == TransportFollowerPolicy.lapseReason
        guard update(request, { $0.transportRequest?.refusal = lapse ? .lapseNoAnswer : .macNoAnswer }) != nil else { return }
        Self.logger.notice("a request toward iCloud had no answer for a day")
        guard !lapse else { return }
        await withdraw(request, link: link)
    }

    /// Takes an owner's request back, best effort: the queued row and the iCloud copy (whether or not its write was
    /// saved: a copy a lost commit left would move the Mac later).
    private func withdraw(_ request: TransportRequestRecord, link: LinkRecord) async {
        guard !stopped, let host, let session else { return }
        do {
            try await session.outbox.withdrawControl(id: request.controlID)
        } catch {
            Self.logger.warning("the queued request was not withdrawn: \(String(describing: type(of: error)), privacy: .public)")
        }
        guard let other = link.otherRoute, !stopped, host.followerLink(hubID: hubID) != nil else { return }
        await withSide(other, host: host, session: session) { secure in
            do {
                let wire = try secure.wireName(plain: "c-\(request.controlID)", zone: .relay)
                _ = try await secure.deleteSealed([ConditionalDelete(recordName: wire, zone: .relay, expect: .none)])
            } catch {
                Self.logger.notice("the request's iCloud copy was not withdrawn: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    // MARK: - The other transport

    /// Runs `body` over the hub's other route's transport (no engine, no socket), then closes it.
    @discardableResult
    private func withSide<T>(
        _ route: HubRoute, host: any TransportRequestHost, session: HubSession, _ body: (SecureTransport) async -> T
    ) async -> T? {
        let side: SideTransport
        do {
            // Write-only, beside the reader's running engine on the same file: no launch sweep of the stash.
            side = try TransportStore.withoutStashSweep { try host.makeOtherSide(hubID: hubID, route: route) }
        } catch {
            Self.logger.error("no transport to the other route: \(String(describing: type(of: error)), privacy: .public)")
            return nil
        }
        let result = await body(session.sealing(side.transport))
        await (side.transport as? any LiveTransport)?.stop()
        do {
            try side.store?.close()
        } catch {
            Self.logger.error("the other route's store was not closed")
        }
        return result
    }

    // MARK: - State

    /// Writes the row with `change` applied when it still holds `expected` as its request: an answer, a move or an
    /// unlink meanwhile wins, and this pass writes nothing more. nil when it was not written.
    private func update(_ expected: TransportRequestRecord, _ change: (inout LinkRecord) -> Void) -> LinkRecord? {
        guard !stopped, let host, var current = host.followerLink(hubID: hubID), current.transportRequest == expected else {
            Self.logger.notice("the row changed meanwhile; this pass stops")
            return nil
        }
        change(&current)
        guard host.persistRoute(current) else { return nil }
        return current
    }

    private func replace(_ expected: TransportRequestRecord, with next: TransportRequestRecord) -> LinkRecord? {
        update(expected) { $0.transportRequest = next }
    }
}

/// A call's outcome, handed out of its place in the chain.
@MainActor
private final class OutcomeBox {
    var outcome: TransportRequestOutcome = .underWay
}
