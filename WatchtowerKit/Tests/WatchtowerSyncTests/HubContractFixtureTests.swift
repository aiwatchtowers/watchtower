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
}
