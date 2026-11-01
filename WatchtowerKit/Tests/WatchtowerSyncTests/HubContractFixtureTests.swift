import CryptoKit
import XCTest
@testable import WatchtowerSync

/// The phone side of the shared phone <-> hub contract fixture
/// (`Tests/Fixtures/link/hub_contract_cases.json`, go hub spec §12a). The Go
/// hub's `internal/hub/wire` reads the same file.
final class HubContractFixtureTests: XCTestCase {
    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // WatchtowerSyncTests
        .deletingLastPathComponent() // Tests
        .appendingPathComponent("Fixtures/link/hub_contract_cases.json")

    private func load() throws -> [String: [[String: Any]]] {
        let data = try Data(contentsOf: Self.fixtureURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [[String: Any]]])
    }

    /// Re-serialises a fixture object (the `json` member) to bytes for the decoder.
    private func bytes(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    func testDeviceGrantCasesDecodeAndIgnoreNewKeys() throws {
        let cases = try XCTUnwrap(load()["device_grant"])
        XCTAssertFalse(cases.isEmpty)
        for fixtureCase in cases {
            let name = try XCTUnwrap(fixtureCase["name"] as? String)
            let grant = try RelayCoder.makeDecoder().decode(DeviceGrant.self, from: bytes(try XCTUnwrap(fixtureCase["json"])))
            // The expected decoding (new keys included) reads to the same grant.
            let expected = try RelayCoder.makeDecoder().decode(DeviceGrant.self, from: bytes(try XCTUnwrap(fixtureCase["expect"])))
            XCTAssertEqual(grant, expected, name)

            let kit = try XCTUnwrap(fixtureCase["kit"] as? [String: Any], name)
            XCTAssertEqual(grant.linked, kit["linked"] as? Bool, name)
            XCTAssertEqual(grant.awaitingConfirmation, kit["awaiting_confirmation"] as? Bool, name)
            XCTAssertEqual(grant.confirmNonce, kit["confirm_nonce"] as? String, name)
            XCTAssertEqual(grant.linkCodeTag, kit["link_code_tag"] as? String, name)
            XCTAssertEqual(grant.revoked, kit["revoked"] as? Bool, name)
            XCTAssertEqual(grant.mayStartSessions, kit["may_start_sessions"] as? Bool, name)
            XCTAssertEqual(grant.permissionsAllowed, kit["permissions_allowed"] as? Bool, name)
            XCTAssertEqual(grant.name, kit["name"] as? String, name)
            XCTAssertEqual(grant.scope.rawValue, kit["scope"] as? String, name)
            XCTAssertEqual(grant.typingAllowed, kit["typing_allowed"] as? Bool, name)
            XCTAssertEqual(grant.linkedAt?.timeIntervalSince1970, kit["linked_at"] as? Double, name)
            XCTAssertEqual(grant.decidedAt?.timeIntervalSince1970, kit["decided_at"] as? Double, name)
            XCTAssertTrue(kit.keys.contains("ordered_actions"), name)
            let ordered = kit["ordered_actions"] as? Int
            XCTAssertEqual(grant.orderedActions, ordered, name)
            XCTAssertEqual(grant.runsOrderedActions, (ordered ?? 0) >= 1, name)
        }
    }

    /// Equal as JSON objects (key order and number spelling aside).
    private func assertSameJSON(_ data: Data, _ expected: Any, _ name: String) throws {
        let got = try JSONSerialization.jsonObject(with: data) as? NSDictionary
        XCTAssertEqual(got, expected as? NSDictionary, name)
    }

    /// The phone's action payloads: `action_seq` is read and written exactly as the Go `wire.ActionRequest`
    /// does, and the re-encoding carries no key the Go struct lacks.
    /// Compares with `expect` (the Go `wire.Marshal` re-encoding), which equals `json` minus dropped unknown keys.
    func testActionCasesRoundTrip() throws {
        let cases = try XCTUnwrap(load()["action"])
        XCTAssertGreaterThanOrEqual(cases.count, 4)
        for fixtureCase in cases {
            let name = try XCTUnwrap(fixtureCase["name"] as? String)
            let action = try RelayCoder.makeDecoder().decode(ActionRequestPayload.self, from: bytes(try XCTUnwrap(fixtureCase["json"])))
            let kit = try XCTUnwrap(fixtureCase["kit"] as? [String: Any], name)
            let seq = (kit["action_seq"] as? NSNumber)?.uint64Value
            XCTAssertEqual(action.actionSeq, seq, name)
            XCTAssertEqual(action.status.rawValue, kit["status"] as? String, name)
            let recordName: String
            if let seq {
                let device = try XCTUnwrap(action.deviceID.flatMap(UUID.init(uuidString:)), name)
                recordName = ActionRequestPayload.orderedRecordName(deviceID: device, actionSeq: seq)
            } else {
                recordName = action.recordName
            }
            XCTAssertEqual(recordName, kit["record_name"] as? String, name)
            try assertSameJSON(RelayCoder.makeEncoder().encode(action), try XCTUnwrap(fixtureCase["expect"]), name)
        }
    }

    /// Control records decode whatever their kind; an unknown kind keeps its raw value, and the keybox inside
    /// `transport_switched` is ignored in Phase 1.
    func testControlCasesDecode() throws {
        let cases = try XCTUnwrap(load()["control"])
        XCTAssertGreaterThanOrEqual(cases.count, 5)
        for fixtureCase in cases {
            let name = try XCTUnwrap(fixtureCase["name"] as? String)
            let control = try RelayCoder.makeDecoder().decode(ControlPayload.self, from: bytes(try XCTUnwrap(fixtureCase["json"])))
            let kit = try XCTUnwrap(fixtureCase["kit"] as? [String: Any], name)
            XCTAssertEqual(control.kind.rawValue, kit["kind"] as? String, name)
            XCTAssertEqual(control.deviceID, kit["device_id"] as? String, name)
            XCTAssertEqual(control.hubID, kit["hub_id"] as? String, name)
            XCTAssertEqual(control.seq, (kit["seq"] as? NSNumber)?.uint64Value, name)
            XCTAssertEqual(control.epoch, (kit["epoch"] as? NSNumber)?.uint32Value, name)
            XCTAssertEqual(control.target, kit["target"] as? String, name)
            XCTAssertEqual(control.by, kit["by"] as? String, name)
            XCTAssertEqual(control.at?.timeIntervalSince1970, kit["at"] as? Double, name)
            XCTAssertEqual(control.reason, kit["reason"] as? String, name)
            XCTAssertEqual(control.retryAfterS, (kit["retry_after_s"] as? NSNumber)?.uint32Value, name)
            XCTAssertEqual(control.recordName, kit["record_name"] as? String, name)
            // `expect` is Go's re-encoding; keys the Kit does not read yet (the keybox) are listed in `ignored_keys`.
            var expected = try XCTUnwrap(fixtureCase["expect"] as? [String: Any], name)
            for key in kit["ignored_keys"] as? [String] ?? [] {
                expected.removeValue(forKey: key)
            }
            try assertSameJSON(RelayCoder.makeEncoder().encode(control), expected, name)
        }
        let unknown = try XCTUnwrap(cases.first { $0["name"] as? String == "unknown_kind" })
        let decoded = try RelayCoder.makeDecoder().decode(ControlPayload.self, from: bytes(try XCTUnwrap(unknown["json"])))
        XCTAssertFalse(decoded.kind.isKnown)
        XCTAssertEqual(decoded.kind.rawValue, "future_control")
    }

    private func linkCase(_ name: String) throws -> [String: Any] {
        let cases = try XCTUnwrap(load()["link_payload"])
        return try XCTUnwrap(cases.first { $0["name"] as? String == name }, name)
    }

    /// A `watchtower://link` URL carrying `object`, sorted keys as the link encoder writes them.
    private func linkURL(_ object: [String: Any]) throws -> URL {
        let json = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return try XCTUnwrap(URL(string: "watchtower://link?d=" + WireBytes.base64URL(json)))
    }

    /// The relay identity a case's fixed seed derives: base64url `relay_auth` public key and relay device id.
    private func relayPair(seed: Any?) throws -> (pub: String, id: String) {
        let seedBytes = try XCTUnwrap(WireBytes.fromBase64URL(try XCTUnwrap(seed as? String)))
        let pub = try Curve25519.Signing.PrivateKey(rawRepresentation: seedBytes).publicKey.rawRepresentation
        return (WireBytes.base64URL(pub), RelayIDs.deviceID(publicKey: pub))
    }

    /// Owner approval 5: a v4 code decodes on this phone. `v4_desktop` offers both routes, `v4_headless` the relay
    /// only; both carry the relay identity their seed derives.
    func testV4LinksDecodeOnThisPhone() throws {
        for name in ["v4_desktop", "v4_headless"] {
            let fixtureCase = try linkCase(name)
            let url = try XCTUnwrap(URL(string: try XCTUnwrap(fixtureCase["url"] as? String)), name)
            let payload = try LinkPayload.parse(url).get()
            let kit = try XCTUnwrap(fixtureCase["kit"] as? [String: Any], name)
            XCTAssertEqual(payload.v, 4, name)
            XCTAssertEqual(payload.offersCloudKit, kit["offers_cloudkit"] as? Bool, name)
            XCTAssertEqual(payload.offersRelay, kit["offers_relay"] as? Bool, name)
            XCTAssertEqual(payload.container, kit["container"] as? String, name)
            XCTAssertEqual(payload.ownerUser, kit["owner_user"] as? String, name)
            XCTAssertEqual(payload.transport?.rawValue, kit["transport"] as? String, name)
            XCTAssertEqual(payload.transports, kit["transports"] as? [String], name)
            XCTAssertEqual(payload.relayDeviceID, kit["relay_device_id"] as? String, name)
            XCTAssertEqual(payload.relayAuthPub, kit["relay_auth_pub"] as? String, name)
            XCTAssertEqual(payload.dataShare, kit["data_share"] as? String, name)
            XCTAssertEqual(payload.relayShare, kit["relay_share"] as? String, name)
            let pair = try relayPair(seed: fixtureCase["relay_auth_seed"])
            XCTAssertEqual(payload.relayAuthPub, pair.pub, name)
            XCTAssertEqual(payload.relayDeviceID, pair.id, name)
            // The Kit writes the bytes Go wrote (Go re-encodes the fixture URL from `expect`).
            XCTAssertEqual(payload.url().absoluteString, fixtureCase["url"] as? String, name)
        }
        XCTAssertFalse(try LinkPayload.parse(try linkURL(try XCTUnwrap(linkCase("v4_headless")["expect"] as? [String: Any]))).get().offersCloudKit)
    }

    func testV5IsStillNewerAndV2Older() throws {
        let newer = try linkCase("v5_newer")
        XCTAssertEqual(newer["kit"] as? String, "newer_version")
        XCTAssertEqual(LinkPayload.parse(try XCTUnwrap(URL(string: try XCTUnwrap(newer["url"] as? String)))), .failure(.newerVersion))
        var object = try XCTUnwrap(linkCase("v4_desktop")["expect"] as? [String: Any])
        object["v"] = 5
        XCTAssertEqual(LinkPayload.parse(try linkURL(object)), .failure(.newerVersion))
        object["v"] = 2
        XCTAssertEqual(LinkPayload.parse(try linkURL(object)), .failure(.olderVersion))
    }

    /// R6: the phone vouches for `relay_auth_pub` and opens a slot for `relay_device_id`, so a pair that does not
    /// match, a malformed key or half a pair is refused.
    func testAMismatchedRelayIdentityIsRefused() throws {
        let base = try XCTUnwrap(linkCase("v4_desktop")["expect"] as? [String: Any])
        let other = try relayPair(seed: WireBytes.base64URL(Data(repeating: 0x07, count: 32)))
        var variants: [[String: Any]] = []
        var object = base
        object["relay_device_id"] = other.id
        variants.append(object)
        object = base
        object["relay_auth_pub"] = other.pub
        variants.append(object)
        object = base
        object["relay_auth_pub"] = WireBytes.base64URL(Data(count: 32))
        variants.append(object)
        object = base
        object["relay_auth_pub"] = WireBytes.base64URL(Data(repeating: 1, count: 31))
        variants.append(object)
        object = base
        object.removeValue(forKey: "relay_auth_pub")
        variants.append(object)
        object = base
        object.removeValue(forKey: "relay_device_id")
        variants.append(object)
        for (index, variant) in variants.enumerated() {
            XCTAssertEqual(LinkPayload.parse(try linkURL(variant)), .failure(.badRelayIdentity), "variant \(index)")
        }
        // Without either key a v4 code is a plain iCloud code.
        object = base
        object.removeValue(forKey: "relay_auth_pub")
        object.removeValue(forKey: "relay_device_id")
        let plain = try LinkPayload.parse(try linkURL(object)).get()
        XCTAssertTrue(plain.offersCloudKit)
        XCTAssertFalse(plain.offersRelay)
    }

    /// The hello's `relay_device_id` (wire key), read and written as the Go `wire.DeviceHello` does.
    func testHelloCasesRoundTrip() throws {
        let cases = try XCTUnwrap(load()["device_hello"])
        XCTAssertEqual(cases.map { $0["name"] as? String }, ["with_relay_id", "without_relay_id", "bad_relay_id"])
        for fixtureCase in cases {
            let name = try XCTUnwrap(fixtureCase["name"] as? String)
            let hello = try RelayCoder.makeDecoder().decode(DeviceHello.self, from: bytes(try XCTUnwrap(fixtureCase["json"])))
            let kit = try XCTUnwrap(fixtureCase["kit"] as? [String: Any], name)
            XCTAssertEqual(hello.relayDeviceID, kit["relay_device_id"] as? String, name)
            let encoded = try XCTUnwrap(String(bytes: try RelayCoder.makeEncoder().encode(hello), encoding: .utf8), name)
            XCTAssertFalse(encoded.contains("relayDeviceId"), name)
            if let relayCoder = fixtureCase["relay_coder"] as? String {
                XCTAssertEqual(encoded, relayCoder, name)
            } else {
                XCTAssertFalse(encoded.contains("relay_device_id"), name)
            }
        }
        let withID = try XCTUnwrap(cases.first)
        let decoded = try RelayCoder.makeDecoder().decode(DeviceHello.self, from: bytes(try XCTUnwrap(withID["json"])))
        XCTAssertEqual(decoded.relayDeviceID, try relayPair(seed: withID["relay_auth_seed"]).id)
        XCTAssertTrue(RelayIDs.isValid(try XCTUnwrap(decoded.relayDeviceID)))
    }

    /// The grant's relay fields; an absent `transports` reads as an iCloud-only hub.
    func testDeviceGrantRelayFieldsDecode() throws {
        let cases = try XCTUnwrap(load()["device_grant"])
        var withRelay = 0
        for fixtureCase in cases {
            let name = try XCTUnwrap(fixtureCase["name"] as? String)
            let grant = try RelayCoder.makeDecoder().decode(DeviceGrant.self, from: bytes(try XCTUnwrap(fixtureCase["json"])))
            let kit = try XCTUnwrap(fixtureCase["kit"] as? [String: Any], name)
            let hubTransports = kit["hub_transports"] as? [String] ?? ["cloudkit"]
            XCTAssertEqual(Set(grant.hubTransports.map(\.rawValue)), Set(hubTransports), name)
            XCTAssertEqual(grant.transports, kit["transports"] as? [String], name)
            XCTAssertEqual(grant.relayDeviceID, kit["relay_device_id"] as? String, name)
            XCTAssertEqual(grant.relayAuthPub, kit["relay_auth_pub"] as? String, name)
            if let seed = fixtureCase["relay_auth_seed"] {
                let pair = try relayPair(seed: seed)
                XCTAssertEqual(grant.relayAuthPub, pair.pub, name)
                XCTAssertEqual(grant.relayDeviceID, pair.id, name)
                withRelay += 1
            }
        }
        XCTAssertEqual(withRelay, 2) // desktop_awaiting, headless_linked
    }

    private struct Stamps: Codable {
        let whole: Date
        let at: Date
        let before: Date
    }

    /// The exact bytes the Kit's encoders write (RelayCoder escapes "/", the link encoder does not); the Go
    /// `wire.Marshal` / `wire.MarshalUnescapedSlashes` are pinned to the same strings.
    func testEncoderBytesMatchFixture() throws {
        let cases = try XCTUnwrap(load()["encoding"])
        for fixtureCase in cases {
            let name = try XCTUnwrap(fixtureCase["name"] as? String)
            let value = try XCTUnwrap(fixtureCase["value"])
            let relay: Data
            var link: Data?
            switch fixtureCase["kind"] as? String {
            case "strings":
                let strings = try XCTUnwrap(value as? [String: String], name)
                relay = try RelayCoder.makeEncoder().encode(strings)
                link = try LinkPayload.makeEncoder().encode(strings)
            case "dates":
                let stamps = try RelayCoder.makeDecoder().decode(Stamps.self, from: bytes(value))
                relay = try RelayCoder.makeEncoder().encode(stamps)
            default:
                return XCTFail("unknown kind in \(name)")
            }
            XCTAssertEqual(String(bytes: relay, encoding: .utf8), fixtureCase["relay_coder"] as? String, name)
            if let link {
                XCTAssertEqual(String(bytes: link, encoding: .utf8), fixtureCase["link_encoder"] as? String, name)
            }
        }
    }
}
