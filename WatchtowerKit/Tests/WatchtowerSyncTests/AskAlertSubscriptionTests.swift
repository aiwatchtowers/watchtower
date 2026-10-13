import CloudKit
import XCTest
@testable import WatchtowerSync

/// The ask-alert push per scope (D14): a `CKQuerySubscription` on `WatchtowerSignal` for a private-scope phone,
/// none for a shared-scope phone.
final class AskAlertSubscriptionTests: XCTestCase {
    private let hubID = "11111111-2222-3333-4444-555555555555"

    func testTheSubscriptionTargetsTheSignalTypeInTheHubsDataZone() throws {
        let subscription = try XCTUnwrap(AskAlertSubscription.subscription(for: .private, hubID: hubID))

        XCTAssertEqual(subscription.recordType, "WatchtowerSignal")
        XCTAssertEqual(subscription.predicate, NSPredicate(value: true))
        XCTAssertEqual(subscription.zoneID, HubZones(scope: .private, hubID: hubID).zoneID(for: .data))
        XCTAssertEqual(subscription.zoneID?.zoneName, "DataZone-\(hubID)")
        XCTAssertEqual(subscription.querySubscriptionOptions, [.firesOnRecordCreation])
        XCTAssertEqual(subscription.subscriptionID, AskAlertSubscription.subscriptionID(hubID: hubID))
        let info = try XCTUnwrap(subscription.notificationInfo)
        XCTAssertFalse(info.shouldSendContentAvailable)
        XCTAssertTrue(info.shouldSendMutableContent)
        XCTAssertEqual(info.alertBody, "A session is waiting")
    }

    func testSharedScopeGetsNoQuerySubscription() {
        XCTAssertNil(AskAlertSubscription.subscription(for: .shared(ownerName: "_owner"), hubID: hubID))
    }

    /// The extension finds the alert a signal names: same zone, the name after `sig-`.
    func testASignalNamesItsAlertInTheSameZone() throws {
        let zone = HubZones(scope: .private, hubID: hubID).zoneID(for: .data)
        let signal = CKRecord.ID(recordName: "sig-ABCDEF234567", zoneID: zone)

        let reference = try XCTUnwrap(AskAlertSubscription.alertReference(forSignal: signal))
        XCTAssertEqual(reference.hubID, hubID)
        XCTAssertEqual(reference.alertID, CKRecord.ID(recordName: "ABCDEF234567", zoneID: zone))

        XCTAssertNil(AskAlertSubscription.alertReference(forSignal: CKRecord.ID(recordName: "ABCDEF", zoneID: zone)))
        XCTAssertNil(AskAlertSubscription.alertReference(forSignal: CKRecord.ID(recordName: "sig-", zoneID: zone)))
        let relay = HubZones(scope: .private, hubID: hubID).zoneID(for: .relay)
        XCTAssertNil(AskAlertSubscription.alertReference(forSignal: CKRecord.ID(recordName: "sig-ABC", zoneID: relay)))
        let legacy = CKRecordZone.ID(zoneName: "DataZone", ownerName: CKCurrentUserDefaultName)
        XCTAssertNil(AskAlertSubscription.alertReference(forSignal: CKRecord.ID(recordName: "sig-ABC", zoneID: legacy)))
    }

    func testTheEnvelopeIsTheSealedPayloadOfAnEnvelopeRecordOnly() {
        let zone = HubZones(scope: .private, hubID: hubID).zoneID(for: .data)
        let record = CKRecord(recordType: "WatchtowerEnvelope", recordID: CKRecord.ID(recordName: "ABC", zoneID: zone))
        XCTAssertNil(AskAlertSubscription.envelope(of: record))
        record.encryptedValues["payload"] = Data([1, 2, 3])
        XCTAssertEqual(AskAlertSubscription.envelope(of: record), Data([1, 2, 3]))
        let signal = CKRecord(recordType: "WatchtowerSignal", recordID: CKRecord.ID(recordName: "sig-ABC", zoneID: zone))
        signal.encryptedValues["payload"] = Data([1, 2, 3])
        XCTAssertNil(AskAlertSubscription.envelope(of: signal))
    }
}
