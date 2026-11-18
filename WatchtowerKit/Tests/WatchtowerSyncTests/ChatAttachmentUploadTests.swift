import XCTest
@testable import WatchtowerSync

/// The `chat_attachment` frame against `Tests/Fixtures/chat/actions.json`'s `upload` section, which the hub's
/// `TestChatActionsFixture` feeds through its intake.
final class ChatAttachmentUploadTests: XCTestCase {
    private func upload() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // WatchtowerSyncTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("Fixtures/chat/actions.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try XCTUnwrap(root["upload"] as? [String: Any])
    }

    private func bytes(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    private func same(_ data: Data, _ expected: Any, _ what: String) throws {
        XCTAssertEqual(try JSONSerialization.jsonObject(with: data) as? NSDictionary, expected as? NSDictionary, what)
    }

    func testTheKindAndTheNameAreTheHubs() throws {
        let fixture = try upload()
        XCTAssertEqual(RelayRecordKind.chatAttachment.rawValue, fixture["kind"] as? String)
        XCTAssertEqual(ChatAttachmentUploadPayload.recordNamePrefix, fixture["record_id_prefix"] as? String)
        XCTAssertTrue(RelayRecordKind.allCases.map(\.rawValue).contains("chat_attachment"))
    }

    func testThePendingDescriptorEncodesToTheFixtureBytes() throws {
        let payload = ChatAttachmentUploadPayload(
            uploadID: "C1D2E3F4-0000-4000-8000-000000000001", conversationID: 2, name: "notes.md",
            mime: "text/markdown", size: 6, deviceID: "BBBBBBBB-0000-4000-8000-000000000002",
            hubID: "AAAAAAAA-0000-4000-8000-000000000001")
        try same(RelayCoder.makeEncoder().encode(payload), try XCTUnwrap(upload()["payload"]), "pending")
        XCTAssertEqual(payload.recordName, "chatupload-C1D2E3F4-0000-4000-8000-000000000001")
    }

    func testTheEchoesDecode() throws {
        let fixture = try upload()
        let applied = try RelayCoder.makeDecoder().decode(
            ChatAttachmentUploadPayload.self, from: bytes(try XCTUnwrap(fixture["echo_applied"])))
        XCTAssertEqual(applied.status, .applied)
        XCTAssertEqual(applied.attachmentID, 1)
        XCTAssertNil(applied.reason)
        try same(RelayCoder.makeEncoder().encode(applied), try XCTUnwrap(fixture["echo_applied"]), "applied")

        let failed = try RelayCoder.makeDecoder().decode(
            ChatAttachmentUploadPayload.self, from: bytes(try XCTUnwrap(fixture["echo_failed"])))
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.reason, .notFound)
        XCTAssertEqual(failed.errorMessage, "The file did not reach your Mac. Send it again.")
        XCTAssertNil(failed.attachmentID)
        try same(RelayCoder.makeEncoder().encode(failed), try XCTUnwrap(fixture["echo_failed"]), "failed")
    }

    func testAnUnknownStatusIsPendingAndAnUnknownReasonIsNil() throws {
        var echo = try XCTUnwrap(upload()["echo_failed"] as? [String: Any])
        echo["status"] = "from_the_future"
        echo["reason"] = "from_the_future"
        let payload = try RelayCoder.makeDecoder().decode(ChatAttachmentUploadPayload.self, from: bytes(echo))
        XCTAssertEqual(payload.status, .pending)
        XCTAssertNil(payload.reason)
    }

    func testTheRecordIsARelayRecordOfTheChatKind() throws {
        let payload = ChatAttachmentUploadPayload(
            uploadID: "U", conversationID: 1, name: "a", mime: "text/plain", size: 1)
        let record = try CloudRecordFactory.record(for: payload, modifiedAt: Date(), assetFileURL: nil)
        XCTAssertEqual(record.kind, "chat_attachment")
        XCTAssertEqual(record.zone, .relay)
        XCTAssertEqual(record.recordName, "chatupload-U")
    }
}
