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
}
