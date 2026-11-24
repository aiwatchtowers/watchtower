import Foundation
import WatchtowerHostedRelay
import WatchtowerSync

/// Which way a scanned code links (relay client Phase 3, R4).
enum LinkRoute: Equatable {
    /// iCloud, as before the relay.
    case cloudKit
    /// A relay pairing slot with the Mac `mac` (its relay device id), vouched for with `authPub` (its `relay_auth`
    /// public key, raw bytes).
    case relay(mac: String, authPub: Data)
    /// No link: the failure screen.
    case refuse(LinkFailure)
}

/// The paying check's answer: paying, and the Macs in this account's slots.
typealias RelayAccountAnswer = (paying: Bool, macs: [String])

/// The link route rule (R4; #2191), pure. A code *offers Relay* when its relay identity is coherent and its
/// `transports` lists `relay` (a code without `transports` goes by the identity alone). In order:
///
/// | Code | Relay on this phone | Paying answer | Route |
/// |---|---|---|---|
/// | hub on iCloud, offers Relay | available | yes, but every slot holds another Mac, and iCloud is usable | `.cloudKit` |
/// | offers Relay | available | yes | `.relay` (also for a hub on iCloud) |
/// | offers Relay | available | none (unreachable, backoff), device entitled | `.refuse(.relayUnreachable)` |
/// | hub on iCloud | available | none, device not entitled | `.cloudKit` |
/// | offers Relay | available | `.updateRequired` | `.refuse(.updateApp)` |
/// | hub on iCloud | off, or not paying | — | `.cloudKit` |
/// | hub on Relay | off, or not paying | — | `.macOnRelay` / `.needsRelay` |
/// | neither route | — | — | `.refuse(.refused)` |
///
/// An iCloud link to a Mac on Relay would only ever receive `hub_on_relay`, so a hub on Relay is never linked over
/// iCloud.
enum LinkRoutePolicy {
    /// `decide` with a paying answer that carries no slots (the route tests).
    static func decide(
        _ code: LinkPayload,
        relay: RelayAvailability,
        entitled: () async -> Bool = { false },
        paying: () async -> Result<Bool, HostedRelayPairing.Refusal>
    ) async -> LinkRoute {
        await route(
            code, relay: relay, entitled: entitled, iCloudUsable: { true },
            account: { await paying().map { (paying: $0, macs: []) } }
        )
    }

    /// `account` is asked only when the code offers Relay and the relay is available. On a hub on Relay, an answer
    /// that is not a definite yes or no refuses with `.relayUnreachable`: it is never read as "not paying". On a hub
    /// on iCloud it does so only when `entitled` (the device's StoreKit entitlement, read only then) says this phone
    /// pays; otherwise the phone links over iCloud as before. A paying phone whose slots all hold other Macs links an
    /// iCloud hub over iCloud rather than stop at the slots screen, but only when `iCloudUsable` (asked only then):
    /// without iCloud the slots screen, where a slot can be freed, is the only way on.
    static func route(
        _ code: LinkPayload,
        relay: RelayAvailability,
        entitled: () async -> Bool,
        iCloudUsable: () async -> Bool,
        account: () async -> Result<RelayAccountAnswer, HostedRelayPairing.Refusal>
    ) async -> LinkRoute {
        guard hubOnRelay(code) else {
            guard code.offersCloudKit else {
                // A code that names no route this phone can use (a v4 code with neither iCloud nor a relay identity).
                return .refuse(.refused)
            }
            guard offersRelay(code), case .available = relay, let mac = code.relayDeviceID,
                  let authPub = code.relayAuthPub.flatMap(WireBytes.fromBase64URL) else { return .cloudKit }
            switch await account() {
            case let .success(answer) where answer.paying:
                let slotsFull = answer.macs.count >= HostedRelayLimits.maxMacSlots && !answer.macs.contains(mac)
                guard slotsFull, await iCloudUsable() else { return .relay(mac: mac, authPub: authPub) }
                return .cloudKit
            case .success, .failure(.notPaying): return .cloudKit
            case .failure(.updateRequired): return .refuse(.updateApp)
            case .failure: return await entitled() ? .refuse(.relayUnreachable) : .cloudKit
            }
        }
        guard code.offersRelay, let mac = code.relayDeviceID,
              let authPub = code.relayAuthPub.flatMap(WireBytes.fromBase64URL) else { return .refuse(.refused) }
        // A Mac on Relay that also offers iCloud is a Mac switched to Relay; one that does not is a headless host.
        let cannotUse: LinkRoute = .refuse(code.offersCloudKit ? .macOnRelay(macName: code.macName) : .needsRelay(macName: code.macName))
        guard case .available = relay else { return cannotUse }
        switch await account() {
        case let .success(answer): return answer.paying ? .relay(mac: mac, authPub: authPub) : cannotUse
        case .failure(.notPaying): return cannotUse
        case .failure(.updateRequired): return .refuse(.updateApp)
        case .failure: return .refuse(.relayUnreachable)
        }
    }

    /// Whether the code's hub runs over Relay (`transport` relay, or a v4 code that offers only the relay).
    static func hubOnRelay(_ code: LinkPayload) -> Bool {
        code.transport == .relay || (code.transport == nil && !code.offersCloudKit && code.offersRelay)
    }

