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

    private func makeAppState(_ box: RawBox, transport: StubHubTransport) throws -> AppState {
        let appState = AppState { box.raw }
        appState.terminalCenter.makeProcess = { FakeTerminalSession() }
        appState.mobileSyncDefaults = defaults
        let sidecar = try XCTUnwrap(self.sidecar)
        appState.makeMobileHubStorage = {
            var storage = try MobileHubStorage.stub(transport: transport, sidecar: sidecar)
            storage.ownerUser = { "_owner-acme" }
            return storage
        }
        appState.initWorkbenches(
            dbPool: dbPool, cliRunner: FakeCLIRunner(), notifier: RecordingWorkbenchNotifier(),
            sessionNotifier: RecordingSessionNotifier()
        )
        return appState
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

    func testLooseningDoesNotStartHubWhenSettingOff() async throws {
        let box = RawBox()
        box.raw = ["MobileSync": "off"]
        let appState = try makeAppState(box, transport: StubHubTransport())
        defer { stopAll(appState) }
        appState.managedPolicy.refresh()
        XCTAssertNil(appState.mobileHub)

        box.raw = [:]
        appState.managedPolicy.refresh()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(appState.mobileHub, "loosening never turns the hub on by itself")
        XCTAssertFalse(appState.isMobileSyncEnabled)
        XCTAssertFalse(defaults.bool(forKey: Constants.mobileSyncEnabledKey))
    }
}
