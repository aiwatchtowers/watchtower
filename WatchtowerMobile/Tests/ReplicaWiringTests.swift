import GRDB
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// Smoke tests for the app's WIRING, not the replica logic (the Kit's own
/// suites cover that): `AppEnvironment` picks the transport, boots, and
/// hydrates exactly the demo seed.
///
/// Coupling note (spec §10): `AppEnvironment()` here and the TEST_HOST app's
/// own environment share ONE on-disk replica. The exact counts hold only
/// because DemoSeed uses fixed record names and `apply` is an idempotent
/// upsert, and only on a replica a previous build did not leave behind:
/// uninstall the simulator app before `make mobile-test` (the recipe does).
@MainActor
final class ReplicaWiringTests: XCTestCase {
    /// DemoSeed's record tally per kind.
    private let seededCounts: [SliceKind: Int] = [
        .heartbeat: 1,
        .deviceGrant: 1
    ]

    private func count(_ kind: SliceKind, in store: ReplicaStore) async throws -> Int {
        try await store.reader.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM slice_records WHERE kind = ?",
                arguments: [kind.rawValue]
            ) ?? 0
        }
    }

    // MARK: - Boot and demo seed

    func testAppEnvironmentBootsAndHydratesExactlyTheDemoSeed() async throws {
        let env = try AppEnvironment()
        try await poll { env.lastSyncAt != nil }

        for (kind, expected) in seededCounts {
            let rows = try await count(kind, in: env.store)
            XCTAssertEqual(rows, expected, "unexpected \(kind.rawValue) count after boot")
        }
        let total = try await env.store.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM slice_records") ?? 0
        }
        XCTAssertEqual(total, seededCounts.values.reduce(0, +), "a stale replica? uninstall the simulator app first")
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
            try SettingsSnapshot.read(from: db, deviceID: DemoSeed.device.deviceID)
        }
        XCTAssertEqual(MacStatus(heartbeat: snapshot.heartbeat, now: now), .online(macName: DemoSeed.macName))
        let grant = try XCTUnwrap(snapshot.grant)
        XCTAssertTrue(grant.linked)
        XCTAssertEqual(grant.hubID, snapshot.heartbeat?.hubID)
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
        let env = try AppEnvironment()
        XCTAssertEqual(env.transportKind, .inMemoryDemo)
        XCTAssertEqual(env.linkedDevice, DemoSeed.device)
    }

    /// A real-transport install starts EMPTY and unlinked: DemoSeed never
    /// runs on the `.cloudKit` kind. Forced through the designated init with
    /// an in-memory stand-in on an isolated path.
    func testCloudKitKindSeedsNothingAndStartsUnlinked() async throws {
        let env = try AppEnvironment(
            transport: InMemoryCloudTransport(),
            replicaPath: try makeReplicaPath(),
            transportKind: .cloudKit,
            defaults: try makeDefaults()
        )
        XCTAssertNil(env.linkedDevice)

        try await poll { env.lastSyncAt != nil }
        let rows = try await env.store.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM slice_records") ?? 0
        }
        XCTAssertEqual(rows, 0, "the cloudKit kind must start empty")
    }

    /// A replica that cannot open is a throw (the app shows BootFailureView),
    /// never a crash. `/dev/null/sub/…` is unopenable: its parent is a device.
    func testInitThrowsWhenReplicaPathIsUnopenable() throws {
        XCTAssertThrowsError(
            try AppEnvironment(
                transport: InMemoryCloudTransport(),
                replicaPath: "/dev/null/sub/replica.sqlite",
                defaults: try makeDefaults()
            )
        )
    }
}
