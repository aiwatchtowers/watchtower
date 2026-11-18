import XCTest
@testable import WatchtowerSync

final class HeartbeatPayloadTests: XCTestCase {
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
