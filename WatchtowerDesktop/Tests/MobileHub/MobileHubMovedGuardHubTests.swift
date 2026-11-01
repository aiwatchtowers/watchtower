import Foundation
import GRDB
import SwiftUI
import ViewInspector
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerSync
import WatchtowerTestSupport

/// The downgrade guard (go hub phase 3 Task 2, spec §12.1): once a newer
/// Watchtower left `MobileHub/MOVED` with `hub_impl=go`, this app's Swift hub
/// opens no `hubstate.db`, touches no Keychain item and starts no transport,
/// and Settings → Mobile shows one line instead of the toggle.
@MainActor
final class MobileHubMovedGuardHubTests: XCTestCase {
    private var dbPath: String!
    private var dbPool: DatabasePool!
    private var sidecar: HubSyncState!
    private var defaults: UserDefaults!
    private var hubDir: URL!
    private let suiteName = "WatchtowerDesktopTests.mobileHubMovedGuard"

    override func setUp() async throws {
        (dbPool, dbPath) = try TestDatabase.createPool()
        sidecar = try HubSyncState.inMemoryPerHub()
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
        hubDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileHubMovedGuardHubTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: hubDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: hubDir)
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = nil
        sidecar = nil
        dbPool = nil
        TestDatabase.cleanup(path: dbPath)
    }

    private func writeNote(_ text: String) throws {
        try Data(text.utf8).write(to: hubDir.appendingPathComponent(MobileHubMovedGuard.noteName))
    }

    /// An AppState over `hubDir` with the toggle on; `storageBuilds` counts
    /// every open of the hub's storage (sidecar, keychain, transport).
    /// `policy` holds the organization's managed preferences; `transport`
    /// is the stub every built storage uses.
    private func makeAppState(
        policy: PolicyBox = PolicyBox(),
        transport: StubHubTransport = StubHubTransport(),
        storageBuilds: @escaping () -> Void
    ) throws -> AppState {
        let appState = AppState { policy.raw }
        appState.terminalCenter.makeProcess = { FakeTerminalSession() }
        appState.mobileSyncDefaults = defaults
        appState.mobileHubDirectory = hubDir
        defaults.set(true, forKey: Constants.mobileSyncEnabledKey)
        let sidecar = try XCTUnwrap(self.sidecar)
        appState.makeMobileHubStorage = {
            storageBuilds()
            var storage = try MobileHubStorage.stub(transport: transport, sidecar: sidecar)
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

    func testMovedMessageIsDefinedInTheModel() throws {
        let host = FakeMobileSettingsHost(enabled: true)
        host.isMobileHubMoved = true
        let model = MobileSettingsViewModel(host: host, entitlementPresent: true)

        XCTAssertEqual(model.state, .movedToNewerApp(message: "Mobile is run by a newer Watchtower"))
        XCTAssertEqual(MobileSettingsViewModel.movedSectionTitle, "iPhone")

        let view = MobileSettingsView(model: model)
        XCTAssertNoThrow(try view.inspect().find(text: "Mobile is run by a newer Watchtower"))
        XCTAssertNoThrow(try view.inspect().find(text: "iPhone"))
        XCTAssertThrowsError(try view.inspect().find(ViewType.Toggle.self), "no toggle once Mobile moved")
        XCTAssertThrowsError(try view.inspect().find(text: "Sync with iPhone"))

        // The view takes the text from the model; it holds no copy of its own.
        let desktopRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewSource = try String(
            contentsOf: desktopRoot.appendingPathComponent("Sources/Views/Settings/MobileSettingsView.swift"), encoding: .utf8)
        XCTAssertFalse(viewSource.contains("\"Mobile is run by"))
        XCTAssertFalse(viewSource.contains("\"iPhone\""))
    }

    func testMovedNoteStopsTheSwiftHub() async throws {
        try writeNote("hub_impl=go\nmoved_to=/var/empty/.hub\n")

        // The live storage refuses before it creates or opens anything in the directory.
        XCTAssertThrowsError(try MobileHubStorage.live(directory: hubDir)) { error in
            XCTAssertTrue(error is MobileHubMovedGuard.Moved, "\(error)")
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: hubDir.path)
        XCTAssertEqual(left, [MobileHubMovedGuard.noteName], "no hubstate.db, no transport.db")

        var builds = 0
        let appState = try makeAppState { builds += 1 }
        defer { stopAll(appState) }
        runInitWorkbenches(appState)
        appState.setMobileSyncEnabled(true)

        XCTAssertEqual(builds, 0, "the hub's storage is never opened")
        XCTAssertNil(appState.mobileHub)
        XCTAssertNil(appState.mobileHubInitError, "moved is not an error")
        XCTAssertTrue(appState.isMobileHubMoved)
        XCTAssertEqual(MobileSettingsViewModel(host: appState, entitlementPresent: true).state,
                       .movedToNewerApp(message: MobileHubMovedGuard.message))

        // Turning it off still goes through.
        appState.setMobileSyncEnabled(false)
        XCTAssertFalse(defaults.bool(forKey: Constants.mobileSyncEnabledKey))
    }

    /// `MobileSync = off` with the toggle on would build the hub once to wipe
    /// the phone; moved, it builds nothing and the policy tick stops trying.
    func testMovedSkipsThePolicyOffWipe() throws {
        try writeNote("hub_impl=go\n")
        var builds = 0
        let appState = try makeAppState(policy: PolicyBox(["MobileSync": "off"])) { builds += 1 }
        defer { stopAll(appState) }
        appState.managedPolicy.refresh()
        XCTAssertEqual(appState.mobileSyncPolicy.current, "off")
        runInitWorkbenches(appState)
        appState.retryPolicyOffWipe()
        appState.managedPolicy.refresh()

        XCTAssertEqual(builds, 0, "no wipe build while moved")
        XCTAssertNil(appState.mobileHub)
    }

    /// Leaving `MobileSync = off` while moved starts nothing.
    func testLeavingPolicyOffWhileMovedStartsNothing() throws {
        try writeNote("hub_impl=go\n")
        var builds = 0
        let policy = PolicyBox(["MobileSync": "off"])
        let transport = StubHubTransport()
        let appState = try makeAppState(policy: policy, transport: transport) { builds += 1 }
        defer { stopAll(appState) }
        appState.managedPolicy.refresh()
        runInitWorkbenches(appState)

        policy.raw = [:]
        appState.managedPolicy.refresh()

        XCTAssertNotEqual(appState.mobileSyncPolicy.current, "off", "the policy left off")
        XCTAssertEqual(builds, 0)
        XCTAssertEqual(transport.starts, 0)
        XCTAssertNil(appState.mobileHub)
    }

    /// A hub built before the note appeared: turning the toggle off still
    /// disables it.
    func testToggleOffWhileMovedDisablesTheHub() async throws {
        var builds = 0
        let transport = StubHubTransport()
        let appState = try makeAppState(transport: transport) { builds += 1 }
        defer { stopAll(appState) }
        runInitWorkbenches(appState)
        let hub = try XCTUnwrap(appState.mobileHub)
        await awaitHubCondition("the hub runs") { hub.status == .running }
        try writeNote("hub_impl=go\n")
        appState.resolveMobileHubMoved()

        appState.setMobileSyncEnabled(false)

        XCTAssertEqual(hub.status, .off, "disable() ran")
        XCTAssertFalse(defaults.bool(forKey: Constants.mobileSyncEnabledKey))
        await awaitHubCondition("the zones are deleted") { transport.zoneDeletes > 0 }
    }

    /// A note that appears after launch refuses a later toggle-on.
    func testToggleOnAfterANoteAppearsIsRefused() throws {
        var builds = 0
        let appState = try makeAppState { builds += 1 }
        defaults.set(false, forKey: Constants.mobileSyncEnabledKey)
        defer { stopAll(appState) }
        runInitWorkbenches(appState)
        XCTAssertFalse(appState.isMobileHubMoved)
        try writeNote("hub_impl=go\n")

        appState.setMobileSyncEnabled(true)

        XCTAssertEqual(builds, 0)
        XCTAssertNil(appState.mobileHub)
        XCTAssertTrue(appState.isMobileHubMoved)
        XCTAssertFalse(defaults.bool(forKey: Constants.mobileSyncEnabledKey), "the toggle is not written")
    }

    /// The note is read at launch and at each hub build, not on a view read:
    /// a note that appears later shows after the next build.
    func testMovedIsResolvedAtTheHubBuild() throws {
        var builds = 0
        let appState = try makeAppState { builds += 1 }
        defer { stopAll(appState) }
        runInitWorkbenches(appState)
        XCTAssertEqual(builds, 1)
        try writeNote("hub_impl=go\n")
        XCTAssertFalse(appState.isMobileHubMoved, "not re-read on a view read")

        runInitWorkbenches(appState)
        XCTAssertTrue(appState.isMobileHubMoved)
        XCTAssertNil(appState.mobileHub, "the rebuilt hub is not started")
    }

    /// Moved with a hub still present: the Settings model polls nothing.
    func testMovedSettingsPollNothing() async throws {
        let fixture = try MobileSettingsFixture()
        await fixture.startHub()
        fixture.host.isMobileHubMoved = true
        final class Counter: @unchecked Sendable { var sleeps = 0 }
        let counter = Counter()
        let model = MobileSettingsViewModel(host: fixture.host, entitlementPresent: true) { _ in
            counter.sleeps += 1
            withUnsafeCurrentTask { $0?.cancel() } // a loop that ran ends after one pass
        }

        await model.refresh()
        XCTAssertNil(model.account, "no iCloud probe while moved")
        await model.windowVisibility(true)
        XCTAssertEqual(counter.sleeps, 0, "no polling loop while moved")
        XCTAssertNil(model.account)
        await fixture.tearDown()
    }

    func testANoteWithoutTheImplLineIsIgnored() async throws {
        try writeNote("moved_to=/var/empty/.hub\n")
        try assertTodaysBehaviour()
    }

    func testNoNoteKeepsTodaysBehaviour() async throws {
        try assertTodaysBehaviour()
    }

    private func assertTodaysBehaviour() throws {
        var builds = 0
        let appState = try makeAppState { builds += 1 }
        defer { stopAll(appState) }
        runInitWorkbenches(appState)

        XCTAssertEqual(builds, 1)
        XCTAssertNotNil(appState.mobileHub)
        XCTAssertFalse(appState.isMobileHubMoved)
        let model = MobileSettingsViewModel(host: appState, entitlementPresent: true)
        XCTAssertEqual(model.state, .regular)
        XCTAssertNoThrow(try MobileSettingsView(model: model).inspect().find(ViewType.Toggle.self))
    }
}

/// The managed preferences an AppState reads, changeable between ticks.
final class PolicyBox {
    var raw: [String: Any]
    init(_ raw: [String: Any] = [:]) { self.raw = raw }
}
