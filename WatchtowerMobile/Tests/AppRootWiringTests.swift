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

    /// Every environment the root built, and the database and hub each runs.
    private var built: [(env: AppEnvironment, scope: CloudDatabaseScope, hubID: String)] = []
    private var transports: [InMemoryCloudTransport] = []
    private var replicaPath = ""

    /// A live-kind root on one replica path. Without `transportStorePath`
    /// each environment gets a fresh in-memory transport; with it, a
    /// `CloudKitTransport` over the persistent store at that path (the app's
    /// shape: one transport file across restarts; no engine starts in the
    /// unsigned test host). `link` is the saved link the flow starts with.
    private func makeRoot(
        linked: LinkedDevice?, transportStorePath: String? = nil, link: LinkRecord? = nil, clock: any LinkClock = SystemLinkClock()
    ) throws -> AppRoot {
        let path = try makeReplicaPath()
        replicaPath = path
        let defaults = try makeDefaults()
        LinkStore(defaults: defaults).link = link
        let recordings = try makeRecordingsDirectory()
        let make: @MainActor (CloudDatabaseScope, String, LinkedDevice?) throws -> AppEnvironment = { [weak self] scope, hubID, device in
            let transport: any CloudSyncTransport
            if let transportStorePath {
                transport = CloudKitTransport(
                    store: try TransportStore(path: transportStorePath), scope: scope, hubID: hubID, role: .phone
                )
            } else {
                let memory = InMemoryCloudTransport()
                self?.transports.append(memory)
                transport = memory
            }
            let env = try AppEnvironment(
                transport: transport,
                replicaPath: path,
                transportKind: .cloudKit,
                linkedDevice: device,
                defaults: defaults,
                recordingsDirectory: recordings
            )
            self?.addTeardownBlock { @MainActor in env.stop() }
            self?.built.append((env, scope, hubID))
            return env
        }
        let identity = DeviceIdentity(deviceID: device.deviceID, name: device.name, model: device.model, appVersion: device.appVersion)
        return AppRoot(
            env: try make(.private, AppEnvironment.unlinkedHubID, linked),
            scope: .private,
            hubID: AppEnvironment.unlinkedHubID,
            linking: LinkingViewModel(
                container: FakeLinkContainer(log: LinkEventLog()), store: LinkStore(defaults: defaults), identity: identity, clock: clock
            ),
            restarter: AppRoot.Restarter(replicaPath: path, transportStorePath: transportStorePath, make: make)
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

        let notSent = await root.wipeLocalData(restartingOn: .private, hubID: AppEnvironment.unlinkedHubID)

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

    /// Finding 1 of the task review: a private → private wipe must also
    /// empty the persistent transport store (buffered events, the send queue,
    /// the engine state), or the new replica never re-hydrates the compacted
    /// prefix and the unlinked phone's queue still goes out.
    func testWipeAlsoEmptiesThePersistentTransportStore() async throws {
        let transportPath = (try makeReplicaPath() as NSString).deletingLastPathComponent + "/cloudkit-transport.sqlite"
        let root = try makeRoot(linked: device, transportStorePath: transportPath)
        let first = root.env
        try await poll { first.isBootstrapped }
        for id in 1...3 {
            try await first.outbox.enqueue(kind: .targetDone, entityRecordName: "workbench_target-\(id)")
        }
        // The Kit's own tables, read and seeded directly: the engine and the
        // fetch buffer have no public writer outside CloudKit.
        let raw = try DatabaseQueue(path: transportPath)
        try await raw.write { db in
            try db.execute(sql: "INSERT INTO engine_state (id, data) VALUES (1, x'00')")
            try db.execute(sql: """
                INSERT INTO events (zone, record_name, kind, modified_at, payload)
                VALUES ('DataZone', 'heartbeat', 'heartbeat', 0, x'7b7d')
                """)
        }
        let before = try await transportCounts(raw)
        XCTAssertEqual(before.pending, 3, "the outbox's sends wait in the transport queue")

        let notSent = await root.wipeLocalData(restartingOn: .private, hubID: AppEnvironment.unlinkedHubID)

        XCTAssertEqual(notSent, 3)
        let after = try await transportCounts(raw)
        XCTAssertEqual(after.pending, 0, "the unlinked phone's queue is not sent")
        XCTAssertEqual(after.events, 0, "the next replica re-reads the zone from scratch")
        XCTAssertEqual(after.engineState, 0, "the engine fetches everything again")
        XCTAssertEqual(built.last?.scope, .private)
        XCTAssertNil(root.failure)
    }

    private func transportCounts(_ raw: DatabaseQueue) async throws -> (pending: Int, events: Int, engineState: Int) {
        try await raw.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM events") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM engine_state") ?? 0
            )
        }
    }

    /// Finding 2 of the task review: two teardowns at once run one after
    /// the other. Each environment but the last is shut down, and the last
    /// one's replica is not deleted under it.
    func testConcurrentWipesRestartOneAfterTheOther() async throws {
        let root = try makeRoot(linked: device)

        async let first = root.wipeLocalData(restartingOn: .private, hubID: AppEnvironment.unlinkedHubID)
        async let second = root.wipeLocalData(restartingOn: .private, hubID: AppEnvironment.unlinkedHubID)
        _ = await (first, second)

        XCTAssertEqual(built.count, 3, "the initial environment and one per wipe")
        let last = try XCTUnwrap(built.last?.env)
        XCTAssertTrue(root.env === last)
        try await poll { self.built.allSatisfy { $0.env.isBootstrapped } }
        try await poll { last.isLooping }
        for (index, entry) in built.dropLast().enumerated() {
            XCTAssertFalse(entry.env.isLooping, "environment \(index) was replaced without a shutdown")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: replicaPath), "the live replica's file is in place")
        let now = Date()
        try await transports[2].save([try CloudRecordFactory.record(for: heartbeat(updatedAt: now), modifiedAt: now)])
        let fetched = await last.refresh()
        XCTAssertTrue(fetched)
        XCTAssertEqual(try sliceCountSync(last), 1, "the live replica takes writes")
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

        let samePrivate = try await root.prepare(scope: .private, hubID: AppEnvironment.unlinkedHubID)
        XCTAssertTrue(root.env === first, "the running scope needs no restart")
        XCTAssertTrue((samePrivate as? InMemoryCloudTransport) === transports[0])

        let shared = try await root.prepare(scope: .shared(ownerName: "_owner-acme"), hubID: AppEnvironment.unlinkedHubID)

        XCTAssertFalse(root.env === first)
        XCTAssertEqual(built.last?.scope, .shared(ownerName: "_owner-acme"))
        XCTAssertTrue((shared as? InMemoryCloudTransport) === transports.last)
        let rows = try await sliceCount(root.env)
        XCTAssertEqual(rows, 0, "another database's data is not kept")
    }

    func testPreparingAnotherHubOnTheSameScopeRestartsOnAnEmptyReplica() async throws {
        let root = try makeRoot(linked: nil)
        let first = root.env
        let now = Date()
        try await transports[0].save([try CloudRecordFactory.record(for: heartbeat(updatedAt: now), modifiedAt: now)])
        try await poll { (try? self.sliceCountSync(first)) == 1 }

        _ = try await root.prepare(scope: .private, hubID: "hub-acme")

        XCTAssertFalse(root.env === first, "another hub is another pair of zones")
        XCTAssertEqual(built.last?.hubID, "hub-acme")
        let rows = try await sliceCount(root.env)
        XCTAssertEqual(rows, 0, "another hub's data is not kept")
        _ = try await root.prepare(scope: .private, hubID: "hub-acme")
        XCTAssertEqual(built.count, 2, "the running hub needs no restart")
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

    /// #64: a same-Apple-ID phone gets no `unlinked` event. After each
    /// fetch the root judges the grant of the device id the link was made
    /// with: one this build cannot decode is never judged, and a grant gone
    /// on two fetches 30 s apart is the Mac's Remove.
    func testTheLinkedDevicesGrantGoneOnTwoFetchesIsTheMacsRemoveAndAnUndecodableOneIsNot() async throws {
        let linkedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = FakeLinkClock(now: linkedAt)
        var link = LinkRecord(
            hubID: "hub-acme", macName: "Acme Mac", scope: .private, ownerName: "_owner-acme",
            userRecordName: "_owner-acme", nonce: LinkPayload.makeNonce(), dataShareURL: nil, relayShareURL: nil
        )
        link.deviceID = "device-linked"
        link.linkedAt = linkedAt
        let root = try makeRoot(linked: device, link: link, clock: clock)
        let transport = transports[0]
        let later = linkedAt.addingTimeInterval(60)
        let grant = DeviceGrant(
            deviceID: "device-linked", hubID: "hub-acme", name: device.name, scope: .private,
            linked: true, linkedAt: linkedAt, typingAllowed: false, startSessionsAllowed: true
        )
        try await transport.save([
            try CloudRecordFactory.record(for: heartbeat(updatedAt: later), modifiedAt: later),
            try CloudRecordFactory.record(for: grant, modifiedAt: later)
        ])
        // Each fetch's link check, awaited.
        let fetch = {
            await root.env.refresh()
            await root.linkCheck?.value
        }
        await fetch()
        XCTAssertNotNil(root.linking.link, "granted under the id it linked with (not the Keychain's \(self.device.deviceID))")

        let reshaped = CloudRecord(
            recordName: grant.recordName, zone: .data, kind: SliceKind.deviceGrant.rawValue,
            modifiedAt: later.addingTimeInterval(1), payload: Data(#"{"linked":"maybe"}"#.utf8)
        )
        try await transport.save([reshaped])
        await fetch()
        clock.advance(by: LinkingViewModel.removalConfirmAfter)
        await fetch()
        XCTAssertNotNil(root.linking.link, "an unreadable grant is not a removed one")

        try await transport.delete(recordNames: [grant.recordName], in: .data)
        await fetch()
        XCTAssertNotNil(root.linking.link, "one look is not enough")
        clock.advance(by: LinkingViewModel.removalConfirmAfter)
        await fetch()
        XCTAssertNil(root.linking.link, "the Mac's Remove ends the link")
        XCTAssertEqual(root.linking.notice, .removed())
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
