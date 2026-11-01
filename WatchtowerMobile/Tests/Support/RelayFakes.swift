import CryptoKit
import Foundation
import WatchtowerE2ETesting
import WatchtowerHostedRelay
import WatchtowerSync
@testable import WatchtowerMobile

/// App Attest stand-in that counts every DeviceCheck call, `isSupported` included. The key calls throw.
final class SpyAppAttest: AppAttesting, @unchecked Sendable {
    private let lock = NSLock()
    private let supported: Bool
    private var count = 0

    init(supported: Bool) {
        self.supported = supported
    }

    /// DeviceCheck calls made so far.
    var calls: Int { lock.withLock { count } }

    var isSupported: Bool {
        lock.withLock {
            count += 1
            return supported
        }
    }

    func generateKey() async throws -> String {
        try refuse()
    }

    func attestKey(_: String, clientDataHash _: Data) async throws -> Data {
        try refuse()
    }

    func generateAssertion(_: String, clientDataHash _: Data) async throws -> Data {
        try refuse()
    }

    private func refuse<T>() throws -> T {
        lock.withLock { count += 1 }
        throw AppAttestFailure.other("test")
    }
}

/// An in-memory Keychain that counts every operation.
final class SpyKeychain: KeychainBackend, @unchecked Sendable {
    private let inner = InMemoryKeychainBackend()
    private let lock = NSLock()
    private var count = 0

    /// Keychain operations made so far.
    var operations: Int { lock.withLock { count } }

    func read(account: String, group: String?) throws -> Data? {
        tick()
        return try inner.read(account: account, group: group)
    }

    func write(_ data: Data, account: String, access: KeyAccess, group: String?, dataProtection: Bool) throws {
        tick()
        try inner.write(data, account: account, access: access, group: group, dataProtection: dataProtection)
    }

    func add(_ data: Data, account: String, access: KeyAccess, group: String?, dataProtection: Bool) throws -> Bool {
        tick()
        return try inner.add(data, account: account, access: access, group: group, dataProtection: dataProtection)
    }

    func delete(account: String, group: String?) throws {
        tick()
        try inner.delete(account: account, group: group)
    }

    private func tick() {
        lock.withLock { count += 1 }
    }
}

/// A relay network that is never reached: every request and dial fails at once and is counted.
final class OfflineRelayNetwork: RelayHTTP, RelaySocketDialer, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// Requests and dials attempted so far.
    var attempts: Int { lock.withLock { count } }

    func post(_: URL, body _: Data, headers _: [String: String]) async throws -> (status: Int, body: Data) {
        try fail()
    }

    func put(_: URL, file _: URL, headers _: [String: String]) async throws -> Int {
        try fail()
    }

    func get(_: URL, to _: URL, maxBytes _: Int64, headers _: [String: String]) async throws -> Int {
        try fail()
    }

    func dial(_: URL, headers _: [String: String]) async throws -> any RelaySocket {
        try fail()
    }

    private func fail<T>() throws -> T {
        lock.withLock { count += 1 }
        throw URLError(.notConnectedToInternet)
    }
}

/// The relay parts of a test: spies for every live part, and a count of how often the parts were asked for.
final class RelaySpies: @unchecked Sendable {
    static let origin = "https://relay.example.com"

    let attest: SpyAppAttest
    let keychain = SpyKeychain()
    let network = OfflineRelayNetwork()
    private let lock = NSLock()
    private var built = 0

    init(attestSupported: Bool = true) {
        attest = SpyAppAttest(supported: attestSupported)
    }

    /// How often `RelayParts` were built.
    var partsBuilt: Int { lock.withLock { built } }

    func parts() -> RelayParts {
        lock.withLock { built += 1 }
        return RelayParts(attest: attest, keychain: keychain, keychainGroup: nil, http: network, sockets: network)
    }

    /// The process's relay over these spies, for `config` (an origin by default).
    func relay(origin: String? = RelaySpies.origin) -> SharedRelaySession {
        SharedRelaySession(config: RelayConfig.parse(origin)) { self.parts() }
    }
}

/// The relay's account ops as a scripted account (relay client Phase 3 Task 10): the Macs in slots, the pairing
/// slots opened, the vouches; every op logged by name. A queued error answers the next call of its op instead.
/// `promote` puts the slot's Mac in the slots (a lost answer still applies it: `promoteAppliesThenThrows`).
final class FakeRelayOps: RelayLinkOps, @unchecked Sendable {
    /// A relay device id from a fixed seed: 52 characters a–z2–7.
    static let phoneID = String(repeating: "p", count: 52)

    private let lock = NSLock()
    private let clock: any LinkClock
    var availability: RelayAvailability
    private var state = State()

    private struct State {
        var paying = true
        var slots: [String] = []
        var slotMacs: [String: String] = [:]
        var opened = 0
        var ops: [String] = []
        var errors: [String: [any Error]] = [:]
        var promoteAppliesThenThrows: (any Error)?
        var parking: Set<String> = []
        var parked: [String: [CheckedContinuation<Void, Never>]] = [:]
    }

    /// The next calls of `op` wait until `release(op)` (an op still running when the screen is shot).
    func park(_ op: String) {
        lock.withLock { _ = state.parking.insert(op) }
    }

    func isParked(_ op: String) -> Bool {
        lock.withLock { !(state.parked[op] ?? []).isEmpty }
    }

