import Foundation
import os
import WatchtowerHostedRelay
import WatchtowerSync

/// An iCloud link's upgrade to the hosted relay (relay client Phase 3b Task 19, R22, R23): the steps, their state on
/// the hub's `LinkRecord`, the refusals and their texts. The model only: Phase 4's per-Mac choice calls
/// `HubSession.upgradeToRelay()`, and no view shows the texts yet.
enum RelayUpgrade {
    /// How long the phone waits, in wall time from a successful `add_slot`, to read the Mac's data zone on the relay
    /// before it asks for the switch: a running hub confirms within minutes, a Mac shut overnight within a day.
    static let readerWaitLimit: TimeInterval = 24 * 3600
    /// A pass started by a fetch runs at most this often (the feed cadence while the app is active).
    static let resumeInterval: TimeInterval = 30
    /// The hub's `transport_switch_rejected` reasons (Go `wire.Switch*`).
    static let tooSoon = "too_soon"
    static let notPaying = "not_paying"
    static let unavailable = "unavailable"
    static let notSupported = "not supported yet"
}

/// Where an upgrade stands. Each step is persisted before the next starts, so a relaunch resumes at it.
enum RelayUpgradeStep: String, Codable, CaseIterable, Sendable {
    /// The phone's own `device` record names its relay id, with the proof (R22).
    case namingRelayID
    /// `vouch_hub` for the Mac.
    case vouching
    /// `add_slot` for the Mac (a vouch first again on a resume: it lasts 10 minutes).
    case addingSlot
    /// The Mac's data zone on the relay is read once before the request (the hub named the phone a reader).
    case awaitingReader
    /// `transport_switch{relay}` is written; the phone waits for the hub's answer on iCloud.
    case requested
    /// The hub moved to the relay, or answered that it runs there.
    case switched
}

/// Why an upgrade ended. Kept on the `LinkRecord` (all but the first checks', which write nothing) for Phase 4's
/// screen.
enum RelayUpgradeRefusal: Equatable, Sendable {
    /// The grant's relay pair is missing or not coherent.
    case noRelayIdentity
    /// The relay is not `.available` (an empty origin included).
    case relayOff
    /// `vouch_hub` (or `add_slot`) refused, with the Task 10 row's reason.
    case vouch(HostedRelayPairing.VouchRefusal)
    /// `too_soon`: the hub's `retry_after_s` kept as a date.
    case tooSoon(retryAt: Date)
    /// The hub's `not_paying`, or the relay account is not paying.
    case notPaying
    /// The hub's `unavailable` after the one automatic new request.
    case unavailable
    /// `not supported yet`: the hub has one transport (or reads no controls).
    case notSupported
    /// No read of the Mac's data zone within `RelayUpgrade.readerWaitLimit`.
    case readerNotConfirmed
    /// `add_slot`'s `SLOT_REPLACEMENT_LIMIT`.
    case replacementLimit

    /// The text Phase 4's screen shows; nil for the two refusals that hide the choice (no relay on this phone, a hub
    /// that names no relay identity).
    func message(macName: String, now: Date) -> String? {
        switch self {
        case .noRelayIdentity, .relayOff:
            nil
        case .vouch(.updateRequired):
            "Update Watchtower on this iPhone to move \(macName) to Relay."
        case .vouch(let refusal):
            Self.linkReason(refusal).message(macName: macName)
        case .tooSoon(let retryAt):
            "Switching to Relay is possible again in \(Self.minutes(until: retryAt, now: now)) min"
        case .notPaying:
            "\(macName) stays on iCloud: Relay doesn't show a subscription for this iPhone yet. Try again in a few minutes."
        case .unavailable:
            "\(macName) couldn't switch right now. Try again in a minute."
        case .notSupported:
            "\(macName) can't switch to Relay. Update Watchtower on the Mac."
        case .readerNotConfirmed:
            "\(macName) didn't confirm Relay. Update Watchtower on the Mac and try again."
        case .replacementLimit:
            "\(macName) stays on iCloud: too many Mac changes on Relay this month. Try again later."
        }
    }

    /// The line under the choice (`too_soon` only).
    var footnote: String? {
        if case .tooSoon = self { return "The Mac was switched less than 5 minutes ago." }
        return nil
    }

