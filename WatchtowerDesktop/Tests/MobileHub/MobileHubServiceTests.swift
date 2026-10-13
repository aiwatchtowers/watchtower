import CloudKit
import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerSync
import WatchtowerTestSupport

/// The hub's composition root and its AppState wiring (mobile POC spec
/// §6.1): opt-in, loops, availability gating, the relay re-nudge and the
/// teardown when `initWorkbenches` re-runs.
@MainActor
final class MobileHubServiceTests: XCTestCase {
    private var dbPath: String!
    private var dbPool: DatabasePool!
    private var sidecar: HubSyncState!
    private var defaults: UserDefaults!
    private let suiteName = "WatchtowerDesktopTests.mobileHub"

    override func setUp() async throws {
        (dbPool, dbPath) = try TestDatabase.createPool()
        sidecar = try HubSyncState.inMemoryPerHub()
        try sidecar.linkTestDevice()
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = nil
        sidecar = nil
        dbPool = nil
        TestDatabase.cleanup(path: dbPath)
    }

    private func makeService(
        transport: StubHubTransport,
        relayInterval: Duration = .milliseconds(20),
        relayActiveInterval: Duration? = nil,
        dispatcher: MobileHubCommandDispatcher? = nil,
        companions: [any HubCompanion] = [],
        assets: SliceAssetStore? = nil,
        cloudTimeout: Duration = MobileHubService.defaultCloudTimeout,
        keyring: HubKeyring? = nil,
        reprobeInterval: Duration = .milliseconds(20),
        isEnabled: @escaping () -> Bool = { true }
    ) -> MobileHubService {
        let publisher = SlicePublisher(
            dbPool: dbPool, state: sidecar, transport: transport.sealing(names: sidecar), sources: [],
            timing: .init(tick: .milliseconds(20), fastWindow: .milliseconds(10), fastSpacing: .milliseconds(10)),
            assets: assets
        )
        let processor = RelayProcessor(
            transport: transport.sealing(), sidecar: sidecar, dispatcher: dispatcher ?? MobileHubCommandDispatcher(), hubID: "hub-acme"
        )
        return MobileHubService(
            transport: transport, publisher: publisher, processor: processor, sidecar: sidecar,
            hostInfo: testHostInfo(), keyring: keyring, companions: companions,
            relayIdleInterval: relayInterval, relayActiveInterval: relayActiveInterval ?? relayInterval,
            availabilityReprobeInterval: reprobeInterval, cloudTimeout: cloudTimeout, isEnabled: isEnabled
        )
    }

    private func appliedEchoes(_ transport: StubHubTransport) throws -> [ActionRequestPayload] {
        try transport.saved
            .filter { $0.record.zone == .relay }
            .map { try decodeAction($0.record) }
            .filter { $0.status == .applied }
    }

    private func heartbeatPayload(hubID: String) throws -> Data {
        try CloudRecordFactory.record(for: HeartbeatPayload(
            updatedAt: Date(), appVersion: "0.0.0-test", hubID: hubID, macName: "Mac acme", flavor: .default,
            lastPublishAt: nil, lastRelayAt: nil, relayBacklog: 0, accounts: [], enabledAt: Date(),
            ownerUser: "_owner-acme", sharing: .none
        ), modifiedAt: Date()).payload
    }

    // MARK: - Service

    func testPinnedRelayCadence() {
        XCTAssertEqual(MobileHubService.defaultRelayIdleInterval, .seconds(30))
        XCTAssertEqual(MobileHubService.defaultRelayActiveInterval, .seconds(3))
        XCTAssertEqual(MobileHubService.activityWindow, 300)
    }

    /// A phone that scanned the QR writes its `device` record: while the
    /// code is open the relay polls at the active cadence, so the grant
    /// lands well inside the phone's 60 s wait.
    func testAnOpenLinkCodeRunsTheRelayAtTheActiveCadence() async throws {
        let hub = makeService(transport: StubHubTransport(), relayInterval: .seconds(30), relayActiveInterval: .seconds(3))
        XCTAssertEqual(hub.relayInterval(), .seconds(30))
        let center = MobileLinkCenter(
            sidecar: sidecar, shares: FakeShareService(), macName: "Mac acme", ownerUser: { "_owner-acme" },
            keyring: try sidecar.testKeyring(),
            nudge: { _ in }, sleep: { _ in try? await Task.sleep(for: .seconds(3600)) }
        )
        hub.linkCenter = center
        XCTAssertEqual(hub.relayInterval(), .seconds(30), "no code on screen")

        _ = try await center.issueCode()
        XCTAssertEqual(hub.relayInterval(), .seconds(3))

        await center.closeLink(reason: .sheetClosed)
        XCTAssertEqual(hub.relayInterval(), .seconds(30))
    }

    func testAStopWhileTheTransportHandlersInstallLeavesTheTransportStopped() async throws {
        let transport = StubHubTransport()
        let gate = SaveGate()
        transport.gateNextResetHandlerInstall(on: gate)
        let service = makeService(transport: transport)

        let starting = Task { await service.start() }
        await fulfillment(of: [gate.arrived], timeout: 5)
        service.stop()
        await service.waitUntilStopped()
        gate.release()
        await starting.value

        XCTAssertEqual(transport.lifecycle.last, "stop", "a stop during the install is never undone by a late start")
        XCTAssertEqual(service.status, .off)
        XCTAssertFalse(service.isPublishing)
    }

    func testCompanionsRunOnlyWhileTheHubPublishes() async throws {
        let companion = CountingCompanion()
        let offline = makeService(transport: StubHubTransport(availability: .noAccount), companions: [companion])
        await offline.start()
        XCTAssertEqual(companion.starts, 0, "no companion runs while the hub cannot publish")

        let service = makeService(transport: StubHubTransport(), companions: [companion])
        await service.start()
        XCTAssertEqual(service.status, .running)
        XCTAssertEqual(companion.starts, 1)

        service.stop()
        XCTAssertEqual(companion.stops, 1)
        offline.stop()
    }

    func testRunningHubAnswersAProbe() async throws {
        let transport = StubHubTransport()
        try await transport.save([try pendingActionRecord(kind: .probe, params: ["nonce": .string("n")])])
        let service = makeService(transport: transport)

        await service.start()
        defer { service.stop() }

        XCTAssertEqual(service.status, .running)
        XCTAssertEqual(transport.starts, 1)
        try await awaitHubCondition("the probe is echoed") { try appliedEchoes(transport).count == 1 }
    }

    func testLongSleepBacklogDrainsWithoutWaitingForTheNextPoll() async throws {
        let transport = StubHubTransport()
        let records = try (0..<500).map { try pendingActionRecord(kind: .probe, params: ["nonce": .string("n-\($0)")]) }
        try await transport.save(records)
        // A poll interval far beyond the test: only the re-nudge can drain it.
        let service = makeService(transport: transport, relayInterval: .seconds(600))

        await service.start()
        defer { service.stop() }

        await awaitHubCondition("500 probes are echoed in one relay cycle", timeout: 20) {
            transport.appliedEchoIDs.count >= 500 && service.relayBacklog == 0
        }
        let echoed = transport.appliedEchoIDs
        XCTAssertEqual(echoed.count, 500)
        XCTAssertEqual(Set(echoed).count, 500, "each probe is echoed exactly once")
        XCTAssertEqual(service.relayBacklog, 0)
    }

