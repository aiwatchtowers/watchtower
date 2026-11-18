import GRDB
import XCTest
@testable import WatchtowerCore

/// A code root per bench folder (#2003): the home folder's root is today's
/// main root (same identity, same UserDefaults keys); another folder's root
/// has its own keys, and so do its worktrees.
final class CodeRootFolderTests: XCTestCase {
    private let workbench = Workbench(row: Row(["id": 7, "name": "acme", "folder_path": "/tmp/acme"]))
    private let home = WorkbenchFolder(id: 3, workbenchID: 7, folderPath: "/tmp/acme", position: 0, name: "acme")
    private let hub = WorkbenchFolder(id: 5, workbenchID: 7, folderPath: "/tmp/hub", position: 1, name: "hub")

    func testHomeRootKeepsTodaysDefaultsKey() {
        let root = CodeRoot(folder: home, homeFolderID: home.id)
        XCTAssertEqual(root, CodeRoot(main: workbench), "the home folder's root is the workbench's main root")
        XCTAssertNil(root.folderID)
        XCTAssertEqual(root.defaultsKeySuffix, "")
        XCTAssertEqual(root.filesCaption, "FILES")
    }

    func testSecondFolderRootHasItsOwnKey() {
        let root = CodeRoot(folder: hub, homeFolderID: home.id)
        XCTAssertEqual(root.folderID, 5)
        XCTAssertTrue(root.isMain, "a folder's own root is no worktree")
        XCTAssertEqual(root.folder.path, "/tmp/hub")
        XCTAssertEqual(root.defaultsKeySuffix, ".f5")
        XCTAssertNotEqual(root, CodeRoot(main: workbench))
    }

    func testWorktreeKeysCarryTheirFolder() {
        let tree = URL(fileURLWithPath: "/tmp/hub/.worktrees/a")
        let homeTree = CodeRoot(workbenchID: 7, worktree: tree)
        let hubTree = CodeRoot(workbenchID: 7, worktree: tree, folderID: hub.id)
        XCTAssertTrue(homeTree.defaultsKeySuffix.hasPrefix(".wt."), "a home worktree's key is unchanged")
        XCTAssertEqual(hubTree.defaultsKeySuffix, ".f5" + homeTree.defaultsKeySuffix)
        XCTAssertNotEqual(homeTree, hubTree)
        let homeByID = CodeRoot(workbenchID: 7, worktree: tree, folderID: home.id, homeFolderID: home.id)
        XCTAssertEqual(homeByID, homeTree, "a home-folder worktree named by its id keeps today's key")
        XCTAssertEqual(CodeRoot(workbenchID: 7, worktree: tree, folderID: hub.id, homeFolderID: home.id), hubTree)
    }
}