    /// The Task 10 row's reason for the same refusal (Owner approval 3); `updateRequired` has its own upgrade text
    /// (ask #997). A transient answer is never kept as a refusal; it reads as "not confirmed".
    static func linkReason(_ refusal: HostedRelayPairing.VouchRefusal) -> PromotedLink.Reason {
        switch refusal {
        case .notPaying: .notPaying
        case .updateRequired: .updateApp
        case .hubNotOnRelay: .hubNotOnRelay
        case .slotsFull: .slotsFull
        case .notConfirmed, .unreachable, .attestationBackoff: .notConfirmed
        }
    }

    /// Whole minutes left, at least 1.
    private static func minutes(until date: Date, now: Date) -> Int {
        max(1, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
    }
}

extension RelayUpgradeRefusal: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, vouch, until, retryAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "noRelayIdentity": self = .noRelayIdentity
        case "relayOff": self = .relayOff
        case "vouch":
            let until = try container.decodeIfPresent(Date.self, forKey: .until)
            self = .vouch(try Self.vouchRefusal(try container.decode(String.self, forKey: .vouch), until: until))
        case "tooSoon": self = .tooSoon(retryAt: try container.decode(Date.self, forKey: .retryAt))
        case "notPaying": self = .notPaying
        case "unavailable": self = .unavailable
        case "notSupported": self = .notSupported
        case "readerNotConfirmed": self = .readerNotConfirmed
        case "replacementLimit": self = .replacementLimit
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "unknown refusal \(other)")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .noRelayIdentity: try container.encode("noRelayIdentity", forKey: .kind)
        case .relayOff: try container.encode("relayOff", forKey: .kind)
        case .vouch(let refusal):
            try container.encode("vouch", forKey: .kind)
            let (name, until) = Self.name(refusal)
            try container.encode(name, forKey: .vouch)
            try container.encodeIfPresent(until, forKey: .until)
        case .tooSoon(let retryAt):
            try container.encode("tooSoon", forKey: .kind)
            try container.encode(retryAt, forKey: .retryAt)
        case .notPaying: try container.encode("notPaying", forKey: .kind)
        case .unavailable: try container.encode("unavailable", forKey: .kind)
        case .notSupported: try container.encode("notSupported", forKey: .kind)
        case .readerNotConfirmed: try container.encode("readerNotConfirmed", forKey: .kind)
        case .replacementLimit: try container.encode("replacementLimit", forKey: .kind)
        }
    }

    private static func name(_ refusal: HostedRelayPairing.VouchRefusal) -> (String, Date?) {
        switch refusal {
        case .notPaying: ("notPaying", nil)
        case .updateRequired: ("updateRequired", nil)
        case .hubNotOnRelay: ("hubNotOnRelay", nil)
        case .slotsFull: ("slotsFull", nil)
        case .notConfirmed: ("notConfirmed", nil)
        case .unreachable: ("unreachable", nil)
        case .attestationBackoff(let until): ("attestationBackoff", until)
        }
    }

    private static func vouchRefusal(_ name: String, until: Date?) throws -> HostedRelayPairing.VouchRefusal {
        switch name {
        case "notPaying": return .notPaying
        case "updateRequired": return .updateRequired
        case "hubNotOnRelay": return .hubNotOnRelay
        case "slotsFull": return .slotsFull
        case "notConfirmed": return .notConfirmed
        case "unreachable": return .unreachable
        case "attestationBackoff": return .attestationBackoff(until: until ?? .distantPast)
        default: throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "unknown vouch refusal \(name)"))
        }
    }
}

/// An upgrade's state on the hub's `LinkRecord` (JSON only: no registry migration).
struct RelayUpgradeRecord: Codable, Equatable, Sendable {
    var step: RelayUpgradeStep
    /// The last `transport_switch`'s control id (from `requested` on).
    var requestID: String?
    /// After a first `unavailable`: when the one automatic new request is due.
    var retryAt: Date?
    /// The one automatic new request after `unavailable` was sent.
    var askedAgain = false
    /// Why the upgrade ended; nil while it goes on (or once switched).
    var refusal: RelayUpgradeRefusal?
    /// When `add_slot` succeeded (or found the Mac in the slots): the reader wait's start. Set, the phone holds the
    /// Mac's relay slot until the link is unlinked (a refusal keeps it, Open decision 5).
    var slotSince: Date?
    /// The Mac's relay id from the grant, kept from `addingSlot` on: an unlink there frees whatever slot the relay may
    /// hold for it (an `add_slot` whose success was not saved yet).
    var macDeviceID: String?
    /// The request `requestID` is in the outbox's queue (the row named it first, so its answer always finds the row
    /// waiting).
    var askQueued = false

