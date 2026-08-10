import XCTest
import ViewInspector
import SwiftUI
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
            isRunning: true, daemonError: nil, cliStoreError: nil,
            openAction: {}, settingsAction: {})
        let openButton = try view.inspect().find(button: "Open Watchtower")
        let settingsButton = try view.inspect().find(button: "Settings…")
        let quitButton = try view.inspect().find(button: "Quit Watchtower")
        XCTAssertNotNil(openButton)
        XCTAssertNotNil(settingsButton)
        XCTAssertNotNil(quitButton)
    }

    func testStatusLineReflectsDaemonState() throws {
        XCTAssertEqual(TrayMenuContent.statusText(isRunning: true), "Syncing in background")
        XCTAssertEqual(TrayMenuContent.statusText(isRunning: false), "Sync daemon not running")
    }

    func testNoErrorLinesWhenNothingFailed() throws {
        let view = TrayMenuContent(
            isRunning: true, daemonError: nil, cliStoreError: nil,
            openAction: {}, settingsAction: {})
        XCTAssertThrowsError(try view.inspect().find { text, _ in text.hasPrefix("CLI store:") })
        XCTAssertThrowsError(try view.inspect().find { text, _ in text.hasPrefix("Daemon:") })
    }

    /// The CLI store falling back to the bundle is the one thing the tray can
    /// say that no other always-available surface does.
    func testCLIStoreErrorIsRendered() throws {
        let view = TrayMenuContent(
            isRunning: false, daemonError: nil, cliStoreError: "rename to /x failed: No such file",
            openAction: {}, settingsAction: {})
        XCTAssertNoThrow(try view.inspect().find(text: "CLI store: rename to /x failed: No such file"))
    }

    /// A daemon that could not be started must not fail silently in the one
    /// surface that is always on screen.
    func testDaemonErrorIsRendered() throws {
        let view = TrayMenuContent(
            isRunning: false, daemonError: "Failed to start daemon (exit code 1)", cliStoreError: nil,
            openAction: {}, settingsAction: {})
        XCTAssertNoThrow(try view.inspect().find(text: "Daemon: Failed to start daemon (exit code 1)"))
    }
}
