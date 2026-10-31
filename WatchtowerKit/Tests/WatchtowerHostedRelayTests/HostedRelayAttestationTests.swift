import CryptoKit
import Foundation
import WatchtowerHostedRelay
import WatchtowerHostedRelayTesting
import WatchtowerRelayProto
import XCTest

/// The relay's "Attestation scenarios for the Swift client" (`sim/README.md`),
/// one per row of the client failure-path table in `proto/README.md`, at the
/// client's level: what goes over the wire and what the caller sees.
final class HostedRelayAttestationTests: XCTestCase {
    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private enum Kind: Equatable {
        case none, appAttest, assertion
    }

    private func kinds(_ harness: RelayClientHarness) -> [Kind] {
        harness.http.requests("login").map { recorded in
            switch recorded.request.login.attestation.kind {
            case .appAttest: return .appAttest
            case .appAttestAssertion: return .assertion
            case nil: return .none
            }
        }
    }

    func testAttestUnsupportedRefusesBeforeAnyRequest() async throws {
        let harness = try RelayClientHarness()
        harness.fake.isSupported = false
        await assertRelayError(.attestation(.notSupported)) { _ = try await harness.client.register() }
        await assertRelayError(.attestation(.notSupported)) { try await harness.client.login() }
        await assertRelayError(.attestation(.notSupported)) {
            _ = try await harness.client.perform(RelayClientHarness.removeSlot)
        }
        XCTAssertEqual(harness.http.ops, [])
        XCTAssertEqual(harness.fake.calls, [])
    }

    func testGenerateKeyFailsBacksOff() async throws {
        let harness = try RelayClientHarness(storedKey: false)
        harness.fake.script(.generateKey, failures: [.other("dc_0"), .serverUnavailable])
        await assertRelayError(.attestation(.retryLater(after: .seconds(1)))) { _ = try await harness.client.register() }
        await assertRelayError(.attestation(.retryLater(after: .seconds(2)))) { _ = try await harness.client.register() }
        // No register goes out without an attestation; the caller owns the retry (CloudKit meanwhile).
        XCTAssertEqual(harness.http.ops, ["challenge", "challenge"])
        XCTAssertEqual(harness.clock.sleeps, [])

        _ = try await harness.client.register()
        XCTAssertEqual(harness.http.ops, ["challenge", "challenge", "challenge", "register"])
        XCTAssertEqual(harness.fake.calls, ["generateKey", "generateKey", "generateKey", "attestKey"])
    }

    func testAttestKeyServerUnavailableRetriesSameKey() async throws {
        let harness = try RelayClientHarness(storedKey: false)
        harness.fake.script(.attestKey, failures: [.serverUnavailable])
        await assertRelayError(.attestation(.retryLater(after: .seconds(1)))) { _ = try await harness.client.register() }
        let firstKeyStored = await harness.keys.keyID()
        let firstKey = try XCTUnwrap(firstKeyStored)

        _ = try await harness.client.register()
        XCTAssertEqual(harness.fake.calls, ["generateKey", "attestKey", "attestKey"])
        let register = try XCTUnwrap(harness.http.requests("register").last).request.register
        XCTAssertEqual(register.attestation.appAttest.keyID, Data(base64Encoded: firstKey))
    }

    func testInvalidKeyRegeneratesAndAttests() async throws {
        let harness = try RelayClientHarness()
        let oldKeyStored = await harness.keys.keyID()
        let oldKey = try XCTUnwrap(oldKeyStored)
        harness.fake.script(.generateAssertion, failures: [.invalidKey])
        try await harness.client.login()

        XCTAssertEqual(harness.fake.calls, ["generateAssertion", "generateKey", "attestKey"])
        XCTAssertEqual(kinds(harness), [.appAttest])
        let login = try XCTUnwrap(harness.http.requests("login").first).request.login
        XCTAssertNotEqual(login.attestation.appAttest.keyID, Data(base64Encoded: oldKey))
        let object = try json(login.attestation.appAttest.attestationObject)
        let hash = RelayAuthMessages.loginClientDataHash(nonce: ScriptedRelayHTTP.nonce, deviceID: harness.client.deviceID, origin: harness.origin)
        XCTAssertEqual(object["client_data_hash"] as? String, hash.base64EncodedString())
    }

    func testAssertionFailsRetriesLogin() async throws {
        let harness = try RelayClientHarness()
        try await harness.client.login()
        let first = try XCTUnwrap(harness.http.requests("login").first).request.login
        let hash = RelayAuthMessages.loginClientDataHash(nonce: ScriptedRelayHTTP.nonce, deviceID: harness.client.deviceID, origin: harness.origin)
        let assertion = try json(first.attestation.appAttestAssertion.assertion)
        XCTAssertEqual(assertion["client_data_hash"] as? String, hash.base64EncodedString())
        let message = RelayAuthMessages.loginMessage(nonce: ScriptedRelayHTTP.nonce, deviceID: harness.client.deviceID, origin: harness.origin)
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: harness.signer.publicKey)
        XCTAssertTrue(key.isValidSignature(first.signature, for: message))

