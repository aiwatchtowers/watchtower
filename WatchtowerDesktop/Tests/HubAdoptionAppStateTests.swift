import Foundation
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerSync
import WatchtowerTestSupport

/// The hand-over's production wiring on `AppState` (go hub plan 3 Task 22):
/// `startMobile`'s retired branch, start and Retry, the Settings switch, the
/// Swift hub's stop, and the inert old toggle.
@MainActor
final class HubAdoptionAppStateTests: XCTestCase {
    private let suite = "WatchtowerDesktopTests.hubAdoptionAppState"
    private var defaults: UserDefaults!
    private var log: AdoptionLog!
    private var hub: FakeAdoptHub!
    private var keys: FakeHubKeyStore!

    override func setUp() async throws {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
        log = AdoptionLog()
        hub = FakeAdoptHub(log: log)
        keys = FakeHubKeyStore(log: log)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    private func retiredAppState() -> AppState {
        let appState = AppState { [:] }
        appState.mobileSyncDefaults = defaults
        appState.swiftHubRetired = true
        appState.hubAdoptionDeps = HubAdoptionDeps(runner: hub, keyStore: keys)
        return appState
    }

    func testStartMobileOnTheRetiredBranchStartsTheHandOverNotTheSwiftHub() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        hub.state = .init(swiftState: "absent")
        let appState = retiredAppState()

        appState.startMobile(dbPool: pool)

        let driver = try XCTUnwrap(appState.hubAdoption)
        let result = await driver.run()
        XCTAssertEqual(result, .notNeeded)
        XCTAssertNil(appState.mobileHub, "the Swift hub is never built on the retired branch")
        XCTAssertNil(MobileSettingsTab.handOver(driver.state), "with no Swift state nothing about the hand-over shows")
        appState.startMobile(dbPool: pool)
        XCTAssertTrue(appState.hubAdoption === driver, "once per app run")
    }

    func testRetryAndTheSettingsSwitch() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        hub.state = .init(hubID: "hub-acme", swiftState: "present")
        hub.adoptError = "locked"
        try keys.seed(hubID: "hub-acme")
        let appState = retiredAppState()
        appState.startMobile(dbPool: pool)
        let driver = try XCTUnwrap(appState.hubAdoption)
        _ = await driver.run()
        XCTAssertEqual(MobileSettingsTab.handOver(driver.state), .failed(reason: "locked"), "the failure takes the tab's place")

        hub.adoptError = nil
        appState.retryHubAdoption()
        let deadline = ContinuousClock.now + .seconds(5)
        while driver.state != .done, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(driver.state, .done)
        XCTAssertNil(MobileSettingsTab.handOver(driver.state), "done: the tab's own rows")
        XCTAssertEqual(MobileSettingsTab.handOver(.checking), .checking)
        XCTAssertNil(MobileSettingsTab.handOver(.idle))
        XCTAssertNil(MobileSettingsTab.handOver(nil))
    }

    func testTheOldToggleIsInertOnceRetired() throws {
        defaults.set(true, forKey: Constants.mobileSyncEnabledKey)
        let appState = retiredAppState()
        appState.setMobileSyncEnabled(false)
        XCTAssertTrue(defaults.bool(forKey: Constants.mobileSyncEnabledKey), "mobileSyncEnabled is never written back")
        defaults.removeObject(forKey: Constants.mobileSyncEnabledKey)
        appState.setMobileSyncEnabled(true)
        XCTAssertNil(defaults.object(forKey: Constants.mobileSyncEnabledKey))
        XCTAssertTrue(appState.mobileToggleRetired)
        let host = FakeMobileSettingsHost(enabled: true)
        host.mobileToggleRetired = true
        XCTAssertTrue(MobileSettingsViewModel(host: host, entitlementPresent: true, flavor: .default).toggleDisabled)
    }

    /// The live stop seam: the Swift hub an older launch left running stops,
    /// its storage closes, and nothing builds it again in this run.
    func testStopSwiftHubForAdoptionClosesTheStorageAndNeverRebuilds() async throws {
        defaults.set(true, forKey: Constants.mobileSyncEnabledKey)
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let sidecar = try HubSyncState.inMemoryPerHub()
        let appState = AppState { [:] }
        appState.mobileSyncDefaults = defaults
        var closed = 0
        appState.makeMobileHubStorage = {
            var storage = try MobileHubStorage.stub(transport: StubHubTransport(), sidecar: sidecar)
            storage.close = { closed += 1 }
            return storage
        }
        appState.initMobileHub(dbPool: pool)
        let hub = try XCTUnwrap(appState.mobileHub)
        await awaitHubCondition("the Swift hub runs") { hub.status == .running }

        let stopped = await appState.stopSwiftHubForAdoption()

        XCTAssertTrue(stopped)
        XCTAssertEqual(hub.status, .off)
        XCTAssertEqual(closed, 1, "its storage is closed before the stop returns")
        XCTAssertNil(appState.mobileHub)
        XCTAssertTrue(appState.swiftHubRetired)
        appState.setMobileSyncEnabled(true)
        appState.initMobileHub(dbPool: pool)
        XCTAssertNil(appState.mobileHub, "never two hubs: nothing builds the Swift hub again")
    }

    /// A close that keeps failing is tried twice, then reported (swift_busy).
    func testAStorageCloseErrorIsNotSwallowed() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let sidecar = try HubSyncState.inMemoryPerHub()
        defaults.set(true, forKey: Constants.mobileSyncEnabledKey)
        let appState = AppState { [:] }
        appState.mobileSyncDefaults = defaults
        var attempts = 0
        appState.makeMobileHubStorage = {
            var storage = try MobileHubStorage.stub(transport: StubHubTransport(), sidecar: sidecar)
            storage.close = {
                attempts += 1
                throw CocoaError(.fileWriteUnknown)
            }
            return storage
        }
        appState.initMobileHub(dbPool: pool)
        XCTAssertNotNil(appState.mobileHub)

        let stopped = await appState.stopSwiftHubForAdoption()

        XCTAssertFalse(stopped)
        XCTAssertEqual(attempts, 2, "retried once")
        XCTAssertNotNil(appState.mobileHubStorage, "kept for Retry")
    }

    /// `isMobileSyncEnabled` reads `hub status --json` (through HubCenter):
    /// off for no reason or switched off is off; off for another reason is
    /// still the owner's on.
    func testMobileSyncEnabledReadsTheHubStatus() {
        let table: [(WatchtowerCore.HubStatus, Bool)] = [
            (.init(state: "running"), true),
            (.init(state: "starting"), true),
            (.init(state: "paused", reason: "needs_relay"), true),
            (.init(state: "off", reason: "locked"), true),
            (.init(state: "off"), false),
            (.init(state: "off", reason: "disabled"), false),
            (.init(state: "off", reason: "policy_off"), false)
        ]
        for (status, on) in table {
            XCTAssertEqual(AppState.hubIsOn(status), on, "\(status)")
        }
    }

    func testSettingsAreTheStoredToggleReadOnce() throws {
        let appState = AppState { [:] }
        appState.mobileSyncDefaults = defaults
        XCTAssertEqual(appState.hubAdoptSettings(), HubAdoptSettings(enabled: false, startSessionAllows: [:]))
        defaults.set(true, forKey: Constants.mobileSyncEnabledKey)
        XCTAssertEqual(appState.hubAdoptSettings(), HubAdoptSettings(enabled: true, startSessionAllows: [:]))
    }
}
