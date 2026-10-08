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
        sidecar = try HubSyncState.inMemory()
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
        isEnabled: @escaping () -> Bool = { true }
    ) -> MobileHubService {
        let publisher = SlicePublisher(
            dbPool: dbPool, state: sidecar, transport: transport, sources: [],
            timing: .init(tick: .milliseconds(20), fastWindow: .milliseconds(10), fastSpacing: .milliseconds(10))
        )
        let processor = RelayProcessor(
            transport: transport, sidecar: sidecar, dispatcher: MobileHubCommandDispatcher(), hubID: "hub-acme"
        )
        return MobileHubService(
            transport: transport, publisher: publisher, processor: processor, sidecar: sidecar,
            relayIdleInterval: relayInterval, relayActiveInterval: relayInterval,
            availabilityReprobeInterval: .milliseconds(20), isEnabled: isEnabled
        )
    }

    private func appliedEchoes(_ transport: StubHubTransport) throws -> [ActionRequestPayload] {
        try transport.saved
            .filter { $0.record.zone == .relay }
            .map { try decodeAction($0.record) }
            .filter { $0.status == .applied }
    }

    // MARK: - Service

    func testPinnedRelayCadence() {
        XCTAssertEqual(MobileHubService.defaultRelayIdleInterval, .seconds(30))
        XCTAssertEqual(MobileHubService.defaultRelayActiveInterval, .seconds(3))
        XCTAssertEqual(MobileHubService.activityWindow, 300)
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

        try await awaitHubCondition("500 probes are echoed in one relay cycle", timeout: 20) {
            try appliedEchoes(transport).count >= 500
        }
        let echoed = try appliedEchoes(transport).map(\.id)
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

    func testAccountResetWipesTheSyncState() async throws {
        try sidecar.setHash("hash", for: "workbench-1")
        try sidecar.markRelayDone("action-1", outcome: "applied", at: Date())
        let transport = StubHubTransport()
        let service = makeService(transport: transport)
        await service.start()
        defer { service.stop() }

        transport.fireAccountReset()

        XCTAssertTrue(try sidecar.hashes(forKind: .workbench).isEmpty)
        XCTAssertNil(try sidecar.relayPhase("action-1"))
    }

    func testRejectedDataRecordClearsItsHash() async throws {
        try sidecar.setHash("hash", for: "workbench-1")
        try sidecar.setHash("hash", for: "workbench-2")
        let transport = StubHubTransport()
        let service = makeService(transport: transport)
        await service.start()
        defer { service.stop() }

        transport.fireRecordRejected("workbench-1", zone: .data)

        XCTAssertEqual(Set(try sidecar.hashes(forKind: .workbench).keys), ["workbench-2"])
    }

    // MARK: - AppState wiring

    /// An AppState whose hub storage is a stub; counts how often it is built.
    private func makeAppState(transport: StubHubTransport, storageBuilds: @escaping () -> Void) throws -> AppState {
        let appState = AppState()
        appState.terminalCenter.makeProcess = { FakeTerminalSession() }
        appState.mobileSyncDefaults = defaults
        let sidecar = try XCTUnwrap(self.sidecar)
        appState.makeMobileHubStorage = {
            storageBuilds()
            return MobileHubStorage(transport: transport, sidecar: sidecar)
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