    init(
        step: RelayUpgradeStep,
        requestID: String? = nil,
        retryAt: Date? = nil,
        askedAgain: Bool = false,
        refusal: RelayUpgradeRefusal? = nil,
        slotSince: Date? = nil,
        macDeviceID: String? = nil,
        askQueued: Bool = false
    ) {
        self.step = step
        self.requestID = requestID
        self.retryAt = retryAt
        self.askedAgain = askedAgain
        self.refusal = refusal
        self.slotSince = slotSince
        self.macDeviceID = macDeviceID
        self.askQueued = askQueued
    }

    /// A record an earlier build of this task wrote lacks `macDeviceID` and `askQueued`: that build queued the request
    /// before it named it, so a named request is queued.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        step = try container.decode(RelayUpgradeStep.self, forKey: .step)
        requestID = try container.decodeIfPresent(String.self, forKey: .requestID)
        retryAt = try container.decodeIfPresent(Date.self, forKey: .retryAt)
        askedAgain = try container.decodeIfPresent(Bool.self, forKey: .askedAgain) ?? false
        refusal = try container.decodeIfPresent(RelayUpgradeRefusal.self, forKey: .refusal)
        slotSince = try container.decodeIfPresent(Date.self, forKey: .slotSince)
        macDeviceID = try container.decodeIfPresent(String.self, forKey: .macDeviceID)
        askQueued = try container.decodeIfPresent(Bool.self, forKey: .askQueued) ?? (requestID != nil)
    }

    private enum CodingKeys: String, CodingKey {
        case step, requestID, retryAt, askedAgain, refusal, slotSince, macDeviceID, askQueued
    }

    /// An unlink frees the Mac's slot (R14).
    var holdsSlot: Bool { slotSince != nil }
    /// The relay may hold the Mac's slot for this phone: `add_slot` succeeded, or may have (`addingSlot`).
    var mayHoldSlot: Bool { holdsSlot || step == .addingSlot }
    /// A pass has something left to do.
    var isPending: Bool { refusal == nil && step != .switched }
}

/// Where an upgrade stands after a call (`HubSession.upgradeToRelay()`).
enum RelayUpgradeOutcome: Equatable, Sendable {
    /// Nothing was decided or written (the relay did not answer, the keychain is locked): the upgrade is asked again
    /// at the next launch pass, return to the foreground or fetch while this process runs.
    case waiting
    /// Under way at this step: the next passes go on with it.
    case underWay(RelayUpgradeStep)
    /// The hub runs on the relay with this phone.
    case switched
    /// Ended; kept on the row unless a first check refused.
    case refused(RelayUpgradeRefusal)

    var refusal: RelayUpgradeRefusal? {
        if case .refused(let refusal) = self { return refusal }
        return nil
    }
}

/// What the upgrade needs from the app (`AppRoot`): the hub's row, the relay, the device record and the relay
/// transport to the Mac.
@MainActor
protocol RelayUpgradeHost: AnyObject {
    /// The hub's registry row's link; nil when it has none.
    func followerLink(hubID: String) -> LinkRecord?
    /// Saves `link` on its registry row in one write; false when it was not written.
    func persistRoute(_ link: LinkRecord) -> Bool
    /// The relay's account ops (`get_account_state`, `vouch_hub`, `add_slot`).
    var upgradeRelay: any RelayLinkOps { get }
    /// Rewrites the phone's `device` record for the hub (the relay id with its proof while an upgrade is set) and
    /// sends it now; false when it was not written.
    func rewriteDeviceRecord(hubID: String) async -> Bool
    /// A transport to the relay Mac `mac` on the hub's relay store, on the process's one relay session (R2).
    func makeRelaySide(hubID: String, mac: String) throws -> SideTransport
}

