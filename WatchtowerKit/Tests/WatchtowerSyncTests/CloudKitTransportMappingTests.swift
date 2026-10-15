import XCTest
import CloudKit
import os
@testable import WatchtowerSync

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
        XCTAssertEqual(ck.recordType, "WatchtowerEnvelope")

        let roundTripped = CloudKitTransport.cloudRecord(from: ck, zone: .data)
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
        XCTAssertEqual(rebuilt.recordType, "WatchtowerEnvelope")
        XCTAssertEqual(rebuilt.encryptedValues["payload"] as? Data, Data("{\"v\":2}".utf8))
        XCTAssertEqual(rebuilt["kind"] as? String, "target")
        XCTAssertEqual(rebuilt["modifiedAt"] as? Date, stamp.addingTimeInterval(60))
        // System-fields archives carry identity/metadata only — no payload keys.
        XCTAssertEqual(CloudKitTransport.cloudRecord(from: rebuilt, zone: .data), updated)
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
        XCTAssertEqual(ck.recordType, "WatchtowerEnvelope")
        XCTAssertEqual(ck.encryptedValues["payload"] as? Data, Data("{}".utf8))
    }

    func testCKRecordWithoutPayloadMapsToNil() {
        let zoneID = CKRecordZone.ID(zoneName: CloudZoneID.relay.rawValue, ownerName: CKCurrentUserDefaultName)
        let ck = CKRecord(recordType: "WatchtowerEnvelope", recordID: CKRecord.ID(recordName: "x", zoneID: zoneID))
        XCTAssertNil(CloudKitTransport.cloudRecord(from: ck, zone: .relay))
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
        XCTAssertEqual(CloudKitTransport.cloudRecord(from: ck, zone: .data), original)
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
        XCTAssertNil(CloudKitTransport.cloudRecord(from: ck, zone: .data)?.notifyLevel)
    }

    func testEnvelopeRecordWithoutNotifyLevelDecodesToNil() {
        // Sealed records never carry a wire notifyLevel (F28): absent decodes to nil.
        let zoneID = CKRecordZone.ID(zoneName: CloudZoneID.data.rawValue, ownerName: CKCurrentUserDefaultName)
        let ck = CKRecord(recordType: "WatchtowerEnvelope", recordID: CKRecord.ID(recordName: "target-1", zoneID: zoneID))
        ck.encryptedValues["payload"] = Data("{}".utf8)
        ck["kind"] = "target"
        ck["modifiedAt"] = stamp
        let decoded = CloudKitTransport.cloudRecord(from: ck, zone: .data)
        XCTAssertNotNil(decoded)
        XCTAssertNil(decoded?.notifyLevel)
    }

    // MARK: - E2E record types (mobile E2E spec §2.8)

    func testEnvelopeRecordsUseTheWatchtowerEnvelopeType() {
        let zoneID = CKRecordZone.ID(zoneName: CloudZoneID.data.rawValue, ownerName: CKCurrentUserDefaultName)
        let record = CloudRecord(
            recordName: "abcdefghijklmnopqrstuvwxyz", zone: .data, kind: WireKind.envelope, modifiedAt: stamp,
            payload: Data("WTE".utf8))
        let ck = CloudKitTransport.ckRecord(from: record, in: zoneID, systemFields: nil)
        XCTAssertEqual(CloudKitTransport.recordType, "WatchtowerEnvelope")
        XCTAssertEqual(ck.recordType, "WatchtowerEnvelope")
        XCTAssertEqual(CloudKitTransport.cloudRecord(from: ck, zone: .data), record)
    }

    func testSignalRecordsUseTheWatchtowerSignalTypeAndCarryNoPayload() {
        let zoneID = CKRecordZone.ID(zoneName: CloudZoneID.data.rawValue, ownerName: CKCurrentUserDefaultName)
        let signal = CloudRecord(
            recordName: "sig-abcdefghijklmnopqrstuvwxyz", zone: .data, kind: WireKind.signal, modifiedAt: stamp,
            payload: Data("ignored".utf8))
        let ck = CloudKitTransport.ckRecord(from: signal, in: zoneID, systemFields: nil)
        XCTAssertEqual(CloudKitTransport.signalRecordType, "WatchtowerSignal")
        XCTAssertEqual(ck.recordType, "WatchtowerSignal")
        XCTAssertNil(ck.encryptedValues["payload"], "a signal carries no payload")
        XCTAssertFalse(ck.allKeys().contains("payload"))
        let decoded = CloudKitTransport.cloudRecord(from: ck, zone: .data)
        XCTAssertEqual(decoded?.payload, Data())
        XCTAssertEqual(decoded?.kind, WireKind.signal)
        XCTAssertEqual(decoded?.recordName, signal.recordName)
    }

    func testARecordOfThePreE2ETypeIsIgnoredOnFetch() {
        let zoneID = CKRecordZone.ID(zoneName: CloudZoneID.data.rawValue, ownerName: CKCurrentUserDefaultName)
        let legacy = CKRecord(recordType: "WatchtowerRecord", recordID: CKRecord.ID(recordName: "target-1", zoneID: zoneID))
        legacy.encryptedValues["payload"] = Data("{}".utf8)
        legacy["kind"] = "target"
        legacy["modifiedAt"] = stamp
        XCTAssertNil(CloudKitTransport.cloudRecord(from: legacy, zone: .data))
        XCTAssertNil(CloudKitTransport.cloudRecord(from: legacy, zone: .data), "ignored again (logged once per type)")
    }

    func testPayloadStaysAnEncryptedValueAndModifiedAtAPlainField() {
        let zoneID = CKRecordZone.ID(zoneName: CloudZoneID.relay.rawValue, ownerName: CKCurrentUserDefaultName)
        let record = CloudRecord(
            recordName: "abcdefghijklmnopqrstuvwxyz", zone: .relay, kind: WireKind.envelope, modifiedAt: stamp,
            payload: Data("WTE-sealed".utf8))
        let ck = CloudKitTransport.ckRecord(from: record, in: zoneID, systemFields: nil)
        XCTAssertEqual(ck.encryptedValues["payload"] as? Data, Data("WTE-sealed".utf8))
        XCTAssertNil(ck["payload"], "the envelope is never a plain field (spec §3, §7: encryptedValues stays the outer layer)")
        XCTAssertEqual(ck["modifiedAt"] as? Date, stamp, "modifiedAt stays plaintext (spec §2.4)")
        XCTAssertNil(ck.encryptedValues["modifiedAt"])
        XCTAssertEqual(ck["kind"] as? String, WireKind.envelope)
    }

    // MARK: - Direct save (the phone's kept farewell, #143)

    /// A direct save sends a fresh record (no change tag) in the hub's zone
    /// of the record's kind, owned by the shared link's owner.
    func testADirectSaveSendsAFreshRecordInTheHubsZone() {
        let record = CloudRecord(
            recordName: "abcdefghijklmnopqrstuvwxyz", zone: .relay, kind: WireKind.envelope, modifiedAt: stamp,
            payload: Data("WTE".utf8))

        let ck = CloudKitTransport.directSaveRecord(record, scope: .shared(ownerName: "_owner-acme"), hubID: "hub-a")

        XCTAssertEqual(ck.recordID.zoneID.zoneName, "RelayZone-hub-a")
        XCTAssertEqual(ck.recordID.zoneID.ownerName, "_owner-acme")
        XCTAssertNil(ck.recordChangeTag, "nothing fetched: no change tag")
        XCTAssertEqual(CloudKitTransport.cloudRecord(from: ck, zone: .relay), record)

        let own = CloudKitTransport.directSaveRecord(record, scope: .private, hubID: "hub-a")
        XCTAssertEqual(own.recordID.zoneID.ownerName, CKCurrentUserDefaultName)
    }

    /// #261: the direct save is a compare-and-swap. With nothing on the
    /// server the fresh record goes; refused for a server copy, it goes once
    /// more over that copy (its system fields, the farewell's payload), so
    /// a write landing after the read refuses it in turn, and that refusal
    /// is thrown (the farewell stays kept).
    func testADirectSaveReplacesOnlyTheServerCopyItWasRefusedFor() async throws {
        let record = farewellRecord()
        var sent: [CKRecord] = []
        try await CloudKitTransport.saveDirectly(record, scope: .private, hubID: "hub-a") { sent.append($0) }
        XCTAssertEqual(sent.count, 1)
        XCTAssertNil(sent.first?.recordChangeTag)

        let server = CloudKitTransport.directSaveRecord(
            CloudRecord(recordName: record.recordName, zone: .relay, kind: WireKind.envelope,
                        modifiedAt: stamp.addingTimeInterval(-60), payload: Data("old".utf8)),
            scope: .private, hubID: "hub-a")
        sent = []
        try await CloudKitTransport.saveDirectly(record, scope: .private, hubID: "hub-a") { ck in
            sent.append(ck)
            if sent.count == 1 { throw Self.changed(server) }
        }
        XCTAssertEqual(sent.count, 2)
        let retry = try XCTUnwrap(sent.last)
        XCTAssertEqual(CloudKitTransport.archivedSystemFields(of: retry), CloudKitTransport.archivedSystemFields(of: server),
                       "over the copy it was refused for")
        XCTAssertEqual(CloudKitTransport.cloudRecord(from: retry, zone: .relay), record)

        sent = []
        do {
            try await CloudKitTransport.saveDirectly(record, scope: .private, hubID: "hub-a") { ck in
                sent.append(ck)
                throw Self.changed(server)
            }
            XCTFail("a second refusal is thrown")
        } catch let error as CKError {
            XCTAssertEqual(error.code, .serverRecordChanged)
        }
        XCTAssertEqual(sent.count, 2, "one retry, never a loop")
    }

    /// #261: a direct save cancelled (the farewell's cap) while its first
    /// try was refused never tries again over the copy it read.
    func testACancelledDirectSaveNeverRetriesOverTheServerCopy() async {
        let record = farewellRecord()
        let server = CloudKitTransport.directSaveRecord(record, scope: .private, hubID: "hub-a")
        let saves = OSAllocatedUnfairLock(initialState: 0)
        let task = Task {
            try await CloudKitTransport.saveDirectly(record, scope: .private, hubID: "hub-a") { _ in
                saves.withLock { $0 += 1 }
                withUnsafeCurrentTask { $0?.cancel() }
                throw Self.changed(server)
            }
        }
        do {
            try await task.value
            XCTFail("a cancelled save throws")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(saves.withLock { $0 }, 1)
    }

    private func farewellRecord() -> CloudRecord {
        CloudRecord(
            recordName: "abcdefghijklmnopqrstuvwxyz", zone: .relay, kind: WireKind.envelope, modifiedAt: stamp,
            payload: Data("WTE".utf8))
    }

    private static func changed(_ server: CKRecord) -> CKError {
        CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server])
    }
}
