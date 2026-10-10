import Foundation
import GRDB
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// `AppRoot` as the link flow's host (spec §2.3, §9): the wipe really
/// empties the replica and the outbox, a moved hub sends nothing, a scope
/// change restarts on an empty replica, and the demo never onboards.
@MainActor
final class AppRootWiringTests: XCTestCase {
    private let device = LinkedDevice(
        deviceID: "device-acme-1",
        name: "Colleague A's iPhone",
        model: "iPhone",
        appVersion: "1.0",
        scope: .private,
        userRecordName: "_owner-acme"
    )

    /// Every environment the root built, and the database each runs.
    private var built: [(env: AppEnvironment, scope: CloudDatabaseScope)] = []
    private var transports: [InMemoryCloudTransport] = []

    /// A live-kind root over in-memory transports (one per environment, as
    /// each CloudKit transport serves one database) on one replica path.
    private func makeRoot(linked: LinkedDevice?) throws -> AppRoot {
        let path = try makeReplicaPath()
        let defaults = try makeDefaults()
        let recordings = try makeRecordingsDirectory()
        let make: @MainActor (CloudDatabaseScope, LinkedDevice?) throws -> AppEnvironment = { [weak self] scope, device in
            let transport = InMemoryCloudTransport()
            let env = try AppEnvironment(
                transport: transport,
                replicaPath: path,
                transportKind: .cloudKit,
                linkedDevice: device,
                defaults: defaults,
                recordingsDirectory: recordings
            )
            self?.addTeardownBlock { @MainActor in env.stop() }
            self?.built.append((env, scope))
            self?.transports.append(transport)
            return env
        }
        let identity = DeviceIdentity(deviceID: device.deviceID, name: device.name, model: device.model, appVersion: device.appVersion)
        return AppRoot(
            env: try make(.private, linked),
            scope: .private,
            linking: LinkingViewModel(container: FakeLinkContainer(log: LinkEventLog()), store: LinkStore(defaults: defaults), identity: identity),
            restarter: AppRoot.Restarter(replicaPath: path, make: make)
        )
    }

