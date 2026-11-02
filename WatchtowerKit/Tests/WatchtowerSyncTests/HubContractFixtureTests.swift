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
        }
    }

    func testAV4LinkIsRefusedAsNewerByTodaysPhone() throws {
        let cases = try XCTUnwrap(load()["link_payload"])
        var checked = 0
        for fixtureCase in cases where (fixtureCase["kit"] as? String) == "newer_version" {
            let name = try XCTUnwrap(fixtureCase["name"] as? String)
            let url = try XCTUnwrap(URL(string: try XCTUnwrap(fixtureCase["url"] as? String)), name)
            XCTAssertEqual(LinkPayload.parse(url), .failure(.newerVersion), name)
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 3) // v4_desktop, v4_headless, v5_newer
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

    /// The phone's reading of `transport_switched.keybox` (phone contract
    /// point 3): a string of unpadded base64url (RFC 4648 §5 alphabet
    /// `A–Z a–z 0–9 - _`, no `=`) is the sealed keybox envelope; any other
    /// value, or a string outside that alphabet, reads as no keybox.
    private func switchKeybox(_ value: Any?) -> Data? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        let alphabet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard text.unicodeScalars.allSatisfy(alphabet.contains) else { return nil }
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    func testTransportSwitchedCarriesTheKeyboxAsUnpaddedBase64URL() throws {
        let cases = try XCTUnwrap(load()["transport_switched"])
        XCTAssertEqual(cases.count, 4)
        for fixtureCase in cases {
            let name = try XCTUnwrap(fixtureCase["name"] as? String)
            let json = try XCTUnwrap(fixtureCase["json"] as? [String: Any], name)
            let kit = try XCTUnwrap(fixtureCase["kit"] as? [String: Any], name)
            XCTAssertEqual(json["kind"] as? String, "transport_switched", name)
            XCTAssertEqual(json["target"] as? String, kit["target"] as? String, name)
            XCTAssertEqual((json["epoch"] as? NSNumber)?.uint32Value, (kit["epoch"] as? NSNumber)?.uint32Value, name)
            let keybox = switchKeybox(json["keybox"])
            if let want = kit["keybox"] as? String {
                XCTAssertEqual(json["keybox"] as? String, want, name)
                XCTAssertNotNil(keybox, name)
                XCTAssertFalse(want.contains("="), "unpadded: \(name)")
            } else {
                XCTAssertNil(keybox, "an object or absent keybox reads as none: \(name)")
            }
            if name == "transport_marker" {
                XCTAssertNil(json["device_id"], name)
                XCTAssertNil(json["keybox"], name)
            }
        }
        XCTAssertNil(switchKeybox("AQID=="), "padding is not the contract")
        XCTAssertNil(switchKeybox("AQ+/"), "the standard alphabet is not the contract")
    }

    func testTransportSwitchRejectedReasonsArePinned() throws {
        let cases = try XCTUnwrap(load()["transport_switch_rejected"])
        var reasons: [String] = []
        for fixtureCase in cases {
            let name = try XCTUnwrap(fixtureCase["name"] as? String)
            let json = try XCTUnwrap(fixtureCase["json"] as? [String: Any], name)
            let kit = try XCTUnwrap(fixtureCase["kit"] as? [String: Any], name)
            XCTAssertEqual(json["kind"] as? String, "transport_switch_rejected", name)
            XCTAssertEqual(json["reason"] as? String, kit["reason"] as? String, name)
            XCTAssertEqual((json["retry_after_s"] as? NSNumber)?.intValue, (kit["retry_after_s"] as? NSNumber)?.intValue, name)
            reasons.append(try XCTUnwrap(kit["reason"] as? String, name))
        }
        XCTAssertEqual(Set(reasons), ["too_soon", "not_paying", "unavailable", "not supported yet"])
    }
}
