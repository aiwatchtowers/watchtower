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
    /// How long the device's entitlement read may take before it counts as "not entitled".
    static let entitlementBound = Duration.seconds(5)

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

    /// `read`, or false once `timeout` returns first or the caller is cancelled. The read is left to finish on its own
    /// (StoreKit's reads do not stop on a cancel), so a hung read never holds the scan.
    static func bounded(_ read: @escaping @Sendable () async -> Bool, timeout: @escaping @Sendable () async -> Void) async -> Bool {
        let race = FirstAnswer()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.wait(continuation)
                race.add(Task { race.answer(await read()) })
                race.add(Task {
                    await timeout()
                    race.answer(false)
                })
            }
        } onCancel: {
            race.answer(false)
        }
    }
}

/// One entitlement read shared by every caller while it runs (`HostedRelayLinkOps`): a hung StoreKit read is never
/// started again by a later scan, and each caller bounds its own wait (`LinkRoutePolicy.bounded`).
final class SharedEntitlementRead: @unchecked Sendable {
    private let read: @Sendable () async -> Bool
    private let lock = NSLock()
    private var running: (id: UInt64, task: Task<Bool, Never>)?
    private var started: UInt64 = 0

    init(_ read: @escaping @Sendable () async -> Bool) {
        self.read = read
    }

    /// The read in flight, or a new one when none is.
    func start() -> Task<Bool, Never> {
        lock.withLock {
            if let running { return running.task }
            started += 1
            let id = started
            let task = Task { [read] in
                let value = await read()
                self.finished(id)
                return value
            }
            running = (id, task)
            return task
        }
    }

    func callAsFunction() async -> Bool {
        await start().value
    }

    private func finished(_ id: UInt64) {
        lock.withLock { if running?.id == id { running = nil } }
    }
}

/// The first answer of `LinkRoutePolicy.bounded`'s two tasks (or the caller's cancel); the other task is cancelled.
private final class FirstAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var tasks: [Task<Void, Never>] = []
    private var done = false
    private var result = false

    /// Resumes at once when the answer came first (a caller cancelled before it waited).
    func wait(_ continuation: CheckedContinuation<Bool, Never>) {
        let (answered, value) = lock.withLock {
            if !done { self.continuation = continuation }
            return (done, result)
        }
        if answered { continuation.resume(returning: value) }
    }

    func add(_ task: Task<Void, Never>) {
        let late = lock.withLock {
            if !done { tasks.append(task) }
            return done
        }
        if late { task.cancel() }
    }

    func answer(_ value: Bool) {
        let (waiter, others): (CheckedContinuation<Bool, Never>?, [Task<Void, Never>]) = lock.withLock {
            guard !done else { return (nil, []) }
            done = true
            result = value
            defer {
                continuation = nil
                tasks = []
            }
            return (continuation, tasks)
        }
        waiter?.resume(returning: value)
        for task in others { task.cancel() }
    }
}
