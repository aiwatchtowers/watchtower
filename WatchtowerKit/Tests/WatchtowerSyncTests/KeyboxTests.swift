import XCTest
@testable import WatchtowerSync

final class KeyboxTests: XCTestCase {
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    private var grant: DeviceGrant {
        DeviceGrant(
            deviceID: "dev-1", hubID: "hub-1", name: "Acme iPhone", scope: .private, linked: true,
            linkedAt: stamp, typingAllowed: false, startSessionsAllowed: true, decidedAt: stamp)
    }

    private var keys: KeyboxKeys {
        KeyboxKeys(
            epoch: 3, dataKey: "ZGF0YQ", alertKey: "YWxlcnQ", metaKey: "bWV0YQ",
            previousEpoch: nil, previousDataKey: nil, previousAlertKey: nil)
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testAKeyboxEncodesTheGrantByteForByteAsDeviceGrant() throws {
        let keybox = Keybox(grant: grant, keys: keys)
        let encoded = try RelayCoder.makeEncoder().encode(keybox)
        let grantJSON = try RelayCoder.makeEncoder().encode(grant)
        let nested = try XCTUnwrap(object(encoded)["grant"])
        let renested = try JSONSerialization.data(withJSONObject: nested, options: [.sortedKeys])
        XCTAssertEqual(renested, try JSONSerialization.data(
            withJSONObject: JSONSerialization.jsonObject(with: grantJSON), options: [.sortedKeys]))
        XCTAssertEqual(try RelayCoder.makeDecoder().decode(DeviceGrant.self, from: renested), grant)
        XCTAssertEqual(try RelayCoder.makeDecoder().decode(Keybox.self, from: encoded), keybox)
        // The grant sits as a contiguous byte range of the keybox JSON.
        XCTAssertNotNil(encoded.range(of: grantJSON))
    }

    func testAbsentKeysAndFlagsAreAbsentKeys() throws {
        let json = try XCTUnwrap(String(
            data: try RelayCoder.makeEncoder().encode(Keybox(grant: grant, keys: nil)), encoding: .utf8))
        XCTAssertFalse(json.contains("keys"), json)
        XCTAssertFalse(json.contains("awaiting_confirmation"), json)
        XCTAssertFalse(json.contains("confirm_nonce"), json)
        XCTAssertFalse(json.contains("revoked"), json)
        XCTAssertFalse(json.contains("null"), json)

        let keyJSON = try XCTUnwrap(String(
            data: try RelayCoder.makeEncoder().encode(keys), encoding: .utf8))
        XCTAssertFalse(keyJSON.contains("previous"), keyJSON)
        XCTAssertTrue(keyJSON.contains(#""data_key":"ZGF0YQ""#), keyJSON)
    }

    func testPreviousEpochKeysRoundTrip() throws {
        let withPrevious = KeyboxKeys(
            epoch: 4, dataKey: "a", alertKey: "b", metaKey: "c", previousEpoch: 3, previousDataKey: "d", previousAlertKey: "e")
        let keybox = Keybox(grant: grant, keys: withPrevious)
        let decoded = try RelayCoder.makeDecoder().decode(Keybox.self, from: RelayCoder.makeEncoder().encode(keybox))
        XCTAssertEqual(decoded, keybox)
    }

    func testGrantStatesTravelAsOptionalFlags() throws {
        let waiting = DeviceGrant(
            deviceID: "d", hubID: "h", name: "n", scope: .shared, linked: false, typingAllowed: false,
            startSessionsAllowed: true, awaitingConfirmation: true)
        let revoked = DeviceGrant(
            deviceID: "d", hubID: "h", name: "n", scope: .shared, linked: false, linkRefused: .notConfirmed,
            typingAllowed: false, startSessionsAllowed: true, revoked: true)
        for value in [waiting, revoked] {
            let data = try RelayCoder.makeEncoder().encode(value)
            XCTAssertEqual(try RelayCoder.makeDecoder().decode(DeviceGrant.self, from: data), value)
        }
        let json = try XCTUnwrap(String(data: try RelayCoder.makeEncoder().encode(waiting), encoding: .utf8))
        XCTAssertTrue(json.contains(#""awaiting_confirmation":true"#), json)
        XCTAssertFalse(json.contains("revoked"), json)
        XCTAssertEqual(LinkRefusal.notConfirmed.rawValue, "not_confirmed")
        XCTAssertTrue(LinkRefusal.knownValues.contains(.notConfirmed))
    }

    /// SAS v2: the waiting keybox carries the hub's confirm nonce (base64url of 32 bytes) as `confirm_nonce`.
    func testTheWaitingGrantCarriesTheConfirmNonce() throws {
        let nonce = WireBytes.base64URL(Data(repeating: 0xAB, count: KeyDerivation.confirmNonceLength))
        let waiting = DeviceGrant(
            deviceID: "d", hubID: "h", name: "n", scope: .private, linked: false, typingAllowed: false,
            startSessionsAllowed: true, awaitingConfirmation: true, confirmNonce: nonce)
        let data = try RelayCoder.makeEncoder().encode(Keybox(grant: waiting, keys: nil))
        XCTAssertEqual(try RelayCoder.makeDecoder().decode(Keybox.self, from: data).grant.confirmNonce, nonce)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains(#""confirm_nonce":"\#(nonce)""#), json)
        XCTAssertEqual(LinkRefusal.tooManyRequests.rawValue, "too_many_requests")
        XCTAssertTrue(LinkRefusal.knownValues.contains(.tooManyRequests))
    }

    func testNamesAreKeyFree() {
        XCTAssertEqual(Keybox.recordName(deviceID: "D1"), "keybox-D1")
    }

    func testHelloCarriesTheDevicePayloadAndPublicKeys() throws {
        let device = DevicePayload(
            deviceID: "D1", name: "Acme iPhone", model: "iPhone", appVersion: "1.0", scope: .private,
            userRecordName: "_owner", linkNonce: "n", typingRequested: false, startSessions: true, updatedAt: stamp)
        let hello = DeviceHello(device: device, signingKey: "c2ln", agreementKey: "a3g")
        XCTAssertEqual(hello.recordName, "hello-D1")
        let data = try RelayCoder.makeEncoder().encode(hello)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains(#""signing_key":"c2ln""#), json)
        XCTAssertTrue(json.contains(#""agreement_key":"a3g""#), json)
        XCTAssertEqual(try RelayCoder.makeDecoder().decode(DeviceHello.self, from: data), hello)
        let record = try CloudRecordFactory.record(for: hello, modifiedAt: stamp)
        XCTAssertEqual(record.recordName, "hello-D1")
        XCTAssertEqual(record.kind, "hello")
        XCTAssertEqual(record.zone, .relay)
        XCTAssertEqual(record.payload, data)
    }
}
