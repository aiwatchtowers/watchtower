import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerSync
import WatchtowerTestSupport

/// `MobileSync` on the hub (#608): `off` outvotes the owner's toggle and
/// stops the hub without rewriting the toggle; loosening never starts a hub
/// the owner left off (POLICY-03, Review Focus 5).
@MainActor
final class MobileHubPolicyTests: XCTestCase {
    private var dbPath: String!
    private var dbPool: DatabasePool!
    private var sidecar: HubSyncState!
    private var defaults: UserDefaults!
    private let suiteName = "WatchtowerDesktopTests.mobileHubPolicy"
    private final class RawBox { var raw: [String: Any] = [:] }

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

    private func makeAppState(_ box: RawBox, transport: StubHubTransport, initialize: Bool = true) throws -> AppState {
        let appState = AppState { box.raw }
        appState.terminalCenter.makeProcess = { FakeTerminalSession() }
        appState.mobileSyncDefaults = defaults
        let sidecar = try XCTUnwrap(self.sidecar)
        appState.makeMobileHubStorage = {
            var storage = try MobileHubStorage.stub(transport: transport, sidecar: sidecar)
            storage.ownerUser = { "_owner-acme" }
            return storage
        }
        if initialize { runInitWorkbenches(appState) }
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

    func testOffStopsHubKeepsSetting() async throws {
        let box = RawBox()
        defaults.set(true, forKey: Constants.mobileSyncEnabledKey)
        let appState = try makeAppState(box, transport: StubHubTransport())
        defer { stopAll(appState) }
        let hub = try XCTUnwrap(appState.mobileHub)
        await awaitHubCondition("the hub runs") { hub.status == .running }

        box.raw = ["MobileSync": "off"]
        appState.managedPolicy.refresh()

        XCTAssertEqual(hub.status, .off, "off stops the hub")
        XCTAssertFalse(appState.isMobileSyncEnabled)
        XCTAssertTrue(appState.mobileSyncLockedByPolicy)
        XCTAssertTrue(defaults.bool(forKey: Constants.mobileSyncEnabledKey), "the owner's toggle is untouched")

        box.raw = [:]
        appState.managedPolicy.refresh()
        await awaitHubCondition("the profile removed: the owner's toggle was on, the hub runs again") {
            appState.mobileHub?.status == .running
        }
    }

    /// A profile installed while the app was quit: the first refresh sees
    /// `off` before the workbench state exists, the owner's toggle is on.
    /// The hub is built once and disabled (the phone is wiped), nothing runs.
    func testOffAtLaunchWithToggleOnWipesOnceAndRunsNothing() async throws {
        let box = RawBox()
        box.raw = ["MobileSync": "off"]
        defaults.set(true, forKey: Constants.mobileSyncEnabledKey)
        let transport = StubHubTransport()
        let appState = try makeAppState(box, transport: transport, initialize: false)
        defer { stopAll(appState) }
        appState.managedPolicy.refresh()
        runInitWorkbenches(appState)

        XCTAssertFalse(appState.isMobileSyncEnabled)
        let hub = try XCTUnwrap(appState.mobileHub, "built once, to wipe")
        await awaitHubCondition("the zones are deleted") { transport.zoneDeletes > 0 }
        XCTAssertEqual(hub.status, .off)
        XCTAssertEqual(transport.starts, 0, "the hub never ran")
        XCTAssertTrue(defaults.bool(forKey: Constants.mobileSyncEnabledKey), "the owner's toggle is untouched")

        runInitWorkbenches(appState)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(transport.zoneDeletes, 1, "once per run")
    }

    /// `off` → `workbench_only` with the toggle on: the hub starts, and
    /// publishes only the workbench kinds.
    func testOffToWorkbenchOnlyStartsTheHubRestricted() async throws {
        let box = RawBox()
        box.raw = ["MobileSync": "off"]
        defaults.set(true, forKey: Constants.mobileSyncEnabledKey)
        let appState = try makeAppState(box, transport: StubHubTransport(), initialize: false)
        defer { stopAll(appState) }
        appState.managedPolicy.refresh()
        runInitWorkbenches(appState)

        box.raw = ["MobileSync": "workbench_only"]
        appState.managedPolicy.refresh()
        await awaitHubCondition("the hub runs again") { appState.mobileHub?.status == .running }
        XCTAssertEqual(appState.mobileSyncPolicy.allowedKinds, SliceKind.workbenchOnly)
    }

    /// Loosening with the owner's toggle off: no hub is built or started,
    /// nothing is wiped, the toggle stays off.
    func testLooseningDoesNotStartHubWhenSettingOff() async throws {
        let box = RawBox()
        box.raw = ["MobileSync": "off"]
        let transport = StubHubTransport()
        let appState = try makeAppState(box, transport: transport, initialize: false)
        defer { stopAll(appState) }
        appState.managedPolicy.refresh()
        runInitWorkbenches(appState)
        XCTAssertNil(appState.mobileHub, "toggle off: nothing to wipe, no hub built")

        box.raw = [:]
        appState.managedPolicy.refresh()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(appState.mobileHub, "loosening never turns the hub on by itself")
        XCTAssertEqual(transport.starts, 0)
        XCTAssertEqual(transport.zoneDeletes, 0)
        XCTAssertFalse(defaults.bool(forKey: Constants.mobileSyncEnabledKey))
    }

    /// The wipe under `off` whose storage could not be built is tried again
    /// at the next policy tick.
    func testPolicyOffWipeRetriesOnTheNextTick() async throws {
        let box = RawBox()
        box.raw = ["MobileSync": "off"]
        defaults.set(true, forKey: Constants.mobileSyncEnabledKey)
        let transport = StubHubTransport()
        let appState = try makeAppState(box, transport: transport, initialize: false)
        defer { stopAll(appState) }
        let sidecar = try XCTUnwrap(self.sidecar)
        var failures = 1
        appState.makeMobileHubStorage = {
            if failures > 0 {
                failures -= 1
                throw CocoaError(.fileReadUnknown)
            }
            var storage = try MobileHubStorage.stub(transport: transport, sidecar: sidecar)
            storage.ownerUser = { "_owner-acme" }
            return storage
        }
        appState.managedPolicy.refresh()
        runInitWorkbenches(appState)
        XCTAssertNil(appState.mobileHub, "the first build failed")
        XCTAssertEqual(transport.zoneDeletes, 0)

        appState.managedPolicy.refresh() // the next tick, nothing changed
        await awaitHubCondition("the wipe ran on the retry") { transport.zoneDeletes > 0 }
        XCTAssertEqual(appState.mobileHub?.status, .off)
    }

    /// `off` cannot be turned on from the toggle path, whatever the view shows.
    func testSetMobileSyncEnabledRefusesUnderOff() async throws {
        let box = RawBox()
        box.raw = ["MobileSync": "off"]
        let transport = StubHubTransport()
        let appState = try makeAppState(box, transport: transport, initialize: false)
        defer { stopAll(appState) }
        appState.managedPolicy.refresh()
        runInitWorkbenches(appState)

        appState.setMobileSyncEnabled(true)
        XCTAssertFalse(defaults.bool(forKey: Constants.mobileSyncEnabledKey), "the toggle is not written")
        XCTAssertNil(appState.mobileHub)
        XCTAssertEqual(transport.starts, 0)
    }

    // MARK: - Production branch (the Swift hub retired, go hub plan 3 Task 22)

    /// The app run as shipped: a Swift state waits for the hand-over, the
    /// owner's toggle is on and `MobileSync = off`. The Swift hub is built
    /// only to be disabled (what it published is removed), never started;
    /// the toggle is kept.
    func testRetiredOffWipesAPendingSwiftStateAndKeepsSetting() async throws {
        let box = RawBox()
        box.raw = ["MobileSync": "off"]
        defaults.set(true, forKey: Constants.mobileSyncEnabledKey)
        let transport = StubHubTransport()
        let appState = try makeAppState(box, transport: transport, initialize: false)
        defer { stopAll(appState) }
        let adoption = retire(appState)
        appState.managedPolicy.refresh()
        runInitWorkbenches(appState)
        let result = try await XCTUnwrap(appState.hubAdoption).run()

        XCTAssertEqual(result, .failed(reason: "no_keys"), "the stub has no keys: the hand-over stops there")
        await awaitHubCondition("the Swift hub's zones are deleted") { transport.zoneDeletes > 0 }
        XCTAssertEqual(transport.starts, 0, "built only to wipe, never started")
        XCTAssertFalse(appState.isMobileSyncEnabled)
        XCTAssertTrue(defaults.bool(forKey: Constants.mobileSyncEnabledKey), "the owner's toggle is untouched")
        XCTAssertEqual(adoption.applied, [], "nothing adopted")
    }

    /// The same run, the profile removed: loosening never starts the Swift
    /// hub (the Go hub owns Mobile); with the toggle off nothing is built.
    func testRetiredLooseningNeverStartsTheSwiftHub() async throws {
        let box = RawBox()
        box.raw = ["MobileSync": "off"]
        defaults.set(true, forKey: Constants.mobileSyncEnabledKey)
        let transport = StubHubTransport()
        let appState = try makeAppState(box, transport: transport, initialize: false)
        defer { stopAll(appState) }
        _ = retire(appState)
        appState.managedPolicy.refresh()
        runInitWorkbenches(appState)
        _ = try await XCTUnwrap(appState.hubAdoption).run()

        box.raw = [:]
        appState.managedPolicy.refresh()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(transport.starts, 0, "loosening never turns the Swift hub on")
        XCTAssertNotEqual(appState.mobileHub?.status, .running)
        XCTAssertTrue(defaults.bool(forKey: Constants.mobileSyncEnabledKey))
    }

    func testRetiredWithTheToggleOffNothingIsBuilt() async throws {
        let box = RawBox()
        box.raw = ["MobileSync": "off"]
        let transport = StubHubTransport()
        let appState = try makeAppState(box, transport: transport, initialize: false)
        defer { stopAll(appState) }
        _ = retire(appState)
        appState.managedPolicy.refresh()
        runInitWorkbenches(appState)
        _ = try await XCTUnwrap(appState.hubAdoption).run()
        box.raw = [:]
        appState.managedPolicy.refresh()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(appState.mobileHub, "toggle off: nothing wiped, nothing built")
        XCTAssertEqual(transport.starts + transport.zoneDeletes, 0)
    }

    /// The production setting: the Swift hub retired, the hand-over over a
    /// fake Go hub that reports a Swift state waiting (no keys in the stub).
    private func retire(_ appState: AppState) -> FakeAdoptHub {
        let log = AdoptionLog()
        let adoption = FakeAdoptHub(log: log)
        adoption.state = .init(hubID: "hub-acme", swiftState: "present")
        appState.swiftHubRetired = true
        appState.hubAdoptionDeps = HubAdoptionDeps(runner: adoption, keyStore: FakeHubKeyStore(log: log))
        return adoption
    }
}
