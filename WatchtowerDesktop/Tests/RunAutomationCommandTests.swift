import XCTest
import SwiftUI
@testable import WatchtowerDesktop

/// "Run Automation…" (spec §12.7, owner ruling 2026-10-15): one key
/// combination, ⌃⌘R, doing the same thing on every tab.
final class RunAutomationCommandTests: XCTestCase {
    private let tabs: [SidebarDestination?] = [.workbench, .chat, .catchUp, .automations, .home, nil]

    func testShortcutIsControlCommandR() {
        XCTAssertEqual(RunAutomationCommand.key, "r")
        XCTAssertEqual(RunAutomationCommand.modifiers, [.control, .command])
        XCTAssertEqual(RunAutomationCommand.title, "Run Automation…")
    }

    func testSameTargetOnEveryTab() {
        for tab in tabs {
            XCTAssertEqual(RunAutomationCommand.target(hasCenter: true, selected: tab),
                           .runAutomationPalette, String(describing: tab))
        }
        XCTAssertTrue(RunAutomationCommand.isAvailable(hasCenter: true))
    }

    func testUnavailableWithoutCenter() {
        for tab in tabs {
            XCTAssertEqual(RunAutomationCommand.target(hasCenter: false, selected: tab),
                           .unavailable, String(describing: tab))
        }
        XCTAssertFalse(RunAutomationCommand.isAvailable(hasCenter: false))
    }
}
