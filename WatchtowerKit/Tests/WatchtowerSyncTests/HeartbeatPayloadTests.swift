import XCTest
@testable import WatchtowerSync

/// The heartbeat's capabilities as the phone decodes them.
final class HeartbeatPayloadTests: XCTestCase {
    private func decode(_ capabilities: String) throws -> HeartbeatPayload {
        let json = """
            {"accounts":[],"app_version":"1.0.0",\(capabilities)"enabled_at":1730000000,"flavor":"default",
            "hub_id":"AAAAAAAA-0000-4000-8000-000000000001","mac_name":"Test Hub","owner_user":"","relay_backlog":0,
            "sharing":"none","updated_at":1730000100}
            """
        return try RelayCoder.makeDecoder().decode(HeartbeatPayload.self, from: Data(json.utf8))
    }

    /// The phone Inbox capability: "on", "policy_off" with its reason, and nil for an older hub that sends no key.
    func testInboxCapabilityDecodes() throws {
        let on = try decode(#""capabilities":{"inbox":"on"},"#)
        XCTAssertEqual(on.capabilities?.inbox, "on")
        XCTAssertNil(on.capabilities?.inboxReason)
        let off = try decode(#""capabilities":{"inbox":"policy_off","inbox_reason":"policy"},"#)
        XCTAssertEqual(off.capabilities?.inbox, "policy_off")
        XCTAssertEqual(off.capabilities?.inboxReason, "policy")
        let older = try decode(#""capabilities":{"recordings":"on"},"#)
        XCTAssertNil(older.capabilities?.inbox)
        XCTAssertNil(try decode("").capabilities?.inbox)
    }

    private func decode(backgroundAI: String?) throws -> HeartbeatPayload {
        var json: [String: Any] = [
            "accounts": [], "app_version": "1.0.0", "enabled_at": 1_730_000_000, "flavor": "default",
            "hub_id": "hub", "mac_name": "Mac", "owner_user": "", "relay_backlog": 0, "sharing": "none",
            "updated_at": 1_730_000_100
        ]
        if let backgroundAI { json["background_ai"] = backgroundAI }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try RelayCoder.makeDecoder().decode(HeartbeatPayload.self, from: data)
    }

    func testBackgroundAIKeyIsOptional() throws {
        XCTAssertNil(try decode(backgroundAI: nil).backgroundAI)
        XCTAssertNil(try decode(backgroundAI: "later").backgroundAI)
        XCTAssertEqual(try decode(backgroundAI: "organization").backgroundAI, .organization)
        XCTAssertEqual(try decode(backgroundAI: "allowed").backgroundAI, .allowed)
        XCTAssertEqual(try decode(backgroundAI: "paused").backgroundAI, .paused)
    }
}
