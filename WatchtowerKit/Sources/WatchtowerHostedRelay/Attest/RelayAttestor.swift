import Foundation
import os
import WatchtowerRelayProto

/// The relay client's time source: real time in production, `ManualRelayClock`
/// in tests.
public protocol RelayClock: Sendable {
    func now() -> Date
    func sleep(for duration: Duration) async throws
}

public struct SystemRelayClock: RelayClock {
    public init() {}

    public func now() -> Date {
        Date()
    }

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

/// Why the client cannot attest right now (proto README, "Failure paths on the client").
public enum HostedRelayAttestError: Error, Equatable, Sendable {
    /// `isSupported == false`: the relay is not offered (CloudKit stays).
    case notSupported
    /// `generateKey` / `attestKey` / assertion failed transiently.
    case retryLater(after: Duration)
    /// `ATTESTATION_REQUIRED`, or `ATTESTATION_FAILED` after the one fresh attestation.
    case updateRequired
}

/// Builds the `attestation` field of `register`, `login` and `vouch_hub` over App Attest,
/// following the client failure-path table of the relay's proto README.
///
/// The only caller of `generateAssertion`. Login and `vouch_hub` assertions share the server's
/// counter, and a later assertion reaching the server first makes the earlier one fail (proto
/// README "Client rules (phone)"), so each runs inside `withAssertionTurn`: one at a time, the
/// next generated only after the previous request was answered.
public actor RelayAttestor {
    private static let logger = Logger(subsystem: "WatchtowerKit", category: "HostedRelay")

    private let attest: any AppAttesting
    private let keys: any AppAttestKeyStore
    /// Reserved for the client's retry loop; required by the init.
    private let clock: any RelayClock
    /// Transient failures since the last success; drives `backoff(failures:)`.
    private var failures = 0
    /// The server refused an assertion: the next login forgets the stored key.
    private var forgetKeyOnNextLogin = false
    /// `serverRefusedAssertion()` was already taken since the last successful login.
    private var refusedSinceLogin = false
    /// A `withAssertionTurn` body is running.
    private var turnTaken = false
    /// The callers waiting for the turn, oldest first.
    private var turnQueue: [CheckedContinuation<Void, Never>] = []

    public init(attest: any AppAttesting, keys: any AppAttestKeyStore, clock: any RelayClock) {
        self.attest = attest
        self.keys = keys
        self.clock = clock
    }

    /// `AppAttesting.isSupported`: the client refuses before any request when false (R16).
    nonisolated public var isSupported: Bool {
        attest.isSupported
    }

    /// For `register`: a fresh attestation over `clientDataHash` (generateKey when no key is stored).
    public func registerAttestation(clientDataHash: Data) async throws -> Relay_V1_Attestation {
        guard attest.isSupported else { throw HostedRelayAttestError.notSupported }
        return try await freshAttestation(clientDataHash: clientDataHash)
    }

    /// For `login`: an assertion when a key is stored, else a fresh attestation (lost-key path).
    public func loginAttestation(clientDataHash: Data) async throws -> Relay_V1_Attestation {
        guard attest.isSupported else { throw HostedRelayAttestError.notSupported }
        if forgetKeyOnNextLogin {
            await keys.setKeyID(nil)
            forgetKeyOnNextLogin = false
        }
        guard let keyID = await keys.keyID() else {
            return try await freshAttestation(clientDataHash: clientDataHash)
        }
        do {
            let assertion = try await attest.generateAssertion(keyID, clientDataHash: clientDataHash)
            failures = 0
            var attestation = Relay_V1_Attestation()
            attestation.appAttestAssertion.assertion = assertion
            return attestation
        } catch {
            let failure = AppAttestFailure.classify(error)
            guard failure == .invalidKey else { throw transient("generateAssertion", failure) }
            Self.logger.info("app attest generateAssertion: invalid key, attesting a new one")
            await keys.setKeyID(nil)
            return try await freshAttestation(clientDataHash: clientDataHash)
        }
    }

    /// For `vouch_hub`: an assertion by the stored key over the vouch `clientDataHash`. Called inside
    /// `withAssertionTurn`. No stored key, or `invalidKey` (the key is then discarded), throws
    /// `NoAssertionKey`: the caller logs in again, which attests afresh (lost-key path), and retries.
    public func vouchAssertion(clientDataHash: Data) async throws -> Relay_V1_Attestation {
        guard attest.isSupported else { throw HostedRelayAttestError.notSupported }
        guard let keyID = await keys.keyID() else { throw NoAssertionKey() }
        do {
            let assertion = try await attest.generateAssertion(keyID, clientDataHash: clientDataHash)
            failures = 0
            var attestation = Relay_V1_Attestation()
            attestation.appAttestAssertion.assertion = assertion
            return attestation
        } catch {
            let failure = AppAttestFailure.classify(error)
            guard failure == .invalidKey else { throw transient("generateAssertion", failure) }
            Self.logger.info("app attest generateAssertion: invalid key, attesting a new one at the next login")
            await keys.setKeyID(nil)
            throw NoAssertionKey()
        }
    }

    /// Runs `body` (an assertion and the request that carries it) when no other body runs, in the
    /// order the callers came. The body must not wait for another turn (a login inside a vouch's
    /// turn would wait forever).
    public func withAssertionTurn<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        if turnTaken {
            await withCheckedContinuation { turnQueue.append($0) }
        } else {
            turnTaken = true
        }
        defer { passTurn() }
        return try await body()
    }

