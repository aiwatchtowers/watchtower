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
    private func makeAppState(storageBuilds: @escaping () -> Void) throws -> AppState {
        let appState = AppState()
        appState.terminalCenter.makeProcess = { FakeTerminalSession() }
        appState.mobileSyncDefaults = defaults
        appState.mobileHubDirectory = hubDir
        defaults.set(true, forKey: Constants.mobileSyncEnabledKey)
        let sidecar = try XCTUnwrap(self.sidecar)
        appState.makeMobileHubStorage = {
            storageBuilds()
            var storage = try MobileHubStorage.stub(transport: StubHubTransport(), sidecar: sidecar)
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
        appState.retryPolicyOffWipe()

        XCTAssertEqual(builds, 0, "the hub's storage is never opened")
        XCTAssertNil(appState.mobileHub)
        XCTAssertNil(appState.mobileHubInitError, "moved is not an error")
        XCTAssertTrue(appState.isMobileHubMoved)
        let model = MobileSettingsViewModel(host: appState, entitlementPresent: true)
        XCTAssertEqual(model.state, .movedToNewerApp(message: MobileHubMovedGuard.message))

        // The polled parts read nothing while moved.
        await model.refresh()
        XCTAssertNil(model.account)
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