/// Runs one hub's upgrade to the relay (steps 0–5 of Task 19). A pass does what it can and returns: the first checks,
/// the device record, `vouch_hub`, `add_slot`, the reader wait (one read of `data/<mac>`), the request, then the
/// wait for the hub's answer (read on iCloud by the session's feed and on the relay here). The answers end it: the
/// follower's move to the relay or `requestAnswered` (`switched`), a rejection (`rejected(_:)`). Passes run one at a
/// time; `upgrade()` starts or restarts one, `resume()` goes on with a pending one at launch and on the return to the
/// foreground, `resumeAfterFetch()` after a fetch (at most every `RelayUpgrade.resumeInterval`, while active).
///
/// Every write is a compare-and-set on the row's upgrade record: a pass that finds the record changed meanwhile (a
/// rejection, a switch) stops without writing. Nothing is written before the first checks pass. A transient answer
/// (the relay unreachable, a locked keychain, a refused write) leaves the step as it is for the next pass.
@MainActor
final class RelayUpgrader {
    let hubID: String
    private weak var session: HubSession?
    private weak var host: (any RelayUpgradeHost)?
    private let follower: TransportFollower
    private let now: @MainActor () -> Date
    private var last: Task<RelayUpgradeOutcome, Never>?
    private var lastResumeAt: Date?
    /// The owner asked for the upgrade and no pass has decided anything yet (no record written, no refusal): the
    /// resumer starts it. In memory only: a kill before the first decision forgets it, and the owner asks again.
    private var wanted = false
    /// Queues the `transport_switch{relay}` named `id` in the session's ordered outbox; a test replaces it to fail the
    /// queue step once.
    var queue: @MainActor (HubSession, String) async throws -> Void = { session, id in
        _ = try await session.outbox.enqueueSwitchRequest(target: .relay, id: id)
    }
    /// Set by a pass that started fresh: the record the row held then (nil for none).
    private var freshFrom: RelayUpgradeRecord??
    private var stopped = false
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "RelayUpgrade")

    init(session: HubSession, follower: TransportFollower, host: any RelayUpgradeHost, now: @escaping @MainActor () -> Date) {
        hubID = session.hubID
        self.session = session
        self.follower = follower
        self.host = host
        self.now = now
    }

    /// Starts the upgrade, or goes on with the one under way; after a refusal, or once switched while the hub is back
    /// on iCloud, starts it again from the device record (a slot already held is reused).
    func upgrade() async -> RelayUpgradeOutcome {
        lastResumeAt = now()
        wanted = true
        return await startPass(start: true).value
    }

    /// Goes on with a pending upgrade, or one asked for that decided nothing yet (`wanted`); none: nothing, no relay
    /// call. At launch and on the return to the foreground.
    @discardableResult
    func resume() async -> RelayUpgradeOutcome? {
        guard resumes(throttled: false) else { return nil }
        return await startPass(start: wanted).value
    }

    /// After a fetch: as `resume()`, at most every `RelayUpgrade.resumeInterval`, started now and not awaited
    /// (`idle()` waits for it).
    func resumeAfterFetch() {
        guard resumes(throttled: true) else { return }
        _ = startPass(start: wanted)
    }

    /// Returns once the passes started so far ended.
    func idle() async {
        _ = await last?.value
    }

    private func resumes(throttled: Bool) -> Bool {
        guard !stopped, wanted || host?.followerLink(hubID: hubID)?.relayUpgrade?.isPending == true else { return false }
        if throttled, let lastResumeAt, now().timeIntervalSince(lastResumeAt) < RelayUpgrade.resumeInterval { return false }
        lastResumeAt = now()
        return true
    }

    /// The session is going: no pass starts after this, and the running one writes nothing more.
    func stop() {
        stopped = true
    }

    /// A pass after the ones started before it, registered at once; its outcome read from the row it left.
    private func startPass(start: Bool) -> Task<RelayUpgradeOutcome, Never> {
        let previous = last
        let pass = Task {
            _ = await previous?.value
            self.freshFrom = nil
            let outcome = self.outcome(await self.pass(start: start))
            if outcome != .waiting { self.wanted = false }
            return outcome
        }
        last = pass
        return pass
    }

    /// The pass's outcome from the row it left. A fresh start that wrote nothing (the row still holds the record it
    /// found: an old refusal, a switch the hub has gone back from, or none) decided nothing: `.waiting`.
    private func outcome(_ refusal: RelayUpgradeRefusal?) -> RelayUpgradeOutcome {
        if let refusal { return .refused(refusal) }
        let current = host?.followerLink(hubID: hubID)?.relayUpgrade
        if case .some(let found) = freshFrom, current == found { return .waiting }
        guard let upgrade = current else { return .waiting }
        if let refusal = upgrade.refusal { return .refused(refusal) }
        return upgrade.step == .switched ? .switched : .underWay(upgrade.step)
    }

    // MARK: - The hub's rejection

    /// A `transport_switch_rejected` (read on iCloud by the feed, or on the relay by a pass): ends the waiting upgrade
    /// with its reason, or, for a first `unavailable`, schedules the one automatic new request after `retry_after_s`.
    /// true once decided (one with no upgrade waiting for it is decided as nothing to do); false when the row could
    /// not be written (the feed hands it again).
    func rejected(_ control: ControlPayload) async -> Bool {
        guard let host, let link = host.followerLink(hubID: hubID), var upgrade = link.relayUpgrade,
              upgrade.isPending, upgrade.step == .requested else {
            Self.logger.notice("transport_switch_rejected read; no upgrade waits for it")
            return true
        }
        let after = TimeInterval(control.retryAfterS ?? 0)
        // An answer proves the request left the phone.
        upgrade.askQueued = true
        switch control.reason {
        case RelayUpgrade.tooSoon: upgrade.refusal = .tooSoon(retryAt: now().addingTimeInterval(after))
        case RelayUpgrade.notPaying: upgrade.refusal = .notPaying
        case RelayUpgrade.unavailable where upgrade.askedAgain: upgrade.refusal = .unavailable
        case RelayUpgrade.unavailable: upgrade.retryAt = now().addingTimeInterval(after)
        case RelayUpgrade.notSupported: upgrade.refusal = .notSupported
        default:
            Self.logger.notice("transport_switch_rejected with a reason this build does not know: still waiting")
            return true
        }
        var next = link
        next.relayUpgrade = upgrade
        guard host.persistRoute(next) else { return false }
        Self.logger.notice("relay upgrade: the hub rejected the request (\(control.reason ?? "", privacy: .public))")
        return true
    }

    // MARK: - One pass

    /// The upgrade's state for this pass: the record as the row held it when read, and what the pass makes of it.
    private struct Run {
        var link: LinkRecord
        var stored: RelayUpgradeRecord?
        var upgrade: RelayUpgradeRecord
    }

    private func pass(start: Bool) async -> RelayUpgradeRefusal? {
        guard !stopped, let host, let session, let link = host.followerLink(hubID: hubID) else { return nil }
        let stored = link.relayUpgrade
        let upgrade: RelayUpgradeRecord
        if let stored, stored.isPending {
            upgrade = stored
        } else {
            guard start else { return stored?.refusal }
            guard link.transport != .relay else { return nil }
            // A first start, a start again after a refusal, or after a switch the hub has gone back from: from the
            // device record, a slot already held kept.
            upgrade = RelayUpgradeRecord(step: .namingRelayID, slotSince: stored?.slotSince, macDeviceID: stored?.macDeviceID)
            freshFrom = .some(stored)
        }
        var run = Run(link: link, stored: stored, upgrade: upgrade)

        // 0. The checks; nothing is written before they pass.
        guard case .available = host.upgradeRelay.availability else { return .relayOff }
        let mac: MacIdentity
        switch macIdentity(session, link) {
        case .unreadable: return nil
        case .missing: return .noRelayIdentity
        case .present(let identity): mac = identity
        }
        do {
            guard try await session.outbox.orderedActions() else { return .notSupported }
        } catch {
            return nil
        }
        var slotted: [String] = []
        if Self.order(run.upgrade.step) < Self.order(.awaitingReader) {
            switch await accountState(host.upgradeRelay) {
            case .unknown: return nil
            case .refused(let refusal): return end(refusal, &run)
            case .paying(let macs): slotted = macs
            }
        }
        return await steps(&run, mac: mac, slotted: slotted, host: host, session: session)
    }

    /// Steps 1–5 from the run's step.
    private func steps(
        _ run: inout Run, mac: MacIdentity, slotted: [String], host: any RelayUpgradeHost, session: HubSession
    ) async -> RelayUpgradeRefusal? {
        if run.upgrade.step == .namingRelayID {
            // The record first: the device record carries the relay id only while it is set.
            guard commit(&run) else { return nil }
            guard await host.rewriteDeviceRecord(hubID: hubID) else { return nil }
            run.upgrade.step = .vouching
            guard commit(&run) else { return nil }
        }
        let inSlots = slotted.contains(mac.deviceID)
        var vouched = false
        if run.upgrade.step == .vouching {
            if !inSlots {
                if let outcome = await vouch(mac, host.upgradeRelay) { return finish(outcome, &run) }
                vouched = true
            }
            run.upgrade.step = .addingSlot
            run.upgrade.macDeviceID = mac.deviceID
            guard commit(&run) else { return nil }
        }
        if run.upgrade.step == .addingSlot {
            if !inSlots {
                if let outcome = await addSlot(mac, host.upgradeRelay, vouched: vouched) { return finish(outcome, &run) }
            }
            run.link.setRelayIdentity(mac: mac.deviceID, authPub: mac.authPubText, transports: mac.transports)
            run.upgrade.macDeviceID = mac.deviceID
            run.upgrade.step = .awaitingReader
            run.upgrade.slotSince = now()
            guard commit(&run) else { return nil }
        }
        if run.upgrade.step == .awaitingReader {
            return await awaitReader(&run, mac: mac.deviceID, host: host, session: session)
        }
        if run.upgrade.step == .requested {
            return await wait(&run, mac: mac.deviceID, host: host, session: session)
        }
        return nil
    }

    /// Step 3a, then step 4 once the Mac's data zone read.
    private func awaitReader(
        _ run: inout Run, mac: String, host: any RelayUpgradeHost, session: HubSession
    ) async -> RelayUpgradeRefusal? {
        let since = run.upgrade.slotSince ?? now()
        let read = await withSide(mac, host: host, session: session) { side, _ in await Self.readData(side) }
        guard read == .read else {
            if now().timeIntervalSince(since) >= RelayUpgrade.readerWaitLimit {
                Self.logger.notice("relay upgrade: the Mac did not name this phone a reader within the wait")
                return end(.readerNotConfirmed, &run)
            }
            return nil
        }
        return await request(&run, mac: mac, host: host, session: session)
    }

    /// Step 4: the row names the request and waits for its answer first, then `transport_switch{relay}` goes into
    /// the iCloud mailbox and the same control id into the relay mailbox: an answer read at once finds the row ready.
    private func request(
        _ run: inout Run, mac: String, host: any RelayUpgradeHost, session: HubSession
    ) async -> RelayUpgradeRefusal? {
        run.upgrade.step = .requested
        run.upgrade.requestID = UUID().uuidString
        run.upgrade.askQueued = false
        guard commit(&run) else { return nil }
        return await queueRequest(&run, mac: mac, host: host, session: session)
    }

    /// Queues the request the row names (once: `askQueued`), then writes its relay copy.
    private func queueRequest(
        _ run: inout Run, mac: String, host: any RelayUpgradeHost, session: HubSession
    ) async -> RelayUpgradeRefusal? {
        guard let id = run.upgrade.requestID else { return nil }
        do {
            try await queue(session, id)
        } catch ActionOutboxError.legacyPath {
            return end(.notSupported, &run)
        } catch {
            Self.logger.warning("relay upgrade: the request was not queued: \(String(describing: type(of: error)), privacy: .public)")
            return nil
        }
        run.upgrade.askQueued = true
        // A rejection read meanwhile wins the row; the request is queued either way.
        _ = commit(&run)
        await withSide(mac, host: host, session: session) { _, secure in await Self.writeRelayCopy(id, secure, session) }
        return nil
    }

    /// Step 5: the one automatic new request after `unavailable` once its time came, then the relay mailbox read for
    /// the hub's answer (a `transport_switched` to the follower, a rejection to `rejected(_:)`).
    private func wait(_ run: inout Run, mac: String, host: any RelayUpgradeHost, session: HubSession) async -> RelayUpgradeRefusal? {
        if let retryAt = run.upgrade.retryAt, now() >= retryAt {
            run.upgrade.retryAt = nil
            run.upgrade.askedAgain = true
            run.upgrade.requestID = UUID().uuidString
            run.upgrade.askQueued = false
            guard commit(&run) else { return nil }
        }
        if !run.upgrade.askQueued {
            if let refusal = await queueRequest(&run, mac: mac, host: host, session: session) { return refusal }
            guard run.upgrade.askQueued else { return nil }
        }
        let follower = follower
        await withSide(mac, host: host, session: session) { side, secure in
            do {
                try await side.pullMailbox()
                _ = try await session.readOtherControls(over: secure) { control in
                    await follower.handle(control: control, on: .relay)
                }
            } catch {
                Self.logger.notice("relay upgrade: the relay mailbox was not read: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
        return nil
    }

    // MARK: - Relay calls

    private enum AccountRead {
        case paying(macs: [String])
        case refused(RelayUpgradeRefusal)
        case unknown
    }

    /// `get_account_state`, three-way as Task 11's `canUseRelay`: not paying ends the upgrade, a failed read decides
    /// nothing (an app that must update is the Task 10 row's refusal).
    private func accountState(_ relay: any RelayLinkOps) async -> AccountRead {
        do {
            let state = try await relay.accountState()
            return state.paying ? .paying(macs: state.macs) : .refused(.notPaying)
        } catch HostedRelayPairing.Refusal.notPaying {
            return .refused(.notPaying)
        } catch HostedRelayPairing.Refusal.updateRequired {
            return .refused(.vouch(.updateRequired))
        } catch {
            Self.logger.notice("relay upgrade: the account state was not read; the next pass asks again")
            return .unknown
        }
    }

    /// A step's end other than success: wait for the next pass, or a refusal.
    private enum Outcome {
        case wait
        case refused(RelayUpgradeRefusal)
    }

    /// `vouch_hub`: nil once vouched.
    private func vouch(_ mac: MacIdentity, _ relay: any RelayLinkOps) async -> Outcome? {
        do {
            try await relay.vouch(hubDeviceID: mac.deviceID, authPub: mac.authPub)
            return nil
        } catch let refusal as HostedRelayPairing.VouchRefusal {
            switch refusal {
            case .unreachable, .attestationBackoff: return .wait
            default: return .refused(.vouch(refusal))
            }
        } catch {
            return .wait
        }
    }

    /// `add_slot`, after a vouch in this pass (else one first: a vouch lasts 10 minutes). `HUB_NOT_VOUCHED` vouches
    /// again once and repeats once; nil once the Mac holds the slot.
    private func addSlot(_ mac: MacIdentity, _ relay: any RelayLinkOps, vouched: Bool) async -> Outcome? {
        if !vouched, let outcome = await vouch(mac, relay) { return outcome }
        var vouchedAgain = false
        while true {
            do {
                try await relay.addSlot(mac: mac.deviceID)
                return nil
            } catch HostedRelayError.server(code: .hubNotVouched, _) where !vouchedAgain {
                Self.logger.notice("relay add_slot: hub not vouched, vouching again")
                vouchedAgain = true
                if let outcome = await vouch(mac, relay) { return outcome }
            } catch {
                return Self.addSlotOutcome(error)
            }
        }
    }

    private static func addSlotOutcome(_ error: any Error) -> Outcome {
        if let refusal = error as? HostedRelayPairing.Refusal {
            switch refusal {
            case .notPaying: return .refused(.notPaying)
            case .slotsFull: return .refused(.vouch(.slotsFull))
            case .replacementLimit: return .refused(.replacementLimit)
            case .updateRequired: return .refused(.vouch(.updateRequired))
            case .pairingExpired, .unreachable, .attestationBackoff: return .wait
            }
        }
        guard case let HostedRelayError.server(code, _) = error else { return .wait }
        switch code {
        case .hubNotVouched, .forbidden: return .refused(.vouch(.notConfirmed))
        case .notFound: return .refused(.vouch(.hubNotOnRelay))
        default: return .wait
        }
    }

    private enum DataRead {
        case read
        case notYet
    }

    /// One read of the Mac's data zone on the relay: `FORBIDDEN` is "not a reader yet" (as R5); any other failure
    /// is retried at the next pass too.
    private static func readData(_ side: SideTransport) async -> DataRead {
        guard let relay = side.transport as? HostedRelayTransport else { return .notYet }
        do {
            try await relay.pull(only: [.data])
            return .read
        } catch HostedRelayError.server(code: .forbidden, _) {
            logger.notice("relay upgrade: not a reader of the Mac's data zone yet")
            return .notYet
        } catch {
            logger.notice("relay upgrade: the Mac's data zone was not read: \(String(describing: type(of: error)), privacy: .public)")
            return .notYet
        }
    }

    /// The request's copy in the relay mailbox, the same control id (rule 9's initiator write). Best effort: the
    /// iCloud copy is the one the outbox keeps until written.
    private static func writeRelayCopy(_ id: String, _ secure: SecureTransport, _ session: HubSession) async {
        do {
            let control = try await session.outbox.switchRequest(target: .relay, id: id)
            let sealed = try await secure.seal(try CloudRecordFactory.record(for: control, modifiedAt: Date()))
            _ = try await secure.saveSealed([ConditionalSave(record: sealed, expect: .absent)])
        } catch {
            logger.notice("relay upgrade: the request's relay copy was not written: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    /// Runs `body` over a relay transport to the Mac on the hub's relay store (the shared socket's client, no socket
    /// of its own), then closes it: the session that follows a switch opens the same store.
    @discardableResult
    private func withSide<T>(
        _ mac: String,
        host: any RelayUpgradeHost,
        session: HubSession,
        _ body: (SideTransport, SecureTransport) async -> T
    ) async -> T? {
        let side: SideTransport
        do {
            side = try host.makeRelaySide(hubID: hubID, mac: mac)
        } catch {
            Self.logger.error("relay upgrade: no relay transport to the Mac: \(String(describing: type(of: error)), privacy: .public)")
            return nil
        }
        let result = await body(side, session.sealing(side.transport))
        await (side.transport as? any LiveTransport)?.stop()
        do {
            try side.store?.close()
        } catch {
            Self.logger.error("relay upgrade: the relay store was not closed")
        }
        return result
    }

    // MARK: - State

    /// Writes the run's record (and its link) when the row still holds the record the run read: a rejection or a
    /// switch meanwhile wins, and this pass writes nothing more.
    private func commit(_ run: inout Run) -> Bool {
        guard !stopped, let host, var current = host.followerLink(hubID: hubID), current.relayUpgrade == run.stored else {
            Self.logger.notice("relay upgrade: the row changed meanwhile; this pass stops")
            return false
        }
        if let mac = run.link.relayMacDeviceID, current.relayMacDeviceID != mac {
            current.setRelayIdentity(mac: mac, authPub: run.link.relayAuthPub, transports: run.link.hubTransports)
        }
        current.relayUpgrade = run.upgrade
        guard host.persistRoute(current) else { return false }
        run.link = current
        run.stored = run.upgrade
        return true
    }

    /// Ends the upgrade with `refusal`, kept on the row when a record is stored (a first start's checks write nothing).
    private func end(_ refusal: RelayUpgradeRefusal, _ run: inout Run) -> RelayUpgradeRefusal {
        guard run.stored != nil else { return refusal }
        run.upgrade.refusal = refusal
        _ = commit(&run)
        let step = run.upgrade.step.rawValue
        Self.logger.notice("relay upgrade ended at \(step, privacy: .public)")
        return refusal
    }

    private func finish(_ outcome: Outcome, _ run: inout Run) -> RelayUpgradeRefusal? {
        switch outcome {
        case .wait: return nil
        case .refused(let refusal): return end(refusal, &run)
        }
    }

    private static func order(_ step: RelayUpgradeStep) -> Int {
        RelayUpgradeStep.allCases.firstIndex(of: step) ?? 0
    }

    // MARK: - The Mac's relay identity

    private struct MacIdentity {
        let deviceID: String
        let authPub: Data
        let authPubText: String
        let transports: [String]?
    }

    private enum IdentityRead {
        case present(MacIdentity)
        case missing
        case unreadable
    }

    /// The linked grant's relay pair (`relay_device_id`, `relay_auth_pub`), coherent; unreadable while the
    /// keychain is locked or the keybox does not open.
    private func macIdentity(_ session: HubSession, _ link: LinkRecord) -> IdentityRead {
        guard let deviceID = link.deviceID.flatMap(UUID.init(uuidString:)) else { return .missing }
        let grant: DeviceGrant
        do {
            guard let keybox = try session.keybox(deviceID: deviceID) else { return .missing }
            grant = keybox.grant
        } catch {
            return .unreadable
        }
        guard let mac = grant.relayDeviceID, let text = grant.relayAuthPub,
              LinkPayload.relayIdentityIsCoherent(deviceID: mac, authPub: text),
              let authPub = WireBytes.fromBase64URL(text) else { return .missing }
        return .present(MacIdentity(deviceID: mac, authPub: authPub, authPubText: text, transports: grant.transports))
    }
}
