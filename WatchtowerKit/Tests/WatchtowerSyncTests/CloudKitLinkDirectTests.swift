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
        let throttled = await transport.isThrottled
        XCTAssertTrue(throttled, "isThrottled: \(what)", file: file, line: line)
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

    /// A partial failure is judged by the requested record's own error: a rate limit inside it throttles, a zone gone
    /// inside it unlinks.
    func testAPartialFailureIsJudgedByTheRecordsOwnError() async throws {
        let id = CKRecord.ID(recordName: "keybox-DEVICE", zoneID: zones.zoneID(for: .data))
        let (throttling, throttlingDatabase, _) = try make()
        throttlingDatabase.fetchFailures = [CKError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: [id: CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 30.0])]
        ])]
        _ = try? await throttling.serverRecord(named: "keybox-DEVICE", in: .data)
        await assertThrottled(throttling, throttlingDatabase, "partialFailure(requestRateLimited)")

        let (unlinking, unlinkingDatabase, _) = try make()
        unlinkingDatabase.fetchFailures = [CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [id: CKError(.zoneNotFound)]])]
        _ = try? await unlinking.serverRecord(named: "keybox-DEVICE", in: .data)
        let unlinked = await unlinking.isUnlinked
        XCTAssertTrue(unlinked)
    }

    /// A partial failure whose entry for the requested record is `unknownItem` is an absence; one about another
    /// record still throws.
    func testAPartialUnknownItemForTheRecordIsAnAbsence() async throws {
        let id = CKRecord.ID(recordName: "keybox-DEVICE", zoneID: zones.zoneID(for: .data))
        let other = CKRecord.ID(recordName: "keybox-OTHER", zoneID: zones.zoneID(for: .data))
        let (transport, database, _) = try make()
        database.fetchFailures = [
            CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [id: CKError(.unknownItem)]]),
            CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [other: CKError(.unknownItem)]])
        ]

        let absent = try await transport.serverRecord(named: "keybox-DEVICE", in: .data)
        XCTAssertNil(absent)
        do {
            _ = try await transport.serverRecord(named: "keybox-DEVICE", in: .data)
            XCTFail("expected a throw")
        } catch let error as CKError {
            XCTAssertEqual(error.code, .partialFailure)
        }
    }

    /// A shorter throttle never shortens a longer one, nor cancels the retry waiting for it.
    func testAShorterThrottleKeepsTheLongerOne() async throws {
        let sleeps = Collector<TimeInterval>()
        let transport = CloudKitTransport.conditionalTesting(store: try .inMemory(), database: FakeConditionalDatabase()) {
            sleeps.append($0)
            try? await Task.sleep(for: .seconds(3_600))
        }
        _ = await transport.applyThrottle(from: [CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 60.0])])
        let long = await transport.throttledUntil
        _ = await transport.applyThrottle(from: [CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 5.0])])

        let after = await transport.throttledUntil
        XCTAssertEqual(after, long, "the later deadline stands")
        for _ in 0..<10_000 where sleeps.values.isEmpty { await Task.yield() }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(sleeps.values, [60], "one retry, for the longer wait")
    }

    /// A save answered with no result for the record is not a save: it throws, so the link flow queues the hello.
    func testASaveWithoutAResultIsNoSave() async throws {
        let (transport, database, _) = try make()
        database.missingResults = ["hello-DEVICE"]

        do {
            try await transport.saveDirectly(record("hello-DEVICE", zone: .relay, payload: "new"))
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? DirectCallRefusal, .noResult)
        }
        XCTAssertNil(database.record(named: "hello-DEVICE"))
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

    /// `modify` may wrap the record's `serverRecordChanged` in a `partialFailure`: the save still retries once over
    /// the server copy.
    func testAWrappedConflictStillRetriesOverTheServersCopy() async throws {
        let (transport, database, _) = try make()
        let server = database.seed(CloudKitTransport.ckRecord(
            from: record("hello-DEVICE", zone: .relay, payload: "old"), in: zones.zoneID(for: .relay), systemFields: nil))
        let id = server.recordID
        database.callFailures = [CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [
            id: CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server])
        ]])]

        try await transport.saveDirectly(record("hello-DEVICE", zone: .relay, payload: "new"))

        XCTAssertEqual(database.calls.count, 2, "the wrapped conflict, then the retry over the copy")
        XCTAssertEqual(database.record(named: "hello-DEVICE")?.encryptedValues["payload"] as? Data, Data("new".utf8))
    }

    /// A throttle that elapsed during a direct call (nil now) is no newer throttle: the call's success ends the
    /// stretch and its backoff.
    func testASuccessEndsAThrottleThatElapsedDuringIt() async throws {
        let gate = SleepGate()
        let store = try TransportStore.inMemory()
        let database = FakeConditionalDatabase()
        let transport = CloudKitTransport.conditionalTesting(store: store, database: database) { _ in await gate.wait() }
        // A throttle whose deadline is already here: the call goes out, while its retry has not run yet.
        _ = await transport.applyThrottle(from: [CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 0.0])])
        let since = await transport.throttledSince
        XCTAssertNotNil(since)
        database.duringRequest = {
            await gate.open()
            while await transport.throttledUntil != nil { await Task.yield() }
        }

        _ = try await transport.serverRecord(named: "keybox-DEVICE", in: .data)

        let after = await transport.throttledSince
        XCTAssertNil(after, "the stretch ended")
    }

    /// An engine send's success keeps a throttle another request set while the batch was in flight.
    func testASendSuccessKeepsANewerThrottle() async throws {
        let (transport, _, _) = try make()
        _ = await transport.applyThrottle(from: [CKError(.zoneBusy)])
        let saved = CloudKitTransport.ckRecord(
            from: record("action-1", zone: .relay, payload: "x"), in: zones.zoneID(for: .relay), systemFields: nil)

        await transport.handleSentChanges(saved: [saved], deleted: [], failedSaves: [], failedDeletes: [:])

        let throttled = await transport.throttledUntil
        XCTAssertNotNil(throttled, "set after the batch was built: kept")
    }
}

/// A sleep the test ends: every `wait()` returns once `open()` was called.
actor SleepGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
