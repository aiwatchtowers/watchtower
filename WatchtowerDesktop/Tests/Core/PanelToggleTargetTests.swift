import XCTest
@testable import WatchtowerCore

/// View → Show/Hide … (⌥⌘S): one item for the Workbench page's sessions
/// panel and the Inbox's folder rail.
final class PanelToggleTargetTests: XCTestCase {
    private typealias Target = PanelToggleTarget

    private func resolve(
        canToggle: Bool = false,
        panelShown: Bool = true,
        workbenchKey: Bool = false,
        inbox: Bool = false,
        railHidden: Bool = false
    ) -> Target? {
        Target.resolve(workbenchCanToggle: canToggle, workbenchPanelShown: panelShown,
                       workbenchWindowIsKey: workbenchKey, inboxOnScreen: inbox, inboxRailHidden: railHidden)
    }

    func testWorkbenchWinsWhenItHasTheKeys() {
        for inbox in [false, true] {
            XCTAssertEqual(resolve(canToggle: true, panelShown: true, workbenchKey: true, inbox: inbox),
                           .workbenchSessions(isShown: true))
            XCTAssertEqual(resolve(canToggle: true, panelShown: false, workbenchKey: true, inbox: inbox,
                                   railHidden: true),
                           .workbenchSessions(isShown: false))
        }
    }

    func testInboxWhenOnScreen() {
        XCTAssertEqual(resolve(inbox: true, railHidden: false), .inboxFolders(isShown: true))
        XCTAssertEqual(resolve(inbox: true, railHidden: true), .inboxFolders(isShown: false))
    }

    /// A workbench window under its Go to… palette (no keys for its panel)
    /// never flips the Inbox rail of the main window behind it.
    func testAKeyWorkbenchWindowWithoutTheKeysLeavesTheInboxAlone() {
        XCTAssertNil(resolve(canToggle: false, workbenchKey: true, inbox: true))
    }

    func testNilElsewhere() {
        for shown in [false, true] {
            XCTAssertNil(resolve(panelShown: shown, inbox: false, railHidden: shown))
        }
    }

    func testTitles() {
        XCTAssertEqual(Target.workbenchSessions(isShown: true).title, "Hide Sessions Panel")
        XCTAssertEqual(Target.workbenchSessions(isShown: false).title, "Show Sessions Panel")
        XCTAssertEqual(Target.inboxFolders(isShown: true).title, "Hide Inbox Folders")
        XCTAssertEqual(Target.inboxFolders(isShown: false).title, "Show Inbox Folders")
    }
}