        // A transient assertion failure: retry later, no login request sent.
        harness.fake.script(.generateAssertion, failures: [.other("dc_0"), .other("dc_0")])
        await assertRelayError(.attestation(.retryLater(after: .seconds(1)))) { try await harness.client.login() }
        XCTAssertEqual(harness.http.requests("login").count, 1)

        // The session in hand keeps serving ops ...
        _ = try await harness.client.perform(RelayClientHarness.removeSlot)
        XCTAssertEqual(harness.http.requests("removeSlot").last?.headers["Authorization"], "Bearer token-1")

        // ... until the relay refuses it: then the relogin's assertion failure is returned.
        harness.http.script("removeSlot", [.error(.unauthenticated, status: 401)])
        await assertRelayError(.attestation(.retryLater(after: .seconds(2)))) {
            _ = try await harness.client.perform(RelayClientHarness.removeSlot)
        }
        XCTAssertEqual(harness.http.requests("login").count, 1)
        XCTAssertEqual(harness.clock.sleeps, [])
    }

    func testAttestationFailedOnLoginReattestsOnce() async throws {
        // ATTESTATION_FAILED on an assertion: one login with a fresh app_attest, and it works.
        let recovering = try RelayClientHarness()
        recovering.http.script("login", [.error(.attestationFailed)])
        try await recovering.client.login()
        XCTAssertEqual(kinds(recovering), [.assertion, .appAttest])

        // Refused again: "update the app", never a loop.
        let harness = try RelayClientHarness()
        harness.http.script("login", Array(repeating: .error(.attestationFailed), count: 5))
        await assertRelayError(.attestation(.updateRequired)) { try await harness.client.login() }
        XCTAssertEqual(kinds(harness), [.assertion, .appAttest])

        // The next login asserts with the new key; serverRefusedAssertion() says no → update.
        await assertRelayError(.attestation(.updateRequired)) {
            _ = try await harness.client.perform(RelayClientHarness.removeSlot)
        }
        XCTAssertEqual(kinds(harness), [.assertion, .appAttest, .assertion])
        XCTAssertEqual(harness.http.requests("removeSlot").count, 0)
        XCTAssertEqual(harness.clock.sleeps, [])
    }

    func testAttestationRequiredShowsUpdate() async throws {
        let harness = try RelayClientHarness()
        harness.http.script("login", [.error(.attestationRequired)])
        await assertRelayError(.attestation(.updateRequired)) {
            _ = try await harness.client.perform(RelayClientHarness.removeSlot)
        }
        XCTAssertEqual(harness.http.ops, ["challenge", "login"])

        let registering = try RelayClientHarness(storedKey: false)
        registering.http.script("register", [.error(.attestationRequired)])
        await assertRelayError(.attestation(.updateRequired)) { _ = try await registering.client.register() }
        XCTAssertEqual(registering.http.ops, ["challenge", "register"])
        XCTAssertEqual(harness.clock.sleeps + registering.clock.sleeps, [])
    }

    func testRegisterSendsPurposeRegisterAndSignature() async throws {
        let harness = try RelayClientHarness(storedKey: false)
        _ = try await harness.client.register()

        XCTAssertEqual(harness.http.ops, ["challenge", "register"])
        XCTAssertEqual(try XCTUnwrap(harness.http.requests.first).request.challenge.purpose, .register)
        let register = try XCTUnwrap(harness.http.requests.last).request.register
        XCTAssertEqual(register.deviceKind, .phone)
        XCTAssertEqual(register.authPub, harness.signer.publicKey)
        XCTAssertEqual(register.nonce, ScriptedRelayHTTP.nonce)

        let hash = RelayAuthMessages.registerClientDataHash(nonce: ScriptedRelayHTTP.nonce, authPub: harness.signer.publicKey, origin: harness.origin)
        let storedKeyStored = await harness.keys.keyID()
        let storedKey = try XCTUnwrap(storedKeyStored)
        XCTAssertEqual(register.attestation.appAttest.keyID, Data(base64Encoded: storedKey))
        let object = try json(register.attestation.appAttest.attestationObject)
        XCTAssertEqual(object["client_data_hash"] as? String, hash.base64EncodedString())
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: register.authPub)
        XCTAssertTrue(key.isValidSignature(register.signature, for: hash))
    }

    func testAttestationFailedOnRegisterShowsUpdate() async throws {
        // A register always carries a fresh attestation: a refusal is "update the app", no retry.
        let harness = try RelayClientHarness(storedKey: false)
        harness.http.script("register", [.error(.attestationFailed)])
        await assertRelayError(.attestation(.updateRequired)) { _ = try await harness.client.register() }
        XCTAssertEqual(harness.http.ops, ["challenge", "register"])
        XCTAssertEqual(harness.clock.sleeps, [])
    }
}