    /// Callers waiting for the turn (tests).
    var turnWaiters: Int {
        turnQueue.count
    }

    /// Hands the turn to the oldest waiter, or frees it.
    private func passTurn() {
        if turnQueue.isEmpty {
            turnTaken = false
        } else {
            turnQueue.removeFirst().resume()
        }
    }

    /// The server answered ATTESTATION_FAILED to an assertion login (or to a second `vouch_hub`): forget the key so
    /// the next login attests afresh.
    /// Returns false when this already happened once since the last successful login (→ updateRequired).
    public func serverRefusedAssertion() -> Bool {
        guard !refusedSinceLogin else { return false }
        refusedSinceLogin = true
        forgetKeyOnNextLogin = true
        return true
    }

    public func loginSucceeded() {
        refusedSinceLogin = false
    }

    /// Backoff for transient failures: 1 s doubling to 5 min (proto README).
    public static func backoff(failures: Int) -> Duration {
        let exponent = min(max(failures, 1) - 1, 9)
        return .seconds(min(1 << exponent, 300))
    }

    /// generateKey when no key is stored, then attestKey; an `invalidKey`
    /// discards the key and tries once more with a new one.
    private func freshAttestation(clientDataHash: Data) async throws -> Relay_V1_Attestation {
        var regenerated = false
        while true {
            let keyID = try await storedOrNewKey()
            do {
                guard let keyBytes = Data(base64Encoded: keyID) else { throw AppAttestFailure.invalidKey }
                let object = try await attest.attestKey(keyID, clientDataHash: clientDataHash)
                failures = 0
                var attestation = Relay_V1_Attestation()
                attestation.appAttest.keyID = keyBytes
                attestation.appAttest.attestationObject = object
                return attestation
            } catch {
                let failure = AppAttestFailure.classify(error)
                // An invalid key is never reused; serverUnavailable keeps it (Apple: reuse the key).
                if failure == .invalidKey { await keys.setKeyID(nil) }
                guard failure == .invalidKey, !regenerated else { throw transient("attestKey", failure) }
                Self.logger.info("app attest attestKey: invalid key, generating a new one")
                regenerated = true
            }
        }
    }

    private func storedOrNewKey() async throws -> String {
        if let keyID = await keys.keyID() { return keyID }
        do {
            let keyID = try await attest.generateKey()
            await keys.setKeyID(keyID)
            return keyID
        } catch {
            throw transient("generateKey", AppAttestFailure.classify(error))
        }
    }

    /// Counts a transient failure and turns it into `.retryLater`.
    private func transient(_ op: String, _ failure: AppAttestFailure) -> HostedRelayAttestError {
        failures += 1
        Self.logger.error("app attest \(op, privacy: .public) failed: \(Self.code(failure), privacy: .public), failures \(self.failures)")
        return .retryLater(after: Self.backoff(failures: failures))
    }

    private static func code(_ failure: AppAttestFailure) -> String {
        switch failure {
        case .invalidKey: return "invalid_key"
        case .serverUnavailable: return "server_unavailable"
        case .other(let code): return code
        }
    }
}

/// `vouchAssertion` has no key to assert with: log in afresh (lost-key path), then vouch again.
struct NoAssertionKey: Error {}
