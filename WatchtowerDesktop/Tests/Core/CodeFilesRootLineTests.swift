import XCTest
@testable import WatchtowerCore

/// The FILES tree's root row (board #2017): the folder name always, the
/// branch, dirty dot and counters only from a usable git status.
final class CodeFilesRootLineTests: XCTestCase {
    private let root = CodeRoot(workbenchID: 7, worktree: URL(fileURLWithPath: "/tmp/acme/app"))

    func testDirtyBranchAheadAndBehind() {
        let line = CodeFilesRootLine(
            root: root, status: WorkbenchGitStatus(branch: "feature/pdf-export", ahead: 2, behind: 1, dirty: true)
        )
        XCTAssertEqual(line.name, "app")
        XCTAssertEqual(line.path, "/tmp/acme/app")
        XCTAssertEqual(line.branch, .init(text: "feature/pdf-export", style: .branch))
        XCTAssertTrue(line.dirty)
        XCTAssertEqual(line.counters, "↑2 ↓1")
        XCTAssertEqual(
            line.accessibilityLabel,
            "Folder app, branch feature/pdf-export, uncommitted changes, 2 ahead, 1 behind"
        )
    }

    func testCleanBranchLevelWithUpstreamShowsTheNameOnly() {
        let line = CodeFilesRootLine(root: root, status: WorkbenchGitStatus(branch: "main"))
        XCTAssertEqual(line.branch?.text, "main")
        XCTAssertFalse(line.dirty)
        XCTAssertNil(line.counters)
        XCTAssertEqual(line.accessibilityLabel, "Folder app, branch main")
    }

    func testDetachedHeadShowsTheHash() {
        let line = CodeFilesRootLine(root: root, status: WorkbenchGitStatus(detached: true, head: "b1c2d3e"))
        XCTAssertEqual(line.branch, .init(text: "b1c2d3e", style: .detachedHash))
        XCTAssertEqual(line.accessibilityLabel, "Folder app, detached at b1c2d3e")
    }

    func testLongBranchIsCappedLikeTheHeaderButton() {
        let name = String(repeating: "x", count: WorkbenchBranchPresentation.maxButtonNameLength + 8)
        let line = CodeFilesRootLine(root: root, status: WorkbenchGitStatus(branch: name))
        XCTAssertEqual(line.branch?.text, WorkbenchBranchPresentation.capped(name))
    }

    func testNoUsableGitStatusLeavesTheRightSideEmpty() {
        let unusable: [WorkbenchGitStatus?] = [
            nil,
            WorkbenchGitStatus(git: false, branch: "main", dirty: true),
            WorkbenchGitStatus(gitAvailable: false, branch: "main"),
            WorkbenchGitStatus(branch: "main", ahead: 3, statusOK: false)
        ]
        for status in unusable {
            let line = CodeFilesRootLine(root: root, status: status)
            XCTAssertNil(line.branch)
            XCTAssertFalse(line.dirty)
            XCTAssertNil(line.counters)
            XCTAssertEqual(line.accessibilityLabel, "Folder app")
        }
    }

    func testCopy() {
        XCTAssertEqual(CodeFilesRootLine.dirtyHelp, "Uncommitted changes")
        XCTAssertEqual(CodeFilesRootLine.emptyFolder, "This folder is empty.")
        XCTAssertEqual(CodeFilesRootLine.accessibilityValue(expanded: true), "Expanded")
        XCTAssertEqual(CodeFilesRootLine.accessibilityValue(expanded: false), "Collapsed")
    }
}

final class CodeFilesHeaderCopyTests: XCTestCase {
    func testCopy() {
        XCTAssertEqual(CodeFilesHeaderCopy.collapse, "Collapse files")
        XCTAssertEqual(CodeFilesHeaderCopy.expand, "Expand files")
        XCTAssertEqual(CodeFilesHeaderCopy.newEntry, "New file or folder")
        XCTAssertEqual(CodeFilesHeaderCopy.newFile, "New File…")
        XCTAssertEqual(CodeFilesHeaderCopy.newFolder, "New Folder…")
        XCTAssertEqual(CodeFilesHeaderCopy.collapseAll, "Collapse all folders")
        XCTAssertEqual(CodeFilesHeaderCopy.reload, "Reload the tree")
    }

    func testCaptionHelpNamesAWorktreeOnly() {
        let worktree = CodeRoot(workbenchID: 7, worktree: URL(fileURLWithPath: "/tmp/acme-wt/mobile-a"))
        XCTAssertEqual(
            CodeFilesHeaderCopy.captionHelp(worktree), "The worktree the session on screen works in:\n/tmp/acme-wt/mobile-a"
        )
        XCTAssertEqual(worktree.filesCaption, "FILES — ⑂ mobile-a")
    }
}