    func testUnavailableICloudRunsNoLoopsAndRecoversWhenItReturns() async throws {
        let transport = StubHubTransport(availability: .noAccount)
        try await transport.save([try pendingActionRecord(kind: .probe, params: ["nonce": .string("n")])])
        let service = makeService(transport: transport)

        await service.start()
        defer { service.stop() }
        XCTAssertEqual(service.status, .unavailable("No iCloud account is signed in"))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(try appliedEchoes(transport).isEmpty, "nothing runs while iCloud is unavailable")

        transport.setAvailability(.available)
        await awaitHubCondition("the re-probe starts the hub") { service.status == .running }
        try await awaitHubCondition("the recovered hub runs its relay loop") { try appliedEchoes(transport).count == 1 }
    }

    func testStopHaltsEveryLoop() async throws {
        let transport = StubHubTransport()
        let service = makeService(transport: transport)
        await service.start()
        XCTAssertTrue(service.isPublishing)

        service.stop()

        XCTAssertEqual(service.status, .off)
        XCTAssertFalse(service.isPublishing)
        try await Task.sleep(for: .milliseconds(100))
        try await transport.save([try pendingActionRecord(kind: .probe, params: ["nonce": .string("n")])])
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(try appliedEchoes(transport).isEmpty, "a stopped hub answers nothing")
    }

    func testStartWhileDisabledDoesNothing() async {
        let transport = StubHubTransport()
        let service = makeService(transport: transport) { false }

        await service.start()

        XCTAssertEqual(service.status, .off)
        XCTAssertEqual(transport.starts, 0)
    }

    func testAccountResetWipesHashesAndTokenButKeepsTheLedger() async throws {
        try sidecar.setHash("hash", for: "workbench-1")
        try sidecar.setMetaValue("{}", forKey: RelayProcessor.relayTokenKey)
        try sidecar.markRelayDone("action-1", outcome: "applied", at: Date())
        let transport = StubHubTransport()
        let service = makeService(transport: transport)
        await service.start()
        defer { service.stop() }
        let hubID = try sidecar.ensureHubID()
        let enabledAt = try HubIdentity(sidecar: sidecar).ensureEnabledAt(Date(timeIntervalSince1970: 1_800_000_000))

        transport.fireAccountReset()

        XCTAssertTrue(try sidecar.hashes(forKind: .workbench).isEmpty)
        XCTAssertNil(try sidecar.metaValue(forKey: RelayProcessor.relayTokenKey))
        XCTAssertEqual(try sidecar.relayPhase("action-1"), .done, "phone UUIDs cannot collide across accounts")
        XCTAssertEqual(try sidecar.ensureHubID(), hubID, "hub_id names this hub's zones and survives")
        XCTAssertEqual(
            try HubIdentity(sidecar: sidecar).ensureEnabledAt(Date(timeIntervalSince1970: 1_900_000_000)), enabledAt,
            "enabled_at survives"
        )
    }

    /// A server-side DataZone deletion wipes what the hub believes is
    /// published (and the staged assets), but not the relay cursor: the
    /// relay buffer survived (final-review P2-I1).
    func testDataZoneResetWipesHashesButKeepsTheRelayTokenAndTheLedger() async throws {
        try sidecar.setHash("hash", for: "workbench-1")
        try sidecar.setMetaValue("{}", forKey: RelayProcessor.relayTokenKey)
        try sidecar.markRelayDone("action-1", outcome: "applied", at: Date())
        let store = try stagedAssetStore()
        let transport = StubHubTransport()
        let service = makeService(transport: transport, relayInterval: .seconds(600), assets: store)
        await service.start()
        defer { service.stop() }

        transport.fireDataZoneReset()

        XCTAssertTrue(try sidecar.hashes(forKind: .workbench).isEmpty)
        XCTAssertNotNil(try sidecar.metaValue(forKey: RelayProcessor.relayTokenKey), "the relay buffer was not reset")
        XCTAssertEqual(try sidecar.relayPhase("action-1"), .done)
        XCTAssertFalse(store.isStaged(recordName: "meeting_transcript-1", fileName: "segments.json"))
    }

