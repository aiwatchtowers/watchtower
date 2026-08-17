import GRDB
import XCTest
import WatchtowerKit
@testable import WatchtowerMobile

/// Smoke tests for the WatchtowerMobile app WIRING — not the replica logic,
/// which WatchtowerKit's ReplicaTests already cover end-to-end. Here we prove
/// that the app's own glue holds: `AppEnvironment` boots and hydrates the demo
/// seed, each tab's view model surfaces the seeded rows, the sync footer sees a
/// completed cycle, and — critically — `ReplicaObserver` observes a real
/// DatabasePool store without trapping and re-fires on a write.
@MainActor
final class ReplicaWiringTests: XCTestCase {

    // MARK: - DemoSeed record tallies (fixed ids + idempotent upserts → stable)

    private let seededCounts: [SliceKind: Int] = [
        .briefing: 1,
        .calendarEvent: 2,
        .inboxItem: 2,
        .situation: 2,
        .target: 3,
        .track: 2,
        .meetingTranscript: 2,
        .slackAccount: 2,
        .googleAccount: 1,
        .jiraAccount: 1,
    ]

    // MARK: - Helpers

    /// Pool-backed store on a throwaway temp path — the production mechanism
    /// (`DatabasePool` + WAL) that `ReplicaObserver` and every tab run against,
    /// and the exact path the Task-5 reentrancy crash hid in.
    private func makePoolStore() throws -> ReplicaStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobile-replica-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return try ReplicaStore(path: dir.appendingPathComponent("replica.sqlite").path)
    }

    /// Loads the demo seed through the transport and runs one hydrate cycle,
    /// leaving `store` populated exactly as the app's bootstrap would.
    private func seed(into store: ReplicaStore) async throws {
        let transport = InMemoryCloudTransport()
        try await DemoSeed.load(into: transport)
        let hydrator = ReplicaHydrator(transport: transport, store: store)
        _ = try await hydrator.hydrateOnce()
    }

    /// Polls the main run loop until `condition` holds or the timeout elapses.
    /// Observation callbacks are delivered async on the main queue, so tests
    /// must yield to let them land.
    private func poll(
        timeout: TimeInterval = 5,
        _ condition: () -> Bool,
        _ message: @autoclosure () -> String = "condition not met in time",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), message(), file: file, line: line)
    }

    // MARK: - AppEnvironment boot + demo seed

    /// AppEnvironment's init kicks off an async bootstrap: seed → hydrate →
    /// poll loop. After it settles, the replica holds exactly the demo seed.
    ///
    /// Coupling note: this env (and the host app's own AppEnvironment, booted
    /// by TEST_HOST) share ONE on-disk replica path. The exact-count
    /// assertions hold only because DemoSeed uses fixed record ids and
    /// apply() is an idempotent upsert — if the seed ever generates ids or
    /// appends, these tests will flake; fix the seed, not the assertions.
    func testAppEnvironmentBootsAndHydratesDemoSeed() async throws {
        let env = try AppEnvironment()

        // Bootstrap runs in a detached Task; wait for the first cycle to land.
        try await poll { env.lastHydrate != nil }

        for (kind, expected) in seededCounts {
            let rows = try await env.store.reader.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM slice_records WHERE kind = ?",
                    arguments: [kind.rawValue]
                ) ?? 0
            }
            XCTAssertEqual(rows, expected, "unexpected \(kind.rawValue) count after boot")
        }
    }

    /// The sync footer renders `env.isHydrating` / `env.lastHydrate`. After the
    /// bootstrap cycle completes the spinner is off and a result is recorded —
    /// which is exactly what `SyncStatusFooter` reads to show "Synced".
    func testSyncFooterReflectsCompletedHydrate() async throws {
        let env = try AppEnvironment()
        try await poll { env.lastHydrate != nil }

        XCTAssertFalse(env.isHydrating, "footer would still show the spinner")
        let last = try XCTUnwrap(env.lastHydrate, "footer has no completed cycle to show")
        XCTAssertGreaterThanOrEqual(last.applied, 0)
        XCTAssertGreaterThanOrEqual(last.deleted, 0)
    }

    // MARK: - Probe-driven transport swap (Plan 6 Task 2)

    /// The unsigned test host (CODE_SIGNING_ALLOWED=NO — the CI reality) has
    /// no iCloud entitlement, so `AppEnvironment()` must keep today's demo
    /// behavior byte-for-byte: probe false → InMemory transport + DemoSeed,
    /// label "demo". The count assertions above stay the deep pin; this test
    /// pins the SELECTION.
    func testUnsignedHostProbesFalseAndBootsDemo() async throws {
        XCTAssertFalse(
            CloudKitTransport.entitlementPresent(),
            "unsigned sim/CI host must probe false — a true here means the demo path is dead"
        )

        let env = try AppEnvironment()
        XCTAssertEqual(env.transportKind, .inMemoryDemo)
        XCTAssertEqual(env.transportLabel, "demo")

        try await poll { env.lastHydrate != nil }
        let briefings = try await env.store.reader.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM slice_records WHERE kind = ?",
                arguments: [SliceKind.briefing.rawValue]
            ) ?? 0
        }
        XCTAssertEqual(briefings, 1, "demo path must still seed (today's behavior)")
    }

    /// Decision 2: a real-transport install starts EMPTY and hydrates from
    /// the user's own zone — DemoSeed must NEVER run on the `.cloudKit` kind.
    /// Forced via the designated init (an InMemory stand-in transport, so the
    /// test never touches CloudKit) on an ISOLATED replica path — the shared
    /// TEST_HOST path already holds the host app's demo rows.
    func testForcedCloudKitKindSeedsNothingAndLabelsICloud() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobile-cloudkit-kind-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let env = try AppEnvironment(
            transport: InMemoryCloudTransport(),
            replicaPath: dir.appendingPathComponent("replica.sqlite").path,
            transportKind: .cloudKit
        )
        XCTAssertEqual(env.transportKind, .cloudKit)
        XCTAssertEqual(env.transportLabel, "iCloud")

        // Bootstrap still runs a first hydrate cycle — over an empty zone.
        try await poll { env.lastHydrate != nil }
        let rows = try await env.store.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM slice_records") ?? 0
        }
        XCTAssertEqual(rows, 0, "the cloudKit kind must start empty — DemoSeed leaked past its gate")
    }

    /// The Settings "Sync" row renders the kind through this mapping.
    func testSettingsSyncRowRendersTransportKind() {
        XCTAssertEqual(SettingsView.syncValue(for: .cloudKit), "iCloud")
        XCTAssertEqual(SettingsView.syncValue(for: .inMemoryDemo), "Demo")
    }

    // MARK: - Degraded boot (unopenable replica)

    /// A pool-open failure must surface as a THROW — the app catches it and
    /// renders the full-screen `BootFailureView` instead of the tabs — never
    /// a `fatalError`. `/dev/null/sub/…` is a deterministic unopenable path
    /// in the simulator: the parent "directory" is a device file.
    func testInitThrowsWhenReplicaPathIsUnopenable() {
        XCTAssertThrowsError(
            try AppEnvironment(
                transport: InMemoryCloudTransport(),
                replicaPath: "/dev/null/sub/replica.sqlite"
            )
        )
    }

    // MARK: - Per-tab view models

    func testTodayAndInboxViewModelsExposeSeededRows() async throws {
        let store = try makePoolStore()
        try await seed(into: store)

        let today = TodayViewModel()
        today.start(store: store)
        try await poll { today.briefing != nil && !today.events.isEmpty }
        XCTAssertEqual(today.briefing?.role, "Middle Management")
        XCTAssertFalse(today.events.isEmpty, "Today tab should list today's calendar events")

        let inbox = InboxViewModel()
        inbox.start(store: store, outbox: ActionOutbox(transport: InMemoryCloudTransport(), store: store))
        try await poll { inbox.situations.count == self.seededCounts[.situation] }
        // Rank-sorted: the high-rank launch situation leads.
        XCTAssertEqual(inbox.situations.first?.priority, "high")
        // Member signals join in from the inbox slice via signal_ids.
        try await poll { inbox.itemsByID.count == self.seededCounts[.inboxItem] }
        let lead = try XCTUnwrap(inbox.situations.first)
        XCTAssertEqual(inbox.memberSignals(of: lead).map(\.id), [2, 1],
                       "bubbles run oldest-first (the DM predates the mention)")
    }

    func testTasksTracksAndSettingsViewModelsExposeSeededRows() async throws {
        let store = try makePoolStore()
        try await seed(into: store)

        let tasks = TasksViewModel()
        tasks.start(store: store, outbox: ActionOutbox(transport: InMemoryCloudTransport(), store: store))
        try await poll { tasks.targets.count == self.seededCounts[.target] }
        XCTAssertFalse(tasks.groups.isEmpty, "Tasks tab should group targets by status")

        let tracks = TracksViewModel()
        tracks.start(store: store)
        try await poll { tracks.tracks.count == self.seededCounts[.track] }

        let settings = SettingsViewModel()
        settings.start(store: store)
        try await poll { !settings.counts.isEmpty }
        // Settings lists a per-kind tally for every seeded slice kind.
        XCTAssertEqual(settings.counts.count, self.seededCounts.count)
    }

    // MARK: - ReplicaObserver end-to-end guard (MANDATORY)

    /// Durable guard against re-nesting the reentrant `fetchAll(_:kind:)` inside
    /// the ValueObservation closure (the Task-5 Critical). Drives the app's own
    /// `ReplicaObserver.observe` against a REAL `DatabasePool` store and asserts
    /// it (a) does not trap and (b) re-fires on a subsequent write.
    ///
    /// Why this fails on a re-nest: on a `DatabasePool` the tracking closure
    /// already runs on a reader connection; calling the `writer.read`-wrapping
    /// overload there opens a nested `DatabasePool.read`, which GRDB answers
    /// with a `fatalError` (release AND debug). That trap crashes the test
    /// process, so the run aborts with a non-zero exit — the Kit's overload
    /// test cannot catch a revert of THIS file's wiring, but this test does.
    func testReplicaObserverObservesAndRefiresOnPoolStore() async throws {
        let store = try makePoolStore()

        // The observation emits an initial value, then re-fires on each write.
        // We assert it decodes 1 target after the first apply and 2 after the
        // second — the re-fire is the load-bearing half of the guard.
        let sawFirst = expectation(description: "observer decodes the first target")
        let sawSecond = expectation(description: "observer re-fires after the second write")
        sawFirst.assertForOverFulfill = false
        sawSecond.assertForOverFulfill = false

        var latest: [Target] = []
        let cancellable = ReplicaObserver.observe(Target.self, kind: .target, in: store) { targets in
            latest = targets
            if targets.count == 1 { sawFirst.fulfill() }
            if targets.count == 2 { sawSecond.fulfill() }
        }
        defer { cancellable.cancel() }

        try store.apply(batch(id: "1", text: "first", token: 1))
        await fulfillment(of: [sawFirst], timeout: 5)
        XCTAssertEqual(latest.map(\.text), ["first"])

        try store.apply(batch(id: "2", text: "second", token: 2))
        await fulfillment(of: [sawSecond], timeout: 5)
        XCTAssertEqual(Set(latest.map(\.text)), ["first", "second"])
    }

    // MARK: - Fixtures

    private func batch(id: String, text: String, token: Int) throws -> CloudChangeBatch {
        let payload = try RowPayloadCoder.payload(from: Row([
            "id": Int(id) ?? 0,
            "text": text,
            "level": "week",
            "status": "todo",
            "priority": "high",
            "created_at": "2026-07-06T10:00:00Z",
        ]))
        let record = CloudRecord(
            recordName: SliceKind.target.recordName(id: id),
            zone: .data,
            kind: SliceKind.target.rawValue,
            modifiedAt: Date(timeIntervalSince1970: 1_720_000_000 + Double(token)),
            payload: payload
        )
        return CloudChangeBatch(changed: [record], deletedRecordNames: [], newToken: CloudChangeToken(value: token))
    }
}
