import XCTest
import ViewInspector
import SwiftUI
@testable import WatchtowerCore
@testable import WatchtowerDesktop

@MainActor
final class TrayMenuViewTests: XCTestCase {
    // `TrayMenuView` itself reads @Environment(AppState.self), which
    // ViewInspector (0.10.3, this repo) cannot populate without a real render
    // pass — it hits an uncatchable fatal error, not a throwable Swift error.
    // `TrayMenuContent` is the environment-free split that carries the actual
    // rendering (see RecordingIndicatorView/RecordingJobPill for the same
    // pattern), so it's what gets exercised here.
    func testMenuOffersOpenSettingsAndQuit() throws {
        let view = TrayMenuContent(
            isRunning: true, syncProgress: nil, daemonError: nil, cliStoreError: nil,
            syncNowAction: {}, quickCaptureAction: {}, openAction: {}, settingsAction: {})
        let openButton = try view.inspect().find(button: "Open Watchtower")
        let settingsButton = try view.inspect().find(button: "Settings…")
        let quitButton = try view.inspect().find(button: "Quit Watchtower")
        XCTAssertNotNil(openButton)
        XCTAssertNotNil(settingsButton)
        XCTAssertNotNil(quitButton)
    }

    /// New Voice Idea is the tray's entry point into quick capture — it must
    /// stay reachable and must fire the closure the environment-wired
    /// `TrayMenuView` wires to `AppState.openQuickCapture`.
    func testNewVoiceIdeaFiresQuickCaptureAction() throws {
        var fired = false
        let view = TrayMenuContent(
            isRunning: true, syncProgress: nil, daemonError: nil, cliStoreError: nil,
            syncNowAction: {}, quickCaptureAction: { fired = true }, openAction: {}, settingsAction: {})
        let button = try view.inspect().find(button: "New Voice Idea")
        try button.tap()
        XCTAssertTrue(fired)
    }

    func testStatusLineReflectsDaemonState() throws {
        XCTAssertEqual(
            TrayMenuContent.statusText(isRunning: false, syncProgress: nil),
            "Sync daemon not running")
        XCTAssertEqual(
            TrayMenuContent.statusText(isRunning: true, syncProgress: nil),
            "Daemon running · idle")
    }

    /// The point of the heartbeat: while a sync runs, the tray says which phase
    /// it is in — a live daemon between syncs must not claim to be syncing.
    func testStatusLineShowsLiveSyncPhase() throws {
        let now = Date()
        let syncing = Self.progress(active: true, phase: "Messages", detail: "34/105 channels", updated: now)
        XCTAssertEqual(
            TrayMenuContent.statusText(isRunning: true, syncProgress: syncing, now: now),
            "Syncing: Messages · 34/105 channels")

        let noDetail = Self.progress(active: true, phase: "Metadata", detail: nil, updated: now)
        XCTAssertEqual(
            TrayMenuContent.statusText(isRunning: true, syncProgress: noDetail, now: now),
            "Syncing: Metadata")
    }

    /// A daemon killed mid-sync leaves `active: true` behind forever; the tray
    /// must not keep claiming a sync is running because of a dead file.
    func testStaleHeartbeatDoesNotClaimSyncing() throws {
        let now = Date()
        let stale = Self.progress(
            active: true, phase: "Messages", detail: "34/105 channels",
            updated: now.addingTimeInterval(-SyncProgress.staleAfter - 1))
        XCTAssertEqual(
            TrayMenuContent.statusText(isRunning: true, syncProgress: stale, now: now),
            "Daemon running · idle")
    }

    func testSyncNowFiresActionAndNeedsARunningDaemon() throws {
        var fired = false
        let view = TrayMenuContent(
            isRunning: true, syncProgress: nil, daemonError: nil, cliStoreError: nil,
            syncNowAction: { fired = true }, quickCaptureAction: {}, openAction: {}, settingsAction: {})
        try view.inspect().find(button: "Sync Now").tap()
        XCTAssertTrue(fired)

        // Without a daemon there is nothing to ask: the CLI signals a process
        // that isn't there.
        let stopped = TrayMenuContent(
            isRunning: false, syncProgress: nil, daemonError: nil, cliStoreError: nil,
            syncNowAction: {}, quickCaptureAction: {}, openAction: {}, settingsAction: {})
        XCTAssertTrue(try stopped.inspect().find(button: "Sync Now").isDisabled())
    }

    /// Builds a heartbeat through the JSON decoder, so the test exercises the
    /// same field names and timestamp format the Go writer emits.
    private static func progress(active: Bool, phase: String, detail: String?, updated: Date) -> SyncProgress {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let detailJSON = detail.map { "\"detail\": \"\($0)\"," } ?? ""
        let json = """
        {
          "active": \(active),
          "phase": "\(phase)",
          \(detailJSON)
          "messages_fetched": 1200,
          "started_at": "\(formatter.string(from: updated.addingTimeInterval(-60)))",
          "updated_at": "\(formatter.string(from: updated))"
        }
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(SyncProgress.self, from: Data(json.utf8))
    }

    func testNoErrorLinesWhenNothingFailed() throws {
        let view = TrayMenuContent(
            isRunning: true, syncProgress: nil, daemonError: nil, cliStoreError: nil,
            syncNowAction: {}, quickCaptureAction: {}, openAction: {}, settingsAction: {})
        XCTAssertThrowsError(try view.inspect().find { text, _ in text.hasPrefix("CLI store:") })
        XCTAssertThrowsError(try view.inspect().find { text, _ in text.hasPrefix("Daemon:") })
    }

    /// The CLI store falling back to the bundle is the one thing the tray can
    /// say that no other always-available surface does.
    func testCLIStoreErrorIsRendered() throws {
        let view = TrayMenuContent(
            isRunning: false, syncProgress: nil, daemonError: nil, cliStoreError: "rename to /x failed: No such file",
            syncNowAction: {}, quickCaptureAction: {}, openAction: {}, settingsAction: {})
        XCTAssertNoThrow(try view.inspect().find(text: "CLI store: rename to /x failed: No such file"))
    }

    /// A daemon that could not be started must not fail silently in the one
    /// surface that is always on screen.
    func testDaemonErrorIsRendered() throws {
        let view = TrayMenuContent(
            isRunning: false, syncProgress: nil, daemonError: "Failed to start daemon (exit code 1)", cliStoreError: nil,
            syncNowAction: {}, quickCaptureAction: {}, openAction: {}, settingsAction: {})
        XCTAssertNoThrow(try view.inspect().find(text: "Daemon: Failed to start daemon (exit code 1)"))
    }
}
