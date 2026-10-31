import CryptoKit
import Foundation
import WatchtowerHostedRelay
import WatchtowerHostedRelayTesting
import WatchtowerRelayProto
import XCTest

/// `FakeHostedRelay` driven through `handle`, with requests signed by
/// `Ed25519RelaySigner` and attested by `FakeAppAttest` (relay@3a99bd7 `proto/README.md`).
final class FakeHostedRelayTests: XCTestCase {
    private let origin = "https://relay.example.com"
    private let year: Duration = .seconds(365 * 86_400)
    private var clock = ManualRelayClock()

    // MARK: - Zones

    func testConditionalSaveOutcomesPerItem() async throws {
        let (relay, mac, _) = try await pairedWorld()
        let zone = "data/\(mac.id)"
        let first = try saveResult(relay, mac, [item(zone, "a", "1", mustNotExist: true)])
        XCTAssertEqual(first.saved.map(\.recordSeq), [1])
        XCTAssertEqual(first.saved.first?.zone, zone)
        XCTAssertEqual(first.saved.first?.envelope, Data(), "save answers metadata only")

        let mixed = try saveResult(relay, mac, [
            item(zone, "a", "2", mustNotExist: true),
            item(zone, "b", "3", mustNotExist: true),
            item(zone, "a", "4", expectedSeq: 1),
            item(zone, "c", "5", expectedSeq: 5)
        ])
        XCTAssertEqual(mixed.saved.map(\.name), ["b", "a"])
        XCTAssertEqual(mixed.saved.map(\.recordSeq), [2, 3])
        XCTAssertEqual(mixed.conflicts.map(\.index), [0, 3])
        XCTAssertTrue(mixed.conflicts[0].hasCurrent)
        XCTAssertEqual(mixed.conflicts[0].current.recordSeq, 1)
        XCTAssertEqual(mixed.conflicts[0].current.envelope, Data("1".utf8))
        XCTAssertFalse(mixed.conflicts[1].hasCurrent, "no record, no current")

        // A tombstone counts as absent for must_not_exist.
        _ = try deleteResult(relay, mac, zone, [deleteItem("b")])
        let again = try saveResult(relay, mac, [item(zone, "b", "6", mustNotExist: true)])
        XCTAssertEqual(again.saved.map(\.recordSeq), [5])
        XCTAssertTrue(again.conflicts.isEmpty)
    }

    func testDeleteIsConditionalPerItem() async throws {
        let (relay, mac, _) = try await pairedWorld()
        let zone = "data/\(mac.id)"
        _ = try saveResult(relay, mac, [item(zone, "a", "1"), item(zone, "b", "2")])
        let result = try deleteResult(relay, mac, zone, [
            deleteItem("a", expectedSeq: 9),
            deleteItem("b", expectedSeq: 2),
            deleteItem("missing"),
            deleteItem("missing2", expectedSeq: 1)
        ])
        XCTAssertEqual(result.conflicts.map(\.index), [0, 3])
        XCTAssertEqual(result.conflicts[0].current.recordSeq, 1)
        XCTAssertFalse(result.conflicts[1].hasCurrent)

        let page = try changes(relay, mac, zone, since: 0)
        XCTAssertEqual(page.changed.map(\.name), ["a"])
        XCTAssertEqual(page.deleted, ["b"])
        XCTAssertEqual(page.newSeq, 3)
    }

    func testRecordSeqGrowsPerZone() async throws {
        let (relay, mac, phone) = try await pairedWorld()
        let data = "data/\(mac.id)"
        let mailbox = "relay/\(mac.id)/\(phone.id)"
        let saved = try saveResult(relay, mac, [item(data, "a", "1"), item(mailbox, "m", "2"), item(data, "b", "3")])
        XCTAssertEqual(saved.saved.map(\.recordSeq), [1, 2, 1], "data a, data b, then the mailbox: each zone counts alone")
        XCTAssertEqual(saved.saved.map(\.zone), [data, data, mailbox])
        _ = try deleteResult(relay, mac, data, [deleteItem("a")])
        XCTAssertEqual(try changes(relay, mac, data, since: 0).newSeq, 3)
        XCTAssertEqual(try changes(relay, phone, mailbox, since: 0).newSeq, 1)
    }

