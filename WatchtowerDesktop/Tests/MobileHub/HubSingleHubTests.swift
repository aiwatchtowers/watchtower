import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerSync
import WatchtowerTestSupport

/// The heartbeat and the single-hub rule (mobile POC spec §4.1, §8 I-1):
/// a live foreign heartbeat refuses enable, Take over writes this hub's
/// heartbeat, and a hub that reads another hub's heartbeat stops.
@MainActor
final class HubSingleHubTests: XCTestCase {
    private var dbPath: String!
    private var dbPool: DatabasePool!
    private var tempDir: URL!
    private var hubs: [MobileHubService] = []
    /// One fixed instant per test (whole seconds: the wire carries Unix seconds).
    private let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))

    override func setUp() async throws {
        (dbPool, dbPath) = try TestDatabase.createPool()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("HubSingleHubTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for hub in hubs {
            hub.stop()
            await hub.waitUntilStopped()
        }
        hubs = []
        dbPool = nil
        TestDatabase.cleanup(path: dbPath)
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeHub(
        transport: StubHubTransport,
        sidecar: HubSyncState,
        host: HubHostInfo = testHostInfo(),
        now: Date? = nil,
        cloudTimeout: Duration = .seconds(3600)
    ) throws -> MobileHubService {
        let instant = now ?? self.now
        let publisher = SlicePublisher(
            dbPool: dbPool, state: sidecar, transport: transport, sources: [],
            timing: .init(tick: .seconds(3600), fastWindow: .seconds(3600), fastSpacing: .seconds(3600))
        )
        let processor = RelayProcessor(
            transport: transport, sidecar: sidecar, dispatcher: MobileHubCommandDispatcher(),
            hubID: try sidecar.ensureHubID()
        ) { instant }
        let hub = MobileHubService(
            transport: transport, publisher: publisher, processor: processor, sidecar: sidecar,
            hostInfo: host,
            relayIdleInterval: .seconds(3600), relayActiveInterval: .seconds(3600),
            availabilityReprobeInterval: .seconds(3600),
            heartbeatInterval: .seconds(3600), cloudTimeout: cloudTimeout,
            now: { instant }, isEnabled: { true }
        )
        hubs.append(hub)
        return hub
    }

    private func foreignHeartbeat(age: TimeInterval, hubID: String = "hub-other", macName: String = "Mac B") -> HeartbeatPayload {
        HeartbeatPayload(
            updatedAt: now.addingTimeInterval(-age), appVersion: "0.0.0-test", hubID: hubID, macName: macName,
            flavor: .default, lastPublishAt: nil, lastRelayAt: nil, relayBacklog: 0, accounts: [],
            enabledAt: now.addingTimeInterval(-86_400), ownerUser: "_owner-acme", sharing: .none
        )
    }

    private func seed(_ heartbeat: HeartbeatPayload, into cloud: InMemoryCloudTransport) async throws {
        try await cloud.save([try CloudRecordFactory.record(for: heartbeat, modifiedAt: heartbeat.updatedAt)])
    }

    /// Every heartbeat this transport saved, decoded, in order.
    private func savedHeartbeats(_ transport: StubHubTransport) throws -> [HeartbeatPayload] {
        try transport.saved
            .filter { $0.record.recordName == HeartbeatPayload.recordName }
            .map { try RelayCoder.makeDecoder().decode(HeartbeatPayload.self, from: $0.record.payload) }
    }

    // MARK: - Enable

    func testPinnedHeartbeatTiming() {
        XCTAssertEqual(MobileHubService.heartbeatInterval, .seconds(300))
        XCTAssertEqual(HubIdentity.liveWindow, 720)
    }

    func testForeignHeartbeat719SecondsOldRefusesEnable() async throws {
        let cloud = InMemoryCloudTransport()
        try await seed(foreignHeartbeat(age: 719, macName: "Mac B"), into: cloud)
        let transport = StubHubTransport(cloud: cloud)
        let hub = try makeHub(transport: transport, sidecar: try HubSyncState.inMemory())

        let result = await hub.enable()

        XCTAssertEqual(result, .otherHub("Mac B"))
        XCTAssertEqual(hub.status, .otherHub("Mac B"))
        XCTAssertFalse(hub.isPublishing)
        XCTAssertTrue(try savedHeartbeats(transport).isEmpty, "a refused hub writes no heartbeat")
        await hub.waitUntilStopped()
        XCTAssertEqual(transport.lifecycle, ["start", "stop"], "a refused hub stops its transport")
    }

    func testForeignHeartbeatExactly720SecondsOldAllowsEnable() async throws {
        let cloud = InMemoryCloudTransport()
        try await seed(foreignHeartbeat(age: 720), into: cloud)
        let transport = StubHubTransport(cloud: cloud)
        let sidecar = try HubSyncState.inMemory()
        let hub = try makeHub(transport: transport, sidecar: sidecar)

        let result = await hub.enable()

        XCTAssertEqual(result, .running)
        XCTAssertTrue(hub.isPublishing)
        XCTAssertEqual(try savedHeartbeats(transport).map(\.hubID), [try sidecar.ensureHubID()])
    }

    func testNoHeartbeatAllowsEnable() async throws {
        let transport = StubHubTransport()
        let sidecar = try HubSyncState.inMemory()
        let hub = try makeHub(transport: transport, sidecar: sidecar)

        let result = await hub.enable()

        XCTAssertEqual(result, .running)
        XCTAssertEqual(try savedHeartbeats(transport).map(\.hubID), [try sidecar.ensureHubID()])
    }

    func testOwnFreshHeartbeatAllowsEnable() async throws {
        let cloud = InMemoryCloudTransport()
        let sidecar = try HubSyncState.inMemory()
        try await seed(foreignHeartbeat(age: 10, hubID: try sidecar.ensureHubID()), into: cloud)
        let hub = try makeHub(transport: StubHubTransport(cloud: cloud), sidecar: sidecar)

        let result = await hub.enable()

        XCTAssertEqual(result, .running, "this hub's own heartbeat from an earlier run is not another hub")
    }

    func testAHungPullAfterAnEarlierReadDoesNotClaim() async throws {
        let cloud = InMemoryCloudTransport()
        let sidecar = try HubSyncState.inMemory()
        _ = try await HubIdentity(sidecar: sidecar).readHeartbeat(from: cloud)  // an earlier run read the zone
        let transport = StubHubTransport(cloud: cloud)
        transport.setPullHangs(true)
        let hub = try makeHub(transport: transport, sidecar: sidecar, cloudTimeout: .milliseconds(50))

        let result = await hub.enable()

        XCTAssertEqual(result, .unavailable("Couldn't check which Mac is the hub: iCloud didn't answer in time"))
        XCTAssertTrue(try savedHeartbeats(transport).isEmpty, "a stale buffer is no proof that no hub is live")
    }

    func testAFailingPullWithAStaleCursorDoesNotClaimButATakeOverDoes() async throws {
        let cloud = InMemoryCloudTransport()
        let sidecar = try HubSyncState.inMemory()
        // An earlier run read the zone: the cursor exists, and the newest
        // heartbeat it holds is this hub's own, long stale. A live foreign
        // heartbeat written since stays unread while the pull fails.
        try await seed(foreignHeartbeat(age: 3600, hubID: try sidecar.ensureHubID(), macName: "Mac acme"), into: cloud)
        _ = try await HubIdentity(sidecar: sidecar).readHeartbeat(from: cloud)
        let transport = StubHubTransport(cloud: cloud)
        transport.setPullFails(true)
        let hub = try makeHub(transport: transport, sidecar: sidecar)

        let result = await hub.enable()

        XCTAssertEqual(result, .unavailable("Couldn't check which Mac is the hub: iCloud fetch failed"))
        XCTAssertFalse(hub.isPublishing)
        XCTAssertTrue(try savedHeartbeats(transport).isEmpty, "no heartbeat on a stale copy")

        let takeOver = await hub.takeOver()
        XCTAssertEqual(takeOver, .running, "the owner's explicit take over does not need the pull")
    }

    func testAHungPullBeforeAnyHeartbeatReadDoesNotClaim() async throws {
        let transport = StubHubTransport()
        transport.setPullHangs(true)
        let hub = try makeHub(
            transport: transport, sidecar: try HubSyncState.inMemory(), cloudTimeout: .milliseconds(50)
        )

        let result = await hub.enable()

        XCTAssertEqual(result, .unavailable("Couldn't check which Mac is the hub: iCloud didn't answer in time"))
        XCTAssertFalse(hub.isPublishing)
        XCTAssertTrue(try savedHeartbeats(transport).isEmpty, "an empty buffer is no proof that no hub is live")
    }

    func testAFailingPullBeforeAnyHeartbeatReadDoesNotClaim() async throws {
        let transport = StubHubTransport()
        transport.setPullFails(true)
        let hub = try makeHub(transport: transport, sidecar: try HubSyncState.inMemory())

        let result = await hub.enable()

        XCTAssertEqual(result, .unavailable("Couldn't check which Mac is the hub: iCloud fetch failed"))
        XCTAssertFalse(hub.isPublishing)
        XCTAssertTrue(try savedHeartbeats(transport).isEmpty)

        transport.setPullFails(false)
        let retried = await hub.enable()
        XCTAssertEqual(retried, .running, "the next start with a good pull claims")
    }

    func testAnAccountResetForgetsTheHeartbeatReadState() async throws {
        let cloud = InMemoryCloudTransport()
        try await seed(foreignHeartbeat(age: 10), into: cloud)
        let sidecar = try HubSyncState.inMemory()
        let identity = HubIdentity(sidecar: sidecar)
        _ = try await identity.readHeartbeat(from: cloud)
        let enabledAt = try identity.ensureEnabledAt(now)

        try sidecar.wipeSyncState(now: Date())

        for key in HubIdentity.heartbeatReadKeys {
            XCTAssertNil(try sidecar.metaValue(forKey: key), key)
        }
        XCTAssertEqual(try identity.ensureEnabledAt(now.addingTimeInterval(60)), enabledAt, "enabled_at survives")
        let reread = try await identity.readHeartbeat(from: cloud)
        XCTAssertEqual(reread?.hubID, "hub-other", "re-read from the start")
    }

    // MARK: - Take over

    func testTakeOverStopsTheOtherHubAfterItsNextRead() async throws {
        let cloud = InMemoryCloudTransport()
        let transportA = StubHubTransport(cloud: cloud)
        let transportB = StubHubTransport(cloud: cloud)
        let hubA = try makeHub(
            transport: transportA, sidecar: try HubSyncState.inMemory(), host: testHostInfo(macName: "Mac A")
        )
        let sidecarB = try HubSyncState.inMemory()
        // B's clock runs a second later, so its take over is the later write.
        let hubB = try makeHub(
            transport: transportB, sidecar: sidecarB, host: testHostInfo(macName: "Mac B"), now: now.addingTimeInterval(1)
        )

        let resultA = await hubA.enable()
        XCTAssertEqual(resultA, .running)
        let refused = await hubB.enable()
        XCTAssertEqual(refused, .otherHub("Mac A"))

        let takeOver = await hubB.takeOver()

        XCTAssertEqual(takeOver, .running)
        XCTAssertTrue(hubB.isPublishing)
        XCTAssertEqual(try savedHeartbeats(transportB).last?.hubID, try sidecarB.ensureHubID())
        XCTAssertEqual(hubA.status, .running, "the other hub stops only once it reads the new heartbeat")

        await hubA.heartbeatTick()

        XCTAssertEqual(hubA.status, .tookOver("Mac B"))
        XCTAssertFalse(hubA.isPublishing)
        XCTAssertEqual(try savedHeartbeats(transportA).count, 1, "a hub that was taken over writes no heartbeat")

        await hubB.heartbeatTick()
        XCTAssertEqual(hubB.status, .running, "the new hub reads its own heartbeat and keeps running")
        XCTAssertEqual(try savedHeartbeats(transportB).count, 2)
    }

    func testATakenOverHubRestartsAtOnceOnATransportThatNeverEchoesItsOwnSaves() async throws {
        let cloud = InMemoryCloudTransport()
        let hubA = try makeHub(
            transport: StubHubTransport(cloud: cloud), sidecar: try HubSyncState.inMemory(),
            host: testHostInfo(macName: "Mac A")
        )
        let transportB = StubHubTransport(cloud: cloud, echoesOwnSaves: false)
        let hubB = try makeHub(
            transport: transportB, sidecar: try HubSyncState.inMemory(), host: testHostInfo(macName: "Mac B"),
            now: now.addingTimeInterval(1)
        )
        await hubA.enable()
        hubA.stop()
        let refused = await hubB.enable()
        XCTAssertEqual(refused, .otherHub("Mac A"))
        let takeOver = await hubB.takeOver()
        XCTAssertEqual(takeOver, .running)

        hubB.stop()
        await hubB.waitUntilStopped()
        let restarted = await hubB.enable()

        XCTAssertEqual(restarted, .running, "this hub's own heartbeat is the newest it knows, though never fetched back")
        await hubB.heartbeatTick()
        XCTAssertEqual(hubB.status, .running)
    }

    func testAForeignHeartbeatOlderThanThisHubsOwnArrivingLateKeepsItRunning() async throws {
        let cloud = InMemoryCloudTransport()
        let hub = try makeHub(transport: StubHubTransport(cloud: cloud, echoesOwnSaves: false), sidecar: try HubSyncState.inMemory())
        let result = await hub.enable()
        XCTAssertEqual(result, .running)

        // The old hub's last write, made before this hub claimed, reaches the buffer late.
        try await seed(foreignHeartbeat(age: 10, macName: "Mac B"), into: cloud)
        await hub.heartbeatTick()
        XCTAssertEqual(hub.status, .running, "an earlier write never beats this hub's later one")

        // A write after this hub's own is a real take over.
        try await seed(foreignHeartbeat(age: -5, macName: "Mac B"), into: cloud)
        await hub.heartbeatTick()
        XCTAssertEqual(hub.status, .tookOver("Mac B"))
    }

    func testThreeFailedTicksInARowStopTheHubAsUnavailable() async throws {
        let transport = StubHubTransport()
        let hub = try makeHub(transport: transport, sidecar: try HubSyncState.inMemory())
        await hub.enable()
        XCTAssertEqual(MobileHubService.maxTickFailures, 3)

        transport.setDataChangesFail(true)
        await hub.heartbeatTick()
        await hub.heartbeatTick()
        transport.setDataChangesFail(false)
        await hub.heartbeatTick()
        transport.setDataChangesFail(true)
        await hub.heartbeatTick()
        await hub.heartbeatTick()
        XCTAssertEqual(hub.status, .running, "a good tick resets the count")

        await hub.heartbeatTick()

        guard case .unavailable(let message) = hub.status else {
            return XCTFail("expected .unavailable, got \(hub.status)")
        }
        XCTAssertTrue(message.hasPrefix("Couldn't check which Mac is the hub"), message)
        XCTAssertFalse(hub.isPublishing)
    }

    func testLastPublishAtComesFromTheInjectedClock() async throws {
        let instant = now
        let clock: @Sendable () -> Date = { instant }
        let publisher = SlicePublisher(
            dbPool: dbPool, state: try HubSyncState.inMemory(), transport: StubHubTransport(), sources: [], now: clock
        )
        XCTAssertNil(publisher.lastPublishAt)

        try await publisher.publishOnce()

        XCTAssertEqual(publisher.lastPublishAt, instant)
    }

    func testAStaleForeignHeartbeatReadWhileRunningDoesNotStopTheHub() async throws {
        let cloud = InMemoryCloudTransport()
        let transport = StubHubTransport(cloud: cloud)
        let hub = try makeHub(transport: transport, sidecar: try HubSyncState.inMemory())
        let result = await hub.enable()
        XCTAssertEqual(result, .running)

        try await seed(foreignHeartbeat(age: 720), into: cloud)
        await hub.heartbeatTick()

        XCTAssertEqual(hub.status, .running, "a stale foreign heartbeat is no live hub")
    }

    func testTheHeartbeatLoopRewritesTheRecord() async throws {
        let transport = StubHubTransport()
        let sidecar = try HubSyncState.inMemory()
        let publisher = SlicePublisher(dbPool: dbPool, state: sidecar, transport: transport, sources: [])
        let processor = RelayProcessor(
            transport: transport, sidecar: sidecar, dispatcher: MobileHubCommandDispatcher(), hubID: "hub-acme"
        )
        let hub = MobileHubService(
            transport: transport, publisher: publisher, processor: processor, sidecar: sidecar,
            hostInfo: testHostInfo(), relayIdleInterval: .seconds(3600), relayActiveInterval: .seconds(3600),
            heartbeatInterval: .milliseconds(10)
        ) { true }
        hubs.append(hub)

        await hub.enable()

        try await awaitHubCondition("the loop writes the heartbeat again") { try savedHeartbeats(transport).count >= 3 }
    }

    // MARK: - enabled_at

    func testEnabledAtIsSetOnTheFirstEnableAndKeptAcrossARelaunch() async throws {
        let path = tempDir.appendingPathComponent("hubstate.db").path
        let firstRun = try HubSyncState(path: path)
        let firstTransport = StubHubTransport()
        let firstHub = try makeHub(transport: firstTransport, sidecar: firstRun)
        let first = await firstHub.enable()
        XCTAssertEqual(first, .running)
        XCTAssertEqual(try savedHeartbeats(firstTransport).first?.enabledAt, now)
        firstHub.stop()
        await firstHub.waitUntilStopped()

        // Relaunch: a new sidecar over the same file, an hour later.
        let relaunched = try HubSyncState(path: path)
        let secondTransport = StubHubTransport()
        let later = now.addingTimeInterval(3600)
        let secondHub = try makeHub(transport: secondTransport, sidecar: relaunched, now: later)
        let second = await secondHub.enable()

        XCTAssertEqual(second, .running)
        let heartbeat = try XCTUnwrap(try savedHeartbeats(secondTransport).first)
        XCTAssertEqual(heartbeat.enabledAt, now, "enabled_at keeps the first enable")
        XCTAssertEqual(heartbeat.updatedAt, later)
        XCTAssertEqual(try HubIdentity(sidecar: relaunched).ensureEnabledAt(later), now)
    }

    // MARK: - Payload

    func testHeartbeatCarriesEveryField() async throws {
        let transport = StubHubTransport()
        let sidecar = try HubSyncState.inMemory()
        let account = HeartbeatAccount(kind: .slack, label: "acme", status: "ok")
        let hub = try makeHub(
            transport: transport, sidecar: sidecar,
            host: testHostInfo(macName: "Mac acme", flavor: .corp, accounts: { [account] }, ownerUser: "_owner-acme")
        )

        await hub.enable()

        let heartbeat = try XCTUnwrap(try savedHeartbeats(transport).first)
        XCTAssertEqual(heartbeat.updatedAt, now)
        XCTAssertEqual(heartbeat.appVersion, "0.0.0-test")
        XCTAssertEqual(heartbeat.hubID, try sidecar.ensureHubID())
        XCTAssertEqual(heartbeat.macName, "Mac acme")
        XCTAssertEqual(heartbeat.flavor, .corp)
        XCTAssertEqual(heartbeat.relayBacklog, 0)
        XCTAssertEqual(heartbeat.accounts, [account])
        XCTAssertEqual(heartbeat.enabledAt, now)
        XCTAssertEqual(heartbeat.ownerUser, "_owner-acme")
        XCTAssertEqual(heartbeat.sharing, HubSharing.none)
        let record = try XCTUnwrap(transport.saved.first { $0.record.recordName == HeartbeatPayload.recordName })
        XCTAssertEqual(record.record.zone, .data, "the heartbeat lives in DataZone")
    }

    func testBuildFlavorMapsToTheWireFlavor() {
        XCTAssertEqual(HubIdentity.flavor(buildFlavor: ""), .default)
        XCTAssertEqual(HubIdentity.flavor(buildFlavor: "dev"), .default)
        XCTAssertEqual(HubIdentity.flavor(buildFlavor: "acme"), .corp)
    }

    func testAccountsHoldNoTokenSecretOrPasswordKey() async throws {
        try await dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO slack_accounts (team_id, team_name, label, status) VALUES ('T1', 'acme', '', 'ok');
                INSERT INTO slack_accounts (team_id, team_name, label, status) VALUES ('T2', 'gone', '', 'removed');
                INSERT INTO google_accounts (email, label, status) VALUES ('colleague-a@example.com', 'Work', 'revoked');
                INSERT INTO jira_accounts (cloud_id, site_name, label, status) VALUES ('c1', 'acme-jira', '', 'error');
                """)
        }
        let pool = try XCTUnwrap(dbPool)
        let transport = StubHubTransport()
        let hub = try makeHub(
            transport: transport, sidecar: try HubSyncState.inMemory(),
            host: testHostInfo { (try? pool.read(HubAccountRows.fetch)) ?? [] }
        )

        await hub.enable()

        let record = try XCTUnwrap(transport.saved.first { $0.record.recordName == HeartbeatPayload.recordName })
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: record.record.payload) as? [String: Any])
        let accounts = try XCTUnwrap(json["accounts"] as? [[String: Any]])
        XCTAssertEqual(accounts.count, 3, "the removed Slack account is left out")
        let keys = accounts.flatMap { Self.allKeys($0) }.map { $0.lowercased() }
        for forbidden in ["token", "secret", "password"] {
            XCTAssertFalse(keys.contains { $0.contains(forbidden) }, "accounts carry a \(forbidden) key: \(keys)")
        }
        XCTAssertEqual(Set(keys), ["kind", "label", "status"])
        let decoded = try XCTUnwrap(try savedHeartbeats(transport).first)
        XCTAssertEqual(decoded.accounts, [
            HeartbeatAccount(kind: .slack, label: "acme", status: "ok"),
            HeartbeatAccount(kind: .google, label: "Work", status: "revoked"),
            HeartbeatAccount(kind: .jira, label: "acme-jira", status: "error")
        ])
    }

    private static func allKeys(_ object: [String: Any]) -> [String] {
        object.flatMap { key, value -> [String] in
            switch value {
            case let nested as [String: Any]: return [key] + allKeys(nested)
            case let list as [[String: Any]]: return [key] + list.flatMap(allKeys)
            default: return [key]
            }
        }
    }

    func testMacNameOf70CharactersIsClippedTo60AtAGraphemeBoundary() async throws {
        let family = "👩‍👩‍👧‍👦"
        let name = String(repeating: "a", count: 59) + family + String(repeating: "b", count: 10)
        XCTAssertEqual(name.count, 70)

        let clipped = HubIdentity.clipMacName(name)

        XCTAssertEqual(clipped.count, 60)
        XCTAssertTrue(clipped.hasSuffix(family), "the ZWJ sequence is kept whole, never split")
        XCTAssertEqual(HubIdentity.clipMacName(String(repeating: "x", count: 70)).count, 60)

        let transport = StubHubTransport()
        let hub = try makeHub(transport: transport, sidecar: try HubSyncState.inMemory(), host: testHostInfo(macName: name))
        await hub.enable()
        XCTAssertEqual(try savedHeartbeats(transport).first?.macName, clipped)
    }
}
