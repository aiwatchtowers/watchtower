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
        let ck = CloudKitTransport.ckRecord(from: original, in: zoneID)
        XCTAssertEqual(ck.recordID.recordName, "target-9")
        XCTAssertEqual(ck.recordType, "WatchtowerRecord")

        let roundTripped = CloudKitTransport.cloudRecord(from: ck)
        XCTAssertEqual(roundTripped, original)
    }

    func testCKRecordWithoutPayloadMapsToNil() {
        let zoneID = CKRecordZone.ID(zoneName: CloudZoneID.relay.rawValue, ownerName: CKCurrentUserDefaultName)
        let ck = CKRecord(recordType: "WatchtowerRecord", recordID: CKRecord.ID(recordName: "x", zoneID: zoneID))
        XCTAssertNil(CloudKitTransport.cloudRecord(from: ck))
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