    func testChangesPagesByLimitAndBytes() async throws {
        let (relay, mac, _) = try await pairedWorld()
        let zone = "data/\(mac.id)"
        var limits = relay.limits
        limits.maxRecordBytes = 6 << 20
        relay.limits = limits
        let big = String(repeating: "x", count: 3 << 19) // 1.5 MiB
        _ = try saveResult(relay, mac, (0..<3).map { item(zone, "big\($0)", big) })
        let firstPage = try changes(relay, mac, zone, since: 0)
        XCTAssertEqual(firstPage.changed.count, 2, "4 MiB of envelopes per page")
        XCTAssertTrue(firstPage.more)
        let lastPage = try changes(relay, mac, zone, since: firstPage.newSeq)
        XCTAssertEqual(lastPage.changed.map(\.name), ["big2"])
        XCTAssertFalse(lastPage.more)

        _ = try saveResult(relay, mac, [item(zone, "huge", String(repeating: "y", count: 5 << 20))])
        let huge = try changes(relay, mac, zone, since: lastPage.newSeq)
        XCTAssertEqual(huge.changed.map(\.name), ["huge"], "at least one record, whatever its size")

        _ = try saveResult(relay, mac, (0..<501).map { item(zone, "small\($0)", "s") })
        let unset = try changes(relay, mac, zone, since: huge.newSeq)
        XCTAssertEqual(unset.changed.count, 500)
        XCTAssertTrue(unset.more)
        let tooMany = try changes(relay, mac, zone, since: huge.newSeq, limit: 1_000)
        XCTAssertEqual(tooMany.changed.count, 500, "a larger limit is capped at 500")
        let two = try changes(relay, mac, zone, since: huge.newSeq, limit: 2)
        XCTAssertEqual(two.changed.map(\.name), ["small0", "small1"])
        XCTAssertTrue(two.more)
    }

    func testTokenExpiredAboveLastAndBelowPurgedTombstones() async throws {
        let (relay, mac, _) = try await pairedWorld()
        let zone = "data/\(mac.id)"
        _ = try saveResult(relay, mac, [item(zone, "a", "1"), item(zone, "b", "2")])
        XCTAssertEqual(try errorCode(relay, mac, changesOp(zone, since: 3)), .tokenExpired, "above the zone's last seq")
        _ = try deleteResult(relay, mac, zone, [deleteItem("a")])
        XCTAssertNil(try errorCode(relay, mac, changesOp(zone, since: 1)), "the tombstone is still kept")

        clock.advance(by: .seconds(31 * 86_400))
        try await login(relay, mac)
        XCTAssertEqual(try errorCode(relay, mac, changesOp(zone, since: 1)), .tokenExpired, "below a purged tombstone")
        let full = try changes(relay, mac, zone, since: 0)
        XCTAssertEqual(full.changed.map(\.name), ["b"])
        XCTAssertEqual(full.deleted, [], "purged tombstones are gone")
        XCTAssertEqual(full.newSeq, 3)
        XCTAssertNil(try errorCode(relay, mac, changesOp(zone, since: 3)))
    }

    func testPhoneCannotWriteTheDataZone() async throws {
        let (relay, mac, phone) = try await pairedWorld()
        XCTAssertEqual(try errorCode(relay, phone, saveOp([item("data/\(mac.id)", "a", "1")])), .forbidden)
        XCTAssertEqual(try errorCode(relay, phone, deleteOp("data/\(mac.id)", [deleteItem("a")])), .forbidden)
        XCTAssertEqual(try errorCode(relay, phone, saveOp([item("bogus/\(mac.id)", "a", "1")])), .forbidden)
    }

    func testOnlyReadersReadTheDataZone() async throws {
        let (relay, mac, reader) = try await pairedWorld()
        let slotted = try await onboard(relay, .phone, seed: 3)
        try await pay(relay, slotted)
        var add = Relay_V1_AddMacSlot()
        add.macDeviceID = mac.id
        XCTAssertNil(try errorCode(relay, slotted, .addSlot(add)))
        let stranger = try await onboard(relay, .phone, seed: 4)
        try await pay(relay, stranger)

        let zone = "data/\(mac.id)"
        _ = try saveResult(relay, mac, [item(zone, "a", "1")])
        XCTAssertEqual(try changes(relay, reader, zone, since: 0).changed.map(\.name), ["a"])
        XCTAssertEqual(try errorCode(relay, slotted, changesOp(zone, since: 0)), .forbidden, "slotted, not a reader")
        XCTAssertEqual(try errorCode(relay, stranger, changesOp(zone, since: 0)), .forbidden)
    }

