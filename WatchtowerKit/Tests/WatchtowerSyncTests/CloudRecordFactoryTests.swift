import XCTest
@testable import WatchtowerSync

final class CloudRecordFactoryTests: XCTestCase {
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    func testActionRecordIdentityAndPayload() throws {
        let action = ActionRequestPayload(id: "A1", kind: .inboxResolve, entityID: "5", createdAt: stamp)
        let record = try CloudRecordFactory.record(for: action, modifiedAt: stamp)
        XCTAssertEqual(record.recordName, "action-A1")
        XCTAssertEqual(record.zone, .relay)
        XCTAssertEqual(record.kind, "action")
        let decoded = try RelayCoder.makeDecoder().decode(ActionRequestPayload.self, from: record.payload)
        XCTAssertEqual(decoded, action)
    }

    /// The heartbeat moved from RelayZone to DataZone (mobile POC spec
    /// §4.1): only the hub writes DataZone, so a RelayZone share
    /// participant cannot rewrite it.
    func testHeartbeatRecordUsesStaticNameInDataZone() throws {
        let beat = HeartbeatFixtures.minimal(updatedAt: stamp)
        let record = try CloudRecordFactory.record(for: beat, modifiedAt: stamp)
        XCTAssertEqual(record.recordName, "heartbeat")
        XCTAssertEqual(record.kind, "heartbeat")
        XCTAssertEqual(record.zone, .data)
    }

    func testSliceRecordMapsKindAndZone() {
        let slice = SliceRecord(kind: .target, id: "9", modifiedAt: stamp, payload: Data("{}".utf8))
        let record = CloudRecordFactory.record(for: slice)
        XCTAssertEqual(record.recordName, "target-9")
        XCTAssertEqual(record.zone, .data)
        XCTAssertEqual(record.kind, "target")
        XCTAssertEqual(record.payload, Data("{}".utf8))
    }

    // MARK: - notifyLevel (Plan 6 Decision 3)

    func testSliceNotifyLevelCarriesThroughToCloudRecord() {
        let tagged = SliceRecord(
            kind: .inboxItem, id: "3", modifiedAt: stamp,
            payload: Data("{}".utf8), notifyLevel: "urgent"
        )
        XCTAssertEqual(tagged.notifyLevel, "urgent")
        XCTAssertEqual(CloudRecordFactory.record(for: tagged).notifyLevel, "urgent")
    }

    func testUntaggedSliceRecordDefaultsToNilNotifyLevel() {
        // The pre-Plan-6 initializer shape must keep producing the
        // pre-Plan-6 record: notifyLevel defaults to nil and the payload
        // bytes pass through untouched.
        let slice = SliceRecord(kind: .target, id: "9", modifiedAt: stamp, payload: Data("{}".utf8))
        XCTAssertNil(slice.notifyLevel)
        let record = CloudRecordFactory.record(for: slice)
        XCTAssertNil(record.notifyLevel)
        XCTAssertEqual(record.payload, Data("{}".utf8))
    }

    func testRelayRecordsNeverCarryNotifyLevel() throws {
        let action = ActionRequestPayload(id: "A1", kind: .inboxResolve, entityID: "5", createdAt: stamp)
        XCTAssertNil(try CloudRecordFactory.record(for: action, modifiedAt: stamp).notifyLevel)
    }

    func testRelayRecordKindRawValuesAreFrozen() {
        XCTAssertEqual(
            RelayRecordKind.allCases.map(\.rawValue),
            ["action", "heartbeat", "recording_upload", "device"]
        )
    }
}
