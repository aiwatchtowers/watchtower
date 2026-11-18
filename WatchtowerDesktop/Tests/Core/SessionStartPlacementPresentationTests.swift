import GRDB
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

    /// Spec 2026-11-18 §6.3/§6.4: Work on It on a target whose folder left
    /// the bench starts in home and says so.
    func testWorkOnItOnARemovedFolderSaysSo() {
        let folders = BenchFolders(folders: [
            WorkbenchFolder(id: 1, workbenchID: 1, folderPath: "/tmp/app", position: 0, name: "app"),
            WorkbenchFolder(id: 2, workbenchID: 1, folderPath: "/tmp/hub", position: 1,
                            removedAt: "2026-11-18T10:00:00Z", name: "hub")
        ], homeID: 1)
        let target = Target(row: Row(["id": 3, "text": "Export", "workbench_folder_id": 2]))
        let wanted = NewSessionFolder.folderID(for: .workOnIt(target: target), homeFolderID: 1)
        let start = NewSessionFolder.resolve(wanted, folders: folders)
        XCTAssertEqual(start.folderID, 1)
        XCTAssertEqual(start.notice, "Started in app: the target's folder hub left the bench.")
        XCTAssertEqual(SessionStartPlacementPresentation.folderLeftTheBench(home: "app", folder: "hub"),
                       "Started in app: the target's folder hub left the bench.")
    }

    func testSetupHint() {
        XCTAssertEqual(
            SessionStartPlacementPresentation.setupHint,
            "Runs in a new session worktree before the agent starts, after the .worktreeinclude paths are copied. Leave empty for none."
        )
    }
}