    func testLapsedPhoneWriteIsEntitlementInactive() async throws {
        let (relay, mac, phone) = try await pairedWorld()
        let mailbox = "relay/\(mac.id)/\(phone.id)"
        _ = try saveResult(relay, phone, [item(mailbox, "a-1", "action")])
        try await relay.setEntitlement(accountID: phone.accountID, state: "expired", for: .zero)

        XCTAssertEqual(try errorCode(relay, phone, saveOp([item(mailbox, "a-2", "action")])), .entitlementInactive)
        XCTAssertEqual(try errorCode(relay, mac, saveOp([item(mailbox, "c-1", "echo")])), .entitlementInactive)
        XCTAssertEqual(try errorCode(relay, mac, saveOp([item("data/\(mac.id)", "s", "slice")])), .entitlementInactive)
        XCTAssertEqual(try changes(relay, phone, mailbox, since: 0).changed.map(\.name), ["a-1"], "reads stay within the window")
        XCTAssertNil(try errorCode(relay, phone, deleteOp(mailbox, [deleteItem("a-1")])), "deletes ignore payment")
    }

    func testPairZoneRefusesAttachmentsAndCapsBytes() async throws {
        let relay = makeRelay()
        let mac = try await onboard(relay, .mac, seed: 1)
        let phone = try await onboard(relay, .phone, seed: 2)
        try await pay(relay, phone)
        var open = Relay_V1_OpenPairingSlot()
        open.macDeviceID = mac.id
        let opened = try ok(relay, phone, .openPairing(open))
        guard case .pairingSlot(let slot) = opened.result else { return XCTFail("want pairing_slot, got \(opened)") }
        XCTAssertEqual(slot.expiresAtMs, ms(clock.now()) + 600_000)
        XCTAssertEqual(controls(relay, mac), [control(.pairingOpened, slot.slotID)])

        let zone = "pair/\(slot.slotID)"
        var upload = Relay_V1_CreateUpload()
        upload.zone = zone
        upload.size = 10
        XCTAssertEqual(try errorCode(relay, phone, .createUpload(upload)), .forbidden)
        let chunk = String(repeating: "k", count: 600 << 10)
        XCTAssertNil(try errorCode(relay, phone, saveOp([item(zone, "hello", chunk)])))
        XCTAssertEqual(try errorCode(relay, mac, saveOp([item(zone, "keybox", chunk)])), .mailboxQuotaExceeded)
        XCTAssertEqual(try changes(relay, mac, zone, since: 0).changed.map(\.name), ["hello"])

        let stranger = try await onboard(relay, .phone, seed: 3)
        XCTAssertEqual(try errorCode(relay, stranger, changesOp(zone, since: 0)), .forbidden)

        clock.advance(by: .seconds(601))
        var promote = Relay_V1_PromotePairing()
        promote.slotID = slot.slotID
        XCTAssertEqual(try errorCode(relay, phone, .promotePairing(promote)), .pairingExpired)
        XCTAssertEqual(try errorCode(relay, mac, changesOp(zone, since: 0)), .forbidden, "an expired pairing admits nobody")
    }

    func testMailboxRecordsExpireAfter14Days() async throws {
        let (relay, mac, phone) = try await pairedWorld()
        let mailbox = "relay/\(mac.id)/\(phone.id)"
        _ = try saveResult(relay, mac, [item(mailbox, "c-1", "hub"), item("data/\(mac.id)", "slice", "s")])
        clock.advance(by: .seconds(14 * 86_400 + 1))
        try await login(relay, mac)
        try await login(relay, phone)
        let page = try changes(relay, phone, mailbox, since: 0)
        XCTAssertEqual(page.changed, [])
        XCTAssertEqual(page.deleted, ["c-1"])
        XCTAssertEqual(try changes(relay, phone, "data/\(mac.id)", since: 0).changed.map(\.name), ["slice"], "the data zone has no TTL")

        // The stand's /dev/expire-mailboxes: expire as if the time had passed.
        _ = try saveResult(relay, phone, [item(mailbox, "a-1", "action")])
        try await relay.expireMailboxes([mailbox], elapsed: .seconds(14 * 86_400 + 1))
        XCTAssertEqual(try changes(relay, phone, mailbox, since: page.newSeq).deleted, ["a-1"])
    }

