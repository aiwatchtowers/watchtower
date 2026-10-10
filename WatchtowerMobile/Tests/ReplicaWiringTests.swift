import GRDB
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// Smoke tests for the app's WIRING, not the replica logic (the Kit's own
/// suites cover that): `AppEnvironment` picks the transport, boots, and
/// hydrates exactly the demo seed.
///
/// Coupling note (spec §10): `AppEnvironment()` here opens the app's own
/// on-disk replica. The TEST_HOST app boots nothing while it hosts the tests
/// (`WatchtowerMobileApp.Boot.hostingTests`), but a replica a previous
/// `make mobile-run` left behind would skew the exact counts: uninstall the
/// simulator app before `make mobile-test` (the recipe does).
@MainActor
final class ReplicaWiringTests: XCTestCase {
    /// DemoSeed's record tally per kind.
    private let seededCounts: [SliceKind: Int] = [
        .heartbeat: 1,
        .deviceGrant: 1,
        .workbench: 3,
        .terminalSession: 10,
        .ownerAsk: 6,
        .workbenchTarget: 13,
        .workbenchComment: 3,
        .sessionReport: 3,
        .sessionTimeline: 5,
        .calendarEvent: 6,
        .meetingTranscript: 1
    ]

    /// A booted demo environment also has the job of the demo phone
    /// recording (`DemoSeed.loadRecordingDemo`), which needs the ledger.
    private var bootCounts: [SliceKind: Int] {
        seededCounts.merging([.recordingJob: 1]) { _, new in new }
    }

