import CryptoKit
import WatchtowerE2ETesting
import XCTest
@testable import WatchtowerSync

/// The notification extension's half of `K_alert` (mobile E2E spec §2.2, §2.6, F21): an `ask_alert` envelope opens
/// with the alert key and the hub's public signing key only, both read from the shared alert group.
final class AlertOpenerTests: XCTestCase {
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)
    private var hubID: String { TestE2E.hubID.uuidString }

    /// The hub's payload as `AskAlertSlice` encodes it (RelayCoder: snake_case keys, sorted).
    private let alertJSON = """
        {"ask_id":42,"kind":"question","quick":true,"session_id":7,"title":"Approve the Acme rollout plan",\
        "workbench_id":3,"workbench_name":"Acme"}
        """

    private func alertRecord(id: String = "42") -> CloudRecord {
        CloudRecord(
            recordName: SliceKind.askAlert.recordName(id: id), zone: .data, kind: SliceKind.askAlert.rawValue,
            modifiedAt: stamp, payload: Data(alertJSON.utf8))
    }

    private func seal(_ record: CloudRecord, epoch: UInt32 = 1) async throws -> CloudRecord {
        try await TestE2E.hubTransport(TestE2E.hub(epoch: epoch)).seal(record)
    }

    private func material(epochs: [UInt32] = [1]) throws -> AlertMaterial {
        try XCTUnwrap(TestE2E.phoneStore(epochs: epochs).alertMaterial(hubID))
    }

    private let expected = AskAlertPayload(
        askID: 42, workbenchID: 3, workbenchName: "Acme", sessionID: 7, kind: "question",
        title: "Approve the Acme rollout plan", quick: true)

    func testAnAlertOpensWithTheAlertKeyOnly() async throws {
        let wire = try await seal(alertRecord())
        let opener = AlertOpener(material: try material())

        XCTAssertEqual(try opener.payload(wireName: wire.recordName, envelope: wire.payload), expected)

        // The data key of the same epoch does not open it.
        XCTAssertThrowsError(try EnvelopeSealer.openSymmetric(
            wire.payload, accepting: [.alert], context: EnvelopeContext(zone: .data, wireName: wire.recordName),
            verifier: TestE2E.hubSigningKey.publicKey
        ) { _ in TestE2E.dataKey(epoch: 1) }) { XCTAssertEqual($0 as? EnvelopeError, .authenticationFailed) }

        // A `.data` envelope is refused by class, before any key is tried.
        let data = try await seal(CloudRecord(
            recordName: SliceKind.ownerAsk.recordName(id: "42"), zone: .data, kind: SliceKind.ownerAsk.rawValue,
            modifiedAt: stamp, payload: Data("{}".utf8)))
        XCTAssertThrowsError(try opener.payload(wireName: data.recordName, envelope: data.payload)) {
            XCTAssertEqual($0 as? EnvelopeError, .wrongClass(.data))
        }
        XCTAssertNil(opener.open(wireName: data.recordName, envelope: data.payload))

        // An alert envelope whose frame is not an ask alert is refused too.
        let other = try EnvelopeSealer.sealSymmetric(
            InnerFrame(kind: SliceKind.ownerAsk.rawValue, id: "owner_ask-42", payload: Data(alertJSON.utf8)),
            envelopeClass: .alert, key: TestE2E.alertKey(epoch: 1), hubID: TestE2E.hubID, senderID: TestE2E.hubID,
            epoch: 1, seq: 9, context: EnvelopeContext(zone: .data, wireName: "other"), signer: TestE2E.hubSigningKey)
        XCTAssertThrowsError(try opener.payload(wireName: "other", envelope: other)) {
            XCTAssertEqual($0 as? EnvelopeError, .frameMalformed)
        }
    }

    /// The shared-group item carries the alert keys and the hub's public signing key, nothing else (§2.6).
    func testTheAlertStoreHoldsNoDataOrMetaKey() throws {
        let backend = FakeKeychainBackend()
        let store = KeychainPhoneKeyStore(backend: backend, privateGroup: "TEAM.private", alertGroup: "TEAM.alerts")
        let dataKey = Data(repeating: 0xD1, count: 32), metaKey = Data(repeating: 0xA1, count: 32)
        let agreementKey = Data(repeating: 0x08, count: 32), linkNonce = Data(repeating: 0x09, count: 16)
        try store.saveHubLink(HubLinkKeys(
            hubID: "hub-1", hubSigningKey: Data(repeating: 0x07, count: 32), hubAgreementKey: agreementKey,
            linkNonce: linkNonce, metaKey: metaKey,
            epochs: [EpochKeys(epoch: 1, dataKey: dataKey, alertKey: Data(repeating: 0xE1, count: 32))]))

        let shared = backend.writes.filter { $0.group == "TEAM.alerts" }
        XCTAssertEqual(shared.map(\.account), ["alert.hub-1"], "one item in the shared group")
        let bytes = try XCTUnwrap(shared.first?.data)
        for secret in [dataKey, metaKey, agreementKey, linkNonce] {
            XCTAssertNil(bytes.firstRange(of: secret), "raw secret in the shared item")
            XCTAssertNil(bytes.firstRange(of: Data(secret.base64EncodedString().utf8)), "base64 secret in the shared item")
        }
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["epochs", "hubSigningKey"])
        let epochs = try XCTUnwrap(object["epochs"] as? [[String: Any]])
        XCTAssertEqual(epochs.map { $0["dataKey"] as? String }, [""], "the data key slot is empty")
    }

    /// F21: the opener is built from `AlertMaterial` alone, so it cannot reach a private item by construction.
    func testTheOpenerNeedsOnlyAlertMaterial() async throws {
        let wire = try await seal(alertRecord())
        let material = try material()
        let opener = AlertOpener(material: material)
        XCTAssertEqual(Mirror(reflecting: opener).children.map(\.label), ["material"], "no store, no other key")
        XCTAssertEqual(opener.open(wireName: wire.recordName, envelope: wire.payload), expected)

        let wrongSigner = AlertMaterial(
            epochs: material.epochs, hubSigningKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        XCTAssertThrowsError(try AlertOpener(material: wrongSigner).payload(wireName: wire.recordName, envelope: wire.payload)) {
            XCTAssertEqual($0 as? EnvelopeError, .signatureInvalid)
        }
        XCTAssertNil(AlertOpener(material: wrongSigner).open(wireName: wire.recordName, envelope: wire.payload))

        // The AAD binds the record name: the envelope moved under another name does not open.
        XCTAssertNil(opener.open(wireName: "moved", envelope: wire.payload))
    }

    /// Task 14: a rotation reseals open alerts under the new epoch without a new signal, so an alert of the current
    /// and of the previous epoch both open; an epoch the material does not hold is nil (the generic text is shown).
    func testAnAlertOfAnUnknownEpochFailsQuietly() async throws {
        let material = try material(epochs: [1, 2])
        let opener = AlertOpener(material: material)
        for epoch: UInt32 in [1, 2] {
            let wire = try await seal(alertRecord(), epoch: epoch)
            XCTAssertEqual(opener.open(wireName: wire.recordName, envelope: wire.payload), expected, "epoch \(epoch)")
        }
        let newer = try await seal(alertRecord(), epoch: 3)
        XCTAssertNil(opener.open(wireName: newer.recordName, envelope: newer.payload))
        XCTAssertThrowsError(try opener.payload(wireName: newer.recordName, envelope: newer.payload)) {
            XCTAssertEqual($0 as? SecureTransportError, .keysUnavailable)
        }
        XCTAssertNil(opener.open(wireName: "garbage", envelope: Data("not an envelope".utf8)))
    }

    /// A payload that does not decode is `frameMalformed`, never a `DecodingError` that could carry its content.
    func testAnUndecodablePayloadIsMalformed() async throws {
        var record = alertRecord()
        record = CloudRecord(
            recordName: record.recordName, zone: .data, kind: record.kind, modifiedAt: stamp, payload: Data("{\"ask_id\":\"x\"}".utf8))
        let wire = try await seal(record)
        XCTAssertThrowsError(try AlertOpener(material: try material()).payload(wireName: wire.recordName, envelope: wire.payload)) {
            XCTAssertEqual($0 as? EnvelopeError, .frameMalformed)
        }
    }

    /// The extension reads the material from the alert group without a full phone key store.
    func testTheExtensionReadsTheMaterialFromTheAlertGroupDirectly() throws {
        let backend = FakeKeychainBackend()
        let store = KeychainPhoneKeyStore(backend: backend, privateGroup: "TEAM.private", alertGroup: "TEAM.alerts")
        let keys = HubLinkKeys(
            hubID: "hub-1", hubSigningKey: Data(repeating: 0x07, count: 32), hubAgreementKey: Data(repeating: 0x08, count: 32),
            linkNonce: Data(repeating: 0x09, count: 16), metaKey: Data(repeating: 0xA1, count: 32),
            epochs: [EpochKeys(epoch: 1, dataKey: Data(repeating: 0xD1, count: 32), alertKey: Data(repeating: 0xE1, count: 32))])
        try store.saveHubLink(keys)
        XCTAssertEqual(
            try KeychainPhoneKeyStore.alertMaterial("hub-1", backend: backend, alertGroup: "TEAM.alerts"),
            try store.alertMaterial("hub-1"))
        XCTAssertNil(try KeychainPhoneKeyStore.alertMaterial("hub-1", backend: backend, alertGroup: "TEAM.private"))
    }
}
