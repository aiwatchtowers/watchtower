import XCTest
@testable import WatchtowerCore

final class SessionStartPlacementPresentationTests: XCTestCase {
    func testMenuTitles() {
        XCTAssertEqual(SessionStartPlacementPresentation.menuTitle(.auto), "Automatic")
        XCTAssertEqual(SessionStartPlacementPresentation.menuTitle(.folder), "In This Folder")
        XCTAssertEqual(SessionStartPlacementPresentation.menuTitle(.worktree), "In Its Own Worktree")
    }

    func testDisabledHelpNamesTheReason() {
        XCTAssertEqual(
            SessionStartPlacementPresentation.disabledHelp("git is not available."),
            "A worktree cannot be made: git is not available."
        )
    }

    func testSetupHint() {
        XCTAssertEqual(
            SessionStartPlacementPresentation.setupHint,
            "Runs in a new session worktree before the agent starts, after the .worktreeinclude paths are copied. Leave empty for none."
        )
    }
}