    func release(_ op: String) {
        let waiting = lock.withLock {
            state.parking.remove(op)
            return state.parked.removeValue(forKey: op) ?? []
        }
        for waiter in waiting { waiter.resume() }
    }

    private func waitIfParked(_ op: String) async {
        guard lock.withLock({ state.parking.contains(op) }) else { return }
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock {
                guard state.parking.contains(op) else { return true }
                state.parked[op, default: []].append(waiter)
                return false
            }
            if resumeNow { waiter.resume() }
        }
    }

    /// The test relay's origin.
    static let origin: RelayOrigin = {
        guard let origin = try? RelayOrigin(RelaySpies.origin) else { preconditionFailure("test origin") }
        return origin
    }()

    init(clock: any LinkClock, availability: RelayAvailability = .available(FakeRelayOps.origin)) {
        self.clock = clock
        self.availability = availability
    }

    /// Every op in call order: `accountState`, `open <mac>`, `vouch <mac>`, `promote <slot>`, `close <slot>`,
    /// `removeSlot <mac>`.
    var ops: [String] { lock.withLock { state.ops } }
    var slots: [String] {
        get { lock.withLock { state.slots } }
        set { lock.withLock { state.slots = newValue } }
    }
    var paying: Bool {
        get { lock.withLock { state.paying } }
        set { lock.withLock { state.paying = newValue } }
    }
    /// The next promote applies (the Mac in slots) and then throws `error`: the answer lost.
    func losePromoteAnswer(_ error: any Error) {
        lock.withLock { state.promoteAppliesThenThrows = error }
    }

    /// Queues `errors` for the next calls of `op` (`accountState`, `open`, `vouch`, `promote`, `removeSlot`).
    func fail(_ op: String, with errors: any Error...) {
        lock.withLock { state.errors[op, default: []] += errors }
    }

    /// How many calls of `op` were made.
    func count(_ op: String) -> Int {
        ops.filter { $0 == op || $0.hasPrefix(op + " ") }.count
    }

    private func call(_ op: String, _ detail: String? = nil) throws {
        try lock.withLock {
            state.ops.append(detail.map { "\(op) \($0)" } ?? op)
            if var queued = state.errors[op], !queued.isEmpty {
                let error = queued.removeFirst()
                state.errors[op] = queued
                throw error
            }
        }
    }

    func phoneDeviceID() throws -> String { Self.phoneID }

    func accountState() async throws -> (paying: Bool, macs: [String]) {
        try call("accountState")
        return lock.withLock { (state.paying, state.slots) }
    }

    func open(mac: String) async throws -> (slot: String, expiresAt: Date) {
        try call("open", mac)
        let now = clock.now()
        return try lock.withLock {
            if state.slots.count >= 3, !state.slots.contains(mac) {
                throw HostedRelayPairing.Refusal.slotsFull(macs: state.slots)
            }
            state.opened += 1
            let slot = "slot-\(state.opened)"
            state.slotMacs[slot] = mac
            return (slot, now.addingTimeInterval(600))
        }
    }

    func vouch(hubDeviceID: String, authPub: Data) async throws {
        await waitIfParked("vouch")
        try call("vouch", hubDeviceID)
    }

    func promote(slot: String) async throws {
        try call("promote", slot)
        let lost: (any Error)? = lock.withLock {
            if let mac = state.slotMacs[slot], !state.slots.contains(mac) { state.slots.append(mac) }
            defer { state.promoteAppliesThenThrows = nil }
            return state.promoteAppliesThenThrows
        }
        if let lost { throw lost }
    }

    func close(slot: String) async {
        lock.withLock { state.ops.append("close \(slot)") }
    }

    func removeSlot(mac: String) async throws {
        await waitIfParked("removeSlot")
        try call("removeSlot", mac)
        lock.withLock { state.slots.removeAll { $0 == mac } }
    }
}

/// A Mac's relay identity from a fixed seed, for v4 codes.
struct RelayTestMac {
    let authPub: Data
    let deviceID: String

    init(seed: UInt8) {
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: seed, count: 32)) else {
            preconditionFailure("test key")
        }
        authPub = key.publicKey.rawRepresentation
        deviceID = RelayIDs.deviceID(publicKey: authPub)
    }

    var authPubText: String { WireBytes.base64URL(authPub) }

    /// A v4 code for `hubID`: iCloud fields when `cloudKit`, this Mac's relay identity, `transport` as given.
    func code(
        hubID: String,
        macName: String,
        owner: String,
        now: Date,
        transport: TransportKind?,
        cloudKit: Bool = true,
        issuedAgo: TimeInterval = 10,
        identity: Bool = true
    ) -> LinkPayload {
        let iat = Int64(now.timeIntervalSince1970 - issuedAgo)
        return LinkPayload(
            v: 4,
            container: cloudKit ? WatchtowerCloud.containerID : nil,
            hubID: hubID,
            macName: macName,
            ownerUser: cloudKit ? owner : nil,
            nonce: LinkPayload.makeNonce(),
            iat: iat,
            exp: iat + LinkPayload.lifetime,
            hubSigningKey: WireBytes.base64URL(TestE2E.hubSigningKey.publicKey.rawRepresentation),
            hubAgreementKey: WireBytes.base64URL(TestE2E.hubAgreementKey.publicKey.rawRepresentation),
            transport: transport,
            transports: transport == nil ? nil : (cloudKit ? ["cloudkit", "relay"] : ["relay"]),
            relayDeviceID: identity ? deviceID : nil,
            relayAuthPub: identity ? authPubText : nil
        )
    }
}
