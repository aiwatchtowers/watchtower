import ChatWire
import XCTest

/// The feed's conversation on the wire (#1822 T17): `routing_reason` decodes when sent and defaults to "" from an older
/// daemon (D22).
final class ChatFeedTests: XCTestCase {
    private func conversation(_ json: String) throws -> ChatFeed.Conversation {
        try ChatWireCoder.makeDecoder().decode(ChatFeed.Conversation.self, from: Data(json.utf8))
    }

    func testConversationCarriesRoutingReason() throws {
        let decoded = try conversation("""
            {"id":3,"title":"Plan","routing":{"mode":"auto"},"actual_provider":"codex","actual_model":"m",
             "routing_reason":"quota_exhausted"}
            """)
        XCTAssertEqual(decoded.routingReason, "quota_exhausted")
    }

    func testConversationWithoutRoutingReasonDecodes() throws {
        let decoded = try conversation(#"{"id":3,"title":"Plan","routing":{"mode":"auto"},"actual_provider":"codex"}"#)
        XCTAssertEqual(decoded.routingReason, "")
        XCTAssertEqual(decoded.actualProvider, "codex")
    }
}
