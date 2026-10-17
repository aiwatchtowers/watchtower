import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

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

    /// A screen link from a chat answer opens a visible screen and closes the popup.
    @MainActor
    func testNavLinkOpensAVisibleScreenAndClosesThePopup() {
        let appState = AppState()
        appState.selectedDestination = .targets
        appState.isHelpChatShown = true
        appState.openNavLink(NavLink.url("home"))
        XCTAssertEqual(appState.selectedDestination, .home)
        XCTAssertFalse(appState.isHelpChatShown)
    }

    /// An unknown screen, or another scheme, does nothing.
    @MainActor
    func testNavLinkIgnoresUnknownScreensAndOtherSchemes() throws {
        let appState = AppState()
        appState.selectedDestination = .targets
        appState.isHelpChatShown = true
        appState.openNavLink(NavLink.url("nope"))
        appState.openNavLink(try XCTUnwrap(URL(string: "https://example.com/home")))
        XCTAssertEqual(appState.selectedDestination, .targets)
        XCTAssertTrue(appState.isHelpChatShown)
    }
}