    private func stagedAssetStore() throws -> SliceAssetStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hub-assets-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let store = SliceAssetStore(directory: dir)
        _ = try store.stage(Data("[]".utf8), fileName: "segments.json", recordName: "meeting_transcript-1")
        return store
    }

    func testAccountResetRemovesTheStagedAssets() async throws {
        let store = try stagedAssetStore()
        let transport = StubHubTransport()
        let service = makeService(transport: transport, assets: store)
        await service.start()
        defer { service.stop() }

        transport.fireAccountReset()

        XCTAssertFalse(store.isStaged(recordName: "meeting_transcript-1", fileName: "segments.json"))
    }

    func testDisableRemovesTheStagedAssetsAndStopStopsOnly() async throws {
        let store = try stagedAssetStore()
        let transport = StubHubTransport()
        let service = makeService(transport: transport, assets: store)
        await service.start()

        service.stop()
        XCTAssertTrue(store.isStaged(recordName: "meeting_transcript-1", fileName: "segments.json"), "a plain stop keeps them")
        await service.start()
        service.disable()
        await service.waitUntilStopped()

        XCTAssertEqual(service.status, .off)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
        XCTAssertThrowsError(
            try store.stage(Data(), fileName: "segments.json", recordName: "meeting_transcript-2"),
            "no file is staged while the hub is off"
        )
    }

    /// The staged files are ciphertext with a `.desc` descriptor (holding `K_asset`) beside each: an account reset
    /// and turning the hub off remove both, never leaving a key behind.
    func testAccountResetAndDisableStillRemoveStagedFilesAndDescriptors() async throws {
        let store = try stagedAssetStore()
        let file = store.fileURL(recordName: "meeting_transcript-1", fileName: "segments.json")
        let descriptor = file.appendingPathExtension("desc")
        XCTAssertTrue(FileManager.default.fileExists(atPath: descriptor.path))
        let transport = StubHubTransport()
        let service = makeService(transport: transport, assets: store)
        await service.start()

        transport.fireAccountReset()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: descriptor.path), "the descriptor goes with its file")

        _ = try store.stage(Data("[]".utf8), fileName: "segments.json", recordName: "meeting_transcript-1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: descriptor.path))
        service.disable()
        await service.waitUntilStopped()

        XCTAssertFalse(FileManager.default.fileExists(atPath: descriptor.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
        XCTAssertNil(store.stagedDescriptor(recordName: "meeting_transcript-1", fileName: "segments.json"))
    }

    func testStopStopsTheTransport() async {
        let transport = StubHubTransport()
        let service = makeService(transport: transport)
        await service.start()

        service.stop()
        await service.waitUntilStopped()

        XCTAssertEqual(transport.stops, 1, "toggle off stops CloudKit syncing too")
    }

    func testOffThenOnWhileAPassRunsAppliesNoRecordTwice() async throws {
        let latch = HandlerLatch()
        let dispatcher = MobileHubCommandDispatcher()
        dispatcher.register(.boardCommentAdd) { action in
            await latch.enter(action)
            return .applied()
        }
        let transport = StubHubTransport()
        let records = try (0..<3).map { _ in try pendingActionRecord(kind: .boardCommentAdd, entityID: "7") }
        try await transport.save(records)
        let service = makeService(transport: transport, dispatcher: dispatcher)
        await service.start()
        await awaitHubCondition("the first pass is inside a handler") { latch.entries == 1 }

        service.stop()
        let restart = Task { await service.start() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(latch.entries, 1, "the new loop waits for the old pass")
        latch.release()
        await restart.value

        await awaitHubCondition("every record is applied") { transport.appliedEchoIDs.count == 3 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(service.status, .running)
        XCTAssertEqual(latch.calls.count, 3)
        XCTAssertTrue(latch.calls.values.allSatisfy { $0 == 1 }, "no record is applied twice: \(latch.calls)")
        XCTAssertEqual(Set(transport.appliedEchoIDs).count, 3)
        XCTAssertEqual(
            transport.lifecycle, ["start", "stop", "start"],
            "the old teardown's transport stop lands before the restart starts it again"
        )
        service.stop()
    }

    func testADisposedHubNeverStarts() async {
        let transport = StubHubTransport()
        let service = makeService(transport: transport)

        service.dispose()
        await service.start()

        XCTAssertEqual(service.status, .off)
        XCTAssertEqual(transport.starts, 0, "a start() queued before the hub was replaced does nothing")
    }

    /// CloudKit names the rejected record by its opaque wire name; the hub maps it back through
    /// `slice_state.wire_name` (F19) and clears that plain name's hash only.
    func testRejectedDataRecordClearsItsHash() async throws {
        let wire = try testSecureTransport(InMemoryCloudTransport()).wireName(plain: "workbench-1", zone: .data)
        XCTAssertTrue(try sidecar.setHashes(
            ["workbench-1": "hash", "workbench-2": "hash"], wireNames: ["workbench-1": wire],
            ifGeneration: try sidecar.generation()
        ))
        let transport = StubHubTransport()
        let service = makeService(transport: transport)
        await service.start()
        defer { service.stop() }

        transport.fireRecordRejected(wire, zone: .data)

        await awaitHubCondition("the rejected record's hash is cleared") {
            (try? Set(self.sidecar.hashes(forKind: .workbench).keys)) == ["workbench-2"]
        }
    }

    // MARK: - Zone lifecycle (multi-hub spec §3.3, §3.6)

    /// Review focus 3.
    func testFirstStartOnPerHubZonesForgetsPublishStateAndTheRelayCursorButKeepsTheLedger() async throws {
        sidecar = try HubSyncState.inMemory()
        try sidecar.setMetaValue("42", forKey: RelayProcessor.relayTokenKey)
        try sidecar.markRelayDone("action-x", outcome: "applied", at: Date())
        let service = makeService(transport: StubHubTransport())

        await service.start()

        XCTAssertNil(try sidecar.metaValue(forKey: RelayProcessor.relayTokenKey), "the relay buffer was wiped; re-read from the start")
        XCTAssertEqual(try sidecar.relayPhase("action-x"), .done, "exactly-once survives")
        XCTAssertEqual(try sidecar.metaValue(forKey: HubIdentity.perHubZonesKey), "1")

        try sidecar.setMetaValue("43", forKey: RelayProcessor.relayTokenKey)
        service.stop()
        await service.waitUntilStopped()
        await service.start()
        XCTAssertNotNil(try sidecar.metaValue(forKey: RelayProcessor.relayTokenKey), "only the first start adopts")
        service.stop()
    }

    /// Review focus 4.
    func testLegacyZonesAreDeletedOnlyForOwnOrNoHeartbeatAndCheckedOnce() async throws {
        let hubID = try sidecar.ensureHubID()
        let cases: [(Data?, Bool, String)] = [
            (nil, true, "deleted"),
            (try heartbeatPayload(hubID: hubID), true, "deleted"),
            (try heartbeatPayload(hubID: "hub-other"), false, "kept"),
            (Data("not json".utf8), false, "kept")
        ]
        for (heartbeat, deletes, marker) in cases {
            sidecar = try HubSyncState.inMemoryPerHub()
            try sidecar.setMetaValue(hubID, forKey: HubSyncState.hubIDKey)
            let transport = StubHubTransport()
            transport.setLegacyZones(.present(heartbeat: heartbeat))
            let service = makeService(transport: transport)

            await service.start()
            service.stop()
            await service.waitUntilStopped()
            await service.start()

            XCTAssertEqual(transport.legacyZonesPresent, !deletes)
            XCTAssertEqual(try sidecar.metaValue(forKey: HubIdentity.legacyZonesCheckedKey), marker)
            XCTAssertEqual(transport.legacyCheckCount, 1, "checked once, at the first start")
            service.stop()
        }
    }

    func testAFailedLegacyCheckIsRetriedAtTheNextStartAndDoesNotBlockTheHub() async throws {
        let transport = StubHubTransport()
        transport.setLegacyCheckFails(true)
        let service = makeService(transport: transport)

        await service.start()
        XCTAssertEqual(service.status, .running)
        XCTAssertNil(try sidecar.metaValue(forKey: HubIdentity.legacyZonesCheckedKey))
        service.stop()
        await service.waitUntilStopped()
        transport.setLegacyCheckFails(false)
        await service.start()

        XCTAssertEqual(try sidecar.metaValue(forKey: HubIdentity.legacyZonesCheckedKey), "none_found")
        service.stop()
    }

    func testDisableDeletesTheHubsZonesWipesSyncStateAndForgetsPhones() async throws {
        let transport = StubHubTransport()
        let service = makeService(transport: transport)
        var forgotten = 0
        service.onZonesDeleted = { forgotten += 1 }
        await service.start()
        try sidecar.setMetaValue("42", forKey: RelayProcessor.relayTokenKey)

        service.disable()
        await service.waitUntilStopped()

        XCTAssertEqual(transport.zoneDeletes, 1)
        XCTAssertEqual(Array(transport.lifecycle.suffix(2)), ["stop", "deleteZones"], "the engine stops first")
        XCTAssertNil(try sidecar.metaValue(forKey: RelayProcessor.relayTokenKey))
        XCTAssertEqual(forgotten, 1)
    }

    func testATimedOutZoneDeleteIsFinishedAtTheNextStartBeforeTheEngineRuns() async throws {
        let transport = StubHubTransport()
        transport.delayNextZoneDelete(.milliseconds(400))
        let service = makeService(transport: transport, cloudTimeout: .milliseconds(50))
        var forgotten = 0
        service.onZonesDeleted = { forgotten += 1 }
        await service.start()
        try sidecar.setMetaValue("42", forKey: RelayProcessor.relayTokenKey)

        service.disable()
        await service.waitUntilStopped()
        XCTAssertEqual(try sidecar.metaValue(forKey: HubIdentity.zonesDeletePendingKey), "1", "outcome unknown")
        XCTAssertEqual(forgotten, 0)
        XCTAssertEqual(try sidecar.metaValue(forKey: RelayProcessor.relayTokenKey), "42")

        let generation = try sidecar.generation()
        let startsBefore = transport.starts
        await service.start()
        XCTAssertEqual(service.status, .unavailable("Couldn't finish deleting this Mac's iCloud zones"))
        XCTAssertEqual(transport.starts, startsBefore, "no engine while the first delete may still land")

        await awaitHubCondition("the reprobe finishes the delete and starts") { service.status == .running }
        // A start within the late delete joins it; one after it ended (its
        // outcome reached no one) deletes again. Never two at once.
        XCTAssertTrue((1...2).contains(transport.zoneDeletes), "\(transport.zoneDeletes) server deletes")
        XCTAssertEqual(forgotten, 1)
        XCTAssertNil(try sidecar.metaValue(forKey: HubIdentity.zonesDeletePendingKey))
        XCTAssertGreaterThan(try sidecar.generation(), generation, "the sync state was wiped")
        service.stop()
    }

    /// Review focus 5.
    func testDisableWhileTheZoneDeleteFailsKeepsSyncStateAndLinkedPhones() async throws {
        let transport = StubHubTransport()
        transport.setZoneDeletesFail(true)
        let service = makeService(transport: transport)
        var forgotten = 0
        service.onZonesDeleted = { forgotten += 1 }
        await service.start()
        try sidecar.setMetaValue("42", forKey: RelayProcessor.relayTokenKey)

        service.disable()
        await service.waitUntilStopped()
        await service.start()

        XCTAssertEqual(try sidecar.metaValue(forKey: RelayProcessor.relayTokenKey), "42", "zones still there: state still true")
        XCTAssertEqual(forgotten, 0, "the phones still share the zones")
        XCTAssertNil(try sidecar.metaValue(forKey: HubIdentity.zonesDeletePendingKey), "a refused delete deleted nothing")
        XCTAssertEqual(service.status, .running, "the hub comes back on its existing zones")
        service.stop()
    }

    /// Final review m1: a delete that removed something (one zone, or both
    /// without the store wipe) keeps the marker like a timeout; the next
    /// start finishes it.
    func testAPartlyDeletedHubOffKeepsTheMarkerAndTheNextStartFinishesIt() async throws {
        let transport = StubHubTransport()
        transport.setZoneDeletesPartial(true)
        let service = makeService(transport: transport)
        var forgotten = 0
        service.onZonesDeleted = { forgotten += 1 }
        await service.start()
        try sidecar.setMetaValue("42", forKey: RelayProcessor.relayTokenKey)

        service.disable()
        await service.waitUntilStopped()

        XCTAssertEqual(try sidecar.metaValue(forKey: HubIdentity.zonesDeletePendingKey), "1", "something was deleted")
        XCTAssertEqual(forgotten, 0)
        XCTAssertEqual(try sidecar.metaValue(forKey: RelayProcessor.relayTokenKey), "42")
        XCTAssertNotNil(service.hubOffProblem)

        transport.setZoneDeletesPartial(false)
        await service.start()
        XCTAssertEqual(service.status, .running)
        XCTAssertEqual(forgotten, 1)
        XCTAssertNil(try sidecar.metaValue(forKey: HubIdentity.zonesDeletePendingKey))
        XCTAssertNil(try sidecar.metaValue(forKey: RelayProcessor.relayTokenKey))
        XCTAssertNil(service.hubOffProblem)
        service.stop()
    }

    /// Final review m2: phones that could not be forgotten keep the delete
    /// pending, so the next start redoes it.
    func testPhonesNotForgottenKeepTheZoneDeletePending() async throws {
        let transport = StubHubTransport()
        let service = makeService(transport: transport)
        service.onZonesDeleted = { throw URLError(.cannotWriteToFile) }
        await service.start()
        try sidecar.setMetaValue("42", forKey: RelayProcessor.relayTokenKey)

        service.disable()
        await service.waitUntilStopped()

        XCTAssertEqual(transport.zoneDeletes, 1)
        XCTAssertEqual(try sidecar.metaValue(forKey: HubIdentity.zonesDeletePendingKey), "1")
        XCTAssertNotNil(service.hubOffProblem)
    }

    /// Final review nit: a sidecar that can't record the pending delete
    /// keeps the zones, and Settings can say so.
    func testAnUnwritableSidecarAtHubOffKeepsTheZonesAndSaysSo() async throws {
        let disk = try HubSyncState.onDiskPerHub()
        defer { try? FileManager.default.removeItem(at: disk.dir) }
        sidecar = disk.state
        let transport = StubHubTransport()
        let service = makeService(transport: transport)
        await service.start()
        try await disk.raw.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_pending BEFORE INSERT ON hub_meta
                WHEN NEW.key = 'hub_zones_delete_pending'
                BEGIN SELECT RAISE(ABORT, 'disk full'); END
                """)
        }

        service.disable()
        await service.waitUntilStopped()

        XCTAssertEqual(transport.zoneDeletes, 0, "no delete without its marker")
        XCTAssertTrue(service.hubOffProblem?.contains("disk full") == true, service.hubOffProblem ?? "")
    }

    /// Final review M1: the delete is serialized on the transport, which
    /// outlives the hub object. A hub built after the one that turned off
    /// does not run the engine while that delete may still land.
    func testAReplacementHubWaitsForTheReplacedHubsZoneDelete() async throws {
        let transport = StubHubTransport()
        transport.delayNextZoneDelete(.milliseconds(400))
        let first = makeService(transport: transport, cloudTimeout: .milliseconds(50))
        await first.start()
        first.disable()
        await first.waitUntilStopped()
        first.dispose()

        let second = makeService(transport: transport, cloudTimeout: .milliseconds(50))
        let startsBefore = transport.starts
        await second.start()
        XCTAssertEqual(second.status, .unavailable("Couldn't finish deleting this Mac's iCloud zones"))
        XCTAssertEqual(transport.starts, startsBefore, "no engine while the replaced hub's delete may land")

        await awaitHubCondition("the replacement finishes the delete and starts") { second.status == .running }
        XCTAssertTrue((1...2).contains(transport.zoneDeletes), "\(transport.zoneDeletes) server deletes")
        XCTAssertNil(try sidecar.metaValue(forKey: HubIdentity.zonesDeletePendingKey))
        second.stop()
    }

    /// Final review m4: the real link center, attached to the hub, forgets
    /// the phones once a hub-off delete went through.
    func testAHubOffDeleteForgetsThePhonesThroughTheAttachedLinkCenter() async throws {
        let transport = StubHubTransport()
        let service = makeService(transport: transport)
        let center = MobileLinkCenter(
            sidecar: sidecar, shares: FakeShareService(), macName: "Mac acme", ownerUser: { "_owner-acme" },
            keyring: try sidecar.testKeyring(),
            nudge: { _ in } // swiftlint:disable:this trailing_closure
        )
        center.attach(to: service)
        await service.start()
        XCTAssertFalse(try sidecar.linkedDevices().isEmpty)

        service.disable()
        await service.waitUntilStopped()

        XCTAssertTrue(try sidecar.linkedDevices().isEmpty)
        XCTAssertTrue(center.devices.isEmpty)
        XCTAssertEqual(service.sharing, HubSharing.none)
        XCTAssertNil(try sidecar.metaValue(forKey: HubIdentity.zonesDeletePendingKey))
    }

    /// Task 14: hub off forgets the group keys with the phones (the next pairing starts on fresh keys) and the
    /// revoked keyboxes (their zone is gone).
    func testTurningTheHubOffResetsGroupKeys() async throws {
        let transport = StubHubTransport()
        let keyring = try sidecar.testKeyring()
        try keyring.rotate(reason: .manual)
        _ = try sidecar.writeKeys { db in
            try db.execute(
                sql: "INSERT INTO revoked_devices (device_id, name, scope, agreement_key, removed_at) VALUES (?, 'Old', 'private', ?, 0)",
                arguments: [UUID().uuidString, Data(repeating: 9, count: 32)])
        }
        let service = makeService(transport: transport, keyring: keyring)
        let center = MobileLinkCenter(
            sidecar: sidecar, shares: FakeShareService(), macName: "Mac acme", ownerUser: { "_owner-acme" },
            keyring: keyring,
            nudge: { _ in } // swiftlint:disable:this trailing_closure
        )
        center.attach(to: service)
        await service.start()

        service.disable()
        await service.waitUntilStopped()

        XCTAssertTrue(try sidecar.latestEpochs().isEmpty, "every epoch is forgotten")
        XCTAssertNil(try sidecar.metaValue(forKey: HubKeyring.metaKeySealedKey), "K_meta is forgotten")
        XCTAssertThrowsError(try keyring.currentEpoch()) { XCTAssertEqual($0 as? SecureTransportError, .keysUnavailable) }
        let revoked = try await sidecar.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM revoked_devices") }
        XCTAssertEqual(revoked, 0)
        XCTAssertNil(try sidecar.metaValue(forKey: HubIdentity.zonesDeletePendingKey))
    }

    // MARK: - E2E hard cut (Task 15, spec §2.8, D13)

    /// The real link center on `service`: the cut forgets the phones through it (`hubZonesDeleted`).
    private func attachLinkCenter(to service: MobileHubService, keyring: HubKeyring) -> MobileLinkCenter {
        let center = MobileLinkCenter(
            sidecar: sidecar, shares: FakeShareService(), macName: "Mac acme", ownerUser: { "_owner-acme" },
            keyring: keyring,
            nudge: { _ in } // swiftlint:disable:this trailing_closure
        )
        center.attach(to: service)
        return center
    }

    /// A hub already on the E2E build: group keys under the identity in `store` and the marker set.
    private func migratedHub(store: InMemoryHubKeyStore) throws -> HubKeyring {
        let keyring = try HubKeyring(hubID: try sidecar.ensureHubID(), sidecar: sidecar, store: store)
        try keyring.ensureGroupKeys()
        try sidecar.setMetaValue("1", forKey: HubIdentity.e2eMigrationKey)
        return keyring
    }

    private func sliceStateRows() async throws -> Int {
        try await sidecar.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM slice_state") ?? -1 }
    }

    /// The pre-E2E hub (a linked phone, a legacy hash, a plaintext staged file) meets the E2E build: its zones go
    /// through the pending-delete path before the engine runs, the phones are forgotten, the hub starts on fresh
    /// keys, and the marker makes it happen once.
    func testFirstStartOnTheE2EBuildDeletesTheZonesForgetsPhonesAndSetsTheMarkerOnce() async throws {
        try sidecar.setMetaValue(String(Date().timeIntervalSince1970), forKey: HubIdentity.enabledAtKey)
        XCTAssertTrue(try sidecar.setHashes(["device_grant-x": "legacy"], ifGeneration: try sidecar.generation()))
        let store = try stagedAssetStore()
        let transport = StubHubTransport()
        let keyring = try HubKeyring(hubID: try sidecar.ensureHubID(), sidecar: sidecar, store: InMemoryHubKeyStore())
        XCTAssertTrue(keyring.identityWasRecreated, "a new identity over pre-E2E phones")
        let service = makeService(transport: transport, assets: store, keyring: keyring)
        let center = attachLinkCenter(to: service, keyring: keyring)

        await service.start()

        XCTAssertEqual(service.status, .running)
        XCTAssertEqual(transport.zoneDeletes, 1)
        XCTAssertEqual(Array(transport.lifecycle.prefix(2)), ["deleteZones", "start"], "the cut runs before the engine")
        XCTAssertTrue(try sidecar.linkedDevices().isEmpty, "every phone re-pairs")
        XCTAssertTrue(center.devices.isEmpty)
        XCTAssertEqual(try sidecar.metaValue(forKey: HubIdentity.e2eMigrationKey), "1")
        XCTAssertNil(try sidecar.metaValue(forKey: HubIdentity.zonesDeletePendingKey))
        XCTAssertFalse(store.isStaged(recordName: "meeting_transcript-1", fileName: "segments.json"), "no plaintext stays")
        XCTAssertFalse(keyring.identityWasRecreated)
        XCTAssertEqual(try keyring.currentEpoch(), 1, "fresh group keys")
        XCTAssertNoThrow(try keyring.metaKey())
        let slices = try await sliceStateRows()
        XCTAssertEqual(slices, 0, "no legacy hash survives")

        service.stop()
        await service.waitUntilStopped()
        await service.start()
        XCTAssertEqual(service.status, .running)
        XCTAssertEqual(transport.zoneDeletes, 1, "the cut runs once")
        service.stop()
    }

    func testAFailedMigrationDeleteKeepsTheMarkerPendingAndRetriesNextStart() async throws {
        let transport = StubHubTransport()
        transport.setZoneDeleteError(CKError(.networkUnavailable))
        let keyring = try HubKeyring(hubID: try sidecar.ensureHubID(), sidecar: sidecar, store: InMemoryHubKeyStore())
        let service = makeService(transport: transport, keyring: keyring)
        _ = attachLinkCenter(to: service, keyring: keyring)

        await service.start()

        XCTAssertEqual(service.status, .unavailable("Couldn't finish deleting this Mac's iCloud zones"))
        XCTAssertEqual(transport.starts, 0, "no engine on the pre-E2E zones")
        XCTAssertEqual(try sidecar.metaValue(forKey: HubIdentity.e2eMigrationKey), "pending")
        XCTAssertEqual(try sidecar.metaValue(forKey: HubIdentity.zonesDeletePendingKey), "1")
        XCTAssertFalse(try sidecar.linkedDevices().isEmpty, "nothing forgotten before the zones are gone")
        XCTAssertThrowsError(try keyring.currentEpoch(), "nothing is sealed before the cut")

        transport.setZoneDeleteError(nil)
        await awaitHubCondition("the reprobe retries the cut and starts") { service.status == .running }
        XCTAssertEqual(try sidecar.metaValue(forKey: HubIdentity.e2eMigrationKey), "1")
        XCTAssertNil(try sidecar.metaValue(forKey: HubIdentity.zonesDeletePendingKey))
        XCTAssertTrue(try sidecar.linkedDevices().isEmpty)
        XCTAssertEqual(try keyring.currentEpoch(), 1)
        service.stop()
    }

    func testARecreatedIdentityTriggersTheSameCut() async throws {
        _ = try migratedHub(store: InMemoryHubKeyStore())
        let transport = StubHubTransport()
        let recreated = try HubKeyring(hubID: try sidecar.ensureHubID(), sidecar: sidecar, store: InMemoryHubKeyStore())
        XCTAssertTrue(recreated.identityWasRecreated)
        let service = makeService(transport: transport, keyring: recreated)
        _ = attachLinkCenter(to: service, keyring: recreated)

        await service.start()

        XCTAssertEqual(service.status, .running)
        XCTAssertEqual(transport.zoneDeletes, 1)
        XCTAssertTrue(try sidecar.linkedDevices().isEmpty)
        XCTAssertEqual(try sidecar.metaValue(forKey: HubIdentity.e2eMigrationKey), "1")
        XCTAssertNoThrow(try recreated.metaKey(), "the new keys open under the new identity")
        XCTAssertNoThrow(try recreated.epochKeys(try recreated.currentEpoch()))
        service.stop()
    }

    func testAMigratedHubDoesNotCutAgain() async throws {
        let store = InMemoryHubKeyStore()
        let first = try migratedHub(store: store)
        let meta = try first.metaKey()
        let transport = StubHubTransport()
        let keyring = try HubKeyring(hubID: try sidecar.ensureHubID(), sidecar: sidecar, store: store)
        let service = makeService(transport: transport, keyring: keyring)
        _ = attachLinkCenter(to: service, keyring: keyring)

        await service.start()

        XCTAssertEqual(service.status, .running)
        XCTAssertEqual(transport.zoneDeletes, 0)
        XCTAssertFalse(try sidecar.linkedDevices().isEmpty, "the phones stay")
        XCTAssertEqual(try keyring.metaKey(), meta, "the keys stay")
        service.stop()
    }

    /// Crash-resume: the app dies after the zones were deleted and the phones forgotten, before the marker was
    /// written. The next start sees `pending` and runs the cut again (a missing zone counts as deleted).
    func testACutKilledBeforeTheMarkerIsFinishedAtTheNextStart() async throws {
        let store = InMemoryHubKeyStore()
        let keyring = try HubKeyring(hubID: try sidecar.ensureHubID(), sidecar: sidecar, store: store)
        try sidecar.clearLinkState()
        try keyring.resetGroupKeys()
        try sidecar.setMetaValue("pending", forKey: HubIdentity.e2eMigrationKey)
        let transport = StubHubTransport()
        let restarted = try HubKeyring(hubID: try sidecar.ensureHubID(), sidecar: sidecar, store: store)
        XCTAssertFalse(restarted.identityWasRecreated)
        let service = makeService(transport: transport, keyring: restarted)

        await service.start()

        XCTAssertEqual(service.status, .running)
        XCTAssertEqual(transport.zoneDeletes, 1)
        XCTAssertEqual(try sidecar.metaValue(forKey: HubIdentity.e2eMigrationKey), "1")
        XCTAssertEqual(try restarted.currentEpoch(), 1)
        service.stop()
    }

    /// Crash-resume: the delete went through but forgetting the phones failed (as if killed there). Both markers
    /// stay, and the next start finishes the cut.
    func testACutWhosePhonesWereNotForgottenIsRedoneAtTheNextStart() async throws {
        let keyring = try HubKeyring(hubID: try sidecar.ensureHubID(), sidecar: sidecar, store: InMemoryHubKeyStore())
        let transport = StubHubTransport()
        // No reprobe retry in between: exactly one delete per start.
        let service = makeService(transport: transport, keyring: keyring, reprobeInterval: .seconds(3600))
        service.onZonesDeleted = { throw URLError(.cannotWriteToFile) }

        await service.start()
        XCTAssertEqual(service.status, .unavailable("Couldn't finish deleting this Mac's iCloud zones"))
        XCTAssertEqual(try sidecar.metaValue(forKey: HubIdentity.e2eMigrationKey), "pending")
        XCTAssertEqual(try sidecar.metaValue(forKey: HubIdentity.zonesDeletePendingKey), "1")
        service.stop()
        await service.waitUntilStopped()

        _ = attachLinkCenter(to: service, keyring: keyring)
        await service.start()
        XCTAssertEqual(service.status, .running)
        XCTAssertEqual(transport.zoneDeletes, 2, "the cut ran again, once")
        XCTAssertTrue(try sidecar.linkedDevices().isEmpty)
        XCTAssertEqual(try sidecar.metaValue(forKey: HubIdentity.e2eMigrationKey), "1")
        service.stop()
    }

    /// The crash window between creating an identity and marking the cut: the marker says migrated, the flag is
    /// gone with the relaunch, but the stored keys no longer open. They cannot be used, so the hub cuts.
    func testKeysSealedUnderALostIdentityTriggerTheCut() async throws {
        let survivor = try HubKeyring(hubID: try sidecar.ensureHubID(), sidecar: sidecar, store: InMemoryHubKeyStore())
        try survivor.resetGroupKeys()
        _ = try migratedHub(store: InMemoryHubKeyStore())
        let transport = StubHubTransport()
        let service = makeService(transport: transport, keyring: survivor)

        await service.start()

        XCTAssertEqual(service.status, .running)
        XCTAssertEqual(transport.zoneDeletes, 1)
        XCTAssertNoThrow(try survivor.metaKey())
        service.stop()
    }

    func testAFreshHubSetsTheMarkerWithoutACut() async throws {
        sidecar = try HubSyncState.inMemory()
        let transport = StubHubTransport()
        let keyring = try HubKeyring(hubID: try sidecar.ensureHubID(), sidecar: sidecar, store: InMemoryHubKeyStore())
        let service = makeService(transport: transport, keyring: keyring)

        await service.start()

        XCTAssertEqual(service.status, .running)
        XCTAssertEqual(transport.zoneDeletes, 0, "a hub that never ran has no zones to cut")
        XCTAssertEqual(try sidecar.metaValue(forKey: HubIdentity.e2eMigrationKey), "1")
        service.stop()
    }

    /// Review fix 3: a pre-E2E hub whose `enabled_at` is missing and whose phones are gone still published (its
    /// slice hashes, or the per-hub adoption, say so): it cuts, never leaving plaintext zones behind.
    func testAPreE2EHubWithoutEnabledAtOrPhonesStillCuts() async throws {
        for published in [true, false] {
            sidecar = try HubSyncState.inMemory()
            if published {
                XCTAssertTrue(try sidecar.setHashes(["task-1": "legacy"], ifGeneration: try sidecar.generation()))
            } else {
                try sidecar.setMetaValue("1", forKey: HubIdentity.perHubZonesKey)
            }
            let transport = StubHubTransport()
            let keyring = try HubKeyring(hubID: try sidecar.ensureHubID(), sidecar: sidecar, store: InMemoryHubKeyStore())
            let service = makeService(transport: transport, keyring: keyring)

            await service.start()

            XCTAssertEqual(transport.zoneDeletes, 1, "published: \(published)")
            XCTAssertEqual(try sidecar.metaValue(forKey: HubIdentity.e2eMigrationKey), "1")
            service.stop()
            await service.waitUntilStopped()
        }
    }

    /// Review fix 2: without a link center (no `onZonesDeleted`), the cut still forgets the pre-E2E phones: marker
    /// `1` never coexists with their rows.
    func testACutWithoutALinkCenterStillForgetsThePhones() async throws {
        let transport = StubHubTransport()
        let keyring = try HubKeyring(hubID: try sidecar.ensureHubID(), sidecar: sidecar, store: InMemoryHubKeyStore())
        let service = makeService(transport: transport, keyring: keyring)

        await service.start()

        XCTAssertEqual(transport.zoneDeletes, 1)
        XCTAssertTrue(try sidecar.linkedDevices().isEmpty)
        XCTAssertEqual(try sidecar.metaValue(forKey: HubIdentity.e2eMigrationKey), "1")
        service.stop()
    }

    func testAHubWithoutKeysNeverCuts() async throws {
        let transport = StubHubTransport()
        let service = makeService(transport: transport)

        await service.start()

        XCTAssertEqual(transport.zoneDeletes, 0, "nothing is published without keys")
        XCTAssertNil(try sidecar.metaValue(forKey: HubIdentity.e2eMigrationKey))
        service.stop()
    }

    /// Spec §2.2: the 90-day (or 2^28-message) rotation runs at the next relay cycle once due, exactly once.
    func testRotationRunsWhenDueAtCycleStart() async throws {
        let transport = StubHubTransport()
        let clock = LinkTestClock()
        let keyring = try HubKeyring(hubID: try sidecar.ensureHubID(), sidecar: sidecar, store: InMemoryHubKeyStore()) {
            clock.now
        }
        let service = makeService(transport: transport, keyring: keyring)
        await service.start()
        defer { service.stop() }
        XCTAssertEqual(try keyring.currentEpoch(), 1, "start made the first epoch")

        clock.advance(HubKeyring.rotationAge)
        await awaitHubCondition("the due rotation runs at a cycle start") { (try? keyring.currentEpoch()) == 2 }
        let rotatedAt = service.lastRelayAt
        await awaitHubCondition("two more relay cycles") { service.lastRelayAt != rotatedAt }
        let later = service.lastRelayAt
        await awaitHubCondition("two more relay cycles") { service.lastRelayAt != later }

        XCTAssertEqual(try keyring.currentEpoch(), 2, "never a third epoch")
        XCTAssertEqual(service.status, .running)
    }

    /// Round 2: `.networkUnavailable` is refused before anything is sent.
    func testADefinitelyRefusedHubOffDeleteClearsTheMarkerAndKeepsThePhones() async throws {
        let transport = StubHubTransport()
        transport.setZoneDeleteError(CKError(.networkUnavailable))
        let service = makeService(transport: transport)
        var forgotten = 0
        service.onZonesDeleted = { forgotten += 1 }
        await service.start()

        service.disable()
        await service.waitUntilStopped()

        XCTAssertNil(try sidecar.metaValue(forKey: HubIdentity.zonesDeletePendingKey))
        XCTAssertEqual(forgotten, 0)
        XCTAssertFalse(try sidecar.linkedDevices().isEmpty, "the phones stay")
    }

    /// Round 2: a lost response may hide a delete that landed: like a
    /// timeout, the marker stays and the next start finishes it.
    func testALostResponseKeepsTheMarkerAndTheNextStartFinishesTheDelete() async throws {
        let transport = StubHubTransport()
        transport.setZoneDeleteError(CKError(.serverResponseLost))
        let service = makeService(transport: transport)
        var forgotten = 0
        service.onZonesDeleted = { forgotten += 1 }
        await service.start()

        service.disable()
        await service.waitUntilStopped()
        XCTAssertEqual(try sidecar.metaValue(forKey: HubIdentity.zonesDeletePendingKey), "1")
        XCTAssertEqual(forgotten, 0)
        XCTAssertEqual(
            service.hubOffProblem,
            "iCloud didn't confirm deleting this Mac's zones. That finishes when the hub is turned on."
        )

        transport.setZoneDeleteError(nil)
        await service.start()
        XCTAssertEqual(service.status, .running)
        XCTAssertEqual(forgotten, 1)
        XCTAssertNil(try sidecar.metaValue(forKey: HubIdentity.zonesDeletePendingKey))
        service.stop()
    }

    func testOnlyRefusalsBeforeTheRequestCountAsNothingDeleted() {
        for refused in [CKError.Code.networkUnavailable, .notAuthenticated, .quotaExceeded, .invalidArguments] {
            XCTAssertTrue(MobileHubService.isDefinitelyRefused(CKError(refused)), "\(refused)")
        }
        XCTAssertTrue(MobileHubService.isDefinitelyRefused(HubZoneError.engineRunning))
        for open in [CKError.Code.networkFailure, .serverResponseLost, .serviceUnavailable, .requestRateLimited,
                     .zoneBusy, .serverRejectedRequest] {
            XCTAssertFalse(MobileHubService.isDefinitelyRefused(CKError(open)), "\(open)")
        }
        XCTAssertFalse(MobileHubService.isDefinitelyRefused(URLError(.notConnectedToInternet)))
        XCTAssertFalse(MobileHubService.isDefinitelyRefused(HubZoneError.partlyDeleted))
    }

    // MARK: - AppState wiring

    /// An AppState whose hub storage is a stub; counts how often it is built.
    private func makeAppState(
        transport: StubHubTransport,
        shares: (any ShareService)? = nil,
        pushRegistrations: (@MainActor () -> Void)? = nil,
        storageBuilds: @escaping () -> Void
    ) throws -> AppState {
        let appState = AppState()
        appState.terminalCenter.makeProcess = { FakeTerminalSession() }
        appState.mobileSyncDefaults = defaults
        let sidecar = try XCTUnwrap(self.sidecar)
        appState.makeMobileHubStorage = {
            storageBuilds()
            var storage = try MobileHubStorage.stub(transport: transport, sidecar: sidecar)
            storage.registerForPushes = pushRegistrations
            storage.shares = shares
            storage.ownerUser = { "_owner-acme" }
            return storage
        }
        return appState
    }

    private func runInitWorkbenches(_ appState: AppState) {
        appState.initWorkbenches(
            dbPool: dbPool, cliRunner: FakeCLIRunner(), notifier: RecordingWorkbenchNotifier(),
            sessionNotifier: RecordingSessionNotifier()
        )
    }

    private func stopAll(_ appState: AppState) {
        appState.mobileHub?.stop()
        appState.sessionAgentStateCenter?.stop()
        appState.sessionReportCenter?.stop()
        appState.workbenchNotificationCenter?.stop()
        appState.workbenchesViewModel?.asks.stop()
    }

    func testToggleOffBuildsNoTransportAndWritesNothing() async throws {
        let transport = StubHubTransport()
        var builds = 0
        let appState = try makeAppState(transport: transport) { builds += 1 }
        defer { stopAll(appState) }

        runInitWorkbenches(appState)

        XCTAssertFalse(appState.isMobileSyncEnabled, "the hub is off by default")
        XCTAssertNil(appState.mobileHub)
        XCTAssertEqual(builds, 0, "no transport is created")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(transport.saved.isEmpty, "nothing is written")
        XCTAssertEqual(transport.starts, 0)
    }

    func testToggleOnOffOnKeepsExactlyOneHub() async throws {
        let transport = StubHubTransport()
        var builds = 0
        let appState = try makeAppState(transport: transport) { builds += 1 }
        defer { stopAll(appState) }
        runInitWorkbenches(appState)

        appState.setMobileSyncEnabled(true)
        let hub = try XCTUnwrap(appState.mobileHub)
        await awaitHubCondition("on: the hub runs") { hub.status == .running }

        appState.setMobileSyncEnabled(false)
        XCTAssertEqual(hub.status, .off)
        XCTAssertFalse(hub.isPublishing)

        appState.setMobileSyncEnabled(true)
        await awaitHubCondition("on again: the same hub runs") { hub.status == .running }
        XCTAssertTrue(appState.mobileHub === hub, "toggling reuses the one hub")
        XCTAssertEqual(builds, 1, "the transport is built once")
        XCTAssertTrue(defaults.bool(forKey: Constants.mobileSyncEnabledKey))
    }

    func testInitWorkbenchesRerunTearsTheOldHubDown() async throws {
        let transport = StubHubTransport()
        var builds = 0
        let appState = try makeAppState(transport: transport) { builds += 1 }
        defaults.set(true, forKey: Constants.mobileSyncEnabledKey)
        defer { stopAll(appState) }

        runInitWorkbenches(appState)
        let first = try XCTUnwrap(appState.mobileHub)
        await awaitHubCondition("the first hub runs") { first.status == .running }

        runInitWorkbenches(appState)
        let second = try XCTUnwrap(appState.mobileHub)

        XCTAssertFalse(first === second, "the hub is rebuilt with the new centers")
        XCTAssertEqual(first.status, .off, "the old hub is torn down")
        XCTAssertFalse(first.isPublishing, "no second publisher")
        await awaitHubCondition("the new hub runs") { second.status == .running }
        XCTAssertEqual(builds, 1, "the transport and sidecar outlive the rebuild")
    }

    func testTheHubRegistersForPushesOncePerRun() async throws {
        let transport = StubHubTransport()
        var registrations = 0
        let appState = try makeAppState(
            transport: transport, pushRegistrations: { registrations += 1 }, storageBuilds: {}
        )
        defer { stopAll(appState) }

        runInitWorkbenches(appState)
        XCTAssertEqual(registrations, 0, "the toggle is off: no CloudKit, no push registration")

        appState.setMobileSyncEnabled(true)
        let hub = try XCTUnwrap(appState.mobileHub)
        await awaitHubCondition("the hub runs") { hub.status == .running }
        runInitWorkbenches(appState)

        XCTAssertEqual(registrations, 1, "registered with the storage, not with every hub rebuild")
    }

    func testWakeRelayPullsBeforeTheWaitEnds() async throws {
        let transport = StubHubTransport()
        let service = makeService(transport: transport, relayInterval: .seconds(3600))
        await service.start()
        defer { service.stop() }
        // Only the relay cycle pulls: the start reads no other hub's heartbeat.
        await awaitHubCondition("the first relay cycle pulled") { transport.pulls == 1 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(transport.pulls, 1, "the next cycle waits the interval")

        service.wakeRelay()

        await awaitHubCondition("a push wakes the relay loop") { transport.pulls == 2 }
    }

    /// #66.7: a new QR wakes the relay loop instead of waiting the idle interval.
    func testIssuingACodeWakesTheRelayLoop() async throws {
        let transport = StubHubTransport()
        let service = makeService(transport: transport, relayInterval: .seconds(3600))
        let center = MobileLinkCenter(
            sidecar: sidecar, shares: FakeShareService(), macName: "Mac acme", ownerUser: { "_owner-acme" },
            keyring: try sidecar.testKeyring(),
            sleep: { _ in try? await Task.sleep(for: .seconds(3600)) } // swiftlint:disable:this trailing_closure
        )
        center.attach(to: service)
        await service.start()
        defer { service.stop() }
        await awaitHubCondition("the first relay cycle pulled") { transport.pulls == 1 }

        _ = try await center.issueCode()

        await awaitHubCondition("the open code wakes the relay loop") { transport.pulls == 2 }
        await center.closeLink(reason: .sheetClosed)
    }

    /// #66.1: a hub rebuilt while the QR is on screen keeps the run's link
    /// center: the code stays open and its link is not closed.
    func testAHubRebuiltWithTheQROpenKeepsTheCodeAndItsLink() async throws {
        let transport = StubHubTransport()
        let shares = FakeShareService()
        let appState = try makeAppState(transport: transport, shares: shares) {}
        defaults.set(true, forKey: Constants.mobileSyncEnabledKey)
        defer { stopAll(appState) }
        runInitWorkbenches(appState)
        let first = try XCTUnwrap(appState.mobileHub)
        await awaitHubCondition("the first hub runs") { first.status == .running }
        let center = try XCTUnwrap(first.linkCenter)
        let code = try await center.issueCode()
        shares.clearCalls()

        runInitWorkbenches(appState)
        let rebuilt = try XCTUnwrap(appState.mobileHub)
        await awaitHubCondition("the rebuilt hub runs") { rebuilt.status == .running }

        XCTAssertTrue(rebuilt.linkCenter === center)
        XCTAssertEqual(rebuilt.sharing, .available, "the rebuilt heartbeat says the link is open")
        XCTAssertEqual(center.openCode?.nonce, code.nonce)
        XCTAssertTrue(shares.isLinkOpen)
        XCTAssertFalse(shares.calls.contains("setPublicLink:false"), "\(shares.calls)")
        await center.closeLink(reason: .sheetClosed)
    }

    /// A hub rebuilt with no QR on screen still retries a pending sweep.
    func testAHubRebuiltWithoutAQRRetriesAPendingSweep() async throws {
        let shares = FakeShareService()
        let center = MobileLinkCenter(
            sidecar: sidecar, shares: shares, macName: "Mac acme", ownerUser: { "_owner-acme" },
            keyring: try sidecar.testKeyring(),
            sleep: { _ in try? await Task.sleep(for: .seconds(3600)) } // swiftlint:disable:this trailing_closure
        )
        try sidecar.setMetaValue("1", forKey: MobileLinkCenter.sweepPendingKey)
        center.attach(to: makeService(transport: StubHubTransport()))
        await awaitHubCondition("the first attach sweeps") {
            (try? sidecar.metaValue(forKey: MobileLinkCenter.sweepPendingKey)) == "0"
        }
        try sidecar.setMetaValue("1", forKey: MobileLinkCenter.sweepPendingKey)
        shares.clearCalls()

        center.attach(to: makeService(transport: StubHubTransport()))

        await awaitHubCondition("the rebuilt hub's attach sweeps") {
            (try? sidecar.metaValue(forKey: MobileLinkCenter.sweepPendingKey)) == "0"
        }
        XCTAssertTrue(shares.calls.contains("setPublicLink:false"))
    }

    func testWakeRelayWhileStoppedDoesNothing() async throws {
        let transport = StubHubTransport()
        let service = makeService(transport: transport, relayInterval: .seconds(3600))

        service.wakeRelay()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(transport.pulls, 0)
    }

    func testInitWorkbenchesRerunWithTheToggleOffDropsTheHub() async throws {
        let transport = StubHubTransport()
        let appState = try makeAppState(transport: transport) {}
        defaults.set(true, forKey: Constants.mobileSyncEnabledKey)
        defer { stopAll(appState) }
        runInitWorkbenches(appState)
        let first = try XCTUnwrap(appState.mobileHub)

        defaults.set(false, forKey: Constants.mobileSyncEnabledKey)
        runInitWorkbenches(appState)

        XCTAssertNil(appState.mobileHub)
        XCTAssertEqual(first.status, .off)
    }

    func testStorageFailureIsSurfacedAndBuildsNoHub() {
        let appState = AppState()
        appState.terminalCenter.makeProcess = { FakeTerminalSession() }
        appState.mobileSyncDefaults = defaults
        defaults.set(true, forKey: Constants.mobileSyncEnabledKey)
        appState.makeMobileHubStorage = { throw CocoaError(.fileWriteNoPermission) }
        defer { stopAll(appState) }

        runInitWorkbenches(appState)

        XCTAssertNil(appState.mobileHub)
        XCTAssertNotNil(appState.mobileHubInitError)
    }
}

/// Counts a hub companion's lifecycle calls.
final class CountingCompanion: HubCompanion, @unchecked Sendable {
    private let lock = NSLock()
    private var startCount = 0
    private var stopCount = 0

    var starts: Int { lock.withLock { startCount } }
    var stops: Int { lock.withLock { stopCount } }

    func start() { lock.withLock { startCount += 1 } }
    func stop() { lock.withLock { stopCount += 1 } }
}
