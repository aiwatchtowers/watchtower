import XCTest
@testable import WatchtowerDesktop

final class HelpChatPolicyTests: XCTestCase {
    func testChatTabFocusesItsComposer() {
        XCTAssertEqual(HelpChatPolicy.action(destination: .chat, editorHasKeyboard: false), .focusChatComposer)
    }

    func testEditorKeepsItsComment() {
        XCTAssertEqual(HelpChatPolicy.action(destination: .workbench, editorHasKeyboard: true), .editorToggleComment)
    }

    func testAnyOtherTabTogglesThePopup() {
        for destination in [SidebarDestination.home, .targets, .workbench] {
            XCTAssertEqual(HelpChatPolicy.action(destination: destination, editorHasKeyboard: false), .togglePopup)
        }
    }
}
