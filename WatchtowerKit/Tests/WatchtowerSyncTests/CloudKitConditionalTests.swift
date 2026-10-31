import CloudKit
import XCTest
@testable import WatchtowerSync

/// `ConditionalTransport` on CloudKit (relay client Phase 1, Task 2): mailbox writes outside `CKSyncEngine`,
/// through `modifyRecords` with `.ifServerRecordUnchanged`; the stored system-fields archive is the version a
/// `.seq` names, and the server enforces its change tag.
final class CloudKitConditionalTests: XCTestCase {
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)
    private var zones: HubZones { HubZones(scope: .shared(ownerName: "_owner-acme"), hubID: HubZones.testHubID) }

    private func record(_ name: String, zone: CloudZoneID = .relay, payload: String = "WTE-1") -> CloudRecord {
        CloudRecord(recordName: name, zone: zone, kind: WireKind.envelope, modifiedAt: stamp, payload: Data(payload.utf8))
    }

    private func serverRecord(_ name: String, payload: String) -> CKRecord {
        CloudKitTransport.ckRecord(from: record(name, payload: payload), in: zones.zoneID(for: .relay), systemFields: nil)
    }

    private func make() throws -> (CloudKitTransport, FakeConditionalDatabase, TransportStore) {
        let store = try TransportStore.inMemory()
        let database = FakeConditionalDatabase()
        return (CloudKitTransport.conditionalTesting(store: store, database: database), database, store)
    }

    /// Buffers `ck` as the engine's fetch would: its event and its system fields in one transaction.
    private func buffer(_ ck: CKRecord, into store: TransportStore) throws {
        let fetched = try XCTUnwrap(CloudKitTransport.cloudRecord(from: ck, zone: .relay))
        try store.bufferFetched(
            changed: [fetched],
            systemFields: [(name: ck.recordID.recordName, zone: .relay, data: CloudKitTransport.archivedSystemFields(of: ck))],
            deleted: [:])
    }

    func testAbsentSendsAFreshRecord() async throws {
        let (transport, database, store) = try make()
        let outcomes = try await transport.save([ConditionalSave(record: record("a-1"), expect: .absent)])

        XCTAssertEqual(outcomes, [.saved(recordSeq: 1)])
        XCTAssertEqual(database.calls.count, 1)
        let sent = try XCTUnwrap(database.calls.first?.saves.first)
        XCTAssertEqual(database.calls.first?.saves.count, 1)
        XCTAssertNil(sent.recordChangeTag, "a fresh record, no system fields")
        XCTAssertEqual(sent.recordID.zoneID, zones.zoneID(for: .relay))
        let version = try XCTUnwrap(try store.recordVersion(recordName: "a-1", zone: .relay))
        XCTAssertEqual(version.recordSeq, 1)
        XCTAssertEqual(version.changeTag, database.record(named: "a-1")?.recordChangeTag)
        XCTAssertNotNil(version.changeTag)
        XCTAssertFalse(try store.isPending(recordName: "a-1", zone: .relay), "never in the engine's queue")
    }

    func testAnAbsentSaveOverAnExistingRecordIsAConflict() async throws {
        let (transport, database, _) = try make()
        database.seed(serverRecord("a-1", payload: "theirs"))
        let outcomes = try await transport.save([ConditionalSave(record: record("a-1"), expect: .absent)])
        guard case .conflict(let current) = outcomes.first else { return XCTFail("\(outcomes)") }
        XCTAssertEqual(current.payload, Data("theirs".utf8))
        XCTAssertEqual(current.recordSeq, 1)
    }

    func testASeqSaveCarriesTheStoredChangeTag() async throws {
        let (transport, database, store) = try make()
        let fetched = database.seed(serverRecord("c-1", payload: "v1"))
        try buffer(fetched, into: store)
        let version = try XCTUnwrap(try store.recordVersion(recordName: "c-1", zone: .relay))
        XCTAssertEqual(version.changeTag, fetched.recordChangeTag)
        let latest = try XCTUnwrap(try store.latestEvent(recordName: "c-1", zone: .relay))
        XCTAssertEqual(latest.recordSeq, version.recordSeq, "the buffered event names its own version")

        let outcomes = try await transport.save([
            ConditionalSave(record: record("c-1", payload: "v2"), expect: .seq(version.recordSeq))
        ])

        XCTAssertEqual(database.calls.first?.saves.first?.recordChangeTag, fetched.recordChangeTag)
        XCTAssertEqual(outcomes, [.saved(recordSeq: version.recordSeq + 1)])
        XCTAssertEqual(try store.recordVersion(recordName: "c-1", zone: .relay)?.changeTag,
                       database.record(named: "c-1")?.recordChangeTag)
    }

    func testServerRecordChangedIsAConflictNotARetry() async throws {
        let (transport, database, store) = try make()
        let fetched = database.seed(serverRecord("c-1", payload: "v1"))
        try buffer(fetched, into: store)
        // Another device writes after this phone fetched.
        let newer = database.seed(serverRecord("c-1", payload: "theirs"))

        let outcomes = try await transport.save([ConditionalSave(record: record("c-1", payload: "mine"), expect: .seq(1))])

        XCTAssertEqual(database.calls.count, 1, "one save, never a retry")
        guard case .conflict(let current) = outcomes.first else { return XCTFail("\(outcomes)") }
        XCTAssertEqual(current.payload, Data("theirs".utf8))
        XCTAssertEqual(current.recordSeq, 2, "the server's version is stored")
        XCTAssertEqual(try store.recordVersion(recordName: "c-1", zone: .relay)?.recordSeq, 2)
        XCTAssertEqual(try store.recordVersion(recordName: "c-1", zone: .relay)?.changeTag, newer.recordChangeTag)
        XCTAssertEqual(database.record(named: "c-1")?.encryptedValues["payload"] as? Data, Data("theirs".utf8),
                       "never my payload wins")
    }

    func testAStaleSeqConflictsWithoutACall() async throws {
        let (transport, database, store) = try make()
        try buffer(database.seed(serverRecord("c-1", payload: "v1")), into: store)
        try buffer(database.seed(serverRecord("c-1", payload: "v2")), into: store)
        XCTAssertEqual(try store.recordVersion(recordName: "c-1", zone: .relay)?.recordSeq, 2)

        let outcomes = try await transport.save([ConditionalSave(record: record("c-1", payload: "mine"), expect: .seq(1))])

        XCTAssertTrue(database.calls.isEmpty)
        guard case .conflict(let current) = outcomes.first else { return XCTFail("\(outcomes)") }
        XCTAssertEqual(current.payload, Data("v2".utf8))
        XCTAssertEqual(current.recordSeq, 2)
    }

    /// The stored handle is newer than every buffered event (this phone's own save, not fetched back yet): the
    /// buffer holds no current copy to hand back, so the write waits for the next fetch.
    func testAStaleBufferIsATransientRefusalNotAnOldCopy() async throws {
        let (transport, database, store) = try make()
        try buffer(database.seed(serverRecord("c-1", payload: "v1")), into: store)
        let saved = try await transport.save([ConditionalSave(record: record("c-1", payload: "v2"), expect: .seq(1))])
        XCTAssertEqual(saved, [.saved(recordSeq: 2)])
        let calls = database.calls.count

        let save = try await transport.save([ConditionalSave(record: record("c-1", payload: "v3"), expect: .seq(1))])
        let delete = try await transport.delete([ConditionalDelete(recordName: "c-1", zone: .relay, expect: .seq(1))])

        XCTAssertEqual(save, [.refused(.transient(code: "staleBuffer"))])
        XCTAssertEqual(delete, [.refused(.transient(code: "staleBuffer"))])
        XCTAssertEqual(database.calls.count, calls, "no call")
    }

    func testASeqWithNothingStoredConflictsWithTheBufferedEventOrIsUnknown() async throws {
        let (transport, database, store) = try make()
        try store.bufferChanged([record("c-1", payload: "seen")])
        let outcomes = try await transport.save([
            ConditionalSave(record: record("c-1"), expect: .seq(4)),
            ConditionalSave(record: record("c-2"), expect: .seq(4))
        ])
        XCTAssertTrue(database.calls.isEmpty)
        guard case .conflict(let current) = outcomes.first else { return XCTFail("\(outcomes)") }
        XCTAssertEqual(current.payload, Data("seen".utf8))
        XCTAssertEqual(outcomes.last, .refused(.permanent(code: "unknownVersion")))
    }

    func testAnUnknownItemOnASeqSaveIsGone() async throws {
        let (transport, database, store) = try make()
        let fetched = database.seed(serverRecord("c-1", payload: "v1"))
        try buffer(fetched, into: store)
        _ = try await database.modify(saving: [], deleting: [fetched.recordID])

        let outcomes = try await transport.save([ConditionalSave(record: record("c-1"), expect: .seq(1))])

        XCTAssertEqual(outcomes, [.refused(.permanent(code: "gone"))])
        XCTAssertNil(try store.recordVersion(recordName: "c-1", zone: .relay), "stored fields dropped")
    }

    func testANoneSaveOverwritesOnceOnAConflict() async throws {
        let (transport, database, store) = try make()
        database.seed(serverRecord("c-1", payload: "theirs"))

        let outcomes = try await transport.save([ConditionalSave(record: record("c-1", payload: "mine"), expect: .none)])

        XCTAssertEqual(database.calls.count, 2, "fresh, then over the server copy")
        XCTAssertEqual(outcomes, [.saved(recordSeq: 2)])
        XCTAssertEqual(database.record(named: "c-1")?.encryptedValues["payload"] as? Data, Data("mine".utf8))
        XCTAssertEqual(try store.recordVersion(recordName: "c-1", zone: .relay)?.recordSeq, 2)
    }

    func testDeleteChecksLocallyThenDeletes() async throws {
        let (transport, database, store) = try make()
        for payload in ["v1", "v2", "v3"] {
            try buffer(database.seed(serverRecord("c-1", payload: payload)), into: store)
        }
        XCTAssertEqual(try store.recordVersion(recordName: "c-1", zone: .relay)?.recordSeq, 3)

        let stale = try await transport.delete([ConditionalDelete(recordName: "c-1", zone: .relay, expect: .seq(2))])
        XCTAssertTrue(database.calls.isEmpty, "a stale version is refused here")
        guard case .conflict(let current) = stale.first else { return XCTFail("\(stale)") }
        XCTAssertEqual(current.payload, Data("v3".utf8))

        let outcomes = try await transport.delete([ConditionalDelete(recordName: "c-1", zone: .relay, expect: .seq(3))])
        XCTAssertEqual(outcomes, [.deleted])
        XCTAssertEqual(database.calls.count, 1)
        XCTAssertEqual(database.calls.first?.deletes.map(\.recordName), ["c-1"])
        XCTAssertNil(database.record(named: "c-1"))
        XCTAssertNil(try store.recordVersion(recordName: "c-1", zone: .relay), "stored fields deleted")

        // Gone on the server already: the seam's idempotent delete.
        let again = try await transport.delete([ConditionalDelete(recordName: "c-1", zone: .relay, expect: .none)])
        XCTAssertEqual(again, [.deleted])
    }

    func testRefusalsMapByCode() async throws {
        let cases: [(CKError, TransportRefusal)] = [
            (CKError(.networkUnavailable), .unreachable),
            (CKError(.networkFailure), .unreachable),
            (CKError(.serviceUnavailable), .unreachable),
            (CKError(.notAuthenticated), .unreachable),
            (CKError(.accountTemporarilyUnavailable), .unreachable),
            (CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 7.0]), .rateLimited(retryAfter: 7)),
            (CKError(.zoneBusy), .rateLimited(retryAfter: nil)),
            (CKError(.quotaExceeded), .quotaExceeded),
            (CKError(.operationCancelled), .transient(code: "operationCancelled")),
            (CKError(.serverResponseLost), .transient(code: "serverResponseLost")),
            (CKError(.partialFailure), .transient(code: "partialFailure")),
            (CKError(.internalError), .transient(code: "internalError")),
            (CKError(.serverRejectedRequest), .transient(code: "serverRejectedRequest")),
            (CKError(.assetFileModified), .transient(code: "ckError\(CKError.Code.assetFileModified.rawValue)")),
            (CKError(.zoneNotFound), .permanent(code: "zoneNotFound")),
            (CKError(.userDeletedZone), .permanent(code: "userDeletedZone")),
            (CKError(.permissionFailure), .permanent(code: "permissionFailure")),
            (CKError(.invalidArguments), .permanent(code: "invalidArguments")),
            (CKError(.badContainer), .permanent(code: "badContainer")),
            (CKError(.badDatabase), .permanent(code: "badDatabase")),
            (CKError(.missingEntitlement), .permanent(code: "missingEntitlement"))
        ]
        for (error, expected) in cases {
            // Per call: every item gets the refusal.
            let (transport, database, _) = try make()
            database.callFailures = [error]
            let saves = try await transport.save([
                ConditionalSave(record: record("a-1"), expect: .absent),
                ConditionalSave(record: record("a-2"), expect: .absent)
            ])
            XCTAssertEqual(saves, [.refused(expected), .refused(expected)], "call: \(error.code.rawValue)")
            database.callFailures = [error]
            let deletes = try await transport.delete([ConditionalDelete(recordName: "a-3", zone: .relay, expect: .none)])
            XCTAssertEqual(deletes, [.refused(expected)], "delete call: \(error.code.rawValue)")

            // Per record.
            database.recordFailures = ["a-4": error]
            let one = try await transport.save([
                ConditionalSave(record: record("a-4"), expect: .absent),
                ConditionalSave(record: record("a-5"), expect: .absent)
            ])
            XCTAssertEqual(one, [.refused(expected), .saved(recordSeq: 1)], "record: \(error.code.rawValue)")
        }
        let notPermanent: [CKError.Code] = [
            .operationCancelled, .serverResponseLost, .networkFailure, .networkUnavailable, .zoneBusy,
            .requestRateLimited, .serviceUnavailable, .assetFileModified
        ]
        for code in notPermanent {
            XCTAssertFalse(CloudKitTransport.refusal(for: CKError(code)).isPermanent, "\(code.rawValue)")
        }
    }

    func testABatchTooLargeIsSplit() async throws {
        let (transport, database, _) = try make()
        for name in ["c-1", "c-2", "c-3", "c-4"] { database.seed(serverRecord(name, payload: "v1")) }
        database.maxRecordsPerCall = 2

        let outcomes = try await transport.delete(["c-1", "c-2", "c-3", "c-4"].map {
            ConditionalDelete(recordName: $0, zone: .relay, expect: .none)
        })

        XCTAssertEqual(outcomes, Array(repeating: .deleted, count: 4))
        XCTAssertEqual(database.calls.map { $0.deletes.map(\.recordName) },
                       [["c-1", "c-2", "c-3", "c-4"], ["c-1", "c-2"], ["c-3", "c-4"]])

        // A record too large even alone.
        database.maxRecordsPerCall = 0
        let alone = try await transport.save([ConditionalSave(record: record("a-1"), expect: .absent)])
        XCTAssertEqual(alone, [.refused(.permanent(code: "tooLarge"))])
        database.maxRecordsPerCall = Int.max
        database.recordFailures = ["a-2": CKError(.limitExceeded)]
        let perRecord = try await transport.save([ConditionalSave(record: record("a-2"), expect: .absent)])
        XCTAssertEqual(perRecord, [.refused(.permanent(code: "tooLarge"))])
    }

    func testADataZoneItemIsRefused() async throws {
        let (transport, database, _) = try make()
        let saves = try await transport.save([ConditionalSave(record: record("target-1", zone: .data), expect: .none)])
        let deletes = try await transport.delete([ConditionalDelete(recordName: "target-1", zone: .data, expect: .none)])
        XCTAssertEqual(saves, [.refused(.permanent(code: "notMailbox"))])
        XCTAssertEqual(deletes, [.refused(.permanent(code: "notMailbox"))])
        XCTAssertTrue(database.calls.isEmpty)
    }

    func testOutcomesKeepTheItemOrderAroundLocalAnswers() async throws {
        let (transport, database, _) = try make()
        let outcomes = try await transport.save([
            ConditionalSave(record: record("target-1", zone: .data), expect: .none),
            ConditionalSave(record: record("a-1"), expect: .absent),
            ConditionalSave(record: record("a-2"), expect: .seq(9)),
            ConditionalSave(record: record("a-3"), expect: .absent)
        ])
        XCTAssertEqual(outcomes, [
            .refused(.permanent(code: "notMailbox")),
            .saved(recordSeq: 1),
            .refused(.permanent(code: "unknownVersion")),
            .saved(recordSeq: 1)
        ])
        XCTAssertEqual(database.calls.count, 1, "one call for what goes out")
    }
}
