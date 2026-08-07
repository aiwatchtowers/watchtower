import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop

@MainActor
final class DaemonSettingsViewTests: XCTestCase {

    /// Fresh state (not running, no resolved binary): the tree shows "Stopped"
    /// and the missing-binary warning. Start/Stop buttons are gone — the
    /// lifecycle is app-owned. `DaemonSettingsContent` is the environment-free
    /// half (the `TrayMenuContent` split), so ViewInspector can render it.
    func testInitialStoppedState() throws {
        let view = DaemonSettingsContent(isRunning: false, binaryPath: nil, errorMessage: nil)
        let inspected = try view.inspect()

        XCTAssertNoThrow(try inspected.find(text: "Stopped"))
        XCTAssertThrowsError(try inspected.find(text: "Start Daemon"))
        XCTAssertNoThrow(try inspected.find(text: "watchtower binary not found"))
    }

    /// The "Daemon Status" section header is present.
    func testDaemonStatusSectionHeader() throws {
        let view = DaemonSettingsContent(isRunning: false, binaryPath: nil, errorMessage: nil)
        XCTAssertNoThrow(try view.inspect().find(text: "Daemon Status"))
    }

    /// No error → no "Error" section in the tree.
    func testErrorSectionHiddenByDefault() throws {
        let view = DaemonSettingsContent(isRunning: false, binaryPath: nil, errorMessage: nil)
        XCTAssertThrowsError(try view.inspect().find(text: "Error"))
    }

    /// A start/stop failure from the shared DaemonManager surfaces here.
    func testErrorSectionShowsDaemonError() throws {
        let view = DaemonSettingsContent(
            isRunning: false, binaryPath: "/usr/local/bin/watchtower",
            errorMessage: "Failed to start daemon (exit code 1)")
        let inspected = try view.inspect()
        XCTAssertNoThrow(try inspected.find(text: "Error"))
        XCTAssertNoThrow(try inspected.find(text: "Failed to start daemon (exit code 1)"))
    }
}
