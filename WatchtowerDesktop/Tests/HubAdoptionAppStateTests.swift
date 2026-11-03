import Foundation
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerSync
import WatchtowerTestSupport

/// The hand-over's production wiring on `AppState` (go hub plan 3 Task 22):
/// start once per run, Retry, the Settings switch and the settings it hands
/// over. This app runs no Swift hub (Task 24).
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

    private func handOverAppState() -> AppState {
        let appState = AppState { [:] }
        appState.mobileSyncDefaults = defaults
        appState.hubAdoptionDeps = HubAdoptionDeps(runner: hub, keyStore: keys)
        return appState
    }

    func testStartHubAdoptionStartsTheHandOverOncePerRun() async throws {
        hub.state = .init(swiftState: "absent")
        let appState = handOverAppState()

        appState.startHubAdoption()

        let driver = try XCTUnwrap(appState.hubAdoption)
        let result = await driver.run()
        XCTAssertEqual(result, .notNeeded)
        XCTAssertNil(MobileSettingsTab.handOver(driver.state), "with no Swift state nothing about the hand-over shows")
        appState.startHubAdoption()
        XCTAssertTrue(appState.hubAdoption === driver, "once per app run")
    }

    func testRetryAndTheSettingsSwitch() async throws {
        hub.state = .init(hubID: "hub-acme", swiftState: "present")
        hub.adoptError = "locked"
        try keys.seed(hubID: "hub-acme")
        let appState = handOverAppState()
        appState.startHubAdoption()
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

    func testSettingsAreTheStoredToggleReadOnce() throws {
        let appState = AppState { [:] }
        appState.mobileSyncDefaults = defaults
        XCTAssertEqual(appState.hubAdoptSettings(), HubAdoptSettings(enabled: false, startSessionAllows: [:]))
        defaults.set(true, forKey: Constants.mobileSyncEnabledKey)
        XCTAssertEqual(appState.hubAdoptSettings(), HubAdoptSettings(enabled: true, startSessionAllows: [:]))
    }
}
