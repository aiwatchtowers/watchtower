import XCTest
import SwiftUI
import GRDB
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The header's branch crumb, button and popover (#233).
@MainActor
final class WorkbenchBranchViewsTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var project: Workbench!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        project = try pool.write { d in
            let id = try TestDatabase.insertWorkbench(d)
            return try XCTUnwrap(WorkbenchQueries.fetch(d, id: id))
        }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private func makeVM() -> WorkbenchesViewModel {
        WorkbenchesViewModel(dbPool: pool, cli: nil)
    }

    // MARK: - Crumb

    func testNoGitShowsNeitherTheSeparatorNorTheButton() throws {
        let vm = makeVM()
        vm.gitStatus[project.id] = WorkbenchGitStatus(gitAvailable: false, git: false, note: "git is not available")
        let crumb = WorkbenchBranchCrumb(vm: vm, project: project)
        XCTAssertThrowsError(try crumb.inspect().find(text: "›"))
        XCTAssertThrowsError(try crumb.inspect().find(WorkbenchBranchButton.self))

        vm.gitStatus[project.id] = nil
        XCTAssertThrowsError(try WorkbenchBranchCrumb(vm: vm, project: project).inspect().find(text: "›"),
                             "an unknown status shows nothing either")
    }

    func testAWorkTreeShowsTheSeparatorAndTheButton() throws {
        let vm = makeVM()
        vm.gitStatus[project.id] = WorkbenchGitStatus(branch: "main", head: "a1b2c3d")
        let crumb = WorkbenchBranchCrumb(vm: vm, project: project)
        XCTAssertNoThrow(try crumb.inspect().find(text: "›"))
        XCTAssertNoThrow(try crumb.inspect().find(WorkbenchBranchButton.self))
    }

    // MARK: - Button

    func testButtonShowsTheBranchCountersAndDirtyDot() throws {
        let button = WorkbenchBranchButton(status: WorkbenchGitStatus(branch: "feature/x", ahead: 2, behind: 1, dirty: true)) {}
        XCTAssertNoThrow(try button.inspect().find(text: "feature/x"))
        XCTAssertNoThrow(try button.inspect().find(text: "↑2 ↓1"))
        XCTAssertNoThrow(try button.inspect().find(viewWithAccessibilityLabel: "Uncommitted changes"), "the orange dot")
    }

    func testCountersAndDotAreHiddenWhenLevelAndClean() throws {
        let button = WorkbenchBranchButton(status: WorkbenchGitStatus(branch: "main")) {}
        XCTAssertNoThrow(try button.inspect().find(text: "main"))
        XCTAssertThrowsError(try button.inspect().find(text: "↑0"))
        let anyCounter: (String, ViewType.Text.Attributes) -> Bool = { text, _ in
            text.contains("↑") || text.contains("↓")
        }
        XCTAssertThrowsError(try button.inspect().find(textWhere: anyCounter))
        XCTAssertThrowsError(try button.inspect().find(viewWithAccessibilityLabel: "Uncommitted changes"))
    }

    func testDetachedShowsTheShortHash() throws {
        let button = WorkbenchBranchButton(status: WorkbenchGitStatus(branch: "", detached: true, head: "a1b2c3d")) {}
        XCTAssertNoThrow(try button.inspect().find(text: "a1b2c3d"))
    }

    func testALongNameIsCappedAndTheTooltipHasItAll() throws {
        let long = "feature/" + String(repeating: "x", count: 60)
        let button = WorkbenchBranchButton(status: WorkbenchGitStatus(branch: long)) {}
        XCTAssertNoThrow(try button.inspect().find(text: WorkbenchBranchPresentation.capped(long)), "the label is capped")
        XCTAssertEqual(try button.inspect().find(ViewType.Button.self).help().string(), long)
    }

    // MARK: - Popover

    func testAWorktreeRowIsDisabledWithItsCaption() throws {
        let row = WorkbenchBranchRow(
            branch: WorkbenchGitBranch(name: "feature/x", worktree: "/tmp/wt/acme-x", worktreeName: "acme-x"),
            badge: nil, switching: nil
        ) {}
        XCTAssertNoThrow(try row.inspect().find(text: "open in worktree acme-x"))
        XCTAssertTrue(try row.inspect().find(ViewType.Button.self).isDisabled())

        let free = WorkbenchBranchRow(branch: WorkbenchGitBranch(name: "dev"), badge: nil, switching: nil) {}
        XCTAssertFalse(try free.inspect().find(ViewType.Button.self).isDisabled())
    }

    func testTappingARowSwitchesButNotTheCurrentOne() throws {
        var switched = 0
        try WorkbenchBranchRow(branch: WorkbenchGitBranch(name: "dev"), badge: nil, switching: nil) { switched += 1 }
            .inspect().find(ViewType.Button.self).tap()
        try WorkbenchBranchRow(branch: WorkbenchGitBranch(name: "main", current: true), badge: nil, switching: nil) { switched += 1 }
            .inspect().find(ViewType.Button.self).tap()
        XCTAssertEqual(switched, 1)
    }

    func testThePopoverListsBranchesWithTheBadge() throws {
        let vm = makeVM()
        vm.gitBranches[project.id] = WorkbenchGitBranches(current: "main", branches: [
            WorkbenchGitBranch(name: "main", current: true),
            WorkbenchGitBranch(name: "feature/x")
        ])
        vm.branchTargets[project.id] = ["feature/x": [WorkbenchBranchTarget(id: 12, title: "Login", status: "in_progress")]]
        let popover = WorkbenchBranchPopover(vm: vm, project: project)
        XCTAssertNoThrow(try popover.inspect().find(text: "LOCAL BRANCHES"))
        XCTAssertNoThrow(try popover.inspect().find(text: "feature/x"))
        XCTAssertNoThrow(try popover.inspect().find(text: "#12"))
        XCTAssertNoThrow(try popover.inspect().find(button: "New branch from current…"))
    }

    func testThePopoverShowsTheGitError() throws {
        let vm = makeVM()
        vm.gitBranches[project.id] = WorkbenchGitBranches()
        vm.gitErrors[project.id] = "git failed: fatal: bad object"
        let popover = WorkbenchBranchPopover(vm: vm, project: project)
        XCTAssertNoThrow(try popover.inspect().find(text: "git failed: fatal: bad object"))
        XCTAssertNoThrow(try popover.inspect().find(text: "No local branches yet."))
    }

    func testCopyBranchNameCallsTheViewModel() throws {
        let vm = makeVM()
        vm.gitStatus[project.id] = WorkbenchGitStatus(branch: "feature/x")
        var copied: [String] = []
        vm.copyToPasteboard = { copied.append($0) }
        try WorkbenchBranchPopover(vm: vm, project: project).inspect().find(button: "Copy branch name").tap()
        XCTAssertEqual(copied, ["feature/x"])
    }
}