    /// Whether a code offers a Relay pairing: a coherent relay identity, and `relay` in its `transports` when it
    /// lists them. Every further condition on the code (a capability the Mac declares) joins here.
    static func offersRelay(_ code: LinkPayload) -> Bool {
        code.offersRelay && (code.transports.map { $0.contains("relay") } ?? true)
    }

    /// The paying check over the relay's account state. Only `.updateRequired` keeps its meaning; every other
    /// failure, mapped or not, is transient (`.unreachable`).
    static func paying(_ accountState: () async throws -> RelayAccountAnswer) async -> Result<Bool, HostedRelayPairing.Refusal> {
        await account(accountState).map(\.paying)
    }

    /// `paying` with the account's slots kept.
    static func account(_ accountState: () async throws -> RelayAccountAnswer) async -> Result<RelayAccountAnswer, HostedRelayPairing.Refusal> {
        do {
            return .success(try await accountState())
        } catch HostedRelayPairing.Refusal.updateRequired {
            return .failure(.updateRequired)
        } catch HostedRelayPairing.Refusal.notPaying {
            return .success((paying: false, macs: []))
        } catch {
            return .failure(.unreachable)
        }
    }
}

/// The device's Relay entitlement read (StoreKit), shared by every scan while it runs. Each caller waits under its
/// own bound and leaves when it times out or is cancelled; the read itself is never cancelled by a caller. A read
/// older than `maxAge` (on `clock`'s uptime) is abandoned: the next caller starts a new one, and the old one's answer is
/// dropped. So a hung StoreKit read neither piles up waiters nor makes the phone "not entitled" for the session.
final class SharedEntitlementRead: @unchecked Sendable {
    /// How long one caller waits for the read before it counts as "not entitled".
    static let bound = Duration.seconds(5)
    /// How old a read in flight may get before a caller starts a new one.
    static let maxAge: TimeInterval = 60

    private struct Waiter {
        let continuation: CheckedContinuation<Bool, Never>
        var timeout: Task<Void, Never>?
    }

    private let read: @Sendable () async -> Bool
    private let clock: any LinkClock
    private let maxAge: TimeInterval
    private let lock = NSLock()
    private var running: (id: UInt64, startedAt: TimeInterval)?
    private var reads: UInt64 = 0
    private var waiters: [UInt64: Waiter] = [:]
    /// Callers that have an id and have not registered yet, and those of them already cancelled.
    private var unregistered: Set<UInt64> = []
    private var cancelledEarly: Set<UInt64> = []
    private var lastWaiter: UInt64 = 0

    init(
        maxAge: TimeInterval = SharedEntitlementRead.maxAge,
        clock: any LinkClock,
        read: @escaping @Sendable () async -> Bool
    ) {
        self.maxAge = maxAge
        self.clock = clock
        self.read = read
    }

    /// Reads started so far.
    var readsStarted: Int { lock.withLock { Int(reads) } }
    /// Callers waiting now.
    var waiting: Int { lock.withLock { waiters.count } }

    /// The read's answer; false once `timeout` returns first or the caller is cancelled. A caller already cancelled
    /// starts nothing.
    func callAsFunction(timeout: @escaping @Sendable () async -> Void = { try? await Task.sleep(for: bound) }) async -> Bool {
        guard !Task.isCancelled else { return false }
        let id = lock.withLock {
            lastWaiter += 1
            unregistered.insert(lastWaiter)
            return lastWaiter
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard register(id, continuation) else {
                    continuation.resume(returning: false)
                    return
                }
                startIfNeeded()
                attach(Task {
                    await timeout()
                    self.leave(id)
                }, to: id)
            }
        } onCancel: {
            leave(id)
        }
    }

    private func register(_ id: UInt64, _ continuation: CheckedContinuation<Bool, Never>) -> Bool {
        lock.withLock {
            unregistered.remove(id)
            guard cancelledEarly.remove(id) == nil else { return false }
            waiters[id] = Waiter(continuation: continuation)
            return true
        }
    }

    private func attach(_ timeout: Task<Void, Never>, to id: UInt64) {
        let answered = lock.withLock {
            guard waiters[id] != nil else { return true }
            waiters[id]?.timeout = timeout
            return false
        }
        if answered { timeout.cancel() }
    }

    /// The caller `id` stops waiting: "not entitled". A cancel that lands before the caller registered is kept, so
    /// its registration answers at once.
    private func leave(_ id: UInt64) {
        let waiter: Waiter? = lock.withLock {
            if let waiter = waiters.removeValue(forKey: id) { return waiter }
            if unregistered.contains(id) { cancelledEarly.insert(id) }
            return nil
        }
        waiter?.timeout?.cancel()
        waiter?.continuation.resume(returning: false)
    }

    private func startIfNeeded() {
        let id: UInt64? = lock.withLock {
            let now = clock.uptime()
            if let running, now - running.startedAt < maxAge { return nil }
            reads += 1
            running = (reads, now)
            return reads
        }
        guard let id else { return }
        Task { [read] in
            let value = await read()
            self.finish(id, value)
        }
    }

    /// The read `id` answered: every caller waiting gets `value`, unless a newer read replaced it.
    private func finish(_ id: UInt64, _ value: Bool) {
        let answered: [Waiter] = lock.withLock {
            guard running?.id == id else { return [] }
            running = nil
            defer { waiters = [:] }
            return Array(waiters.values)
        }
        for waiter in answered {
            waiter.timeout?.cancel()
            waiter.continuation.resume(returning: value)
        }
    }
}
