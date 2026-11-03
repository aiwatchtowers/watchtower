import CryptoKit
import XCTest
@testable import WatchtowerSync

/// The reverse vectors: records sealed by the Go hub's `secure.Sealer` with the fixture keys
/// (`internal/hub/secure/testdata/go-sealed.json`, written by `go test ./internal/hub/secure -run TestWriteGoSealed -update`)
/// open in the Kit, and their frames equal the stored plaintext.
final class GoSealedEnvelopeTests: XCTestCase {
    private struct Case: Decodable {
        var `class`: UInt16
        var zone: String
        var wireName: String
        var sender: String
        var kind: String
        var id: String
        var notifyLevel: String
        var asset: String
        var payload: String
        var envelope: String
    }

    private struct File: Decodable {
        var epoch: UInt32
        var cases: [String: Case]
    }

    /// `<repo>/internal/hub/secure/testdata/go-sealed.json`: this file sits in `WatchtowerKit/Tests/WatchtowerSyncTests/`.
    private static let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // WatchtowerSyncTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // WatchtowerKit
        .deletingLastPathComponent() // repo
        .appendingPathComponent("internal/hub/secure/testdata/go-sealed.json")

    func testEveryGoSealedRecordOpensInTheKit() throws {
        let k = try E2EFixtureKeys()
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: Self.url))
        XCTAssertEqual(Set(file.cases.keys), ["data", "alert", "relayToPhone", "keybox", "alertPush"])
        let metaKey = SymmetricKey(data: E2EFixtureKeys.metaKeyBytes)
        let hubToPhone = try KeyDerivation.relayKey(
            agreementPrivate: k.hubKX, peerPublic: k.devKX.publicKey, linkNonce: k.linkNonce,
            hubID: k.hubID, deviceID: k.deviceID, epoch: file.epoch, direction: .hubToPhone)

        for (name, item) in file.cases.sorted(by: { $0.key < $1.key }) {
            let zone = try XCTUnwrap(CloudZoneID(rawValue: item.zone), name)
            let envelopeClass = try XCTUnwrap(EnvelopeClass(rawValue: item.class), name)
            let context = EnvelopeContext(zone: zone, wireName: item.wireName)
            let data = Data(hex: item.envelope)
            let opened: (header: EnvelopeHeader, frame: InnerFrame)
            switch envelopeClass {
            case .data, .alert:
                let key = SymmetricKey(data: envelopeClass == .data ? HPKEEnvelopeVectors.dataKeyBytes : E2EFixtureKeys.sequence(0xD0, 0xEF))
                opened = try EnvelopeSealer.openSymmetric(
                    data, accepting: [envelopeClass], context: context, verifier: k.hubSig.publicKey) { _ in key }
            case .relayToPhone:
                opened = try EnvelopeSealer.openSymmetric(
                    data, accepting: [.relayToPhone], context: context, verifier: nil) { _ in hubToPhone }
            case .keybox:
                opened = try SealedBox.open(
                    data, envelopeClass: .keybox, recipient: k.devKX,
                    info: SealedBox.keyboxInfo(hubID: k.hubID, deviceID: k.deviceID), context: context,
                    verifier: k.hubSig.publicKey)
                XCTAssertEqual(item.wireName, Keybox.recordName(deviceID: k.deviceID.uuidString), name)
            default:
                XCTFail("\(name): unexpected class \(item.class)")
                continue
            }
            let asset = item.asset.isEmpty ? nil : try AssetDescriptor.parse(Data(hex: item.asset))
            XCTAssertEqual(
                opened.frame,
                InnerFrame(
                    kind: item.kind, id: item.id, notifyLevel: item.notifyLevel.isEmpty ? nil : item.notifyLevel,
                    asset: asset, payload: Data(hex: item.payload)),
                name)
            XCTAssertEqual(opened.header.hubID, k.hubID, name)
            XCTAssertEqual(opened.header.senderID.uuidString, item.sender, name)
            XCTAssertEqual(opened.header.epoch, file.epoch, name)
            if name == "alertPush" {
                // A push is no zone record: its AAD names the fixed wire name.
                XCTAssertEqual(item.wireName, "alert-push", name)
            } else if envelopeClass != .keybox {
                // Go names records exactly as SecureTransport: the plain name split at its first "-".
                let parts = item.id.split(separator: "-", maxSplits: 1).map(String.init)
                XCTAssertEqual(
                    item.wireName,
                    KeyDerivation.recordName(metaKey: metaKey, zone: zone, kind: parts[0], id: parts.count > 1 ? parts[1] : ""),
                    name)
            }
        }
    }

    /// The Go hub's relay push (`secure.Sealer.AlertPush`) opens in the notification extension's `AlertOpener` under
    /// `"alert-push"` with the alert material alone, and never under the `ask_alert` record's own wire name.
    func testGoSealedAlertPushOpensWithAlertOpener() throws {
        let k = try E2EFixtureKeys()
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: Self.url))
        let item = try XCTUnwrap(file.cases["alertPush"])
        let material = AlertMaterial(
            epochs: [EpochKeys(
                epoch: file.epoch, dataKey: HPKEEnvelopeVectors.dataKeyBytes, alertKey: E2EFixtureKeys.sequence(0xD0, 0xEF))],
            hubSigningKey: k.hubSig.publicKey.rawRepresentation)
        let opener = AlertOpener(material: material)
        let envelope = Data(hex: item.envelope)

        let expected = try JSONDecoder().decode(WorkAlertPayload.self, from: Data(hex: item.payload))
        XCTAssertEqual(opener.open(wireName: "alert-push", envelope: envelope), expected)
        XCTAssertEqual(expected.key, "ask-42")
        XCTAssertEqual(expected.requestID, 11, "every WorkAlertPayload key is in the fixture")
        XCTAssertEqual(item.id, "ask_alert-ask-42")

        let parts = item.id.split(separator: "-", maxSplits: 1).map(String.init)
        let recordName = KeyDerivation.recordName(
            metaKey: SymmetricKey(data: E2EFixtureKeys.metaKeyBytes), zone: .data, kind: parts[0], id: parts[1])
        XCTAssertNil(opener.open(wireName: recordName, envelope: envelope))
    }
}
