import XCTest
@testable import WatchtowerCore

/// View → Show/Hide … (⌥⌘S): one item for the Workbench page's sessions
/// panel and the Inbox's folder rail.
final class PanelToggleTargetTests: XCTestCase {
    private typealias Target = PanelToggleTarget

    func testWorkbenchWinsWhenItHasTheKeys() {
        for inbox in [false, true] {
            XCTAssertEqual(
                Target.resolve(workbenchCanToggle: true, workbenchPanelShown: true, inboxOnScreen: inbox,
                               inboxRailHidden: false),
                .workbenchSessions(isShown: true))
            XCTAssertEqual(
                Target.resolve(workbenchCanToggle: true, workbenchPanelShown: false, inboxOnScreen: inbox,
                               inboxRailHidden: true),
                .workbenchSessions(isShown: false))
        }
    }

    func testInboxWhenOnScreen() {
        XCTAssertEqual(
            Target.resolve(workbenchCanToggle: false, workbenchPanelShown: true, inboxOnScreen: true,
                           inboxRailHidden: false),
            .inboxFolders(isShown: true))
        XCTAssertEqual(
            Target.resolve(workbenchCanToggle: false, workbenchPanelShown: true, inboxOnScreen: true,
                           inboxRailHidden: true),
            .inboxFolders(isShown: false))
    }

    func testNilElsewhere() {
        for shown in [false, true] {
            XCTAssertNil(Target.resolve(workbenchCanToggle: false, workbenchPanelShown: shown, inboxOnScreen: false,
                                        inboxRailHidden: shown))
        }
    }

    func testTitles() {
        XCTAssertEqual(Target.workbenchSessions(isShown: true).title, "Hide Sessions Panel")
        XCTAssertEqual(Target.workbenchSessions(isShown: false).title, "Show Sessions Panel")
        XCTAssertEqual(Target.inboxFolders(isShown: true).title, "Hide Inbox Folders")
        XCTAssertEqual(Target.inboxFolders(isShown: false).title, "Show Inbox Folders")
    }
}
