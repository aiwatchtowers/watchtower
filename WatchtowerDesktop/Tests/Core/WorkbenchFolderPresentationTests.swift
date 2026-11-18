import XCTest
@testable import WatchtowerCore

/// FILES roots, Put on the Bench… and the switcher's folder list (#2003,
/// spec §6.1, §6.2, §6.14): every string verbatim.
final class WorkbenchFolderPresentationTests: XCTestCase {
    private typealias Copy = WorkbenchFolderPresentation
    private let home = "/Users/owner"

    private func folder(_ id: Int64, _ path: String, name: String? = nil, position: Int = 0) -> WorkbenchFolder {
        WorkbenchFolder(id: id, workbenchID: 7, folderPath: path, position: position,
                        name: name ?? URL(fileURLWithPath: path).lastPathComponent)
    }

    // MARK: Put on the Bench

    func testPutOnBenchTitle() { XCTAssertEqual(Copy.putOnBenchTitle, "Put on the Bench…") }

    func testPutOnBenchSubtitle() { XCTAssertEqual(Copy.putOnBenchSubtitle(bench: "acme"), "Add a folder to “acme”") }

    func testPanelTitle() { XCTAssertEqual(Copy.panelTitle, "Put on the Bench") }

    func testPanelPrompt() { XCTAssertEqual(Copy.panelPrompt, "Put on Bench") }

    func testTooltip() { XCTAssertEqual(Copy.tooltip, "Put on the Bench…") }

    func testIcon() { XCTAssertEqual(Copy.putOnBenchIcon, "plus.rectangle.on.folder") }

    func testHint() {
        XCTAssertEqual(Copy.hint, "Task touches another repo? Put on the Bench…")
        XCTAssertEqual(Copy.hintLead, "Task touches another repo?")
    }

    func testNoReason() {
        XCTAssertEqual(Copy.putOnBenchFailed(name: "billing", reason: Copy.noReason),
                       "Couldn’t put billing on the bench: the command gave no reason.")
    }

    func testPutOnBenchFailed() {
        XCTAssertEqual(Copy.putOnBenchFailed(name: "billing", reason: "the folder was moved or deleted."),
                       "Couldn’t put billing on the bench: the folder was moved or deleted.")
    }

    // MARK: Root rows

    func testContextMenu() {
        XCTAssertEqual(Copy.showInFinder, "Show in Finder")
        XCTAssertEqual(Copy.newSessionHere, "New Session Here")
        XCTAssertEqual(Copy.removeFromBench, "Remove from Bench…")
    }

    func testNotFoundActions() {
        XCTAssertEqual(Copy.locate, "Locate…")
        XCTAssertEqual(Copy.remove, "Remove")
        XCTAssertEqual(Copy.retry, "Retry")
    }

    func testFolderNotFound() {
        let state = Copy.rootState(exists: false, gitAvailable: true, isRepository: true, installed: true)
        XCTAssertEqual(state, .notFound)
        XCTAssertEqual(state.trailing, "Folder not found")
        XCTAssertEqual(state.emphasis, .error)
        XCTAssertTrue(state.namesAnError)
        XCTAssertEqual(Copy.notFoundDetail(path: "/Users/owner/code/hub", home: home), "~/code/hub was moved or deleted.")
        XCTAssertEqual(Copy.notFoundDetail(path: "/srv/hub", home: home), "/srv/hub was moved or deleted.")
    }

    func testGitUnavailable() {
        let state = Copy.rootState(exists: true, gitAvailable: false, isRepository: false, installed: true)
        XCTAssertEqual(state, .gitUnavailable)
        XCTAssertEqual(state.trailing, "Git unavailable")
        XCTAssertEqual(state.emphasis, .warning)
    }

    func testNotRepository() {
        let state = Copy.rootState(exists: true, gitAvailable: true, isRepository: false, installed: true)
        XCTAssertEqual(state, .notRepository)
        XCTAssertEqual(state.trailing, "Not a repository")
        XCTAssertEqual(state.emphasis, .secondary)
    }

    func testInstallMissingKeepsTheBranchLine() {
        let state = Copy.rootState(exists: true, gitAvailable: true, isRepository: true, installed: false)
        XCTAssertEqual(state, .installMissing)
        XCTAssertNil(state.trailing)
        XCTAssertEqual(Copy.installMissingHelp(name: "hub"),
                       "Watchtower is not installed in hub. Sessions can’t start there until it is — Retry sets it up again.")
    }

    func testNormal() {
        let state = Copy.rootState(exists: true, gitAvailable: true, isRepository: true, installed: true)
        XCTAssertEqual(state, .normal)
        XCTAssertNil(state.trailing)
        XCTAssertFalse(state.namesAnError)
    }

    func testStartRefusedNotInstalled() {
        XCTAssertEqual(Copy.startRefusedNotInstalled(name: "hub"), "Install Watchtower in hub first")
    }

    func testBranchLine() {
        XCTAssertEqual(Copy.branchLine(WorkbenchGitStatus(branch: "main")), "⎇ main")
        XCTAssertEqual(Copy.branchLine(WorkbenchGitStatus(branch: "feature/pdf-export", ahead: 2, dirty: true)),
                       "⎇ feature/pdf-export ● ↑2")
        XCTAssertEqual(Copy.branchLine(WorkbenchGitStatus(branch: "main", behind: 1)), "⎇ main ↓1")
        XCTAssertEqual(Copy.branchLine(WorkbenchGitStatus(branch: "main", ahead: 1, behind: 3)), "⎇ main ↑1 ↓3")
        XCTAssertEqual(Copy.branchLine(WorkbenchGitStatus(detached: true, head: "a1b2c3d")), "⎇ a1b2c3d")
    }

    func testRootNameIsTheStoredName() {
        let app = folder(1, "/Users/owner/code/app")
        let hub = folder(2, "/Users/owner/code/hub")
        let label = Copy.rootName(app, siblings: [app, hub], home: home)
        XCTAssertEqual(label.name, "app")
        XCTAssertNil(label.caption)
    }

    func testDuplicateRootNameGetsItsParentAsCaption() {
        let mine = folder(1, "/Users/owner/code/app")
        let theirs = folder(2, "/Users/owner/work/app", name: "work-app")
        let first = Copy.rootName(mine, siblings: [mine, theirs], home: home)
        let second = Copy.rootName(theirs, siblings: [mine, theirs], home: home)
        XCTAssertEqual(first.name, "app")
        XCTAssertEqual(first.caption, "~/code")
        XCTAssertEqual(second.name, "work-app")
        XCTAssertEqual(second.caption, "~/work")
    }

    // MARK: Switcher

    func testSwitcherFolders() {
        XCTAssertEqual(Copy.switcherFolders(["app", "hub", "site"]), "app, hub, site")
        XCTAssertNil(Copy.switcherFolders(["tools"]), "a one-folder bench lists nothing")
        XCTAssertNil(Copy.switcherFolders([]))
    }
}
