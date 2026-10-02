import XCTest
@testable import WatchtowerCore

final class WorkbenchBranchPresentationTests: XCTestCase {
    private typealias Pres = WorkbenchBranchPresentation

    func testDisplayPathShortensHomeOnly() {
        XCTAssertEqual(Pres.displayPath("/Users/owner/Projects/acme", home: "/Users/owner"), "~/Projects/acme")
        XCTAssertEqual(Pres.displayPath("/Users/owner/Projects/acme", home: "/Users/owner/"), "~/Projects/acme")
        XCTAssertEqual(Pres.displayPath("/Users/owner", home: "/Users/owner"), "~")
        XCTAssertEqual(Pres.displayPath("/Users/ownerx/acme", home: "/Users/owner"), "/Users/ownerx/acme",
                       "a sibling with the same prefix is not inside home")
        XCTAssertEqual(Pres.displayPath("/tmp/acme", home: "/Users/owner"), "/tmp/acme")
        XCTAssertEqual(Pres.displayPath("/tmp/acme", home: ""), "/tmp/acme")
    }

    func testLabelForABranchADetachedHeadAndAnUnbornBranch() {
        XCTAssertEqual(Pres.label(WorkbenchGitStatus(branch: "feature/x", head: "a1b2c3d")),
                       Pres.Label(text: "feature/x", style: .branch))
        XCTAssertEqual(Pres.label(WorkbenchGitStatus(branch: "", detached: true, head: "a1b2c3d")),
                       Pres.Label(text: "a1b2c3d", style: .detachedHash))
        XCTAssertEqual(Pres.label(WorkbenchGitStatus(branch: "main", unborn: true, head: "")),
                       Pres.Label(text: "main", style: .branch), "an unborn branch shows its name, no hash")
    }

    func testCounters() {
        XCTAssertNil(Pres.counters(WorkbenchGitStatus(ahead: 0, behind: 0)))
        XCTAssertEqual(Pres.counters(WorkbenchGitStatus(ahead: 2)), "↑2")
        XCTAssertEqual(Pres.counters(WorkbenchGitStatus(behind: 1)), "↓1")
        XCTAssertEqual(Pres.counters(WorkbenchGitStatus(ahead: 2, behind: 1)), "↑2 ↓1")
        XCTAssertNil(Pres.counters(WorkbenchGitStatus(unborn: true)))
    }

    func testShowsButtonOnlyForAReadableWorkTree() {
        XCTAssertFalse(Pres.showsButton(nil))
        XCTAssertTrue(Pres.showsButton(WorkbenchGitStatus(branch: "main")))
        XCTAssertFalse(Pres.showsButton(WorkbenchGitStatus(gitAvailable: false, git: false)))
        XCTAssertFalse(Pres.showsButton(WorkbenchGitStatus(git: false)))
        XCTAssertFalse(Pres.showsButton(WorkbenchGitStatus(statusOK: false, statusError: "fatal")))
    }

    func testHelpNamesTheOperationInProgress() {
        let help = Pres.help(WorkbenchGitStatus(branch: "a-very-long/branch-name", dirty: true, changes: 3, operation: "rebase"))
        XCTAssertTrue(help.hasPrefix("a-very-long/branch-name"))
        XCTAssertTrue(help.contains("3 changes are not committed"))
        XCTAssertTrue(help.contains("A rebase is in progress"))
        XCTAssertEqual(Pres.help(WorkbenchGitStatus(detached: true, head: "a1b2c3d")), "Detached HEAD at a1b2c3d")
    }

    func testFilterIsCaseInsensitiveAndKeepsOrder() {
        let branches = ["main", "Feature/Login", "fix/feature-flag", "dev"].map { WorkbenchGitBranch(name: $0) }
        XCTAssertEqual(Pres.filter(branches, query: "FEAT").map(\.name), ["Feature/Login", "fix/feature-flag"])
        XCTAssertEqual(Pres.filter(branches, query: "").map(\.name), branches.map(\.name))
        XCTAssertEqual(Pres.filter(branches, query: "  ").map(\.name), branches.map(\.name))
        XCTAssertEqual(Pres.filter(branches, query: "nothing"), [])
    }

    func testDisabledCaptionForABranchOpenElsewhere() {
        XCTAssertNil(Pres.disabledCaption(WorkbenchGitBranch(name: "main")))
        XCTAssertEqual(Pres.disabledCaption(WorkbenchGitBranch(name: "x", worktree: "/tmp/wt/acme-x", worktreeName: "acme-x")),
                       "open in worktree acme-x")
        XCTAssertEqual(Pres.disabledCaption(WorkbenchGitBranch(name: "x", worktree: "/tmp/wt/other")),
                       "open in worktree other", "falls back to the folder's base name")
    }

