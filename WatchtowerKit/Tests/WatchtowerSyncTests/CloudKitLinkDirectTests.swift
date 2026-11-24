import CloudKit
import XCTest
@testable import WatchtowerSync

/// The phone's link flow outside `CKSyncEngine` (#2189): `serverRecord` reads one record by name, `saveDirectly(_:)`
/// saves one at once; both honour the throttle and the unlink, and their failures throttle or unlink as a fetch's do.
final class CloudKitLinkDirectTests: XCTestCase {
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)
    private var zones: HubZones { HubZones(scope: .shared(ownerName: "_owner-acme"), hubID: HubZones.testHubID) }

    private func record(_ name: String, zone: CloudZoneID, payload: String) -> CloudRecord {
        CloudRecord(recordName: name, zone: zone, kind: WireKind.envelope, modifiedAt: stamp, payload: Data(payload.utf8))
    }

    /// A transport whose throttle, once set, holds for the test (its retry never fires).
    private func make(energy: EnergyCounter? = nil) throws -> (CloudKitTransport, FakeConditionalDatabase, TransportStore) {
        let store = try TransportStore.inMemory()
        let database = FakeConditionalDatabase()
        let transport = CloudKitTransport.conditionalTesting(store: store, database: database, energy: energy) { _ in
            try? await Task.sleep(for: .seconds(3_600))
        }
        return (transport, database, store)
    }

    private func counter() throws -> EnergyCounter {
        let suite = "CloudKitLinkDirectTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return EnergyCounter(defaults: defaults)
    }

    func testOnlyARequestThatGoesOutIsCounted() async throws {
        let energy = try counter()
        let (transport, database, _) = try make(energy: energy)
        database.seed(CloudKitTransport.ckRecord(
            from: record("hello-DEVICE", zone: .relay, payload: "old"), in: zones.zoneID(for: .relay), systemFields: nil))

        _ = try await transport.serverRecord(named: "keybox-DEVICE", in: .data)
        try await transport.saveDirectly(record("hello-DEVICE", zone: .relay, payload: "new"))
        XCTAssertEqual(energy.counts(daysAgo: 0)[.fetchLink], 1, "one read")
        XCTAssertEqual(energy.counts(daysAgo: 0)[.sendBatch], 2, "a save per modify call, as the engine's sends")

        database.fetchFailures = [CKError(.zoneBusy)]
        _ = try? await transport.serverRecord(named: "keybox-DEVICE", in: .data)
        _ = try? await transport.serverRecord(named: "keybox-DEVICE", in: .data)
        _ = try? await transport.saveDirectly(record("hello-DEVICE", zone: .relay, payload: "newer"))
        XCTAssertEqual(energy.counts(daysAgo: 0)[.fetchLink], 2, "the throttled read sent nothing")
        XCTAssertEqual(energy.counts(daysAgo: 0)[.sendBatch], 2, "the throttled save sent nothing")
    }

    /// A throttle another request installs while a direct call runs (the launch pull's `zoneBusy`) outlives the
    /// call's success.
    func testASuccessKeepsANewerThrottle() async throws {
        let (transport, database, _) = try make()
        database.duringRequest = { _ = await transport.applyThrottle(from: [CKError(.zoneBusy)]) }

        let read = try await transport.serverRecord(named: "keybox-DEVICE", in: .data)
        XCTAssertNil(read)

        database.duringRequest = nil
        do {
            _ = try await transport.serverRecord(named: "keybox-DEVICE", in: .data)
            XCTFail("expected throttled")
        } catch {
            XCTAssertEqual(error as? DirectCallRefusal, .throttled)
        }
    }

    /// The save's second try, over the server copy, is checked against a throttle set during the first.
    func testTheConflictRetryHonoursAThrottleSetMeanwhile() async throws {
        let (transport, database, _) = try make()
        database.seed(CloudKitTransport.ckRecord(
            from: record("hello-DEVICE", zone: .relay, payload: "old"), in: zones.zoneID(for: .relay), systemFields: nil))
        database.duringRequest = { _ = await transport.applyThrottle(from: [CKError(.zoneBusy)]) }

        do {
            try await transport.saveDirectly(record("hello-DEVICE", zone: .relay, payload: "new"))
            XCTFail("expected throttled")
        } catch {
            XCTAssertEqual(error as? DirectCallRefusal, .throttled)
        }
        XCTAssertEqual(database.calls.count, 1, "no second try")
    }

    private func seedKeybox(_ database: FakeConditionalDatabase) {
        database.seed(CloudKitTransport.ckRecord(
            from: record("keybox-DEVICE", zone: .data, payload: "sealed"), in: zones.zoneID(for: .data), systemFields: nil))
    }

    func testServerRecordReadsOneRecordByNameWithoutBuffering() async throws {
        let (transport, database, store) = try make()
        seedKeybox(database)

        let read = try await transport.serverRecord(named: "keybox-DEVICE", in: .data)
        let absent = try await transport.serverRecord(named: "keybox-OTHER", in: .data)

        XCTAssertEqual(read?.payload, Data("sealed".utf8))
        XCTAssertEqual(read?.zone, .data)
        XCTAssertNil(absent, "absent only when the server has none")
        XCTAssertEqual(database.fetches.map(\.zoneID), [zones.zoneID(for: .data), zones.zoneID(for: .data)])
        XCTAssertNil(try store.latestEvent(recordName: "keybox-DEVICE", zone: .data), "nothing buffered")
    }

    func testARecordThatDoesNotMapIsUnreadableNotAbsent() async throws {
        let (transport, database, _) = try make()
        database.seed(CKRecord(recordType: "WatchtowerRecord", recordID: CKRecord.ID(
            recordName: "keybox-DEVICE", zoneID: zones.zoneID(for: .data))))

        do {
            _ = try await transport.serverRecord(named: "keybox-DEVICE", in: .data)
            XCTFail("expected a throw")
        } catch let refusal as DirectCallRefusal {
            XCTAssertEqual(refusal, .unreadableRecord)
        }
    }

    func testServerRecordThrowsWhatCloudKitThrew() async throws {
        let (transport, database, _) = try make()
        database.fetchFailures = [CKError(.networkUnavailable)]
        do {
            _ = try await transport.serverRecord(named: "keybox-DEVICE", in: .data)
            XCTFail("expected a throw")
        } catch let error as CKError {
            XCTAssertEqual(error.code, .networkUnavailable)
        }
        _ = try await transport.serverRecord(named: "keybox-DEVICE", in: .data)
        XCTAssertEqual(database.fetches.count, 2, "a network failure sets no throttle")
    }

    func testARateLimitThrottlesTheNextCallsWithoutARequest() async throws {
        for failure in [
            CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 30.0]), CKError(.zoneBusy),
            CKError(.serviceUnavailable, userInfo: [CKErrorRetryAfterKey: 30.0])
        ] {
            let (transport, database, _) = try make()
            database.fetchFailures = [failure]
            _ = try? await transport.serverRecord(named: "keybox-DEVICE", in: .data)

            await assertThrottled(transport, database, "\(failure.code)")
        }
    }

    private func assertThrottled(
        _ transport: CloudKitTransport,
        _ database: FakeConditionalDatabase,
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let fetches = database.fetches.count
        let calls = database.calls.count
        do {
            _ = try await transport.serverRecord(named: "keybox-DEVICE", in: .data)
            XCTFail("expected throttled: \(what)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? DirectCallRefusal, .throttled, what, file: file, line: line)
        }
        do {
            try await transport.saveDirectly(record("hello-DEVICE", zone: .relay, payload: "hello"))
            XCTFail("expected throttled: \(what)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? DirectCallRefusal, .throttled, what, file: file, line: line)
        }
        XCTAssertEqual(database.fetches.count, fetches, "no read went out: \(what)", file: file, line: line)
        XCTAssertEqual(database.calls.count, calls, "no save went out: \(what)", file: file, line: line)
    }

    func testAServiceOutageWithoutRetryAfterDoesNotThrottle() async throws {
        let (transport, database, _) = try make()
        database.fetchFailures = [CKError(.serviceUnavailable)]
        _ = try? await transport.serverRecord(named: "keybox-DEVICE", in: .data)
        _ = try await transport.serverRecord(named: "keybox-DEVICE", in: .data)
        XCTAssertEqual(database.fetches.count, 2)
    }

    func testAZoneGoneUnlinksAndStopsTheCalls() async throws {
        let (transport, database, _) = try make()
        database.fetchFailures = [CKError(.zoneNotFound)]
        _ = try? await transport.serverRecord(named: "keybox-DEVICE", in: .data)

        let unlinked = await transport.isUnlinked
        XCTAssertTrue(unlinked)
        do {
            _ = try await transport.serverRecord(named: "keybox-DEVICE", in: .data)
            XCTFail("expected unlinked")
        } catch {
            XCTAssertEqual(error as? DirectCallRefusal, .unlinked)
        }
        XCTAssertEqual(database.fetches.count, 1)
    }

    func testSaveDirectlySavesAFreshRecordThenOverTheServersCopy() async throws {
        let (transport, database, store) = try make()

        try await transport.saveDirectly(record("hello-DEVICE", zone: .relay, payload: "first"))
        try await transport.saveDirectly(record("hello-DEVICE", zone: .relay, payload: "second"))

        XCTAssertEqual(database.record(named: "hello-DEVICE")?.encryptedValues["payload"] as? Data, Data("second".utf8))
        XCTAssertEqual(database.calls.count, 3, "fresh; then fresh refused, and once over the server copy")
        XCTAssertEqual(database.calls.first?.saves.first?.recordID.zoneID, zones.zoneID(for: .relay))
        XCTAssertFalse(try store.isPending(recordName: "hello-DEVICE", zone: .relay), "never in the engine's queue")
    }
}
