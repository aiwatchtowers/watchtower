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
    func testMenuOffersOpenAndQuit() throws {
        let view = TrayMenuContent(isRunning: true, cliStoreError: nil) {}
        let openButton = try view.inspect().find(button: "Open Watchtower")
        let quitButton = try view.inspect().find(button: "Quit Watchtower")
        XCTAssertNotNil(openButton)
        XCTAssertNotNil(quitButton)
    }

    func testStatusLineReflectsDaemonState() throws {
        XCTAssertEqual(TrayMenuContent.statusText(isRunning: true), "Syncing in background")
        XCTAssertEqual(TrayMenuContent.statusText(isRunning: false), "Sync daemon not running")
    }
}
