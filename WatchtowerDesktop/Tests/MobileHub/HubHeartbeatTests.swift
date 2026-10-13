import Foundation
import GRDB
import os
import XCTest
@testable import WatchtowerDesktop
import WatchtowerSync
import WatchtowerTestSupport

/// The heartbeat (multi-hub spec §3.2): written into the hub's own DataZone
/// every 15 min, and at once when its accounts or sharing change; another
/// Mac's heartbeat changes nothing.
@MainActor
final class HubHeartbeatTests: XCTestCase {
    private var dbPath: String!
    private var dbPool: DatabasePool!
    private var tempDir: URL!
    private var hubs: [MobileHubService] = []
    /// One fixed instant per test (whole seconds: the wire carries Unix seconds).
    private let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))

    override func setUp() async throws {
        (dbPool, dbPath) = try TestDatabase.createPool()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("HubHeartbeatTests-\(UUID().uuidString)")
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
        reprobeEvery: Duration = .seconds(3600),
        factsCheckEvery: Duration = .seconds(3600)
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
            availabilityReprobeInterval: reprobeEvery,
            heartbeatInterval: .seconds(3600),
            heartbeatFactsCheckInterval: factsCheckEvery,
            now: { instant }, isEnabled: { true }
        )
        hubs.append(hub)
        return hub
    }

    private func foreignHeartbeat(age: TimeInterval, macName: String) -> HeartbeatPayload {
        HeartbeatPayload(
            updatedAt: now.addingTimeInterval(-age), appVersion: "0.0.0-test", hubID: "hub-other", macName: macName,
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

    // MARK: - Account change (#65)

    /// After the iCloud account signed out or switched, the heartbeat and
    /// the attached link center's QR name the new user.
    func testAnAccountResetLooksTheOwnerUpAgainForTheHeartbeatAndTheQR() async throws {
        let owner = OwnerUserBox("_owner-acme")
        let transport = StubHubTransport()
        let sidecar = try HubSyncState.inMemory()
        let host = HubHostInfo(
            macName: "Mac acme", appVersion: "0.0.0-test", flavor: .default, accounts: { [] }, ownerUser: { owner.value }
        )
        let hub = try makeHub(transport: transport, sidecar: sidecar, host: host)
        let center = MobileLinkCenter(
            sidecar: sidecar, shares: FakeShareService(), macName: "Mac acme", ownerUser: { owner.value },
            sleep: { _ in try? await Task.sleep(for: .seconds(3600)) }
        )
        center.attach(to: hub)
        await hub.enable()
        let issued1 = try await center.issueCode()
        XCTAssertEqual(issued1.ownerUser, "_owner-acme")
        await center.closeLink(reason: .sheetClosed)

        owner.set("_owner-new")
        transport.fireAccountReset()

        try await awaitHubCondition("the heartbeat names the new user") {
            await hub.heartbeatTick()
            return try savedHeartbeats(transport).last?.ownerUser == "_owner-new"
        }
        let issued2 = try await center.issueCode()
        XCTAssertEqual(issued2.ownerUser, "_owner-new")
        await center.closeLink(reason: .sheetClosed)
    }

    /// A lookup still running when the account changes may answer with the
    /// old user: the heartbeat never carries it.
    func testAnOwnerLookupRunningAcrossAnAccountResetNeverReachesTheHeartbeat() async throws {
        let owner = OwnerUserBox("_owner-acme")
        let gate = SaveGate()
        let transport = StubHubTransport()
        let host = HubHostInfo(
            macName: "Mac acme", appVersion: "0.0.0-test", flavor: .default, accounts: { [] },
            ownerUser: {
                let answer = owner.value
                await gate.park()
                return answer
            }
        )
        let hub = try makeHub(transport: transport, sidecar: try HubSyncState.inMemory(), host: host)
        let enabling = Task { await hub.enable() }
        await fulfillment(of: [gate.arrived], timeout: 5)

        owner.set("_owner-new")
        hub.accountChanged()
        gate.release()
        await enabling.value
        await hub.heartbeatTick()

        let owners = try savedHeartbeats(transport).map(\.ownerUser)
        XCTAssertFalse(owners.contains("_owner-acme"), "\(owners)")
        XCTAssertEqual(owners.last, "_owner-new")
    }

    // MARK: - Enable

    /// Board #724, owner decision Q2: every 15 min, and three failed
    /// writes in a row (45 min) outlast the phone's 35 min offline mark.
    func testPinnedHeartbeatTiming() {
        XCTAssertEqual(MobileHubService.heartbeatInterval, .seconds(900))
        XCTAssertEqual(MobileHubService.maxTickFailures, 3)
        XCTAssertGreaterThan(MobileHubService.heartbeatInterval * MobileHubService.maxTickFailures, .seconds(35 * 60))
    }

    func testAnotherMacsLiveHeartbeatNeitherRefusesNorStopsThisHub() async throws {
        let cloud = InMemoryCloudTransport()
        try await seed(foreignHeartbeat(age: 5, macName: "Mac B"), into: cloud)
        let transport = StubHubTransport(cloud: cloud)
        let hub = try makeHub(transport: transport, sidecar: try HubSyncState.inMemory())

        let status = await hub.enable()
        try await seed(foreignHeartbeat(age: -5, macName: "Mac B"), into: cloud)
        await hub.heartbeatTick()

        XCTAssertEqual(status, .running)
        XCTAssertEqual(hub.status, .running, "each Mac publishes into its own zones (spec §2)")
        XCTAssertEqual(try savedHeartbeats(transport).count, 2)
        XCTAssertEqual(try savedHeartbeats(transport).last?.updatedAt, now, "stamped with this Mac's clock")
    }

    func testAFailedFirstHeartbeatLeavesTheHubUnavailableAndTheReprobeRestartsIt() async throws {
        let transport = StubHubTransport()
        transport.failNextSaves(1)
        let hub = try makeHub(transport: transport, sidecar: try HubSyncState.inMemory(), reprobeEvery: .milliseconds(20))

        let status = await hub.enable()

        guard case .unavailable(let message) = status else {
            return XCTFail("expected .unavailable, got \(status)")
        }
        XCTAssertTrue(message.hasPrefix("Couldn't write the heartbeat"), message)
        XCTAssertFalse(hub.isPublishing)
        await awaitHubCondition("the reprobe loop restarts the hub") { hub.status == .running }
        XCTAssertTrue(hub.isPublishing)
        XCTAssertEqual(try savedHeartbeats(transport).count, 1, "the retried write went through")
    }

    func testThreeFailedTicksInARowStopTheHubAsUnavailable() async throws {
        let transport = StubHubTransport()
        let hub = try makeHub(transport: transport, sidecar: try HubSyncState.inMemory())
        await hub.enable()
        XCTAssertEqual(MobileHubService.maxTickFailures, 3)

        transport.failNextSaves(2)
        await hub.heartbeatTick()
        await hub.heartbeatTick()
        await hub.heartbeatTick()
        transport.failNextSaves(3)
        await hub.heartbeatTick()
        await hub.heartbeatTick()
        XCTAssertEqual(hub.status, .running, "a good tick resets the count")

        await hub.heartbeatTick()

        guard case .unavailable(let message) = hub.status else {
            return XCTFail("expected .unavailable, got \(hub.status)")
        }
        XCTAssertTrue(message.hasPrefix("Couldn't write the heartbeat"), message)
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

    /// Board #724: the heartbeat now waits 15 min, so a changed account
    /// status or sharing is written at the next facts check instead; an
    /// unchanged check writes nothing.
    func testChangedAccountsOrSharingRewriteTheHeartbeatAtOnce() async throws {
        let transport = StubHubTransport()
        let accounts = OSAllocatedUnfairLock(initialState: [HeartbeatAccount(kind: .slack, label: "acme", status: "ok")])
        let hub = try makeHub(
            transport: transport, sidecar: try HubSyncState.inMemory(),
            host: testHostInfo { accounts.withLock { $0 } }
        )
        await hub.enable()
        XCTAssertEqual(try savedHeartbeats(transport).count, 1)

        let unchanged = await hub.refreshHeartbeatIfFactsChanged()
        XCTAssertFalse(unchanged)
        XCTAssertEqual(try savedHeartbeats(transport).count, 1, "unchanged facts write nothing")

        accounts.withLock { $0 = [HeartbeatAccount(kind: .slack, label: "acme", status: "revoked")] }
        let statusChanged = await hub.refreshHeartbeatIfFactsChanged()
        XCTAssertTrue(statusChanged)
        XCTAssertEqual(try savedHeartbeats(transport).last?.accounts.map(\.status), ["revoked"])

        hub.sharing = .available
        let sharingChanged = await hub.refreshHeartbeatIfFactsChanged()
        XCTAssertTrue(sharingChanged)
        XCTAssertEqual(try savedHeartbeats(transport).last?.sharing, .available)

        let again = await hub.refreshHeartbeatIfFactsChanged()
        XCTAssertFalse(again)
        XCTAssertEqual(try savedHeartbeats(transport).count, 3, "one write per change")
    }

    /// A failed accounts read is not an empty list: the facts check sees no
    /// change and writes nothing, and the next tick keeps the accounts the
    /// last write carried (board #724).
    func testAFailedAccountsReadIsNeitherAChangeNorAnEmptyList() async throws {
        struct ReadFailed: Error {}
        let transport = StubHubTransport()
        let failing = OSAllocatedUnfairLock(initialState: false)
        let hub = try makeHub(
            transport: transport, sidecar: try HubSyncState.inMemory(),
            host: testHostInfo {
                if failing.withLock({ $0 }) { throw ReadFailed() }
                return [HeartbeatAccount(kind: .google, label: "acme", status: "ok")]
            }
        )
        await hub.enable()
        XCTAssertEqual(try savedHeartbeats(transport).count, 1)

        failing.withLock { $0 = true }
        let changed = await hub.refreshHeartbeatIfFactsChanged()
        XCTAssertFalse(changed, "a failed read is no change")
        XCTAssertEqual(try savedHeartbeats(transport).count, 1, "nothing written, no push")

        await hub.heartbeatTick()
        XCTAssertEqual(try savedHeartbeats(transport).count, 2)
        XCTAssertEqual(try savedHeartbeats(transport).last?.accounts.map(\.label), ["acme"], "the tick keeps the last accounts")

        failing.withLock { $0 = false }
        let recovered = await hub.refreshHeartbeatIfFactsChanged()
        XCTAssertFalse(recovered, "the same accounts once the read works again")
        XCTAssertEqual(try savedHeartbeats(transport).count, 2)
    }

    /// A stop while a tick's accounts read is held: the tick writes
    /// nothing once the read returns (board #724).
    func testAStopDuringATicksAccountsReadWritesNothing() async throws {
        let transport = StubHubTransport()
        let gate = SaveGate()
        let holding = OSAllocatedUnfairLock(initialState: false)
        let hub = try makeHub(
            transport: transport, sidecar: try HubSyncState.inMemory(),
            host: testHostInfo {
                if holding.withLock({ $0 }) { await gate.park() }
                return [HeartbeatAccount(kind: .slack, label: "acme", status: "ok")]
            }
        )
        await hub.enable()
        XCTAssertEqual(try savedHeartbeats(transport).count, 1)

        holding.withLock { $0 = true }
        let tick = Task { await hub.heartbeatTick() }
        await fulfillment(of: [gate.arrived], timeout: 5)
        hub.stop()
        gate.release()
        await tick.value

        XCTAssertEqual(try savedHeartbeats(transport).count, 1, "a stopped hub writes no heartbeat")
    }

    /// A stop while the first heartbeat's accounts read is held: neither
    /// `enabled_at` nor the heartbeat is written.
    func testAStopDuringTheFirstHeartbeatsAccountsReadWritesNothing() async throws {
        let transport = StubHubTransport()
        let sidecar = try HubSyncState.inMemory()
        let gate = SaveGate()
        let hub = try makeHub(
            transport: transport, sidecar: sidecar,
            host: testHostInfo {
                await gate.park()
                return []
            }
        )
        let enabling = Task { await hub.enable() }
        await fulfillment(of: [gate.arrived], timeout: 5)
        hub.stop()
        gate.release()
        _ = await enabling.value

        XCTAssertEqual(try savedHeartbeats(transport).count, 0, "a stopped start writes no heartbeat")
        XCTAssertNil(try sidecar.metaValue(forKey: HubIdentity.enabledAtKey), "nor enabled_at")
        XCTAssertEqual(hub.status, .off)
    }

    /// The loop runs the facts check between two heartbeat ticks.
    func testTheHeartbeatLoopWritesChangedAccountsBeforeTheTick() async throws {
        let transport = StubHubTransport()
        let accounts = OSAllocatedUnfairLock(initialState: [HeartbeatAccount(kind: .jira, label: "acme", status: "ok")])
        let hub = try makeHub(
            transport: transport, sidecar: try HubSyncState.inMemory(),
            host: testHostInfo { accounts.withLock { $0 } }, factsCheckEvery: .milliseconds(10)
        )
        await hub.enable()

        accounts.withLock { $0 = [HeartbeatAccount(kind: .jira, label: "acme", status: "error")] }
        try await awaitHubCondition("the loop writes the changed status") {
            try savedHeartbeats(transport).last?.accounts.map(\.status) == ["error"]
        }
        XCTAssertEqual(try savedHeartbeats(transport).count, 2)
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
