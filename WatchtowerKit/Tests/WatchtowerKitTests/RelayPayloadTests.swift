import XCTest
@testable import WatchtowerKit

final class RelayPayloadTests: XCTestCase {
    func testActionRequestWireFormatIsFrozen() throws {
        let action = ActionRequestPayload(
            id: "A1",
            kind: .inboxSnooze,
            entityID: "42",
            params: ["snooze_until": .string("2026-07-06T09:00:00Z")],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let json = String(data: try RelayCoder.makeEncoder().encode(action), encoding: .utf8)!
        XCTAssertEqual(json, #"{"created_at":1700000000,"entity_id":"42","id":"A1","kind":"inbox_snooze","params":{"snooze_until":"2026-07-06T09:00:00Z"},"status":"pending"}"#)
    }

    func testActionRequestRoundTrip() throws {
        var action = ActionRequestPayload(
            id: "A2",
            kind: .taskCreate,
            entityID: nil,
            params: ["text": .string("call bob"), "priority": .string("high")],
            createdAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        action.status = .failed
        action.errorMessage = "row not found"

        let data = try RelayCoder.makeEncoder().encode(action)
        let decoded = try RelayCoder.makeDecoder().decode(ActionRequestPayload.self, from: data)
        XCTAssertEqual(decoded, action)
        XCTAssertEqual(decoded.recordName, "action-A2")
    }

    func testChatChunkRecordNameAndRoundTrip() throws {
        let chunk = ChatChunkPayload(sessionID: "S1", messageID: "M1", seq: 3, text: "partial", done: false)
        XCTAssertEqual(chunk.recordName, "chatchunk-M1-3")
        let data = try RelayCoder.makeEncoder().encode(chunk)
        XCTAssertEqual(try RelayCoder.makeDecoder().decode(ChatChunkPayload.self, from: data), chunk)
    }

    func testChatMessageRecordName() {
        let message = ChatMessagePayload(id: "M9", sessionID: "S1", text: "hi", createdAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(message.recordName, "chatmsg-M9")
    }

    func testHeartbeatRoundTrip() throws {
        let beat = HeartbeatPayload(updatedAt: Date(timeIntervalSince1970: 1_700_000_002), appVersion: "1.0")
        let data = try RelayCoder.makeEncoder().encode(beat)
        XCTAssertEqual(try RelayCoder.makeDecoder().decode(HeartbeatPayload.self, from: data), beat)
        XCTAssertEqual(HeartbeatPayload.recordName, "heartbeat")
    }

    func testAllActionKindsAreStable() {
        XCTAssertEqual(
            ActionKind.allCases.map(\.rawValue),
            ["target_done", "target_snooze", "inbox_resolve", "inbox_dismiss", "inbox_snooze", "task_create", "track_read"]
        )
    }

    func testFrozenFixtureDecodesWithParamsKeysVerbatim() throws {
        // Decode-direction pin: convertFromSnakeCase must not rewrite params
        // dictionary keys (snooze_until must NOT become snoozeUntil).
        let json = #"{"created_at":1700000000,"entity_id":"42","id":"A1","kind":"inbox_snooze","params":{"snooze_until":"2026-07-06T09:00:00Z"},"status":"pending"}"#
        let decoded = try RelayCoder.makeDecoder().decode(ActionRequestPayload.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.params["snooze_until"], .string("2026-07-06T09:00:00Z"))
        XCTAssertEqual(decoded.entityID, "42")
    }

    func testCamelCaseParamsKeyRoundTripsVerbatim() throws {
        // Encode-direction pin: convertToSnakeCase must not rewrite params
        // dictionary keys (dueDate must NOT become due_date).
        let action = ActionRequestPayload(
            id: "A3",
            kind: .taskCreate,
            entityID: nil,
            params: ["dueDate": .string("2026-07-07")],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try RelayCoder.makeEncoder().encode(action)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains(#""dueDate""#), "params key was rewritten on encode: \(json)")
        XCTAssertFalse(json.contains(#""due_date""#))

        let decoded = try RelayCoder.makeDecoder().decode(ActionRequestPayload.self, from: data)
        XCTAssertEqual(decoded.params["dueDate"], .string("2026-07-07"))
    }
}
