#if canImport(DeviceCheck)
import DeviceCheck
#endif
import Foundation
import WatchtowerHostedRelay
import WatchtowerHostedRelayTesting
import WatchtowerRelayProto
import XCTest

final class RelayAttestorTests: XCTestCase {
    private let registerHash = Data(repeating: 0xA1, count: 32)
    private let loginHash = Data(repeating: 0xB2, count: 32)

    private func makeAttestor(
        _ fake: FakeAppAttest,
        keys: InMemoryAppAttestKeyStore = InMemoryAppAttestKeyStore()
    ) -> RelayAttestor {
        RelayAttestor(attest: fake, keys: keys, clock: ManualRelayClock())
    }

    private func appAttest(_ attestation: Relay_V1_Attestation) throws -> Relay_V1_AppAttest {
        guard case .appAttest(let value) = attestation.kind else {
            throw XCTSkip("expected app_attest, got \(String(describing: attestation.kind))")
        }
        return value
    }

    private func storedKey(_ keys: InMemoryAppAttestKeyStore, _ message: String = "a key id is stored") async throws -> String {
        let keyID = await keys.keyID()
        return try XCTUnwrap(keyID, message)
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func assertThrows(
        _ expected: HostedRelayAttestError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected), nothing thrown", file: file, line: line)
        } catch let error as HostedRelayAttestError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }

    func testAttestUnsupportedRefusesBeforeAnyCall() async {
        let fake = FakeAppAttest()
        fake.isSupported = false
        let attestor = makeAttestor(fake, keys: InMemoryAppAttestKeyStore(keyID: fake.makeKeyID()))
        await assertThrows(.notSupported) { _ = try await attestor.registerAttestation(clientDataHash: self.registerHash) }
        await assertThrows(.notSupported) { _ = try await attestor.loginAttestation(clientDataHash: self.loginHash) }
        XCTAssertEqual(fake.calls, [])
    }

    func testGenerateKeyFailsBacksOff() async throws {
        let fake = FakeAppAttest()
        fake.script(.generateKey, failures: [.other("dc_0"), .serverUnavailable, .other("unknown")])
        let attestor = makeAttestor(fake)
        await assertThrows(.retryLater(after: .seconds(1))) { _ = try await attestor.registerAttestation(clientDataHash: self.registerHash) }
        await assertThrows(.retryLater(after: .seconds(2))) { _ = try await attestor.registerAttestation(clientDataHash: self.registerHash) }
        await assertThrows(.retryLater(after: .seconds(4))) { _ = try await attestor.registerAttestation(clientDataHash: self.registerHash) }
        XCTAssertEqual(RelayAttestor.backoff(failures: 20), .seconds(300))
        XCTAssertEqual(RelayAttestor.backoff(failures: 9), .seconds(256))
        XCTAssertEqual(RelayAttestor.backoff(failures: 10), .seconds(300))

        // A success resets the count: the next failure waits 1 s again.
        _ = try await attestor.registerAttestation(clientDataHash: registerHash)
        fake.script(.attestKey, failures: [.serverUnavailable])
        await assertThrows(.retryLater(after: .seconds(1))) { _ = try await attestor.registerAttestation(clientDataHash: self.registerHash) }
    }

    func testAttestKeyServerUnavailableRetriesSameKey() async throws {
        let fake = FakeAppAttest()
        fake.script(.attestKey, failures: [.serverUnavailable])
        let keys = InMemoryAppAttestKeyStore()
        let attestor = makeAttestor(fake, keys: keys)

        await assertThrows(.retryLater(after: .seconds(1))) { _ = try await attestor.registerAttestation(clientDataHash: self.registerHash) }
        let kept = try await storedKey(keys, "the key survives serverUnavailable")

        let value = try appAttest(try await attestor.registerAttestation(clientDataHash: registerHash))
        XCTAssertEqual(value.keyID, Data(base64Encoded: kept))
        let object = try json(value.attestationObject)
        XCTAssertEqual(object["key_id"] as? String, kept)
        XCTAssertEqual(object["client_data_hash"] as? String, registerHash.base64EncodedString())
        XCTAssertEqual(object["app_id"] as? String, "acme.test")
        XCTAssertEqual(object["fake_app_attest"] as? Int, 1)
        XCTAssertEqual(fake.calls, ["generateKey", "attestKey", "attestKey"])
        let stored = await keys.keyID()
        XCTAssertEqual(stored, kept)
    }

    func testInvalidKeyRegeneratesAndAttests() async throws {
        // attestKey: invalidKey once → a new key, attested and stored.
        let fake = FakeAppAttest()
        let old = fake.makeKeyID()
        let keys = InMemoryAppAttestKeyStore(keyID: old)
        fake.script(.attestKey, failures: [.invalidKey])
        let attestor = makeAttestor(fake, keys: keys)
        let value = try appAttest(try await attestor.registerAttestation(clientDataHash: registerHash))
        let fresh = try await storedKey(keys)
        XCTAssertNotEqual(fresh, old)
        XCTAssertEqual(value.keyID, Data(base64Encoded: fresh))
        XCTAssertEqual(fake.calls, ["attestKey", "generateKey", "attestKey"])

        // generateAssertion: invalidKey → the lost-key path, a fresh attestation over the login hash.
        let fake2 = FakeAppAttest()
        let old2 = fake2.makeKeyID()
        let keys2 = InMemoryAppAttestKeyStore(keyID: old2)
        fake2.script(.generateAssertion, failures: [.invalidKey])
        let attestor2 = makeAttestor(fake2, keys: keys2)
        let value2 = try appAttest(try await attestor2.loginAttestation(clientDataHash: loginHash))
        let fresh2 = try await storedKey(keys2)
        XCTAssertNotEqual(fresh2, old2)
        XCTAssertEqual(value2.keyID, Data(base64Encoded: fresh2))
        XCTAssertEqual(try json(value2.attestationObject)["client_data_hash"] as? String, loginHash.base64EncodedString())
        XCTAssertEqual(fake2.calls, ["generateAssertion", "generateKey", "attestKey"])

        // A second invalidKey within the same call is transient.
        let fake3 = FakeAppAttest()
        fake3.script(.attestKey, failures: [.invalidKey, .invalidKey])
        let attestor3 = makeAttestor(fake3)
        await assertThrows(.retryLater(after: .seconds(1))) { _ = try await attestor3.registerAttestation(clientDataHash: self.registerHash) }
        XCTAssertEqual(fake3.calls, ["generateKey", "attestKey", "generateKey", "attestKey"])
    }

    func testLoginWithoutAStoredKeyAttestsAfresh() async throws {
        let fake = FakeAppAttest()
        let keys = InMemoryAppAttestKeyStore()
        let attestor = makeAttestor(fake, keys: keys)
        let value = try appAttest(try await attestor.loginAttestation(clientDataHash: loginHash))
        XCTAssertEqual(try json(value.attestationObject)["client_data_hash"] as? String, loginHash.base64EncodedString())
        let stored = try await storedKey(keys)
        XCTAssertEqual(value.keyID, Data(base64Encoded: stored))
        XCTAssertEqual(fake.calls, ["generateKey", "attestKey"])

        // With the key now stored, the next login is an assertion with a rising counter.
        for counter in 1...2 {
            let next = try await attestor.loginAttestation(clientDataHash: loginHash)
            guard case .appAttestAssertion(let assertion) = next.kind else {
                return XCTFail("expected an assertion, got \(String(describing: next.kind))")
            }
            let body = try json(assertion.assertion)
            XCTAssertEqual(body["key_id"] as? String, stored)
            XCTAssertEqual(body["client_data_hash"] as? String, loginHash.base64EncodedString())
            XCTAssertEqual(body["counter"] as? Int, counter)
        }
    }

    func testServerRefusedAssertionAllowsOneFreshAttestation() async throws {
        let fake = FakeAppAttest()
        let old = fake.makeKeyID()
        let keys = InMemoryAppAttestKeyStore(keyID: old)
        let attestor = makeAttestor(fake, keys: keys)

        let refused = await attestor.serverRefusedAssertion()
        XCTAssertTrue(refused)
        let value = try appAttest(try await attestor.loginAttestation(clientDataHash: loginHash))
        let fresh = try await storedKey(keys)
        XCTAssertNotEqual(fresh, old, "the refused key is forgotten")
        XCTAssertEqual(value.keyID, Data(base64Encoded: fresh))
        XCTAssertEqual(fake.calls, ["generateKey", "attestKey"])

        let again = await attestor.serverRefusedAssertion()
        XCTAssertFalse(again, "a second refusal before a successful login means update the app")

        await attestor.loginSucceeded()
        let afterSuccess = await attestor.serverRefusedAssertion()
        XCTAssertTrue(afterSuccess)
    }

    #if canImport(DeviceCheck)
    func testDeviceCheckErrorsAreClassified() {
        XCTAssertEqual(AppAttestFailure.classify(DCError(.invalidKey)), .invalidKey)
        XCTAssertEqual(AppAttestFailure.classify(DCError(.serverUnavailable)), .serverUnavailable)
        XCTAssertEqual(AppAttestFailure.classify(URLError(.notConnectedToInternet)), .serverUnavailable)
        XCTAssertEqual(AppAttestFailure.classify(DCError(.featureUnsupported)), .other("dc_1"))
        XCTAssertEqual(AppAttestFailure.classify(DCError(.unknownSystemFailure)), .other("dc_0"))
        XCTAssertEqual(AppAttestFailure.classify(NSError(domain: "acme.test", code: 7)), .other("unknown"))
    }
    #endif

    func testManualClockSleepsUntilAdvanced() async throws {
        let clock = ManualRelayClock(now: Date(timeIntervalSince1970: 1_000))
        let woke = expectation(description: "woke")
        let task = Task {
            try await clock.sleep(for: .seconds(5))
            woke.fulfill()
        }
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(4))
        XCTAssertEqual(clock.now(), Date(timeIntervalSince1970: 1_004))
        clock.advance(by: .seconds(1))
        await fulfillment(of: [woke], timeout: 2)
        try await task.value

        let cancelled = Task { try await clock.sleep(for: .seconds(60)) }
        await clock.waitForSleepers(1)
        cancelled.cancel()
        do {
            try await cancelled.value
            XCTFail("a cancelled sleep throws")
        } catch is CancellationError {
        }
        XCTAssertEqual(clock.sleeperCount, 0)
    }
}