    func testRemoveSlotAnswersUnavailableUntilDelivered() async throws {
        let (relay, mac, phone) = try await pairedWorld()
        _ = controls(relay, phone)
        _ = controls(relay, mac)
        var remove = Relay_V1_RemoveMacSlot()
        remove.phoneDeviceID = phone.id
        remove.macDeviceID = mac.id
        XCTAssertNil(try errorCode(relay, phone, .removeSlot(remove)))
        XCTAssertEqual(controls(relay, phone), [control(.slotRemoved, mac.id)])
        XCTAssertEqual(controls(relay, mac), [control(.slotRemoved, phone.id)])
        XCTAssertEqual(try errorCode(relay, phone, .removeSlot(remove)), .unavailable)
        XCTAssertEqual(try errorCode(relay, mac, .removeSlot(remove)), .unavailable, "the Mac may remove itself too")

        relay.markRevocationsDelivered()
        XCTAssertNil(try errorCode(relay, phone, .removeSlot(remove)))

        clock.advance(by: .seconds(86_401))
        try await login(relay, phone)
        XCTAssertEqual(try errorCode(relay, phone, .removeSlot(remove)), .notFound, "remembered for 24 h only")
    }

    func testEntitlementExpiredControlNamesThePhoneForMacs() async throws {
        let relay = makeRelay()
        let phone = try await onboard(relay, .phone, seed: 2)
        let macA = try await onboard(relay, .mac, seed: 1)
        let macB = try await onboard(relay, .mac, seed: 5)
        try await pay(relay, phone)
        try await relay.pair(mac: macA.id, phones: [phone.id])
        try await relay.pair(mac: macB.id, phones: [phone.id])

        try await relay.setEntitlement(accountID: phone.accountID, state: "expired", for: .zero)
        XCTAssertEqual(controls(relay, phone), [control(.entitlementExpired, "")])
        XCTAssertEqual(controls(relay, macA), [control(.entitlementExpired, phone.id)])
        XCTAssertEqual(controls(relay, macB), [control(.entitlementExpired, phone.id)])

        guard case .accountState(let phoneState) = try ok(relay, phone, .getAccountState(.init())).result else {
            return XCTFail("want account_state")
        }
        XCTAssertEqual(phoneState.entitlement.state, .expired)
        XCTAssertEqual(phoneState.macDeviceIds, [macA.id, macB.id].sorted())
        guard case .accountState(let macState) = try ok(relay, macA, .getAccountState(.init())).result else {
            return XCTFail("want account_state")
        }
        XCTAssertEqual(macState.phones.map(\.phoneDeviceID), [phone.id])
        XCTAssertEqual(macState.phones.map(\.paying), [false])
    }

    // MARK: - Attestation (enforce)

    func testRegisterWithoutAttestationIsRequired() async throws {
        let relay = makeRelay()
        let phone = device(.phone, seed: 2)
        let nonce = try registerNonce(relay, phone)
        let (status, response) = relay.handle(request(.register(registerOp(phone, nonce: nonce))), bearer: nil)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(code(response), .attestationRequired)
        XCTAssertEqual(try errorCode(relay, nil, .challenge(challengeOp(phone, .login))), .unauthenticated, "nothing was created")
    }

    func testRegisterHashMismatchFails() async throws {
        let relay = makeRelay()
        let phone = device(.phone, seed: 2)
        let nonce = try registerNonce(relay, phone)
        let keyID = try await phone.attest.generateKey()
        var attestation = Relay_V1_Attestation()
        attestation.appAttest.keyID = try XCTUnwrap(Data(base64Encoded: keyID))
        attestation.appAttest.attestationObject = try await phone.attest.attestKey(keyID, clientDataHash: Data(repeating: 7, count: 32))
        XCTAssertEqual(try errorCode(relay, nil, .register(registerOp(phone, nonce: nonce, attestation: attestation))), .attestationFailed)

        // The attested key id must be the one in the request.
        let right = registerHash(phone, nonce: nonce)
        attestation.appAttest.attestationObject = try await phone.attest.attestKey(keyID, clientDataHash: right)
        attestation.appAttest.keyID = Data(repeating: 9, count: 32)
        XCTAssertEqual(try errorCode(relay, nil, .register(registerOp(phone, nonce: nonce, attestation: attestation))), .attestationFailed)
    }

