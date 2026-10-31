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
                "probe",
                "ask_answer", "board_target_status", "board_target_priority",
                "board_comment_add", "board_comment_reply", "board_target_create",
                "session_start", "session_input", "session_input_cancel",
                "session_finish_request", "session_stop", "session_report_request",
                "permission_answer", "session_interrupt", "session_chat_request", "automation_run"
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

    func testHubIDEncodesAsHubIdAndNilIsAbsent() throws {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let addressed = ActionRequestPayload(
            id: "a1", kind: .probe, entityID: nil, createdAt: created, deviceID: "device-a", hubID: "hub-acme"
        )
        let json = try XCTUnwrap(String(bytes: try RelayCoder.makeEncoder().encode(addressed), encoding: .utf8))
        XCTAssertTrue(json.contains("\"hub_id\":\"hub-acme\""), json)
        let plain = ActionRequestPayload(id: "a2", kind: .probe, entityID: nil, createdAt: created)
        let plainJSON = try XCTUnwrap(String(bytes: try RelayCoder.makeEncoder().encode(plain), encoding: .utf8))
        XCTAssertFalse(plainJSON.contains("hub_id"))
        let decoded = try RelayCoder.makeDecoder().decode(ActionRequestPayload.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.hubID, "hub-acme")
    }

    /// A legacy action (no order number) is written exactly as before ordered actions existed.
    func testALegacyActionEncodesNoActionSeq() throws {
        let action = ActionRequestPayload(
            id: "A1", kind: .targetDone, entityID: "7", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            deviceID: "device-a", hubID: "hub-acme"
        )
        XCTAssertNil(action.actionSeq)
        let json = try XCTUnwrap(String(data: try RelayCoder.makeEncoder().encode(action), encoding: .utf8))
        // swiftlint:disable:next line_length
        XCTAssertEqual(json, #"{"created_at":1700000000,"device_id":"device-a","entity_id":"7","hub_id":"hub-acme","id":"A1","kind":"target_done","params":{},"status":"pending"}"#)

        var ordered = action
        ordered.actionSeq = 3
        let orderedJSON = try XCTUnwrap(String(data: try RelayCoder.makeEncoder().encode(ordered), encoding: .utf8))
        XCTAssertTrue(orderedJSON.contains(#""action_seq":3"#), orderedJSON)
        XCTAssertEqual(try RelayCoder.makeDecoder().decode(ActionRequestPayload.self, from: Data(orderedJSON.utf8)), ordered)
    }

    /// The Go hub drops a `skip_to` without both ids; the phone's always carries them, uppercase.
    func testSkipToCarriesBothIds() throws {
        let device = try XCTUnwrap(UUID(uuidString: "bbbbbbbb-0000-4000-8000-000000000002"))
        let hub = try XCTUnwrap(UUID(uuidString: "aaaaaaaa-0000-4000-8000-000000000001"))
        let id = try XCTUnwrap(UUID(uuidString: "dddddddd-0000-4000-8000-000000000004"))
        let control = ControlPayload.skipTo(12, deviceID: device, hubID: hub, id: id)
        XCTAssertEqual(control.recordName, "c-DDDDDDDD-0000-4000-8000-000000000004")
        let json = try XCTUnwrap(String(data: try RelayCoder.makeEncoder().encode(control), encoding: .utf8))
        // swiftlint:disable:next line_length
        XCTAssertEqual(json, #"{"device_id":"BBBBBBBB-0000-4000-8000-000000000002","hub_id":"AAAAAAAA-0000-4000-8000-000000000001","id":"DDDDDDDD-0000-4000-8000-000000000004","kind":"skip_to","seq":12}"#)
        XCTAssertNotEqual(ControlPayload.skipTo(1, deviceID: device, hubID: hub).id, ControlPayload.skipTo(1, deviceID: device, hubID: hub).id)
    }
}
