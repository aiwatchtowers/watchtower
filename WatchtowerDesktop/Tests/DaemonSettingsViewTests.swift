import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop

@MainActor
final class DaemonSettingsViewTests: XCTestCase {

    /// На свежем DaemonManager (isRunning=false, path=nil) дерево показывает
    /// "Stopped" и предупреждение про отсутствующий бинарь.
    /// Start/Stop buttons removed (lifecycle is app-owned).
    /// `.onAppear` ViewInspector не триггерит, поэтому
    /// resolvePathIfNeeded()/checkStatus() не запускаются — состояние стабильно.
    func testInitialStoppedState() throws {
        let view = DaemonSettings()
        let inspected = try view.inspect()

        XCTAssertNoThrow(try inspected.find(text: "Stopped"))
        XCTAssertThrowsError(try inspected.find(text: "Start Daemon"))
        XCTAssertNoThrow(try inspected.find(text: "watchtower binary not found"))
    }

    /// Section header «Daemon Status» виден.
    func testDaemonStatusSectionHeader() throws {
        let view = DaemonSettings()
        XCTAssertNoThrow(try view.inspect().find(text: "Daemon Status"))
    }

    /// errorMessage по умолчанию nil → секции «Error» в дереве нет.
    func testErrorSectionHiddenByDefault() throws {
        let view = DaemonSettings()
        XCTAssertThrowsError(try view.inspect().find(text: "Error"))
    }
}
