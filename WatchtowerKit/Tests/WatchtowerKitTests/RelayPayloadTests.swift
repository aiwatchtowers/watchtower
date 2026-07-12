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
        let json = try XCTUnwrap(String(data: try RelayCoder.makeEncoder().encode(action), encoding: .utf8))
        // swiftlint:disable:next line_length
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
            [
                "target_done", "target_snooze", "inbox_resolve", "inbox_dismiss", "inbox_snooze",
                "task_create", "track_read",
                "situation_done", "situation_dismiss", "situation_snooze", "situation_keep_open",
            ]
        )
    }

    func testFrozenFixtureDecodesWithParamsKeysVerbatim() throws {
        // Decode-direction pin: convertFromSnakeCase must not rewrite params
        // dictionary keys (snooze_until must NOT become snoozeUntil).
        // swiftlint:disable:next line_length
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
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains(#""dueDate""#), "params key was rewritten on encode: \(json)")
        XCTAssertFalse(json.contains(#""due_date""#))

        let decoded = try RelayCoder.makeDecoder().decode(ActionRequestPayload.self, from: data)
        XCTAssertEqual(decoded.params["dueDate"], .string("2026-07-07"))
    }

    func testChatMessageWireFormatIsFrozen() throws {
        let message = ChatMessagePayload(id: "M1", sessionID: "S1", text: "hi", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let json = try XCTUnwrap(String(data: try RelayCoder.makeEncoder().encode(message), encoding: .utf8))
        XCTAssertEqual(json, #"{"created_at":1700000000,"id":"M1","session_id":"S1","text":"hi"}"#)
        XCTAssertEqual(try RelayCoder.makeDecoder().decode(ChatMessagePayload.self, from: Data(json.utf8)), message)
    }

    func testChatChunkWireFormatIsFrozen() throws {
        let chunk = ChatChunkPayload(sessionID: "S1", messageID: "M1", seq: 3, text: "partial", done: true)
        let json = try XCTUnwrap(String(data: try RelayCoder.makeEncoder().encode(chunk), encoding: .utf8))
        XCTAssertEqual(json, #"{"done":true,"message_id":"M1","seq":3,"session_id":"S1","text":"partial"}"#)
        XCTAssertEqual(try RelayCoder.makeDecoder().decode(ChatChunkPayload.self, from: Data(json.utf8)), chunk)
    }

    func testHeartbeatWireFormatIsFrozen() throws {
        let beat = HeartbeatPayload(updatedAt: Date(timeIntervalSince1970: 1_700_000_002), appVersion: "1.0")
        let json = try XCTUnwrap(String(data: try RelayCoder.makeEncoder().encode(beat), encoding: .utf8))
        XCTAssertEqual(json, #"{"app_version":"1.0","updated_at":1700000002}"#)
        XCTAssertEqual(try RelayCoder.makeDecoder().decode(HeartbeatPayload.self, from: Data(json.utf8)), beat)
    }

    func testChatChunkErrorFlagWireFormatIsFrozen() throws {
        let chunk = ChatChunkPayload(
            sessionID: "S1", messageID: "M1", seq: 3, text: "partial", done: true, isError: true
        )
        let json = try XCTUnwrap(String(data: try RelayCoder.makeEncoder().encode(chunk), encoding: .utf8))
        XCTAssertEqual(json, #"{"done":true,"is_error":true,"message_id":"M1","seq":3,"session_id":"S1","text":"partial"}"#)
        XCTAssertEqual(try RelayCoder.makeDecoder().decode(ChatChunkPayload.self, from: Data(json.utf8)), chunk)
    }

    func testChatChunkNilErrorFlagMatchesLegacyWireFormat() throws {
        // nil isError must be byte-identical to the pre-flag wire format —
        // the key is absent, so old desktops/mobiles see no change at all.
        let chunk = ChatChunkPayload(
            sessionID: "S1", messageID: "M1", seq: 3, text: "partial", done: true, isError: nil
        )
        let json = try XCTUnwrap(String(data: try RelayCoder.makeEncoder().encode(chunk), encoding: .utf8))
        XCTAssertEqual(json, #"{"done":true,"message_id":"M1","seq":3,"session_id":"S1","text":"partial"}"#)
    }

    func testChatChunkDecodesLegacyWireWithoutErrorFlag() throws {
        // Records written by old desktop versions carry no is_error key.
        let json = #"{"done":true,"message_id":"M1","seq":3,"session_id":"S1","text":"partial"}"#
        let decoded = try RelayCoder.makeDecoder().decode(ChatChunkPayload.self, from: Data(json.utf8))
        XCTAssertNil(decoded.isError)
        XCTAssertEqual(decoded, ChatChunkPayload(sessionID: "S1", messageID: "M1", seq: 3, text: "partial", done: true))
    }

    func testChatChunkErrorFlagRoundTrip() throws {
        let chunk = ChatChunkPayload(
            sessionID: "S1", messageID: "M9", seq: 0, text: "⚠️ boom", done: true, isError: true
        )
        let data = try RelayCoder.makeEncoder().encode(chunk)
        let decoded = try RelayCoder.makeDecoder().decode(ChatChunkPayload.self, from: data)
        XCTAssertEqual(decoded, chunk)
        XCTAssertEqual(decoded.isError, true)
    }

    func testFailedActionWireFormatIsFrozen() throws {
        var action = ActionRequestPayload(
            id: "A1",
            kind: .targetDone,
            entityID: "7",
            params: [:],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        action.status = .failed
        action.errorMessage = "row not found"
        let json = try XCTUnwrap(String(data: try RelayCoder.makeEncoder().encode(action), encoding: .utf8))
        // swiftlint:disable:next line_length
        XCTAssertEqual(json, #"{"created_at":1700000000,"entity_id":"7","error_message":"row not found","id":"A1","kind":"target_done","params":{},"status":"failed"}"#)
        XCTAssertEqual(try RelayCoder.makeDecoder().decode(ActionRequestPayload.self, from: Data(json.utf8)), action)
    }
}
