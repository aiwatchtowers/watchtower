import XCTest
@testable import WatchtowerSync

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

    func testAllActionKindsAreStable() {
        XCTAssertEqual(
            ActionKind.allCases.map(\.rawValue),
            [
                "target_done", "target_snooze", "inbox_resolve", "inbox_dismiss", "inbox_snooze",
                "task_create", "track_read",
                "situation_done", "situation_dismiss", "situation_snooze", "situation_keep_open",
                "day_plan_item_done", "day_plan_item_skip",
                "digest_read", "stream_digest_read",
                "probe"
            ]
        )
    }

    /// The digest mark-as-read actions ship no params — entity id only. The
    /// literal pins the whole record so the wire cannot drift.
    func testDigestReadWireFormatIsFrozen() throws {
        let action = ActionRequestPayload(
            id: "A9",
            kind: .digestRead,
            entityID: "12",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let json = try XCTUnwrap(String(data: try RelayCoder.makeEncoder().encode(action), encoding: .utf8))
        XCTAssertEqual(
            json,
            #"{"created_at":1700000000,"entity_id":"12","id":"A9","kind":"digest_read","params":{},"status":"pending"}"#
        )
        let decoded = try RelayCoder.makeDecoder().decode(ActionRequestPayload.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.kind, .digestRead)
        XCTAssertEqual(decoded.entityID, "12")

        let stream = ActionRequestPayload(
            id: "A10",
            kind: .streamDigestRead,
            entityID: "3",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let streamJSON = try XCTUnwrap(String(data: try RelayCoder.makeEncoder().encode(stream), encoding: .utf8))
        XCTAssertEqual(
            streamJSON,
            #"{"created_at":1700000000,"entity_id":"3","id":"A10","kind":"stream_digest_read","params":{},"status":"pending"}"#
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