    func testAssertionCounterMustGrow() async throws {
        let relay = makeRelay()
        let phone = try await onboard(relay, .phone, seed: 2) // logged in with counter 1
        let nonce = try loginNonce(relay, phone)
        let hash = RelayAuthMessages.loginClientDataHash(nonce: nonce, deviceID: phone.id, origin: try RelayOrigin(origin))
        var attestation = Relay_V1_Attestation()
        attestation.appAttestAssertion.assertion = try JSONSerialization.data(
            withJSONObject: ["key_id": try XCTUnwrap(phone.keyID), "client_data_hash": hash.base64EncodedString(), "counter": 1],
            options: [.sortedKeys]
        )
        XCTAssertEqual(try errorCode(relay, nil, .login(loginOp(phone, nonce: nonce, attestation: attestation))), .attestationFailed)
        try await login(relay, phone) // counter 2
    }

    func testAssertionWithoutStoredKeyFails() async throws {
        let relay = makeRelay(attest: .off)
        let phone = device(.phone, seed: 2)
        try register(relay, phone, attestation: nil)
        relay.attestMode = .enforce(exemptDeviceIDs: [])

        phone.keyID = try await phone.attest.generateKey()
        let nonce = try loginNonce(relay, phone)
        let assertion = try await assertion(phone, nonce: nonce)
        XCTAssertEqual(try errorCode(relay, nil, .login(loginOp(phone, nonce: nonce, attestation: assertion))), .attestationFailed)
        let plain = try loginNonce(relay, phone)
        XCTAssertEqual(try errorCode(relay, nil, .login(loginOp(phone, nonce: plain))), .attestationRequired)

        // The lost-key path: a fresh attestation over the login hash stores the key.
        let fresh = try loginNonce(relay, phone)
        let attestation = try await freshAttestation(phone, hash: loginHash(phone, nonce: fresh))
        XCTAssertNil(try errorCode(relay, nil, .login(loginOp(phone, nonce: fresh, attestation: attestation))))
        try await login(relay, phone)
    }

