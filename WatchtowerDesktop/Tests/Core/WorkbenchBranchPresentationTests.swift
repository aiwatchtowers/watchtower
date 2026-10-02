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

    func testCappedCutsLongNamesAtTheTail() {
        XCTAssertEqual(Pres.capped("main"), "main")
        let exact = String(repeating: "a", count: Pres.maxButtonNameLength)
        XCTAssertEqual(Pres.capped(exact), exact)
        XCTAssertEqual(Pres.capped("feature/very-long-branch-name", limit: 10), "feature/v…")
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
        let help = Pres.help(WorkbenchGitStatus(branch: "a-very-long/branch-name", dirty: true, changes: 3, operation: "rebase"),
                             staleError: nil)
        XCTAssertTrue(help.hasPrefix("a-very-long/branch-name"))
        XCTAssertTrue(help.contains("3 changes are not committed"))
        XCTAssertTrue(help.contains("A rebase is in progress"))
        XCTAssertEqual(Pres.help(WorkbenchGitStatus(detached: true, head: "a1b2c3d"), staleError: nil), "Detached HEAD at a1b2c3d")
    }

    func testHelpOfAStaleStatusSaysWhy() {
        XCTAssertEqual(Pres.help(WorkbenchGitStatus(branch: "main"), staleError: "Could not read the git status: boom"),
                       "main\nMay be out of date — Could not read the git status: boom")
    }

    func testFailureTextTurnsAContractMismatchIntoAnInstruction() {
        let mismatch = "unexpected output from `watchtower workbench git status` — the CLI and the app may be out of sync; "
            + "update Watchtower"
        let decoding = DecodingError.keyNotFound(WorkbenchGitStatus.CodingKeys.git, .init(codingPath: [], debugDescription: "no git"))
        XCTAssertEqual(Pres.failureText(decoding, command: "status"), mismatch)
        let unknown = CLIRunnerError.nonZeroExit(code: 1, stderr: #"Error: unknown command "git" for "watchtower workbench""#)
        XCTAssertEqual(Pres.failureText(unknown, command: "status"), mismatch)
        let flag = CLIRunnerError.nonZeroExit(code: 1, stderr: "Error: unknown flag: --confirm-agent")
        XCTAssertEqual(Pres.failureText(flag, command: "switch").hasPrefix("unexpected output from `watchtower workbench git switch`"), true)
        let other = CLIRunnerError.nonZeroExit(code: 1, stderr: "no such workbench")
        XCTAssertEqual(Pres.failureText(other, command: "status"), other.localizedDescription)
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

    func testOutcomeErrors() {
        XCTAssertEqual(Pres.outcome(WorkbenchGitSwitchResult(switched: true)), Pres.Outcome(error: nil, notice: nil))
        XCTAssertEqual(Pres.outcome(WorkbenchGitSwitchResult(error: "fatal: x")).error, "git failed: fatal: x")
        XCTAssertEqual(Pres.outcome(WorkbenchGitSwitchResult(refused: "exists")).error,
                       "A branch with that name already exists.")
        XCTAssertEqual(Pres.outcome(WorkbenchGitSwitchResult(refused: "unknown_branch", refusedDetail: "no branch zz")).error,
                       "no branch zz", "Go's detail wins over the generic text")
        XCTAssertEqual(Pres.outcome(WorkbenchGitSwitchResult(refused: "brand_new")).error, "Refused: brand_new")
        XCTAssertNotNil(Pres.outcome(WorkbenchGitSwitchResult(unknownConfirmations: ["lfs_locked"])).error)
    }

    func testAGitFailedRefusalShowsGitsError() {
        let result = WorkbenchGitSwitchResult(refused: "git_failed", refusedDetail: "fatal: this operation must be run in a work tree")
        XCTAssertEqual(Pres.outcome(result).error, "git could not read the folder: fatal: this operation must be run in a work tree")
        XCTAssertEqual(Pres.outcome(WorkbenchGitSwitchResult(refused: "git_failed")).error, "git could not read the folder: ")
    }

    func testAWarningIsANoticeNotAnError() {
        let switched = Pres.outcome(WorkbenchGitSwitchResult(branch: "feature", switched: true, warning: "hook says no"))
        XCTAssertNil(switched.error)
        XCTAssertEqual(switched.notice, "Switched to feature, but git reported: hook says no")
        let created = Pres.outcome(WorkbenchGitSwitchResult(branch: "topic", switched: true, created: true, warning: "hook says no"))
        XCTAssertEqual(created.notice, "Created topic, but git reported: hook says no")
    }

    private let sha = "37ec8891211bad0cb17b8c9f07a2152b71c07e2d"
    private let entry = "watchtower: switching from main to feature [d0a6a69fddb64948]"

    /// The stash stack is shared by every worktree and session: the note
    /// names the entry and applies it by id — never `git stash pop`.
    func testAStashNoteNamesTheEntryAndAppliesItByID() {
        let outcome = Pres.outcome(WorkbenchGitSwitchResult(switched: true, stashed: sha, stashMessage: entry))
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.notice, "Your changes are saved in the stash entry \"\(entry)\" — get them back with git stash apply \(sha).")
        XCTAssertFalse(outcome.notice?.contains("pop") ?? true)
    }

    func testAStashNoteShowsWhateverTheSwitchDid() {
        let failed = Pres.outcome(WorkbenchGitSwitchResult(switched: false, stashed: sha, stashMessage: entry,
                                                           error: "a stash was created but git stash push failed"))
        XCTAssertEqual(failed.notice?.contains("git stash apply \(sha)"), true, "a stash a failed switch left is named too")
        XCTAssertNotNil(failed.error)
    }

    func testARestoredStashSaysTheChangesAreBackAndTheEntryKept() {
        let outcome = Pres.outcome(WorkbenchGitSwitchResult(stashed: sha, stashMessage: entry, stashRestored: true,
                                                            error: "fatal: simulated switch failure"))
        XCTAssertEqual(outcome.error, "git failed: fatal: simulated switch failure")
        XCTAssertEqual(outcome.notice, "Your changes are back in the work tree; the stash entry \"\(entry)\" was kept on the stack.")
    }

    func testAStashThatCouldNotBeAppliedIsAnError() {
        let outcome = Pres.outcome(WorkbenchGitSwitchResult(stashed: sha, stashMessage: entry, stashError: "error: conflict",
                                                            error: "fatal: simulated switch failure"))
        XCTAssertNil(outcome.notice)
        XCTAssertEqual(outcome.error, "git failed: fatal: simulated switch failure\nYour changes are only in the stash entry "
                       + "\"\(entry)\" — putting them back failed: error: conflict. Get them back with git stash apply \(sha).")
    }

    func testAStashWithoutAMessageIsNamedByItsID() {
        XCTAssertEqual(Pres.outcome(WorkbenchGitSwitchResult(switched: true, stashed: sha)).notice,
                       "Your changes are saved in the stash entry \(sha) — get them back with git stash apply \(sha).")
    }

    func testUpstreamCaption() {
        XCTAssertNil(Pres.upstreamCaption(WorkbenchGitBranch(name: "main", upstream: "origin/main")))
        XCTAssertEqual(Pres.upstreamCaption(WorkbenchGitBranch(name: "old", upstream: "origin/old", upstreamGone: true)), "upstream gone")
    }
}
