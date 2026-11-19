import CryptoKit
import WatchtowerE2ETesting
import XCTest
@testable import WatchtowerSync

/// The one exception to the phone's key rule (relay client Phase 5, "The scheme", Task 13): when no key of the rule
/// opens an h2p record, the static key is tried and only a `hub_on_relay` control opened that way is taken.
final class SecureTransportStaticExceptionTests: XCTestCase {
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    /// A hub control of `kind` sealed under the static `wt/relay/v1/` key of `epoch`, as the Go hub seals once it
    /// cleared this phone's relay keys.
    private func staticControl(_ kind: ControlKind, epoch: UInt32, over phone: SecureTransport) throws -> CloudRecord {
        let control = ControlPayload(
            id: UUID().uuidString, kind: kind, deviceID: TestE2E.deviceID.uuidString, hubID: TestE2E.hubID.uuidString, seq: 1)
        let wire = try phone.wireName(plain: control.recordName, zone: .relay)
        let frame = InnerFrame(
            kind: RelayRecordKind.control.rawValue, id: control.recordName, payload: try RelayCoder.makeEncoder().encode(control))
        let envelope = try EnvelopeSealer.sealSymmetric(
            frame, envelopeClass: .relayToPhone,
            key: try TestE2E.hub().relayKey(.hubToPhone, deviceID: TestE2E.deviceID, epoch: epoch),
            hubID: TestE2E.hubID, senderID: TestE2E.hubID, epoch: epoch, seq: UInt64.random(in: 1_000 ... 1_000_000),
            context: EnvelopeContext(zone: .relay, wireName: wire), signer: nil)
        return CloudRecord(recordName: wire, zone: .relay, kind: WireKind.envelope, modifiedAt: stamp, payload: envelope)
    }

    /// The inner transport the phone's records are written to.
    private var inner = InMemoryCloudTransport()

    private func phone(_ store: InMemoryPhoneKeyStore) throws -> SecureTransport {
        inner = InMemoryCloudTransport()
        return SecureTransport(inner: inner, keys: try TestE2E.phone(store: store), rollback: InMemoryRollbackGuard())
    }

    private func pair(_ epoch: UInt32) throws -> EpochRelayKeys {
        try EphemeralLink.pair(
            epoch: epoch, device: Curve25519.KeyAgreement.PrivateKey(), hub: Curve25519.KeyAgreement.PrivateKey())
    }

    /// Each row of the key table, and a record epoch for which it applies.
    private func rows() throws -> [(name: String, store: InMemoryPhoneKeyStore, epoch: UInt32)] {
        let withPair = try TestE2E.phoneStore()
        try EphemeralLink.make(withPair, epochs: [1])
        try EphemeralLink.add(withPair, epoch: 2, pair: try pair(2))
        let heldNoPair = try TestE2E.phoneStore()
        try EphemeralLink.make(heldNoPair, epochs: [1, 2])
        let noState = try TestE2E.phoneStore(epochs: [1, 2])
        let pending = try TestE2E.phoneStore()
        try EphemeralLink.make(pending, epochs: [1])
        try EphemeralLink.add(pending, epoch: 2, pair: try pair(2))
        let gone = try TestE2E.phoneStore()
        try EphemeralLink.make(gone, epochs: [1])
        try EphemeralLink.add(gone, epoch: 3, pair: try pair(3))
        return [
            ("present with a stored pair", withPair, 2),
            ("present without a pair", heldNoPair, 2),
            ("absent, no ephemeral state", noState, 5),
            ("absent, above the newest held", pending, 5),
            ("absent, at or below the newest held", gone, 2)
        ]
    }

    func testHubOnRelayOpensOverAStaleEphemeralState() async throws {
        for row in try rows() {
            let phone = try phone(row.store)
            let notice = try staticControl(.hubOnRelay, epoch: row.epoch, over: phone)
            try await inner.save([notice])
            let opened = try await phone.changes(in: .relay, since: nil).changed
            XCTAssertEqual(opened.count, 1, "\(row.name): hub_on_relay sealed static opens")
            let control = try opened.first.map { try RelayCoder.makeDecoder().decode(ControlPayload.self, from: $0.payload) }
            XCTAssertEqual(control?.kind, .hubOnRelay, row.name)
        }
    }

    /// F28: anything but hub_on_relay opened on the static key is unopenable on a link whose rule names another key.
    func testAStaticEchoIsRefusedOnAnEphemeralLink() async throws {
        for row in try rows() where row.name == "present with a stored pair" || row.name == "absent, at or below the newest held" {
            let phone = try phone(row.store)
            try await inner.save([try staticControl(.resendFrom, epoch: row.epoch, over: phone)])
            let opened = try await phone.changes(in: .relay, since: nil).changed
            XCTAssertTrue(opened.isEmpty, "\(row.name): a static resend_from is not taken")
            let scan = try await phone.relayHygieneScan()
            XCTAssertEqual(scan.unopenable.count, 1, row.name)
        }
        // Above the newest held it still waits for its keybox, as before.
        let pending = try XCTUnwrap(try rows().first { $0.name == "absent, above the newest held" })
        let phone = try phone(pending.store)
        try await inner.save([try staticControl(.resendFrom, epoch: pending.epoch, over: phone)])
        do {
            _ = try await phone.changes(in: .relay, since: nil)
            XCTFail("a pending record must keep the token")
        } catch let error as SecureTransportError {
            XCTAssertEqual(error, .keysUnavailable)
        }
    }

    /// The side reader's scan: a record waiting for its keybox holds nothing back; the hub_on_relay behind it is read,
    /// and the pending record stays for later.
    func testTheSideReaderReadsPastAPendingEpochAndKeepsItsToken() async throws {
        let store = try TestE2E.phoneStore()
        try EphemeralLink.make(store, epochs: [1])
        try EphemeralLink.add(store, epoch: 2, pair: try pair(2))
        let phone = try phone(store)
        let hub = SecureTransport(inner: inner, keys: TestE2E.hub(epoch: 4), rollback: InMemoryRollbackGuard())
        // An owed echo in epoch 4, above the newest held, sealed under a key the phone may yet get.
        try await hub.save([CloudRecord(
            recordName: "action-a1", zone: .relay, kind: RelayRecordKind.action.rawValue, modifiedAt: stamp,
            payload: Data("{\"device_id\":\"\(TestE2E.deviceID.uuidString)\",\"id\":\"a1\",\"status\":\"applied\"}".utf8))])
        try await inner.save([try staticControl(.hubOnRelay, epoch: 4, over: phone)])

        let scan = try await phone.relayHygieneScan()
        XCTAssertEqual(scan.pending, 1, "the echo waits")
        XCTAssertEqual(scan.opened.map(\.kind), [RelayRecordKind.control.rawValue], "the notice behind it is read")
        XCTAssertTrue(scan.unopenable.isEmpty, "nothing dropped")
        // The keybox comes: the echo is read on the next pass.
        try EphemeralLink.add(store, epoch: 4)
        let after = try await phone.relayHygieneScan()
        XCTAssertEqual(after.pending, 0)
        XCTAssertEqual(Set(after.opened.map(\.kind)), [RelayRecordKind.action.rawValue, RelayRecordKind.control.rawValue])
    }
}
