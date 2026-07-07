import XCTest
@testable import WatchtowerKit

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

    func testChatChunkRecordIdentity() throws {
        let chunk = ChatChunkPayload(sessionID: "S1", messageID: "M1", seq: 0, text: "hi", done: false)
        let record = try CloudRecordFactory.record(for: chunk, modifiedAt: stamp)
        XCTAssertEqual(record.recordName, "chatchunk-M1-0")
        XCTAssertEqual(record.kind, "chat_chunk")
        XCTAssertEqual(record.zone, .relay)
    }

    func testHeartbeatRecordUsesStaticName() throws {
        let beat = HeartbeatPayload(updatedAt: stamp, appVersion: "1.0")
        let record = try CloudRecordFactory.record(for: beat, modifiedAt: stamp)
        XCTAssertEqual(record.recordName, "heartbeat")
        XCTAssertEqual(record.kind, "heartbeat")
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
            ["action", "chat_message", "chat_chunk", "heartbeat"]
        )
    }
}
