import CryptoKit
import Foundation
import WatchtowerHostedRelay
import WatchtowerRelayProto
import WatchtowerSync
@testable import WatchtowerMobile

/// A hub's session as the account center sees it: counts what it was told.
@MainActor
final class FakeLapseTarget: RelayLapseTarget {
    var isOnRelay: Bool
    private(set) var lapses = 0
    private(set) var ended = 0

    init(isOnRelay: Bool) {
        self.isOnRelay = isOnRelay
    }

    func lapseRelay() async {
        lapses += 1
    }

    func lapseEnded() async {
        ended += 1
    }
}

/// The relay's HTTP with two faults the fake has no word for: a request for one JWS held until released (a submit
/// still in flight), and a scripted entitlement answer to the next `submit_transaction`s.
final class SubmitGateHTTP: RelayHTTP, @unchecked Sendable {
    private let inner: any RelayHTTP
    private let lock = NSLock()
    private var held: Set<String> = []
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var answers: [Relay_V1_EntitlementKind] = []

    init(inner: any RelayHTTP) {
        self.inner = inner
    }

    /// Submits of `jws` wait until `release(jws)`.
    func hold(_ jws: String) {
        lock.withLock { _ = held.insert(jws) }
    }

    func isHolding(_ jws: String) -> Bool {
        lock.withLock { !(waiting[jws] ?? []).isEmpty }
    }

    func release(_ jws: String) {
        let waiters = lock.withLock {
            held.remove(jws)
            return waiting.removeValue(forKey: jws) ?? []
        }
        for waiter in waiters { waiter.resume() }
    }

    /// The next submit answers `state` whatever the fake would.
    func answerNextSubmit(_ state: Relay_V1_EntitlementKind) {
        lock.withLock { answers.append(state) }
    }

    func post(_ url: URL, body: Data, headers: [String: String]) async throws -> (status: Int, body: Data) {
        if let request = try? Relay_V1_Request(serializedBytes: body), case .submitTransaction(let submit)? = request.op {
            await waitIfHeld(submit.signedTransaction)
            let scripted = lock.withLock { answers.isEmpty ? nil : answers.removeFirst() }
            if let scripted {
                var response = Relay_V1_Response()
                response.entitlement.state = scripted
                return (200, try response.serializedData())
            }
        }
        return try await inner.post(url, body: body, headers: headers)
    }

    func put(_ url: URL, file: URL, headers: [String: String]) async throws -> Int {
        try await inner.put(url, file: file, headers: headers)
    }

    func get(_ url: URL, to file: URL, maxBytes: Int64, headers: [String: String]) async throws -> Int {
        try await inner.get(url, to: file, maxBytes: maxBytes, headers: headers)
    }

    private func waitIfHeld(_ jws: String) async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let parked = lock.withLock {
                guard held.contains(jws) else { return false }
                waiting[jws, default: []].append(waiter)
                return true
            }
            if !parked { waiter.resume() }
        }
    }
}

/// One phone: `RelayAccountCenter`s over `FakeHostedRelay` and `FakeSubscriptionStore`, the socket's events scripted.
@MainActor
final class AccountBed {
    let clock = ManualRelayClock(now: Date())
    let fake: FakeHostedRelay
    let http: SubmitGateHTTP
    let attest = FakeAppAttest()
    let relay: SharedRelaySession
    let store = FakeSubscriptionStore()
    let defaults: UserDefaults
    var targets: [FakeLapseTarget] = []
    private var sink: AsyncStream<HostedRelayEvent>.Continuation?
    /// Times the events stream was asked for.
    private(set) var eventStreams = 0

    init() {
        fake = FakeHostedRelay(attest: .off, clock: clock)
        let http = SubmitGateHTTP(inner: fake.http)
        self.http = http
        let parts = RelayParts(
            attest: attest, keychain: InMemoryKeychainBackend(), keychainGroup: nil, http: http, sockets: fake.sockets, clock: clock
        )
        relay = SharedRelaySession(config: RelayConfig.parse(fake.origin)) { parts }
        defaults = UserDefaults(suiteName: "relay-account-\(UUID().uuidString)") ?? .standard
    }

    /// A center over this phone. A new one is a relaunch: its refused set and its state start empty.
    func makeCenter() -> RelayAccountCenter {
        let live = RelayAccountLink.live(relay)
        let (stream, sink) = AsyncStream.makeStream(of: HostedRelayEvent.self)
        self.sink = sink
        let link = RelayAccountLink(hasIdentity: live.hasIdentity, account: live.account) { [weak self] in
            self?.eventStreams += 1
            return stream
        }
        let clock = clock
        return RelayAccountCenter(
            link: link, store: store, defaults: defaults, now: { clock.now() }, targets: { [weak self] in self?.targets ?? [] }
        )
    }

    func emit(_ event: HostedRelayEvent) {
        sink?.yield(event)
    }

    /// Gives this phone its identity and account id, as an earlier use of the relay did.
    @discardableResult
    func register() async throws -> UUID {
        guard let account = try relay.account() else { throw HostedRelayPairing.Refusal.unreachable }
        return try await account.accountID()
    }

    /// A current period's transaction for this phone's account, signed `signedAgo` seconds ago.
    func row(
        id: UInt64 = 1,
        original: String = "1000",
        token: UUID,
        signedAgo: TimeInterval = 0,
        renewal: Bool = false,
        expiresIn: TimeInterval = 30 * 86_400,
        revoked: Bool = false
    ) -> RelayTransaction {
        RelayTransaction(
            id: id, originalID: 1000,
            jws: FakeHostedRelay.fakeJWS(
                originalTransactionID: original, appAccountToken: token.uuidString,
                signedDate: clock.now().addingTimeInterval(-signedAgo)),
            revoked: revoked, isRenewal: renewal, expiresAt: clock.now().addingTimeInterval(expiresIn)
        )
    }

    /// What StoreKit holds after a sale: the purchase's answer, and the row unfinished.
    func sell(_ row: RelayTransaction) {
        store.purchaseResult = .purchased(row)
        store.unfinishedResult = [row]
    }

    /// The JWS of every `submit_transaction` the relay took, in order.
    var submitted: [String] {
        fake.log.compactMap { if case .submitTransaction(let submit) = $0 { submit.signedTransaction } else { nil } }
    }

    /// Every op the relay took, by name, in order.
    var ops: [String] {
        fake.log.map(FakeHostedRelay.name)
    }

    /// `get_account_state` calls.
    var reads: Int {
        ops.filter { $0 == "getAccountState" }.count
    }

    /// Another phone on the same relay, registered.
    func otherPhone(seed: UInt8) async throws -> HostedRelayClient {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: seed, count: 32))
        let client = HostedRelayClient(
            origin: try RelayOrigin(fake.origin), signer: Ed25519RelaySigner(key), kind: .phone,
            attestor: RelayAttestor(attest: FakeAppAttest(), keys: InMemoryAppAttestKeyStore(), clock: clock),
            http: fake.http, sockets: fake.sockets, clock: clock
        )
        _ = try await client.register()
        try await client.login()
        return client
    }

    /// `until` becomes true within the bound, on the main actor.
    func until(_ what: String = "condition", _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { throw AccountBedTimeout(what: what) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

struct AccountBedTimeout: Error {
    let what: String
}
