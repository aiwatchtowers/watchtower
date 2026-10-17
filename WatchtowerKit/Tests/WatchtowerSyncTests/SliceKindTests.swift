import GRDB
import os
import WatchtowerE2ETesting
import XCTest
@testable import WatchtowerSync

/// SliceKind raw values are wire format (mobile POC spec §4): the pre-POC
/// kinds stay in the enum unpublished, `heartbeat`, `device_grant`,
/// `recording_job` and the workbench kinds (§4.2–§4.9) are new, and a kind
/// this build does not know is stored but never surfaced.
final class SliceKindTests: XCTestCase {

    func testRawValuesAreFrozen() {
        XCTAssertEqual(
            SliceKind.allCases.map(\.rawValue),
            [
                "briefing", "inbox_item", "target", "track", "digest", "digest_topic",
                "calendar_event", "person_card", "situation", "meeting_transcript",
                "day_plan", "day_plan_item", "feature_state", "stream_digest",
                "slack_account", "google_account", "jira_account",
                "heartbeat", "device_grant", "recording_job",
                "workbench", "workbench_target", "workbench_comment", "terminal_session",
                "owner_ask", "session_report", "session_timeline", "ask_alert", "permission_request"
            ]
        )
    }

    func testEveryRawValueDecodes() throws {
        for kind in SliceKind.allCases {
            XCTAssertEqual(SliceKind(rawValue: kind.rawValue), kind)
            let json = Data("\"\(kind.rawValue)\"".utf8)
            XCTAssertEqual(try JSONDecoder().decode(SliceKind.self, from: json), kind)
        }
    }

    func testRecordNames() {
        XCTAssertEqual(SliceKind.deviceGrant.recordName(id: "D1"), "device_grant-D1")
        XCTAssertEqual(SliceKind.heartbeat.rawValue, HeartbeatPayload.recordName)
    }

    func testUnknownKindIsStoredButNotSurfaced() async throws {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let transport = InMemoryCloudTransport()
        // The hub's transport refuses to seal a kind it does not know, so the future kind is sealed directly.
        let future = try TestE2E.sealedDataRecord(
            CloudRecord(recordName: "future_kind-1", zone: .data, kind: "future_kind", modifiedAt: stamp, payload: Data("{}".utf8)),
            seq: 1)
        try await transport.save([future, try await TestE2E.hubTransport().seal(TestE2E.keyboxRecord(modifiedAt: stamp))])
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener())
        let surfaced = OSAllocatedUnfairLock(initialState: [AppliedSliceRecord]())
        let hook: @Sendable ([AppliedSliceRecord]) -> Void = { records in
            surfaced.withLock { $0.append(contentsOf: records) }
        }
        let hydrator = ReplicaHydrator(transport: transport, store: store, onRecordsApplied: hook)

        let result = try await hydrator.hydrateOnce()

        XCTAssertEqual(result.applied, 2)
        let storedKinds = try await store.reader.read { db in
            try String.fetchAll(db, sql: "SELECT kind FROM slice_records ORDER BY plain_name")
        }
        XCTAssertEqual(storedKinds, ["device_grant", "future_kind"])
        XCTAssertEqual(surfaced.withLock { $0.map(\.recordName) }, [SliceKind.deviceGrant.recordName(id: TestE2E.deviceID.uuidString)])
    }
}
