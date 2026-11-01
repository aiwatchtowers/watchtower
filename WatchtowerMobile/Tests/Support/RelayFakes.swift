import Foundation
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
