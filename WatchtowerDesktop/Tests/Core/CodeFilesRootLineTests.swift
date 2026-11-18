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

    /// The caption is capped like the header's button; VoiceOver and the
    /// tooltip read the full name.
    func testLongBranchIsCappedOnScreenOnly() {
        let name = String(repeating: "x", count: WorkbenchBranchPresentation.maxButtonNameLength + 8)
        let line = CodeFilesRootLine(root: root, status: WorkbenchGitStatus(branch: name))
        XCTAssertEqual(line.branch?.text, WorkbenchBranchPresentation.capped(name))
        XCTAssertEqual(line.fullBranch, name)
        XCTAssertEqual(line.branchHelp, name)
        XCTAssertEqual(line.accessibilityLabel, "Folder app, branch \(name)")
    }

    /// A refresh that failed after a good read keeps the last status, marked
    /// out of date as the header marks it.
    func testAStatusTheLaterReadsCouldNotRefreshIsMarkedStale() {
        let line = CodeFilesRootLine(
            root: root, status: WorkbenchGitStatus(branch: "main", dirty: true), staleError: "git: index.lock exists"
        )
        XCTAssertEqual(line.branch?.text, "main")
        XCTAssertTrue(line.dirty)
        XCTAssertEqual(line.staleError, "git: index.lock exists")
        XCTAssertEqual(line.branchHelp, "main\nStatus may be out of date: git: index.lock exists")
        XCTAssertEqual(
            line.accessibilityLabel, "Folder app, branch main, uncommitted changes, status may be out of date"
        )
        XCTAssertEqual(CodeFilesRootLine(root: root, status: nil, staleError: "boom").staleError, nil)
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

final class CodeFilesCopyTests: XCTestCase {
    func testCopy() {
        XCTAssertEqual(CodeFilesCopy.collapse, "Collapse files")
        XCTAssertEqual(CodeFilesCopy.expand, "Expand files")
        XCTAssertEqual(CodeFilesCopy.newEntry, "New file or folder")
        XCTAssertEqual(CodeFilesCopy.newFile, "New File…")
        XCTAssertEqual(CodeFilesCopy.newFolder, "New Folder…")
        XCTAssertEqual(CodeFilesCopy.collapseAll, "Collapse all folders")
        XCTAssertEqual(CodeFilesCopy.reload, "Reload the tree")
        XCTAssertEqual(CodeFilesCopy.rename, "Rename…")
        XCTAssertEqual(CodeFilesCopy.moveToTrash, "Move to Trash")
        XCTAssertEqual(CodeFilesCopy.revealInFinder, "Reveal in Finder")
        XCTAssertEqual(CodeFilesCopy.copyRelativePath, "Copy Relative Path")
        XCTAssertEqual(CodeFilesCopy.gitUnavailable, "Git status unavailable — the marks may be out of date.")
        XCTAssertEqual(CodeFilesCopy.notCommitted, "Not committed")
        XCTAssertEqual(CodeFilesCopy.holdsChanges, "Holds uncommitted changes")
    }

    func testCaptionHelpNamesAWorktreeOnly() {
        let worktree = CodeRoot(workbenchID: 7, worktree: URL(fileURLWithPath: "/tmp/acme-wt/mobile-a"))
        XCTAssertEqual(
            CodeFilesCopy.captionHelp(worktree), "The worktree the session on screen works in:\n/tmp/acme-wt/mobile-a"
        )
        XCTAssertEqual(worktree.filesCaption, "FILES — ⑂ mobile-a")
    }
}