    private func count(_ kind: SliceKind, in store: ReplicaStore) async throws -> Int {
        try await store.reader.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM slice_records WHERE kind = ?",
                arguments: [kind.rawValue]
            ) ?? 0
        }
    }

    /// Stops the environment's loop on teardown, so no test leaves a fetch
    /// loop running into the next one.
    private func managed(_ env: AppEnvironment) -> AppEnvironment {
        addTeardownBlock { @MainActor in env.stop() }
        return env
    }

    /// An isolated demo environment on `path`; `sleeper` steps its fetch
    /// loop by hand (nil: real sleeps).
    private func demoEnvironment(at path: String, sleeper: TickSleeper? = nil) throws -> AppEnvironment {
        managed(try AppEnvironment(
            transport: InMemoryCloudTransport(),
            replicaPath: path,
            transportKind: .inMemoryDemo,
            defaults: try makeDefaults(),
            recordingsDirectory: try makeRecordingsDirectory()
        ) { interval in
            if let sleeper {
                try await sleeper.sleep(interval)
            } else {
                try await Task.sleep(for: interval)
            }
        })
    }

    // MARK: - Boot and demo seed

    func testAppEnvironmentBootsAndHydratesExactlyTheDemoSeed() async throws {
        let env = try managed(AppEnvironment(recordingsDirectory: try makeRecordingsDirectory()))
        try await poll { env.lastSyncAt != nil }

        for (kind, expected) in bootCounts {
            let rows = try await count(kind, in: env.store)
            XCTAssertEqual(rows, expected, "unexpected \(kind.rawValue) count after boot")
        }
        let total = try await env.store.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM slice_records") ?? 0
        }
        XCTAssertEqual(total, bootCounts.values.reduce(0, +), "a stale replica? uninstall the simulator app first")
    }

    /// The seed in isolation, on a fresh store: same tally, no shared path.
    func testDemoSeedHydratesTheTallyOnAFreshStore() async throws {
        let store = try makePoolStore()
        let transport = InMemoryCloudTransport()
        try await DemoSeed.load(into: transport, now: Date())
        _ = try await ReplicaHydrator(transport: transport, store: store).hydrateOnce()

        for (kind, expected) in seededCounts {
            let rows = try await count(kind, in: store)
            XCTAssertEqual(rows, expected, "unexpected \(kind.rawValue) count")
        }
    }

    /// The demo heartbeat is fresh and the demo grant belongs to the demo
    /// device, so Settings demos an online Mac and a linked phone.
    func testDemoSeedIsOnlineAndGrantsTheDemoDevice() async throws {
        let store = try makePoolStore()
        let transport = InMemoryCloudTransport()
        let now = Date()
        try await DemoSeed.load(into: transport, now: now)
        _ = try await ReplicaHydrator(transport: transport, store: store).hydrateOnce()

        let snapshot = try await store.reader.read { db in
            try SettingsSnapshot.read(from: db, store: store, deviceID: DemoSeed.device.deviceID)
        }
        XCTAssertEqual(MacStatus(heartbeat: snapshot.heartbeat, now: now), .online(macName: DemoSeed.macName))
        let grant = try XCTUnwrap(snapshot.grant)
        XCTAssertTrue(grant.linked)
        XCTAssertEqual(grant.hubID, snapshot.heartbeat?.hubID)
    }

    /// A relaunch builds a new in-memory transport whose cursor restarts;
    /// the persisted replica must still pick up the fresh seed. The replica
    /// starts with an old heartbeat behind a stored token, as a first
    /// launch two hours ago would have left it.
    func testRelaunchedDemoShowsAFreshHeartbeatAndTheSeedTally() async throws {
        let path = try makeReplicaPath()
        do {
            let stale = InMemoryCloudTransport()
            try await DemoSeed.load(into: stale, now: Date().addingTimeInterval(-7_200))
            _ = try await ReplicaHydrator(transport: stale, store: try ReplicaStore(path: path)).hydrateOnce()
        }

        for launch in 1...2 {
            let env = try demoEnvironment(at: path)
            try await poll { env.lastSyncAt != nil }
            env.stop()

            let store = env.store
            let snapshot = try await store.reader.read { db in
                try SettingsSnapshot.read(from: db, store: store, deviceID: DemoSeed.device.deviceID)
            }
            XCTAssertEqual(
                MacStatus(heartbeat: snapshot.heartbeat, now: Date()),
                .online(macName: DemoSeed.macName),
                "launch \(launch) must show the fresh heartbeat"
            )
            for (kind, expected) in bootCounts {
                let rows = try await count(kind, in: store)
                XCTAssertEqual(rows, expected, "launch \(launch): unexpected \(kind.rawValue) count")
            }
        }
    }

    // MARK: - Fetch loop

    /// "Last sync" follows every successful loop fetch, not only the first.
    func testALoopTickAdvancesLastSync() async throws {
        let env = try demoEnvironment(at: try makeReplicaPath())
        try await poll { env.isLooping }
        let first = try XCTUnwrap(env.lastSyncAt)

        env.setFetchInterval(.milliseconds(50))
        try await poll({ (env.lastSyncAt ?? first) > first }, "a loop fetch did not advance lastSyncAt")
    }

    /// The tab sets the cadence the loop sleeps, and the loop pauses in the
    /// background and resumes in the foreground. The sleeper is stepped by
    /// hand: no wall-clock wait decides anything.
    func testTheLoopFollowsTheTabCadenceAndPausesInTheBackground() async throws {
        let sleeper = TickSleeper()
        let env = try demoEnvironment(at: try makeReplicaPath(), sleeper: sleeper)
        try await poll { env.isLooping && sleeper.waitingCount == 1 }
        XCTAssertEqual(sleeper.requested.last, .seconds(30))

        env.setFetchInterval(RootTabView.Tab.now.fetchInterval)
        XCTAssertEqual(env.fetchInterval, .seconds(5))
        try await poll({ sleeper.requested.last == .seconds(5) && sleeper.waitingCount == 1 }, "the loop sleeps 5 s on Now")
        env.setFetchInterval(RootTabView.Tab.more.fetchInterval)
        XCTAssertEqual(env.fetchInterval, .seconds(30))
        try await poll({ sleeper.requested.last == .seconds(30) && sleeper.waitingCount == 1 }, "the loop sleeps 30 s on More")

        let running = env.fetchCycles
        sleeper.tick()
        try await poll({ env.fetchCycles == running + 1 && sleeper.waitingCount == 1 }, "a tick runs one more cycle")

        env.setActive(false)
        XCTAssertFalse(env.isLooping)
        try await poll({ sleeper.waitingCount == 0 }, "the paused loop's sleep is cancelled")
        let paused = env.fetchCycles
        sleeper.tick()
        await Task.yield()
        XCTAssertEqual(env.fetchCycles, paused, "no cycle may begin while the app is in the background")

        env.setActive(true)
        XCTAssertTrue(env.isLooping)
        try await poll({ env.fetchCycles == paused + 1 }, "the loop did not resume in the foreground")
    }

    /// A-T11 N5: the scene phase is read at launch too (`initial: true`),
    /// so a launch straight into the background (a silent push) pauses the
    /// environment before its boot ends: the boot never starts the loop,
    /// and the first activation does.
    func testABackgroundLaunchStartsNoLoopUntilTheAppIsActive() async throws {
        XCTAssertEqual(RootTabView.isActive(in: .background), false)
        XCTAssertEqual(RootTabView.isActive(in: .active), true)
        XCTAssertNil(RootTabView.isActive(in: .inactive), "inactive (a sheet, the app switcher) changes nothing")

        let env = try demoEnvironment(at: try makeReplicaPath())
        env.setActive(false)
        try await poll({ env.isBootstrapped }, "the boot did not finish")
        XCTAssertFalse(env.isLooping, "a background launch must not start the fetch loop")
        env.setActive(true)
        XCTAssertTrue(env.isLooping)
    }

    // MARK: - Transport choice

    /// The unsigned test host (CODE_SIGNING_ALLOWED=NO) has no iCloud
    /// entitlement, so `AppEnvironment()` runs the demo transport and is
    /// linked to the demo device.
    func testUnsignedHostProbesFalseAndBootsDemo() async throws {
        XCTAssertFalse(
            CloudKitTransport.entitlementPresent(),
            "an unsigned simulator host must probe false, or the demo path is dead"
        )
        let env = try managed(AppEnvironment(recordingsDirectory: try makeRecordingsDirectory()))
        XCTAssertEqual(env.transportKind, .inMemoryDemo)
        XCTAssertEqual(env.linkedDevice, DemoSeed.device)
    }

    /// A real-transport install starts EMPTY and unlinked: DemoSeed never
    /// runs on the `.cloudKit` kind. Forced through the designated init with
    /// an in-memory stand-in on an isolated path.
    func testCloudKitKindSeedsNothingAndStartsUnlinked() async throws {
        let env = try managed(AppEnvironment(
            transport: InMemoryCloudTransport(),
            replicaPath: try makeReplicaPath(),
            transportKind: .cloudKit,
            defaults: try makeDefaults(),
            recordingsDirectory: try makeRecordingsDirectory()
        ))
        XCTAssertNil(env.linkedDevice)

        try await poll { env.lastSyncAt != nil }
        let rows = try await env.store.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM slice_records") ?? 0
        }
        XCTAssertEqual(rows, 0, "the cloudKit kind must start empty")
    }

    // MARK: - Test host

    /// The app hosting XCTest starts nothing of its own: no replica, demo
    /// seed, recorder recovery, fetch loop or push registration beside the
    /// tests' environments. A normal launch still boots.
    func testTheTestHostBootsNoLiveEnvironment() throws {
        XCTAssertTrue(
            WatchtowerMobileApp.Boot.isHostingTests(ProcessInfo.processInfo.environment),
            "this process hosts XCTest"
        )
        XCTAssertNil(AppDelegate.environment, "the test host booted a live AppEnvironment")
        XCTAssertFalse(WatchtowerMobileApp.Boot.isHostingTests([:]), "a process without the XCTest key is not a test host")
        var built = 0
        guard case .hostingTests = WatchtowerMobileApp.Boot.make(
            processEnvironment: ["XCTestConfigurationFilePath": "/tmp/acme.xctestconfiguration"],
            makeEnvironment: { built += 1; return try self.demoEnvironment(at: try self.makeReplicaPath()) }
        ) else {
            return XCTFail("a test host must not build an environment")
        }
        XCTAssertEqual(built, 0, "a test host must not build an environment")

        // A normal launch (no XCTest key) builds and registers one.
        let path = try makeReplicaPath()
        guard case let .ready(env) = WatchtowerMobileApp.Boot.make(
            processEnvironment: [:],
            makeEnvironment: { try self.demoEnvironment(at: path) }
        ) else {
            return XCTFail("a normal launch must boot")
        }
        XCTAssertTrue(AppDelegate.environment === env, "the push path reaches the booted environment")
        AppDelegate.environment = nil
    }

    /// A replica that cannot open is a throw (the app shows BootFailureView),
    /// never a crash. `/dev/null/sub/…` is unopenable: its parent is a device.
    func testInitThrowsWhenReplicaPathIsUnopenable() throws {
        XCTAssertThrowsError(
            try AppEnvironment(
                transport: InMemoryCloudTransport(),
                replicaPath: "/dev/null/sub/replica.sqlite",
                defaults: try makeDefaults(),
                recordingsDirectory: try makeRecordingsDirectory()
            )
        )
    }
}
