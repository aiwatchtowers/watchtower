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
        .target: 3,
        .track: 2,
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
    func testAppEnvironmentBootsAndHydratesDemoSeed() async throws {
        let env = AppEnvironment()

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
        let env = AppEnvironment()
        try await poll { env.lastHydrate != nil }

        XCTAssertFalse(env.isHydrating, "footer would still show the spinner")
        let last = try XCTUnwrap(env.lastHydrate, "footer has no completed cycle to show")
        XCTAssertGreaterThanOrEqual(last.applied, 0)
        XCTAssertGreaterThanOrEqual(last.deleted, 0)
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
        inbox.start(store: store)
        try await poll { inbox.items.count == self.seededCounts[.inboxItem] }
        // Priority-sorted: the high-priority mention leads the medium DM.
        XCTAssertEqual(inbox.items.first?.priority, "high")
    }

    func testTasksTracksAndSettingsViewModelsExposeSeededRows() async throws {
        let store = try makePoolStore()
        try await seed(into: store)

        let tasks = TasksViewModel()
        tasks.start(store: store)
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
