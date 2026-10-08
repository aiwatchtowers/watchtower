/// Frozen wire fixtures for every kept record kind and each payload the
/// mobile POC adds (spec §2.2, §4.1, §4.13, §5.1–5.2). Each payload encodes
/// to the literal and decodes back to the value; a nil optional is an ABSENT
/// key, never `null`.
///
/// Plain imports (no @testable): every symbol here is the public surface the
/// phone app and the Desktop hub build against.
import WatchtowerKit
import WatchtowerSync
import XCTest

final class KitFixtureTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func encoded<P: Encodable>(_ payload: P) throws -> String {
        try XCTUnwrap(String(data: try RelayCoder.makeEncoder().encode(payload), encoding: .utf8))
    }

    private func assertFixture<P: Codable & Equatable>(
        _ payload: P,
        _ fixture: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(try encoded(payload), fixture, file: file, line: line)
        XCTAssertEqual(
            try RelayCoder.makeDecoder().decode(P.self, from: Data(fixture.utf8)),
            payload,
            file: file,
            line: line
        )
    }

    // MARK: - Kinds

    func testRelayRecordKindsAreFrozen() {
        XCTAssertEqual(
            RelayRecordKind.allCases.map(\.rawValue),
            ["action", "heartbeat", "recording_upload", "device"]
        )
    }

    func testActionKindsKeepTheBranchKindsPlusProbe() {
        XCTAssertEqual(ActionKind.probe.rawValue, "probe")
        XCTAssertEqual(ActionKind.allCases.last, .probe)
        XCTAssertEqual(ActionKind.allCases.count, 16)
    }

    func testReasonCodesAreExactlyTheSpecList() {
        XCTAssertEqual(
            ActionReason.allCases.map(\.rawValue),
            [
                "not_found", "not_on_board", "ask_not_open", "invalid_answer", "invalid_params", "conflict",
                "device_not_allowed", "device_not_linked", "session_not_running", "agent_busy",
                "needs_approval", "prompt_has_text",
                "state_unknown", "cannot_type", "claude_not_found", "expired", "cancelled", "outcome_unknown",
                "unsupported_in_poc", "write_failed"
            ]
        )
    }

    // MARK: - action

    func testProbeRequestFixture() throws {
        let probe = ActionRequestPayload(
            id: "A1",
            kind: .probe,
            entityID: nil,
            params: ["nonce": .string("n-1")],
            createdAt: t0,
            deviceID: "D1"
        )
        try assertFixture(
            probe,
            #"{"created_at":1700000000,"device_id":"D1","id":"A1","kind":"probe","params":{"nonce":"n-1"},"status":"pending"}"#
        )
        XCTAssertEqual(probe.recordName, "action-A1")
    }

    func testAppliedEchoCarriesResultObjectWithKeysVerbatim() throws {
        var echo = ActionRequestPayload(
            id: "A1", kind: .probe, entityID: nil, params: ["nonce": .string("n-1")], createdAt: t0, deviceID: "D1"
        )
        echo.status = .applied
        echo.result = ["nonce": .string("n-1"), "hub_id": .string("hub-1")]
        try assertFixture(
            echo,
            // swiftlint:disable:next line_length
            #"{"created_at":1700000000,"device_id":"D1","id":"A1","kind":"probe","params":{"nonce":"n-1"},"result":{"hub_id":"hub-1","nonce":"n-1"},"status":"applied"}"#
        )
    }

    func testFailedEchoCarriesReason() throws {
        var echo = ActionRequestPayload(id: "A2", kind: .probe, entityID: nil, createdAt: t0, deviceID: "D9")
        echo.status = .failed
        echo.reason = .deviceNotLinked
        echo.errorMessage = "This phone is not linked"
        try assertFixture(
            echo,
            // swiftlint:disable:next line_length
            #"{"created_at":1700000000,"device_id":"D9","error_message":"This phone is not linked","id":"A2","kind":"probe","params":{},"reason":"device_not_linked","status":"failed"}"#
        )
    }

    func testActionNilOptionalsAreAbsentKeys() throws {
        let bare = ActionRequestPayload(id: "A3", kind: .probe, entityID: nil, createdAt: t0)
        try assertFixture(bare, #"{"created_at":1700000000,"id":"A3","kind":"probe","params":{},"status":"pending"}"#)
    }

    func testUnknownReasonDecodesAsAbsent() throws {
        let json = #"{"created_at":1700000000,"id":"A4","kind":"probe","params":{},"reason":"from_the_future","status":"failed"}"#
        let decoded = try RelayCoder.makeDecoder().decode(ActionRequestPayload.self, from: Data(json.utf8))
        XCTAssertNil(decoded.reason)
        XCTAssertEqual(decoded.status, .failed)
    }

    // MARK: - recording_upload (kept)

    func testRecordingUploadFixture() throws {
        let upload = RecordingUploadPayload(
            id: "R1",
            startedAt: t0,
            endedAt: t0.addingTimeInterval(10),
            durationSec: 10,
            sampleFormat: "aac-64k-mono"
        )
        try assertFixture(
            upload,
            #"{"duration_sec":10,"ended_at":1700000010,"id":"R1","sample_format":"aac-64k-mono","started_at":1700000000,"status":"pending"}"#
        )
    }

    // MARK: - heartbeat (DataZone)

    func testHeartbeatFixture() throws {
        let beat = HeartbeatPayload(
            updatedAt: t0,
            appVersion: "0.16.0",
            hubID: "hub-1",
            macName: "Acme Mac",
            flavor: .corp,
            lastPublishAt: t0.addingTimeInterval(-10),
            lastRelayAt: t0.addingTimeInterval(-20),
            relayBacklog: 3,
            accounts: [HeartbeatAccount(kind: .slack, label: "acme", status: "connected")],
            enabledAt: t0.addingTimeInterval(-3600),
            ownerUser: "_owner",
            sharing: .available
        )
        try assertFixture(
            beat,
            // swiftlint:disable:next line_length
            #"{"accounts":[{"kind":"slack","label":"acme","status":"connected"}],"app_version":"0.16.0","enabled_at":1699996400,"flavor":"corp","hub_id":"hub-1","last_publish_at":1699999990,"last_relay_at":1699999980,"mac_name":"Acme Mac","owner_user":"_owner","relay_backlog":3,"sharing":"available","updated_at":1700000000}"#
        )
        XCTAssertEqual(HeartbeatPayload.recordName, "heartbeat")
    }

    func testHeartbeatNilOptionalsAreAbsentKeys() throws {
        let beat = HeartbeatPayload(
            updatedAt: t0,
            appVersion: "0.16.0",
            hubID: "hub-1",
            macName: "Acme Mac",
            flavor: .default,
            lastPublishAt: nil,
            lastRelayAt: nil,
            relayBacklog: 0,
            accounts: [],
            enabledAt: t0,
            ownerUser: "_owner",
            sharing: .none
        )
        try assertFixture(
            beat,
            // swiftlint:disable:next line_length
            #"{"accounts":[],"app_version":"0.16.0","enabled_at":1700000000,"flavor":"default","hub_id":"hub-1","mac_name":"Acme Mac","owner_user":"_owner","relay_backlog":0,"sharing":"none","updated_at":1700000000}"#
        )
    }

    func testHeartbeatEnumsAreFrozen() {
        XCTAssertEqual(HubFlavor.allCases.map(\.rawValue), ["default", "corp"])
        XCTAssertEqual(HubSharing.allCases.map(\.rawValue), ["available", "unavailable", "none"])
        XCTAssertEqual(HeartbeatAccount.Kind.allCases.map(\.rawValue), ["slack", "google", "jira"])
    }

    // MARK: - device (RelayZone, phone-written)

    func testDeviceFixture() throws {
        let device = DevicePayload(
            deviceID: "D1",
            name: "Colleague A's iPhone",
            model: "iPhone16,1",
            appVersion: "0.16.0",
            scope: .shared,
            userRecordName: "_phone_user",
            linkNonce: "n-1",
            unlinked: true,
            typingRequested: true,
            startSessions: false,
            updatedAt: t0
        )
        try assertFixture(
            device,
            // swiftlint:disable:next line_length
            #"{"app_version":"0.16.0","device_id":"D1","link_nonce":"n-1","model":"iPhone16,1","name":"Colleague A's iPhone","scope":"shared","start_sessions":false,"typing_requested":true,"unlinked":true,"updated_at":1700000000,"user_record_name":"_phone_user"}"#
        )
        XCTAssertEqual(device.recordName, "device-D1")
    }

    func testDeviceNilOptionalsAreAbsentKeys() throws {
        let device = DevicePayload(
            deviceID: "D2",
            name: "iPhone",
            model: "iPhone16,1",
            appVersion: "0.16.0",
            scope: .private,
            userRecordName: "_owner",
            typingRequested: false,
            startSessions: true,
            updatedAt: t0
        )
        try assertFixture(
            device,
            // swiftlint:disable:next line_length
            #"{"app_version":"0.16.0","device_id":"D2","model":"iPhone16,1","name":"iPhone","scope":"private","start_sessions":true,"typing_requested":false,"updated_at":1700000000,"user_record_name":"_owner"}"#
        )
    }

    func testDeviceRecordGoesToRelayZone() throws {
        let device = DevicePayload(
            deviceID: "D3", name: "iPhone", model: "iPhone16,1", appVersion: "0.16.0", scope: .private,
            userRecordName: "_owner", typingRequested: false, startSessions: true, updatedAt: t0
        )
        let record = try CloudRecordFactory.record(for: device, modifiedAt: t0)
        XCTAssertEqual(record.recordName, "device-D3")
        XCTAssertEqual(record.zone, .relay)
        XCTAssertEqual(record.kind, "device")
    }

    // MARK: - device_grant (DataZone mirror)

    func testDeviceGrantFixture() throws {
        let grant = DeviceGrant(
            deviceID: "D1",
            hubID: "hub-1",
            name: "iPhone",
            scope: .shared,
            linked: false,
            linkRefused: .expiredCode,
            linkedAt: t0.addingTimeInterval(-60),
            typingAllowed: true,
            startSessionsAllowed: false,
            decidedAt: t0
        )
        try assertFixture(
            grant,
            // swiftlint:disable:next line_length
            #"{"decided_at":1700000000,"device_id":"D1","hub_id":"hub-1","link_refused":"expired_code","linked":false,"linked_at":1699999940,"name":"iPhone","scope":"shared","start_sessions_allowed":false,"typing_allowed":true}"#
        )
        XCTAssertEqual(grant.recordName, "device_grant-D1")
    }

    func testDeviceGrantNilOptionalsAreAbsentKeys() throws {
        let grant = DeviceGrant(
            deviceID: "D2",
            hubID: "hub-1",
            name: "iPhone",
            scope: .private,
            linked: false,
            typingAllowed: false,
            startSessionsAllowed: true
        )
        try assertFixture(
            grant,
            // swiftlint:disable:next line_length
            #"{"device_id":"D2","hub_id":"hub-1","linked":false,"name":"iPhone","scope":"private","start_sessions_allowed":true,"typing_allowed":false}"#
        )
    }

    func testLinkRefusalAndScopeAreFrozen() {
        XCTAssertEqual(LinkRefusal.allCases.map(\.rawValue), ["used_code", "expired_code", "unknown_code"])
        XCTAssertEqual(DeviceScope.allCases.map(\.rawValue), ["private", "shared"])
    }
}