    func testBadge() {
        let targets = [
            "feature/x": [WorkbenchBranchTarget(id: 12, title: "Login", status: "in_progress"),
                          WorkbenchBranchTarget(id: 9, title: "Old login", status: "done")],
            "fix/y": [WorkbenchBranchTarget(id: 4, title: "Typo", status: "todo")]
        ]
        XCTAssertEqual(Pres.badge(for: "fix/y", in: targets), Pres.Badge(text: "#4", help: "#4 Typo (todo)"))
        XCTAssertEqual(Pres.badge(for: "feature/x", in: targets),
                       Pres.Badge(text: "#12 +1", help: "#12 Login (in_progress)\n#9 Old login (done)"))
        XCTAssertNil(Pres.badge(for: "main", in: targets))
        XCTAssertNil(Pres.badge(for: "main", in: ["main": []]))
    }

    func testConfirmationForUncommittedChanges() throws {
        let result = WorkbenchGitSwitchResult(branch: "feature/x", needsConfirmation: [.uncommittedChanges], changes: 5)
        let confirmation = try XCTUnwrap(Pres.confirmation(for: result))
        XCTAssertEqual(confirmation.title, "Switch to feature/x?")
        XCTAssertEqual(confirmation.primaryLabel, "Stash and switch")
        XCTAssertTrue(confirmation.stash)
        XCTAssertFalse(confirmation.confirmAgent)
        XCTAssertTrue(confirmation.message.contains("5 changes are not committed"))
        XCTAssertFalse(confirmation.message.contains("Claude Code"))
    }

    func testConfirmationForARunningAgent() throws {
        let result = WorkbenchGitSwitchResult(branch: "feature/x", needsConfirmation: [.agentRunning])
        let confirmation = try XCTUnwrap(Pres.confirmation(for: result))
        XCTAssertEqual(confirmation.primaryLabel, "Switch anyway")
        XCTAssertFalse(confirmation.stash)
        XCTAssertTrue(confirmation.confirmAgent)
        XCTAssertTrue(confirmation.message.contains("the agent's files will be swapped"))
    }

    func testConfirmationForBoth() throws {
        let result = WorkbenchGitSwitchResult(branch: "b", needsConfirmation: [.uncommittedChanges, .agentRunning], changes: 1)
        let confirmation = try XCTUnwrap(Pres.confirmation(for: result))
        XCTAssertEqual(confirmation.primaryLabel, "Stash and switch")
        XCTAssertTrue(confirmation.stash)
        XCTAssertTrue(confirmation.confirmAgent)
        XCTAssertTrue(confirmation.message.contains("the agent's files will be swapped"))
        XCTAssertTrue(confirmation.message.contains("1 change is not committed"))
    }

    func testNoConfirmationWhenNothingIsAsked() {
        XCTAssertNil(Pres.confirmation(for: WorkbenchGitSwitchResult(branch: "b", switched: true)))
        XCTAssertNil(Pres.confirmation(for: WorkbenchGitSwitchResult(branch: "b", already: true)))
        XCTAssertNil(Pres.confirmation(for: WorkbenchGitSwitchResult(branch: "b", refused: "unknown_branch")))
        XCTAssertNil(Pres.confirmation(for: WorkbenchGitSwitchResult(branch: "b", switched: true, needsConfirmation: [.agentRunning])),
                     "a switched result is never confirmed again")
    }

    func testOutcomeMessages() {
        XCTAssertNil(Pres.outcomeMessage(WorkbenchGitSwitchResult(switched: true)))
        XCTAssertEqual(Pres.outcomeMessage(WorkbenchGitSwitchResult(stashRestored: true, error: "fatal: x")),
                       "git failed: fatal: x Your stashed changes were put back.")
        XCTAssertEqual(Pres.outcomeMessage(WorkbenchGitSwitchResult(refused: "exists")),
                       "A branch with that name already exists.")
        XCTAssertEqual(Pres.outcomeMessage(WorkbenchGitSwitchResult(refused: "unknown_branch", refusedDetail: "no branch zz")),
                       "no branch zz", "Go's detail wins over the generic text")
        XCTAssertEqual(Pres.outcomeMessage(WorkbenchGitSwitchResult(refused: "brand_new")), "Refused: brand_new")
        XCTAssertNotNil(Pres.outcomeMessage(WorkbenchGitSwitchResult(unknownConfirmations: ["lfs_locked"])))
    }

    func testStashNote() {
        XCTAssertNil(Pres.stashNote(WorkbenchGitSwitchResult(switched: true)))
        XCTAssertNil(Pres.stashNote(WorkbenchGitSwitchResult(switched: false, stashed: "stash@{0}")))
        XCTAssertEqual(Pres.stashNote(WorkbenchGitSwitchResult(switched: true, stashed: "stash@{0}", stashMessage: "watchtower: m")),
                       "Your changes are in stash@{0} (\"watchtower: m\") — run git stash pop when you want them back.")
    }
}
