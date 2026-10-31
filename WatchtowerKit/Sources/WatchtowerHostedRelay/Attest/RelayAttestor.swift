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

/// Builds the `attestation` field of `register` and `login` over App Attest,
/// following the client failure-path table of the relay's proto README.
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

    public init(attest: any AppAttesting, keys: any AppAttestKeyStore, clock: any RelayClock) {
        self.attest = attest
        self.keys = keys
        self.clock = clock
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

    /// The server answered ATTESTATION_FAILED to an assertion login: forget the key so the next login attests afresh.
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
