import SwiftUI
import ViewInspector
@testable import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerInterface
import XCTest

/// The tray's Pause Sync / Resume Sync (mobile Inbox spec §3, mockup §8):
/// the status line, the item's title and the tower command it sends.
@MainActor
final class TrayMenuContentTests: XCTestCase {
    private static func content(
        isRunning: Bool = true,
        syncPaused: Bool = false,
        syncPauseError: String? = nil,
        pauseAction: @escaping () -> Void = {},
        resumeAction: @escaping () -> Void = {}
    ) -> TrayMenuContent {
        TrayMenuContent(
            isRunning: isRunning, syncPaused: syncPaused, syncProgress: nil, daemonError: nil, cliStoreError: nil,
            voicesPendingCount: 0, updateVersion: nil, updateAction: {}, syncNowAction: {},
            syncPauseError: syncPauseError, pauseAction: pauseAction, resumeAction: resumeAction,
            quickCaptureAction: {}, voicesAction: {}, reviewVoicesAction: {}, trainVoicesAction: {},
            openAction: {}, settingsAction: {})
    }

    func testStatusLineReadsSyncPausedWhilePaused() throws {
        XCTAssertEqual(TowerText.syncPaused, "Sync paused")
        let now = Date()
        let iso = ISO8601DateFormatter()
        let syncing = SyncProgress(
            active: true, phase: "Messages", detail: "3/10 channels", messagesFetched: 12,
            startedAt: iso.string(from: now.addingTimeInterval(-60)), updatedAt: iso.string(from: now)
        )
        XCTAssertEqual(
            TrayMenuContent.statusText(isRunning: true, syncPaused: true, syncProgress: syncing, now: now),
            "Sync paused", "the pause wins over a cycle still finishing")
        XCTAssertEqual(
            TrayMenuContent.statusText(isRunning: true, syncPaused: false, syncProgress: syncing, now: now),
            "Syncing: Messages · 3/10 channels")
        XCTAssertEqual(TrayMenuContent.statusText(isRunning: true, syncPaused: false, syncProgress: nil),
                       "Daemon running · idle")
        XCTAssertEqual(TrayMenuContent.statusText(isRunning: false, syncPaused: true, syncProgress: nil),
                       "Sync daemon not running")
        XCTAssertNoThrow(try Self.content(syncPaused: true).inspect().find(text: "Sync paused"))
    }

    func testPauseItemBecomesResumeWhilePaused() throws {
        XCTAssertEqual(TowerText.pauseSync, "Pause Sync")
        XCTAssertEqual(TowerText.resumeSync, "Resume Sync")
        var paused = 0
        var resumed = 0
        let running = Self.content(pauseAction: { paused += 1 }, resumeAction: { resumed += 1 })
        try running.inspect().find(button: "Pause Sync").tap()
        XCTAssertThrowsError(try running.inspect().find(button: "Resume Sync"))

        let pausedView = Self.content(syncPaused: true, pauseAction: { paused += 1 }, resumeAction: { resumed += 1 })
        try pausedView.inspect().find(button: "Resume Sync").tap()
        XCTAssertThrowsError(try pausedView.inspect().find(button: "Pause Sync"))
        XCTAssertEqual([paused, resumed], [1, 1])
    }

    func testSyncNowIsOffWhilePaused() throws {
        XCTAssertTrue(try Self.content(syncPaused: true).inspect().find(button: "Sync Now").isDisabled())
        XCTAssertFalse(try Self.content().inspect().find(button: "Sync Now").isDisabled())
    }

    func testPauseIsOffWithoutADaemon() throws {
        let view = Self.content(isRunning: false)
        XCTAssertTrue(try view.inspect().find(button: "Pause Sync").isDisabled())
    }

    func testAFailedPauseShowsTheTowerSentence() throws {
        let view = Self.content(syncPauseError: "This workspace has no pause.")
        XCTAssertNoThrow(try view.inspect().find(text: "This workspace has no pause."))
    }

    func testPauseCallsTheTowerCommand() async throws {
        let fake = TowerFakeTransport()
        let appState = AppState.isolated()
        appState.towerClient = TowerClient(
            transport: fake, clock: ContinuousClock(), restartDaemon: nil, startDaemon: nil
        )

        await appState.pauseSync()

        let pause = try XCTUnwrap(fake.requests.first { $0.command == "sync.pause" })
        let params = try JSONDecoder().decode(PauseRequest.self, from: try XCTUnwrap(pause.params).data)
        XCTAssertFalse(params.requestID.isEmpty, "a guarded write carries its request_id")
        XCTAssertTrue(appState.syncPaused)
        XCTAssertNil(appState.syncPauseError)
    }

    func testRefreshReadsThePauseFromHello() async {
        let appState = AppState.isolated()
        appState.towerClient = TowerClient(
            transport: TowerFakeTransport(paused: true), clock: ContinuousClock(), restartDaemon: nil, startDaemon: nil
        )

        await appState.refreshSyncPaused()

        XCTAssertTrue(appState.syncPaused)
    }

    func testARefusedResumeKeepsThePauseAndShowsWhy() async {
        let fake = TowerFakeTransport(paused: true)
        fake.refuse(Refusal(code: .unsupported, sentence: "This workspace has no pause."))
        let appState = AppState.isolated()
        appState.syncPaused = true
        appState.towerClient = TowerClient(transport: fake, clock: ContinuousClock(), restartDaemon: nil, startDaemon: nil)

        await appState.resumeSync()

        XCTAssertTrue(appState.syncPaused)
        XCTAssertEqual(appState.syncPauseError, "This workspace has no pause.")
    }
}
