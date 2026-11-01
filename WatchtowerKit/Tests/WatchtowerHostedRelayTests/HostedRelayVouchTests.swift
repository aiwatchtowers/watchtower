import Foundation
@testable import WatchtowerHostedRelay
import WatchtowerHostedRelayTesting
import WatchtowerRelayProto
import XCTest

/// `vouch_hub` on the phone (relay `proto/README.md` "Vouched hubs"): `HostedRelayPairing.vouch`
/// (GetChallenge{VOUCH} → assertion → `vouch_hub`, the client-rules retries) and the fake's vouch
/// model (the six checks in order, the 10-minute pending vouch, `HUB_NOT_VOUCHED`, the hub gate).
/// Scenarios that need the fake's faults, clock or attestation run on the fake only (R15).
class HostedRelayVouchTests: HostedRelayScenarioCase {
    static let r15 = "needs the fake's faults, clock or attestation (fake only, R15)"

    // MARK: - Helpers

    private struct Hub {
        let client: HostedRelayClient
        let authPub: Data

        var id: String {
            client.deviceID
        }
    }

    /// A Mac on the relay (registered and logged in unless `register` is false); it holds no slot.
    private func hub(seed: UInt8, register: Bool = true) async throws -> Hub {
        let client = try await makeClient(kind: .mac, seed: seed, register: register)
        return Hub(client: client, authPub: try backend.signer(seed: seed).publicKey)
    }

    /// A phone (paying unless told otherwise) with its App Attest key store in hand.
    private func phone(seed: UInt8 = 2, paying: Bool = true) async throws -> (HostedRelayClient, InMemoryAppAttestKeyStore) {
        let keys = InMemoryAppAttestKeyStore()
        let client = try await makeClient(kind: .phone, seed: seed, keys: keys)
        if paying { try await pay(client) }
        return (client, keys)
    }

    private func pairing(_ phone: HostedRelayClient) -> HostedRelayPairing {
        HostedRelayPairing(session: HostedRelaySession(client: phone))
    }

