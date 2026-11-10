import CryptoKit
import XCTest
@testable import WatchtowerSync

/// The proof a phone's `relay_auth` key gives for the relay id its device record names (Task 23, protocol §5.5),
/// against the shared fixture's `device_payload` vector, which the Go hub signed.
final class RelayIDProofTests: XCTestCase {
    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // WatchtowerSyncTests
        .deletingLastPathComponent() // Tests
        .appendingPathComponent("Fixtures/link/hub_contract_cases.json")

    private func provenCase() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.fixtureURL)
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [[String: Any]]])
        return try XCTUnwrap(fixture["device_payload"]?.first { $0["name"] as? String == "with_proven_relay_id" })
    }

    /// The Kit signs the bytes the Go vector signed: the fixture's signature verifies over `message`, and the
    /// Kit's own signature (CryptoKit's are randomized, so not the same bytes) names the same id and key and passes
    /// `verify`.
    func testTheFixtureVectorSignsTheSameBytes() throws {
        let vector = try provenCase()
        let json = try XCTUnwrap(vector["json"] as? [String: Any])
        let seed = try XCTUnwrap(WireBytes.fromBase64URL(try XCTUnwrap(vector["relay_auth_seed"] as? String)))
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let hubID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(vector["hub_id"] as? String)))
        let deviceID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(json["device_id"] as? String)))
        let relayID = try XCTUnwrap(json["relay_device_id"] as? String)

        let goSig = try XCTUnwrap(WireBytes.fromBase64URL(try XCTUnwrap(json["relay_id_sig"] as? String)))
        XCTAssertTrue(key.publicKey.isValidSignature(goSig, for: RelayIDProof.message(hubID: hubID, deviceID: deviceID, relayDeviceID: relayID)))

        let signed = try RelayIDProof.sign(authPub: key.publicKey.rawRepresentation, hubID: hubID, deviceID: deviceID) {
            try key.signature(for: $0)
        }
        XCTAssertEqual(signed.relayDeviceID, relayID)
        XCTAssertEqual(signed.authPub, json["relay_auth_pub"] as? String)
        let payload = DevicePayload(
            deviceID: deviceID.uuidString, name: "Test Phone", model: "iPhone", appVersion: "1.0", scope: .private,
            userRecordName: "_owner0000", typingRequested: false, startSessions: true,
            updatedAt: Date(timeIntervalSince1970: 1_730_000_000),
            relayDeviceID: signed.relayDeviceID, relayAuthPub: signed.authPub, relayIDSig: signed.sig
        )
        XCTAssertTrue(RelayIDProof.verify(payload, hubID: hubID, deviceID: deviceID))
        XCTAssertFalse(RelayIDProof.verify(payload, hubID: UUID(), deviceID: deviceID))
        XCTAssertFalse(RelayIDProof.verify(payload, hubID: hubID, deviceID: UUID()))
    }

    /// `"watchtower/v1/relay-id" ‖ 0x00 ‖ hub_id ‖ device_id ‖ relay_device_id`: each part changes the message.
    func testTheMessageBindsHubDeviceAndRelayID() throws {
        let hubID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001"))
        let deviceID = try XCTUnwrap(UUID(uuidString: "BBBBBBBB-0000-4000-8000-000000000002"))
        let relayID = RelayIDs.deviceID(publicKey: Data(repeating: 7, count: 32))
        let message = RelayIDProof.message(hubID: hubID, deviceID: deviceID, relayDeviceID: relayID)
        var want = Data("watchtower/v1/relay-id".utf8)
        want.append(0)
        want.append(WireBytes.bytes(of: hubID))
        want.append(WireBytes.bytes(of: deviceID))
        want.append(Data(relayID.utf8))
        XCTAssertEqual(message, want)
        XCTAssertEqual(message.count, 22 + 1 + 16 + 16 + 52)
        XCTAssertNotEqual(RelayIDProof.message(hubID: deviceID, deviceID: hubID, relayDeviceID: relayID), message)
        let otherID = RelayIDs.deviceID(publicKey: Data(repeating: 8, count: 32))
        XCTAssertNotEqual(RelayIDProof.message(hubID: hubID, deviceID: deviceID, relayDeviceID: otherID), message)
    }
}
