import ChatWire
import XCTest
@testable import ChatUI

/// The part payloads ChatUI reads, against Go's `internal/chatengine/testdata/parts.json`.
final class ChatPartPayloadsTests: XCTestCase {
    private struct FixtureEntry: Decodable {
        let kind: String
        let part: ChatPart
    }

    /// The approval sample carries the card's fields beyond the args (ask #1409); each one decodes.
    func testApprovalPayloadDecodesCardFields() throws {
        let data = try Data(contentsOf: ChatUIFixtures.goFixture("chatengine/testdata/parts.json"))
        let entries = try ChatWireCoder.makeDecoder().decode([FixtureEntry].self, from: data)
        let approval = try XCTUnwrap(entries.first { $0.kind == ChatPartKind.approval })
        let payload = try XCTUnwrap(try approval.part.decodePayload(ChatApprovalPayload.self))
        XCTAssertEqual(payload.id, 9)
        XCTAssertEqual(payload.tool, "send_slack_message")
        XCTAssertEqual(payload.argsSHA256, "abc123")
        XCTAssertTrue(payload.external)
        XCTAssertEqual(payload.error, "Slack refused the first try")
        XCTAssertEqual(payload.result, ["url": "https://example.com/acme-1", "label": "ACME-1", "warning": "mirror failed"])
        XCTAssertEqual(payload.turnID, "t1")
        XCTAssertTrue(payload.argsComplete)
    }
}