    private func sliceCount(_ env: AppEnvironment) async throws -> Int {
        try await env.store.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM slice_records") ?? 0
        }
    }

    func testWipeEmptiesTheReplicaAndOutboxAndCountsWhatWasNotSent() async throws {
        let root = try makeRoot(linked: device)
        let first = root.env
        let now = Date()
        try await transports[0].save([try CloudRecordFactory.record(for: heartbeat(updatedAt: now), modifiedAt: now)])
        try await poll { (try? self.sliceCountSync(first)) == 1 }
        for id in 1...3 {
            try await first.outbox.enqueue(kind: .targetDone, entityRecordName: "workbench_target-\(id)")
        }
        XCTAssertEqual(try first.store.pendingActions().count, 3)

        let notSent = await root.wipeLocalData()

        XCTAssertEqual(notSent, 3, "the three pending items are reported Not sent")
        XCTAssertFalse(root.env === first, "a new environment on the same files")
        XCTAssertFalse(first.isLooping, "the old environment is stopped")
        let rows = try await sliceCount(root.env)
        XCTAssertEqual(rows, 0, "the replica is wiped")
        XCTAssertTrue(try root.env.store.pendingActions().isEmpty, "the outbox is wiped")
        XCTAssertNil(root.env.linkedDevice)
        XCTAssertEqual(built.last?.scope, .private)
        XCTAssertNil(root.failure)
    }

    private func sliceCountSync(_ env: AppEnvironment) throws -> Int {
        try env.store.reader.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM slice_records") ?? 0 }
    }

    /// A moved hub (spec §9): the link stands, but nothing is sent.
    func testWritesNotAllowedKeepTheLinkAndSendNothing() async throws {
        let root = try makeRoot(linked: device)

        await root.setLink(device, writesAllowed: false)

        XCTAssertEqual(root.env.linkedDevice, device, "Settings still shows the Mac")
        XCTAssertEqual(root.env.deviceSettings.linkedDevice, device)
        do {
            try await root.env.outbox.enqueue(kind: .targetDone, entityRecordName: "workbench_target-1")
            XCTFail("a moved hub's phone must not send")
        } catch {
            XCTAssertEqual(error as? ActionOutboxError, .notLinked)
        }
        let actions = try await transports[0].changes(in: .relay, since: nil).changed
            .filter { $0.kind == RelayRecordKind.action.rawValue }
        XCTAssertTrue(actions.isEmpty)

        await root.setLink(device, writesAllowed: true)
        try await root.env.outbox.enqueue(kind: .targetDone, entityRecordName: "workbench_target-1")
    }

    func testPreparingAnotherScopeRestartsOnAnEmptyReplica() async throws {
        let root = try makeRoot(linked: nil)
        let first = root.env
        let now = Date()
        try await transports[0].save([try CloudRecordFactory.record(for: heartbeat(updatedAt: now), modifiedAt: now)])
        try await poll { (try? self.sliceCountSync(first)) == 1 }

        let samePrivate = try await root.prepare(scope: .private)
        XCTAssertTrue(root.env === first, "the running scope needs no restart")
        XCTAssertTrue((samePrivate as? InMemoryCloudTransport) === transports[0])

        let shared = try await root.prepare(scope: .shared(ownerName: "_owner-acme"))

        XCTAssertFalse(root.env === first)
        XCTAssertEqual(built.last?.scope, .shared(ownerName: "_owner-acme"))
        XCTAssertTrue((shared as? InMemoryCloudTransport) === transports.last)
        let rows = try await sliceCount(root.env)
        XCTAssertEqual(rows, 0, "another database's data is not kept")
    }

    func testFetchGrantReadsThisPhonesHydratedGrant() async throws {
        let root = try makeRoot(linked: nil)
        let grant = DeviceGrant(
            deviceID: device.deviceID, hubID: "hub-acme", name: device.name, scope: .private,
            linked: true, typingAllowed: false, startSessionsAllowed: true
        )
        try await transports[0].save([try CloudRecordFactory.record(for: grant, modifiedAt: Date())])

        let fetched = await root.fetchGrant(deviceID: device.deviceID)

        XCTAssertEqual(fetched, grant)
        let other = await root.fetchGrant(deviceID: "device-other")
        XCTAssertNil(other)
    }

    func testALiveRootWithoutALinkOnboardsAndTheDemoNever() throws {
        XCTAssertTrue(try makeRoot(linked: nil).showsOnboarding)

        let demo = AppRoot.demo(
            try AppEnvironment(
                transport: InMemoryCloudTransport(),
                replicaPath: try makeReplicaPath(),
                transportKind: .inMemoryDemo,
                defaults: try makeDefaults(),
                recordingsDirectory: try makeRecordingsDirectory()
            ),
            defaults: try makeDefaults()
        )
        addTeardownBlock { @MainActor in demo.env.stop() }
        XCTAssertFalse(demo.showsOnboarding)
        XCTAssertEqual(demo.env.linkedDevice, DemoSeed.device)
    }

    func testTheDemoIgnoresALinkURL() async throws {
        let demo = AppRoot.demo(
            try AppEnvironment(
                transport: InMemoryCloudTransport(),
                replicaPath: try makeReplicaPath(),
                transportKind: .inMemoryDemo,
                defaults: try makeDefaults(),
                recordingsDirectory: try makeRecordingsDirectory()
            ),
            defaults: try makeDefaults()
        )
        addTeardownBlock { @MainActor in demo.env.stop() }
        let iat = Int64(Date().timeIntervalSince1970)
        let code = LinkPayload(
            hubID: "hub-acme", macName: "Acme Mac", ownerUser: "_owner-acme", nonce: LinkPayload.makeNonce(), iat: iat, exp: iat + 600
        )

        await demo.open(code.url())

        XCTAssertEqual(demo.linking.phase, .idle)
        XCTAssertEqual(demo.env.linkedDevice, DemoSeed.device)
    }

    private func heartbeat(updatedAt: Date) -> HeartbeatPayload {
        HeartbeatPayload(
            updatedAt: updatedAt,
            appVersion: "1.0",
            hubID: "hub-acme",
            macName: "Acme Mac",
            flavor: .default,
            lastPublishAt: updatedAt,
            lastRelayAt: updatedAt,
            relayBacklog: 0,
            accounts: [],
            enabledAt: updatedAt,
            ownerUser: "_owner-acme",
            sharing: .none
        )
    }
}