    private func names(since mark: Int) -> [String] {
        backend.opLog.dropFirst(mark).map { HostedRelayClient.name($0) }
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func assertVouchRefusal(
        _ expected: HostedRelayPairing.VouchRefusal, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("no refusal, expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? HostedRelayPairing.VouchRefusal, expected, "\(error)", file: file, line: line)
        }
    }

    /// A `vouch_hub` the test builds itself, sent as it is.
    private func rawVouch(_ phone: HostedRelayClient, _ hub: Hub, nonce: Data, attestation: Relay_V1_Attestation? = nil) async throws {
        var vouch = Relay_V1_VouchHub()
        vouch.hubDeviceID = hub.id
        vouch.authPub = hub.authPub
        vouch.nonce = nonce
        if let attestation { vouch.attestation = attestation }
        _ = try await phone.perform(.vouchHub(vouch))
    }

    private func addSlot(_ phone: HostedRelayClient, _ hub: Hub) async throws {
        var add = Relay_V1_AddMacSlot()
        add.macDeviceID = hub.id
        try await phone.addSlot(add)
    }

    // MARK: - The phone's flow

    func testVouchSendsAVouchChallengeThenTheAssertion() async throws {
        let (phone, keys) = try await phone()
        let hub = try await hub(seed: 1)
        let mark = backend.opLog.count
        try await pairing(phone).vouch(hubDeviceID: hub.id, authPub: hub.authPub)

        XCTAssertEqual(names(since: mark), ["challenge", "vouchHub"])
        let ops = Array(backend.opLog.dropFirst(mark))
        guard case .challenge(let challenge) = ops[0], case .vouchHub(let vouch) = ops[1] else { return XCTFail("ops \(ops)") }
        XCTAssertEqual(challenge.purpose, .vouch)
        XCTAssertEqual(challenge.deviceID, phone.deviceID)
        XCTAssertEqual(vouch.hubDeviceID, hub.id)
        XCTAssertEqual(vouch.authPub, hub.authPub)
        XCTAssertFalse(vouch.nonce.isEmpty)
        let assertion = try json(vouch.attestation.appAttestAssertion.assertion)
        let hash = RelayAuthMessages.vouchClientDataHash(nonce: vouch.nonce, hubDeviceID: hub.id, authPub: hub.authPub, origin: try backend.origin)
        XCTAssertEqual(assertion["client_data_hash"] as? String, hash.base64EncodedString())
        let keyID = await keys.keyID()
        XCTAssertEqual(assertion["key_id"] as? String, keyID)
    }

    func testEveryRetryTakesANewNonceAndAssertion() async throws {
        let relay = try requireFake(Self.r15)
        let (phone, _) = try await phone()
        let hub = try await hub(seed: 1)
        relay.failNext("vouchHub", with: .attestationFailed)
        let mark = backend.opLog.count
        try await pairing(phone).vouch(hubDeviceID: hub.id, authPub: hub.authPub)

        XCTAssertEqual(names(since: mark), ["challenge", "vouchHub", "challenge", "vouchHub"])
        let vouches = backend.opLog.dropFirst(mark).compactMap { op -> Relay_V1_VouchHub? in
            guard case .vouchHub(let vouch) = op else { return nil }
            return vouch
        }
        XCTAssertNotEqual(vouches[0].nonce, vouches[1].nonce, "a new VOUCH nonce")
        let counters = try vouches.map { try json($0.attestation.appAttestAssertion.assertion)["counter"] as? Int }
        XCTAssertEqual(counters.count, 2)
        XCTAssertLessThan(try XCTUnwrap(counters[0]), try XCTUnwrap(counters[1]), "a new assertion")
        // The second vouch held: add_slot goes through.
        try await addSlot(phone, hub)
    }

    func testAttestationFailedRetriesOnceThenLostKeyThenOnceMoreThenUpdate() async throws {
        let relay = try requireFake(Self.r15)
        let (phone, _) = try await phone()
        let hub = try await hub(seed: 1)
        let attest = fakeAttest(seed: 2)
        relay.failNext("vouchHub", with: .attestationFailed, times: 3)
        let mark = backend.opLog.count
        let callMark = attest.calls.count
        await assertVouchRefusal(.updateRequired) { try await self.pairing(phone).vouch(hubDeviceID: hub.id, authPub: hub.authPub) }

        XCTAssertEqual(names(since: mark), ["challenge", "vouchHub", "challenge", "vouchHub", "challenge", "login", "challenge", "vouchHub"])
        let login = backend.opLog.dropFirst(mark).compactMap { op -> Relay_V1_Login? in
            guard case .login(let login) = op else { return nil }
            return login
        }
        guard case .appAttest = login.first?.attestation.kind else { return XCTFail("the lost-key login attests afresh") }
        XCTAssertEqual(
            Array(attest.calls.dropFirst(callMark)),
            ["generateAssertion", "generateAssertion", "generateKey", "attestKey", "generateAssertion"]
        )

        // The lost-key login succeeded, so the next vouch may take the path once again: two
        // failures, a fresh login, and the third attempt goes through.
        relay.failNext("vouchHub", with: .attestationFailed, times: 2)
        let again = backend.opLog.count
        try await pairing(phone).vouch(hubDeviceID: hub.id, authPub: hub.authPub)
        XCTAssertEqual(names(since: again), ["challenge", "vouchHub", "challenge", "vouchHub", "challenge", "login", "challenge", "vouchHub"])
        try await addSlot(phone, hub)
    }

    func testAttestationRequiredIsUpdateRequired() async throws {
        let relay = try requireFake(Self.r15)
        let (phone, _) = try await phone()
        let hub = try await hub(seed: 1)
        relay.failNext("vouchHub", with: .attestationRequired)
        let mark = backend.opLog.count
        await assertVouchRefusal(.updateRequired) { try await self.pairing(phone).vouch(hubDeviceID: hub.id, authPub: hub.authPub) }
        XCTAssertEqual(names(since: mark), ["challenge", "vouchHub"], "no retry")
    }

    func testEntitlementInactiveIsNotPaying() async throws {
        let (phone, _) = try await phone(paying: false)
        let hub = try await hub(seed: 1)
        let mark = backend.opLog.count
        await assertVouchRefusal(.notPaying) { try await self.pairing(phone).vouch(hubDeviceID: hub.id, authPub: hub.authPub) }
        XCTAssertEqual(names(since: mark), ["challenge", "vouchHub"], "no retry")
    }

    func testNotFoundIsHubNotOnRelay() async throws {
        let (phone, _) = try await phone()
        let unregistered = try await hub(seed: 1, register: false)
        let mark = backend.opLog.count
        await assertVouchRefusal(.hubNotOnRelay) {
            try await self.pairing(phone).vouch(hubDeviceID: unregistered.id, authPub: unregistered.authPub)
        }
        XCTAssertEqual(names(since: mark), ["challenge", "vouchHub"], "no retry")

        // A registered hub named with another key is not found either.
        let registered = try await hub(seed: 3)
        await assertVouchRefusal(.hubNotOnRelay) {
            try await self.pairing(phone).vouch(hubDeviceID: registered.id, authPub: unregistered.authPub)
        }
    }

    func testSlotLimitIsSlotsFull() async throws {
        let (phone, _) = try await phone()
        for seed in UInt8(10)..<13 {
            let slotted = try await hub(seed: seed)
            try await stand.pair(mac: slotted.id, phones: [phone.deviceID])
        }
        let fourth = try await hub(seed: 13)
        let mark = backend.opLog.count
        await assertVouchRefusal(.slotsFull) { try await self.pairing(phone).vouch(hubDeviceID: fourth.id, authPub: fourth.authPub) }
        XCTAssertEqual(names(since: mark), ["challenge", "vouchHub"], "no retry")
    }

    func testForbiddenIsNotConfirmed() async throws {
        let relay = try requireFake(Self.r15)
        let (phone, _) = try await phone()
        let hub = try await hub(seed: 1)
        relay.failNext("vouchHub", with: .forbidden)
        await assertVouchRefusal(.notConfirmed) { try await self.pairing(phone).vouch(hubDeviceID: hub.id, authPub: hub.authPub) }
    }

    /// No answer, or App Attest failing for now: thrown, and the caller's next attempt takes a
    /// new nonce and a new assertion.
    func testTransientFailuresLeaveTheNextAttemptToTheCaller() async throws {
        let relay = try requireFake(Self.r15)
        let clock = try XCTUnwrap(manualClock)
        let (phone, _) = try await phone()
        let hub = try await hub(seed: 1)
        let pairer = pairing(phone)

        fakeAttest(seed: 2).script(.generateAssertion, failures: [.other("dc_0")])
        let mark = backend.opLog.count
        await assertVouchRefusal(.attestationBackoff(until: clock.now().addingTimeInterval(1))) {
            try await pairer.vouch(hubDeviceID: hub.id, authPub: hub.authPub)
        }
        XCTAssertEqual(names(since: mark), ["challenge"], "no vouch_hub without an assertion")

        relay.crashAfterNext("vouchHub")
        await assertVouchRefusal(.unreachable) { try await pairer.vouch(hubDeviceID: hub.id, authPub: hub.authPub) }
        relay.restart()
        let again = backend.opLog.count
        try await pairer.vouch(hubDeviceID: hub.id, authPub: hub.authPub)
        XCTAssertEqual(names(since: again), ["challenge", "vouchHub"])
        let nonces = backend.opLog.compactMap { op -> Data? in
            guard case .vouchHub(let vouch) = op else { return nil }
            return vouch.nonce
        }
        XCTAssertEqual(Set(nonces).count, nonces.count, "every attempt has its own nonce")
    }

    /// The fake fails several checks at once; the first of FORBIDDEN → ENTITLEMENT_INACTIVE →
    /// ATTESTATION_REQUIRED → ATTESTATION_FAILED → NOT_FOUND → SLOT_LIMIT is answered.
    func testRefusalsComeInTheServersOrder() async throws {
        _ = try requireFake(Self.r15)
        let (phone, keys) = try await phone()
        for seed in UInt8(10)..<13 {
            let slotted = try await hub(seed: seed)
            try await stand.pair(mac: slotted.id, phones: [phone.deviceID])
        }
        let unregistered = try await hub(seed: 1, register: false)
        let fourth = try await hub(seed: 13)

        // 1. A hub's session: FORBIDDEN, although nothing else holds either.
        await assertRelayError(.server(code: .forbidden, retryAfter: nil)) {
            try await self.rawVouch(fourth.client, unregistered, nonce: Data(count: 32))
        }
        // 2. Not paying, no attestation, an unknown hub, slots full: ENTITLEMENT_INACTIVE.
        let account = try await stand.accountID(ofPhone: phone.deviceID)
        try await stand.setEntitlement(accountID: account, state: "expired", for: .zero)
        let first = try await phone.challenge(purpose: .vouch)
        await assertRelayError(.server(code: .entitlementInactive, retryAfter: nil)) {
            try await self.rawVouch(phone, unregistered, nonce: first)
        }
        try await pay(phone)
        // 3. No attestation: ATTESTATION_REQUIRED.
        let second = try await phone.challenge(purpose: .vouch)
        await assertRelayError(.server(code: .attestationRequired, retryAfter: nil)) {
            try await self.rawVouch(phone, unregistered, nonce: second)
        }
        // 4. An assertion over a LOGIN nonce: ATTESTATION_FAILED.
        let loginNonce = try await phone.challenge(purpose: .login)
        let hash = RelayAuthMessages.vouchClientDataHash(
            nonce: loginNonce, hubDeviceID: unregistered.id, authPub: unregistered.authPub, origin: try backend.origin
        )
        let storedKey = await keys.keyID()
        var attestation = Relay_V1_Attestation()
        attestation.appAttestAssertion.assertion = try await fakeAttest(seed: 2).generateAssertion(try XCTUnwrap(storedKey), clientDataHash: hash)
        await assertRelayError(.server(code: .attestationFailed, retryAfter: nil)) {
            try await self.rawVouch(phone, unregistered, nonce: loginNonce, attestation: attestation)
        }
        // 5. A valid vouch of an unknown hub with the slots full: NOT_FOUND.
        await assertVouchRefusal(.hubNotOnRelay) {
            try await self.pairing(phone).vouch(hubDeviceID: unregistered.id, authPub: unregistered.authPub)
        }
        // 6. Of a registered hub: SLOT_LIMIT.
        await assertVouchRefusal(.slotsFull) { try await self.pairing(phone).vouch(hubDeviceID: fourth.id, authPub: fourth.authPub) }
    }

    // MARK: - The pending vouch

    func testPromoteWithoutAVouchIsHubNotVouched() async throws {
        let (phone, _) = try await phone()
        let hub = try await hub(seed: 1)
        let pairer = pairing(phone)
        let (slot, _) = try await pairer.open(mac: hub.id)
        await assertRelayError(.server(code: .hubNotVouched, retryAfter: nil)) { try await pairer.promote(slot: slot) }
        await assertRelayError(.server(code: .hubNotVouched, retryAfter: nil)) { try await self.addSlot(phone, hub) }
        let before = try await pairer.accountState().macs
        XCTAssertEqual(before, [])

        try await pairer.vouch(hubDeviceID: hub.id, authPub: hub.authPub)
        try await pairer.promote(slot: slot)
        let after = try await pairer.accountState().macs
        XCTAssertEqual(after, [hub.id])
    }

    func testAVouchOlderThanTenMinutesIsHubNotVouched() async throws {
        _ = try requireFake(Self.r15)
        let clock = try XCTUnwrap(manualClock)
        let (phone, _) = try await phone()
        let hub = try await hub(seed: 1)
        let pairer = pairing(phone)

        try await pairer.vouch(hubDeviceID: hub.id, authPub: hub.authPub)
        clock.advance(by: .seconds(300))
        let (slot, _) = try await pairer.open(mac: hub.id)
        clock.advance(by: .seconds(301))
        // The slot has 299 s left; the vouch is 601 s old.
        await assertRelayError(.server(code: .hubNotVouched, retryAfter: nil)) { try await pairer.promote(slot: slot) }

        // A repeated vouch renews it: 590 s after the first one plus 590 s after the second still holds.
        try await pairer.vouch(hubDeviceID: hub.id, authPub: hub.authPub)
        clock.advance(by: .seconds(290))
        try await pairer.vouch(hubDeviceID: hub.id, authPub: hub.authPub)
        clock.advance(by: .seconds(590))
        try await addSlot(phone, hub)
        let macs = try await pairer.accountState().macs
        XCTAssertEqual(macs, [hub.id])
    }

    func testAFailedAddSlotDoesNotConsumeTheVouch() async throws {
        let (phone, _) = try await phone()
        var slotted: [Hub] = []
        for seed in UInt8(10)..<12 {
            let mac = try await hub(seed: seed)
            try await stand.pair(mac: mac.id, phones: [phone.deviceID])
            slotted.append(mac)
        }
        let hub = try await hub(seed: 1)
        let pairer = pairing(phone)
        try await pairer.vouch(hubDeviceID: hub.id, authPub: hub.authPub)
        // A third Mac fills the slots after the vouch: add_slot fails and keeps the vouch.
        let third = try await self.hub(seed: 12)
        try await stand.pair(mac: third.id, phones: [phone.deviceID])
        await assertRelayError(.server(code: .slotLimit, retryAfter: nil)) { try await self.addSlot(phone, hub) }

        try await pairer.removeSlot(mac: slotted[0].id)
        try await addSlot(phone, hub)
        let macs = try await pairer.accountState().macs
        XCTAssertEqual(Set(macs), [slotted[1].id, third.id, hub.id])
    }

    func testAHubAlreadyInSlotsNeedsNoVouch() async throws {
        let (phone, _) = try await phone()
        let hub = try await hub(seed: 1)
        try await stand.pair(mac: hub.id, phones: [phone.deviceID])
        let pairer = pairing(phone)
        try await addSlot(phone, hub)
        let (slot, _) = try await pairer.open(mac: hub.id)
        try await pairer.promote(slot: slot)

        // With the slots full, a vouch for a hub already in them is no SLOT_LIMIT.
        for seed in UInt8(10)..<12 {
            let mac = try await self.hub(seed: seed)
            try await stand.pair(mac: mac.id, phones: [phone.deviceID])
        }
        try await pairer.vouch(hubDeviceID: hub.id, authPub: hub.authPub)
        let macs = try await pairer.accountState().macs
        XCTAssertEqual(macs.count, 3)
    }

    // MARK: - The hub gate and dev

    func testAnUnvouchedHubReachesOnlyItsPairZone() async throws {
        let (phone, _) = try await phone()
        let hub = try await hub(seed: 1)
        let pairer = pairing(phone)
        let (slot, _) = try await pairer.open(mac: hub.id)
        let pairZone = HostedRelayZones.pair(slot: slot)
        var readers = Relay_V1_SetHubReaders()
        readers.phoneDeviceIds = [phone.deviceID]

        // Unvouched: its account state and its pair zone, nothing else.
        let state = try await hub.client.accountState()
        XCTAssertEqual(state.phones, [])
        try await save(hub.client, pairZone, "keybox-p")
        await assertRelayError(.server(code: .hubNotVouched, retryAfter: nil)) {
            _ = try await hub.client.perform(.setHubReaders(readers))
        }
        await assertRelayError(.server(code: .hubNotVouched, retryAfter: nil)) {
            try await self.save(hub.client, "data/\(hub.id)", "d0")
        }

        // In a slot it is vouched.
        try await pairer.vouch(hubDeviceID: hub.id, authPub: hub.authPub)
        try await pairer.promote(slot: slot)
        _ = try await hub.client.perform(.setHubReaders(readers))
        try await save(hub.client, "data/\(hub.id)", "d0")
    }

    func testAPhoneOnDevSendsNoAttestation() async throws {
        let relay = try requireFake(Self.r15)
        relay.attestMode = .off
        let (phone, _) = try await phone()
        let hub = try await hub(seed: 1)
        let nonce = try await phone.challenge(purpose: .vouch)
        try await rawVouch(phone, hub, nonce: nonce)
        try await addSlot(phone, hub)
        // The nonce is single use, also on dev.
        await assertRelayError(.server(code: .attestationFailed, retryAfter: nil)) { try await self.rawVouch(phone, hub, nonce: nonce) }
    }
}
