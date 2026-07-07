import XCTest
import CloudKit
@testable import WatchtowerKit

final class CloudKitTransportMappingTests: XCTestCase {
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    func testCloudRecordToCKRecordAndBack() {
        let zoneID = CKRecordZone.ID(zoneName: CloudZoneID.data.rawValue, ownerName: CKCurrentUserDefaultName)
        let original = CloudRecord(
            recordName: "target-9",
            zone: .data,
            kind: "target",
            modifiedAt: stamp,
            payload: Data("{\"id\":9}".utf8)
        )
        let ck = CloudKitTransport.ckRecord(from: original, in: zoneID, systemFields: nil)
        XCTAssertEqual(ck.recordID.recordName, "target-9")
        XCTAssertEqual(ck.recordType, "WatchtowerRecord")

        let roundTripped = CloudKitTransport.cloudRecord(from: ck)
        XCTAssertEqual(roundTripped, original)
    }

    func testCKRecordSeededFromSystemFieldsPreservesIdentityAndTakesNewPayload() throws {
        let zoneID = CKRecordZone.ID(zoneName: CloudZoneID.data.rawValue, ownerName: CKCurrentUserDefaultName)
        let original = CloudRecord(
            recordName: "target-9",
            zone: .data,
            kind: "target",
            modifiedAt: stamp,
            payload: Data("{\"v\":1}".utf8)
        )
        let first = CloudKitTransport.ckRecord(from: original, in: zoneID, systemFields: nil)
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        first.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        let systemFields = archiver.encodedData

        let updated = CloudRecord(
            recordName: "target-9",
            zone: .data,
            kind: "target",
            modifiedAt: stamp.addingTimeInterval(60),
            payload: Data("{\"v\":2}".utf8)
        )
        let rebuilt = CloudKitTransport.ckRecord(from: updated, in: zoneID, systemFields: systemFields)

        // Identity comes from the archive; payload/kind/modifiedAt always from the CloudRecord.
        XCTAssertEqual(rebuilt.recordID, first.recordID)
        XCTAssertEqual(rebuilt.recordID.zoneID, zoneID)
        XCTAssertEqual(rebuilt.recordType, "WatchtowerRecord")
        XCTAssertEqual(rebuilt.encryptedValues["payload"] as? Data, Data("{\"v\":2}".utf8))
        XCTAssertEqual(rebuilt["kind"] as? String, "target")
        XCTAssertEqual(rebuilt["modifiedAt"] as? Date, stamp.addingTimeInterval(60))
        // System-fields archives carry identity/metadata only — no payload keys.
        XCTAssertEqual(CloudKitTransport.cloudRecord(from: rebuilt), updated)
    }

    func testUndecodableSystemFieldsBlobFallsBackToFreshRecord() {
        let zoneID = CKRecordZone.ID(zoneName: CloudZoneID.relay.rawValue, ownerName: CKCurrentUserDefaultName)
        let record = CloudRecord(
            recordName: "action-1",
            zone: .relay,
            kind: "action",
            modifiedAt: stamp,
            payload: Data("{}".utf8)
        )
        let ck = CloudKitTransport.ckRecord(from: record, in: zoneID, systemFields: Data("not an archive".utf8))
        XCTAssertEqual(ck.recordID.recordName, "action-1")
        XCTAssertEqual(ck.recordID.zoneID, zoneID)
        XCTAssertEqual(ck.recordType, "WatchtowerRecord")
        XCTAssertEqual(ck.encryptedValues["payload"] as? Data, Data("{}".utf8))
    }

    func testCKRecordWithoutPayloadMapsToNil() {
        let zoneID = CKRecordZone.ID(zoneName: CloudZoneID.relay.rawValue, ownerName: CKCurrentUserDefaultName)
        let ck = CKRecord(recordType: "WatchtowerRecord", recordID: CKRecord.ID(recordName: "x", zoneID: zoneID))
        XCTAssertNil(CloudKitTransport.cloudRecord(from: ck))
    }

    // MARK: - notifyLevel (Plan 6 Decision 3 — the isError discipline)

    func testNotifyLevelRoundTripsThroughCKRecord() {
        let zoneID = CKRecordZone.ID(zoneName: CloudZoneID.data.rawValue, ownerName: CKCurrentUserDefaultName)
        let original = CloudRecord(
            recordName: "briefing-7",
            zone: .data,
            kind: "briefing",
            modifiedAt: stamp,
            payload: Data("{\"id\":7}".utf8),
            notifyLevel: "briefing"
        )
        let ck = CloudKitTransport.ckRecord(from: original, in: zoneID, systemFields: nil)
        // Owner ruling (Task 3 review): rides encryptedValues like the
        // payload — content-adjacent under ADP, never a plain queryable field.
        XCTAssertEqual(ck.encryptedValues["notifyLevel"] as? String, "briefing")
        // allKeys() lists encrypted keys too; the plain accessor is the
        // discriminator — it must see nothing.
        XCTAssertNil(ck["notifyLevel"], "notifyLevel must never be a plain field")
        XCTAssertEqual(CloudKitTransport.cloudRecord(from: ck), original)
    }

    func testNilNotifyLevelOmitsTheCKRecordField() {
        // The freeze pin: an untagged record produces a CKRecord with NO
        // notifyLevel key at all — byte-identical shape to pre-Plan-6 saves,
        // so old and new versions interoperate without a wire change.
        let zoneID = CKRecordZone.ID(zoneName: CloudZoneID.data.rawValue, ownerName: CKCurrentUserDefaultName)
        let original = CloudRecord(
            recordName: "target-9",
            zone: .data,
            kind: "target",
            modifiedAt: stamp,
            payload: Data("{\"id\":9}".utf8)
        )
        let ck = CloudKitTransport.ckRecord(from: original, in: zoneID, systemFields: nil)
        XCTAssertFalse(ck.allKeys().contains("notifyLevel"), "nil notifyLevel must be ABSENT, not null")
        XCTAssertNil(CloudKitTransport.cloudRecord(from: ck)?.notifyLevel)
    }

    func testLegacyCKRecordWithoutNotifyLevelDecodesToNil() {
        // Records written by pre-Plan-6 desktop versions carry no notifyLevel field.
        let zoneID = CKRecordZone.ID(zoneName: CloudZoneID.data.rawValue, ownerName: CKCurrentUserDefaultName)
        let ck = CKRecord(recordType: "WatchtowerRecord", recordID: CKRecord.ID(recordName: "target-1", zoneID: zoneID))
        ck.encryptedValues["payload"] = Data("{}".utf8)
        ck["kind"] = "target"
        ck["modifiedAt"] = stamp
        let decoded = CloudKitTransport.cloudRecord(from: ck)
        XCTAssertNotNil(decoded)
        XCTAssertNil(decoded?.notifyLevel)
    }

    func testUnknownZoneNameMapsToNil() {
        let zoneID = CKRecordZone.ID(zoneName: "SomeOtherZone", ownerName: CKCurrentUserDefaultName)
        let ck = CKRecord(recordType: "WatchtowerRecord", recordID: CKRecord.ID(recordName: "x", zoneID: zoneID))
        ck.encryptedValues["payload"] = Data("{}".utf8)
        ck["kind"] = "target"
        ck["modifiedAt"] = Date(timeIntervalSince1970: 0)
        XCTAssertNil(CloudKitTransport.cloudRecord(from: ck))
    }
}