    func testWrongSignatureIsUnauthenticatedWhateverTheAttestation() async throws {
        let relay = makeRelay()
        let phone = try await onboard(relay, .phone, seed: 2)
        let impostor = Ed25519RelaySigner(try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 99, count: 32)))

        let withAssertion = try loginNonce(relay, phone)
        var op = loginOp(phone, nonce: withAssertion, attestation: try await assertion(phone, nonce: withAssertion))
        op.signature = try impostor.sign(loginMessage(phone, nonce: withAssertion))
        let (status, response) = relay.handle(request(.login(op)), bearer: nil)
        XCTAssertEqual(status, 401)
        XCTAssertEqual(code(response), .unauthenticated)

        let withFresh = try loginNonce(relay, phone)
        op = loginOp(phone, nonce: withFresh, attestation: try await freshAttestation(phone, hash: loginHash(phone, nonce: withFresh)))
        op.signature = Data(repeating: 1, count: 64)
        XCTAssertEqual(try errorCode(relay, nil, .login(op)), .unauthenticated)

        let bare = try loginNonce(relay, phone)
        op = loginOp(phone, nonce: bare)
        op.signature = Data(repeating: 1, count: 64)
        XCTAssertEqual(try errorCode(relay, nil, .login(op)), .unauthenticated)
        XCTAssertEqual(
            try errorCode(relay, nil, .login(loginOp(phone, nonce: bare))), .unauthenticated, "a failed login burns its nonce"
        )
    }

    /// R20: the Worker verifies a fresh `app_attest` before the signature (`worker/src/http/op.ts`).
    func testBadFreshAttestationFailsBeforeTheSignature() async throws {
        let relay = makeRelay()
        let phone = try await onboard(relay, .phone, seed: 2)
        let nonce = try loginNonce(relay, phone)
        let storedKey = phone.keyID
        var op = loginOp(phone, nonce: nonce, attestation: try await freshAttestation(phone, hash: Data(repeating: 7, count: 32)))
        op.signature = Data(repeating: 1, count: 64)
        XCTAssertEqual(try errorCode(relay, nil, .login(op)), .attestationFailed)
        phone.keyID = storedKey
        let assertion = try await assertion(phone, nonce: nonce)
        XCTAssertNil(
            try errorCode(relay, nil, .login(loginOp(phone, nonce: nonce, attestation: assertion))),
            "the refused attestation did not burn the nonce"
        )
    }

    func testOffModeIgnoresAttestation() async throws {
        let relay = makeRelay(attest: .off)
        let phone = device(.phone, seed: 2)
        try register(relay, phone, attestation: nil)
        let nonce = try loginNonce(relay, phone)
        var junk = Relay_V1_Attestation()
        junk.appAttestAssertion.assertion = Data("junk".utf8)
        XCTAssertNil(try errorCode(relay, nil, .login(loginOp(phone, nonce: nonce, attestation: junk))))
        let plain = try loginNonce(relay, phone)
        XCTAssertNil(try errorCode(relay, nil, .login(loginOp(phone, nonce: plain))))
    }

    func testExemptMacRegistersWithoutAttestation() async throws {
        let mac = device(.mac, seed: 1)
        let relay = makeRelay(attest: .enforce(exemptDeviceIDs: [mac.id]))
        let registered = try register(relay, mac, attestation: nil)
        XCTAssertEqual(registered.accountID, "", "a Mac has no account")
        let nonce = try loginNonce(relay, mac)
        XCTAssertNil(try errorCode(relay, nil, .login(loginOp(mac, nonce: nonce))))

        let phone = device(.phone, seed: 2)
        let phoneNonce = try registerNonce(relay, phone)
        XCTAssertEqual(try errorCode(relay, nil, .register(registerOp(phone, nonce: phoneNonce))), .attestationRequired)
        let otherMac = device(.mac, seed: 6)
        let macNonce = try registerNonce(relay, otherMac)
        XCTAssertEqual(try errorCode(relay, nil, .register(registerOp(otherMac, nonce: macNonce))), .attestationRequired)
        XCTAssertFalse(relay.log.isEmpty)
    }

    // MARK: - Devices

    private final class Device {
        let kind: Relay_V1_DeviceKind
        let signer: Ed25519RelaySigner
        let attest = FakeAppAttest()
        var keyID: String?
        var token = ""
        var accountID = ""

        init(kind: Relay_V1_DeviceKind, seed: UInt8) {
            self.kind = kind
            // A 32-byte seed is always a valid Ed25519 private key.
            // swiftlint:disable:next force_try
            signer = Ed25519RelaySigner(try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: seed, count: 32)))
        }

        var id: String {
            RelayAuthMessages.deviceID(publicKey: signer.publicKey)
        }
    }

    private func makeRelay(attest: FakeHostedRelay.AttestMode = .enforce(exemptDeviceIDs: [])) -> FakeHostedRelay {
        clock = ManualRelayClock()
        return FakeHostedRelay(origin: origin, attest: attest, clock: clock)
    }

    private func device(_ kind: Relay_V1_DeviceKind, seed: UInt8) -> Device {
        Device(kind: kind, seed: seed)
    }

    /// A relay in enforce mode with a paying phone, and a Mac in its slots whose data zone the phone reads.
    private func pairedWorld() async throws -> (FakeHostedRelay, Device, Device) {
        let relay = makeRelay()
        let mac = try await onboard(relay, .mac, seed: 1)
        let phone = try await onboard(relay, .phone, seed: 2)
        try await pay(relay, phone)
        try await relay.pair(mac: mac.id, phones: [phone.id])
        return (relay, mac, phone)
    }

    private func onboard(_ relay: FakeHostedRelay, _ kind: Relay_V1_DeviceKind, seed: UInt8) async throws -> Device {
        let device = device(kind, seed: seed)
        let nonce = try registerNonce(relay, device)
        let attestation = try await freshAttestation(device, hash: registerHash(device, nonce: nonce))
        try register(relay, device, attestation: attestation, nonce: nonce)
        try await login(relay, device)
        return device
    }

    private func pay(_ relay: FakeHostedRelay, _ phone: Device) async throws {
        let accountID = try await relay.accountID(ofPhone: phone.id)
        XCTAssertEqual(accountID, phone.accountID)
        try await relay.setEntitlement(accountID: phone.accountID, state: "active", for: year)
    }

    @discardableResult
    private func register(
        _ relay: FakeHostedRelay, _ device: Device, attestation: Relay_V1_Attestation?, nonce: Data? = nil
    ) throws -> Relay_V1_DeviceRegistered {
        let nonce = try nonce ?? registerNonce(relay, device)
        let response = relay.handle(request(.register(registerOp(device, nonce: nonce, attestation: attestation))), bearer: nil).response
        guard case .registered(let registered) = response.result else { throw Failure.unexpected("\(response)") }
        XCTAssertEqual(registered.deviceID, device.id)
        device.accountID = registered.accountID
        return registered
    }

    /// Logs in with an assertion by the stored key.
    private func login(_ relay: FakeHostedRelay, _ device: Device) async throws {
        let nonce = try loginNonce(relay, device)
        let attestation = try await assertion(device, nonce: nonce)
        let response = relay.handle(request(.login(loginOp(device, nonce: nonce, attestation: attestation))), bearer: nil)
        guard case .session(let session) = response.response.result else { throw Failure.unexpected("\(response.response)") }
        XCTAssertEqual(session.expiresAtMs, ms(clock.now()) + 15 * 60_000)
        device.token = session.token
    }

    private func freshAttestation(_ device: Device, hash: Data) async throws -> Relay_V1_Attestation {
        let keyID = try await device.attest.generateKey()
        device.keyID = keyID
        var attestation = Relay_V1_Attestation()
        attestation.appAttest.keyID = try XCTUnwrap(Data(base64Encoded: keyID))
        attestation.appAttest.attestationObject = try await device.attest.attestKey(keyID, clientDataHash: hash)
        return attestation
    }

    private func assertion(_ device: Device, nonce: Data) async throws -> Relay_V1_Attestation {
        let keyID = try XCTUnwrap(device.keyID)
        var attestation = Relay_V1_Attestation()
        attestation.appAttestAssertion.assertion = try await device.attest.generateAssertion(keyID, clientDataHash: loginHash(device, nonce: nonce))
        return attestation
    }

    // MARK: - Requests

    private enum Failure: Error {
        case unexpected(String)
    }

    private func request(_ op: Relay_V1_Request.OneOf_Op) -> Relay_V1_Request {
        var request = Relay_V1_Request()
        request.id = 7
        request.op = op
        return request
    }

    private func challengeOp(_ device: Device, _ purpose: Relay_V1_ChallengePurpose) -> Relay_V1_GetChallenge {
        var challenge = Relay_V1_GetChallenge()
        challenge.deviceID = device.id
        challenge.purpose = purpose
        return challenge
    }

    private func nonce(_ relay: FakeHostedRelay, _ device: Device, _ purpose: Relay_V1_ChallengePurpose) throws -> Data {
        let response = relay.handle(request(.challenge(challengeOp(device, purpose))), bearer: nil).response
        guard case .challenge(let challenge) = response.result else { throw Failure.unexpected("\(response)") }
        return challenge.nonce
    }

    private func registerNonce(_ relay: FakeHostedRelay, _ device: Device) throws -> Data {
        try nonce(relay, device, .register)
    }

    private func loginNonce(_ relay: FakeHostedRelay, _ device: Device) throws -> Data {
        try nonce(relay, device, .login)
    }

    private func registerHash(_ device: Device, nonce: Data) -> Data {
        // swiftlint:disable:next force_try
        RelayAuthMessages.registerClientDataHash(nonce: nonce, authPub: device.signer.publicKey, origin: try! RelayOrigin(origin))
    }

    private func loginHash(_ device: Device, nonce: Data) -> Data {
        // swiftlint:disable:next force_try
        RelayAuthMessages.loginClientDataHash(nonce: nonce, deviceID: device.id, origin: try! RelayOrigin(origin))
    }

    private func loginMessage(_ device: Device, nonce: Data) -> Data {
        // swiftlint:disable:next force_try
        RelayAuthMessages.loginMessage(nonce: nonce, deviceID: device.id, origin: try! RelayOrigin(origin))
    }

    private func registerOp(_ device: Device, nonce: Data, attestation: Relay_V1_Attestation? = nil) -> Relay_V1_RegisterDevice {
        var op = Relay_V1_RegisterDevice()
        op.deviceKind = device.kind
        op.authPub = device.signer.publicKey
        op.nonce = nonce
        if let attestation { op.attestation = attestation }
        // swiftlint:disable:next force_try
        op.signature = try! device.signer.sign(registerHash(device, nonce: nonce))
        return op
    }

    private func loginOp(_ device: Device, nonce: Data, attestation: Relay_V1_Attestation? = nil) -> Relay_V1_Login {
        var op = Relay_V1_Login()
        op.deviceID = device.id
        op.nonce = nonce
        if let attestation { op.attestation = attestation }
        // swiftlint:disable:next force_try
        op.signature = try! device.signer.sign(loginMessage(device, nonce: nonce))
        return op
    }

    private func item(_ zone: String, _ name: String, _ body: String, mustNotExist: Bool = false, expectedSeq: UInt64? = nil) -> Relay_V1_SaveItem {
        var item = Relay_V1_SaveItem()
        item.record.zone = zone
        item.record.name = name
        item.record.envelope = Data(body.utf8)
        item.record.clientModifiedAtMs = 1
        if mustNotExist { item.mustNotExist = true }
        if let expectedSeq { item.expectedSeq = expectedSeq }
        return item
    }

    private func deleteItem(_ name: String, expectedSeq: UInt64? = nil) -> Relay_V1_DeleteItem {
        var item = Relay_V1_DeleteItem()
        item.name = name
        if let expectedSeq { item.expectedSeq = expectedSeq }
        return item
    }

    private func saveOp(_ items: [Relay_V1_SaveItem]) -> Relay_V1_Request.OneOf_Op {
        var save = Relay_V1_Save()
        save.items = items
        return .save(save)
    }

    private func deleteOp(_ zone: String, _ items: [Relay_V1_DeleteItem]) -> Relay_V1_Request.OneOf_Op {
        var delete = Relay_V1_Delete()
        delete.zone = zone
        delete.items = items
        return .delete(delete)
    }

    private func changesOp(_ zone: String, since: UInt64, limit: UInt32 = 0) -> Relay_V1_Request.OneOf_Op {
        var changes = Relay_V1_Changes()
        changes.zone = zone
        changes.sinceSeq = since
        changes.limit = limit
        return .changes(changes)
    }

    private func code(_ response: Relay_V1_Response) -> Relay_V1_ErrorCode? {
        if case .error(let error) = response.result { return error.code }
        return nil
    }

    /// The error code of `op` for `device` (nil = success); nil device = no session.
    private func errorCode(_ relay: FakeHostedRelay, _ device: Device?, _ op: Relay_V1_Request.OneOf_Op) throws -> Relay_V1_ErrorCode? {
        let (status, response) = relay.handle(request(op), bearer: device?.token)
        XCTAssertEqual(response.id, 7)
        let code = code(response)
        XCTAssertEqual(status, code == .unauthenticated ? 401 : 200)
        return code
    }

    private func ok(_ relay: FakeHostedRelay, _ device: Device, _ op: Relay_V1_Request.OneOf_Op) throws -> Relay_V1_Response {
        let response = relay.handle(request(op), bearer: device.token).response
        if code(response) != nil { throw Failure.unexpected("\(response)") }
        return response
    }

    private func saveResult(_ relay: FakeHostedRelay, _ device: Device, _ items: [Relay_V1_SaveItem]) throws -> Relay_V1_SaveResult {
        guard case .save(let result) = try ok(relay, device, saveOp(items)).result else { throw Failure.unexpected("not a save") }
        return result
    }

    private func deleteResult(
        _ relay: FakeHostedRelay, _ device: Device, _ zone: String, _ items: [Relay_V1_DeleteItem]
    ) throws -> Relay_V1_DeleteResult {
        guard case .delete(let result) = try ok(relay, device, deleteOp(zone, items)).result else { throw Failure.unexpected("not a delete") }
        return result
    }

    private func changes(
        _ relay: FakeHostedRelay, _ device: Device, _ zone: String, since: UInt64, limit: UInt32 = 0
    ) throws -> Relay_V1_ChangesResult {
        guard case .changes(let result) = try ok(relay, device, changesOp(zone, since: since, limit: limit)).result else {
            throw Failure.unexpected("not changes")
        }
        return result
    }

    private func controls(_ relay: FakeHostedRelay, _ device: Device) -> [Relay_V1_Control] {
        relay.takeEvents(for: device.id).compactMap { event in
            if case .control(let control) = event.kind { return control }
            return nil
        }
    }

    private func control(_ kind: Relay_V1_ControlKind, _ detail: String) -> Relay_V1_Control {
        var control = Relay_V1_Control()
        control.kind = kind
        control.detail = detail
        return control
    }

    private func ms(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}
