import XCTest
@testable import WatchtowerCore

/// The `workbench git status|branches|switch|create --json` envelopes. The
/// `Fixture` strings are real Go output: `internal/workbenchgit` marshalled
/// against throwaway repositories (a dirty branch ahead of its upstream, a
/// pruned upstream, a branch open in another worktree, a folder that is not
/// a repository, a status git could not read, a switch git refused, one
/// whose stash could not be applied back, a failing post-checkout hook) and
/// indented the way `cmd`'s `writeJSON` prints them — pasted verbatim, so a
/// renamed key on either side fails here. The plan's
/// contract (docs/superpowers/plans/2026-10-02-workbench-git-branch.md) and
/// Go's `cmd/workbench_git_test.go` key-set guards pin the same shape.
final class WorkbenchGitDecodingTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private enum Fixture {
        static let statusDirtyAhead = #"""
        {
          "workbench_id": 7,
          "git_available": true,
          "git": true,
          "note": "",
          "branch": "main",
          "detached": false,
          "unborn": false,
          "head": "db74bb7",
          "upstream": "origin/main",
          "ahead": 2,
          "behind": 0,
          "changes": 2,
          "dirty": true,
          "operation": "",
          "top_level": "/private/tmp/wtfix/TestZZScratchFixtures2047796624/001",
          "git_dir": "/private/tmp/wtfix/TestZZScratchFixtures2047796624/001/.git",
          "common_dir": "/private/tmp/wtfix/TestZZScratchFixtures2047796624/001/.git",
          "status_ok": true,
          "status_error": ""
        }
        """#
        static let statusNotARepository = #"""
        {
          "workbench_id": 7,
          "git_available": true,
          "git": false,
          "note": "the folder is not a git work tree",
          "branch": "",
          "detached": false,
          "unborn": false,
          "head": "",
          "upstream": "",
          "ahead": 0,
          "behind": 0,
          "changes": 0,
          "dirty": false,
          "operation": "",
          "top_level": "",
          "git_dir": "",
          "common_dir": "",
          "status_ok": false,
          "status_error": ""
        }
        """#
        static let statusUnreadable = #"""
        {
          "workbench_id": 7,
          "git_available": true,
          "git": true,
          "note": "",
          "branch": "",
          "detached": false,
          "unborn": false,
          "head": "",
          "upstream": "",
          "ahead": 0,
          "behind": 0,
          "changes": 0,
          "dirty": false,
          "operation": "",
          "top_level": "",
          "git_dir": "",
          "common_dir": "",
          "status_ok": false,
          "status_error": "fatal: this operation must be run in a work tree"
        }
        """#
        static let branches = #"""
        {
          "workbench_id": 7,
          "git_available": true,
          "git": true,
          "note": "",
          "current": "main",
          "branches": [
            {
              "name": "feature",
              "current": false,
              "head": "1af1a01",
              "committed_at": "2026-10-02T13:19:49Z",
              "upstream": "",
              "upstream_gone": false,
              "ahead": 0,
              "behind": 0,
              "worktree": "",
              "worktree_name": ""
            },
            {
              "name": "main",
              "current": true,
              "head": "db74bb7",
              "committed_at": "2026-10-02T13:19:49Z",
              "upstream": "origin/main",
              "upstream_gone": false,
              "ahead": 2,
              "behind": 0,
              "worktree": "",
              "worktree_name": ""
            },
            {
              "name": "old",
              "current": false,
              "head": "134f89f",
              "committed_at": "2026-10-02T13:19:49Z",
              "upstream": "origin/old",
              "upstream_gone": true,
              "ahead": 0,
              "behind": 0,
              "worktree": "",
              "worktree_name": ""
            },
            {
              "name": "review",
              "current": false,
              "head": "db74bb7",
              "committed_at": "2026-10-02T13:19:49Z",
              "upstream": "",
              "upstream_gone": false,
              "ahead": 0,
              "behind": 0,
              "worktree": "/private/tmp/wtfix/TestZZScratchFixtures2047796624/wt-review",
              "worktree_name": "wt-review"
            }
          ],
          "branches_ok": true,
          "branches_error": ""
        }
        """#
        static let branchesNotARepository = #"""
        {
          "workbench_id": 7,
          "git_available": true,
          "git": false,
          "note": "the folder is not a git work tree",
          "current": "",
          "branches": [],
          "branches_ok": false,
          "branches_error": ""
        }
        """#
        static let switchNeedsConfirmation = #"""
        {
          "workbench_id": 7,
          "branch": "feature",
          "switched": false,
          "already": false,
          "created": false,
          "needs_confirmation": [
            "uncommitted_changes",
            "agent_running"
          ],
          "changes": 2,
          "refused": "",
          "refused_detail": "",
          "stashed": "",
          "stash_message": "",
          "stash_restored": false,
          "stash_error": "",
          "error": "",
          "warning": "",
          "status": {
            "workbench_id": 7,
            "git_available": true,
            "git": true,
            "note": "",
            "branch": "main",
            "detached": false,
            "unborn": false,
            "head": "db74bb7",
            "upstream": "origin/main",
            "ahead": 2,
            "behind": 0,
            "changes": 2,
            "dirty": true,
            "operation": "",
            "top_level": "/private/tmp/wtfix/TestZZScratchFixtures2047796624/001",
            "git_dir": "/private/tmp/wtfix/TestZZScratchFixtures2047796624/001/.git",
            "common_dir": "/private/tmp/wtfix/TestZZScratchFixtures2047796624/001/.git",
            "status_ok": true,
            "status_error": ""
          }
        }
        """#
        static let switchGitFailed = #"""
        {
          "workbench_id": 7,
          "branch": "feature",
          "switched": false,
          "already": false,
          "created": false,
          "needs_confirmation": [],
          "changes": 0,
          "refused": "git_failed",
          "refused_detail": "fatal: this operation must be run in a work tree",
          "stashed": "",
          "stash_message": "",
          "stash_restored": false,
          "stash_error": "",
          "error": "",
          "warning": "",
          "status": {
            "workbench_id": 7,
            "git_available": true,
            "git": true,
            "note": "",
            "branch": "",
            "detached": false,
            "unborn": false,
            "head": "",
            "upstream": "",
            "ahead": 0,
            "behind": 0,
            "changes": 0,
            "dirty": false,
            "operation": "",
            "top_level": "",
            "git_dir": "",
            "common_dir": "",
            "status_ok": false,
            "status_error": "fatal: this operation must be run in a work tree"
          }
        }
        """#
        static let switchFailedStashRestored = #"""
        {
          "workbench_id": 7,
          "branch": "feature",
          "switched": false,
          "already": false,
          "created": false,
          "needs_confirmation": [],
          "changes": 2,
          "refused": "",
          "refused_detail": "",
          "stashed": "2dd96e0373943aad65f88eeabafecb76813fabf0",
          "stash_message": "watchtower: switching from main to feature [83ec588ce137925b]",
          "stash_restored": true,
          "stash_error": "",
          "error": "fatal: simulated switch failure",
          "warning": "",
          "status": {
            "workbench_id": 7,
            "git_available": true,
            "git": true,
            "note": "",
            "branch": "main",
            "detached": false,
            "unborn": false,
            "head": "db74bb7",
            "upstream": "origin/main",
            "ahead": 2,
            "behind": 0,
            "changes": 2,
            "dirty": true,
            "operation": "",
            "top_level": "/private/tmp/wtfix/TestZZScratchFixtures2047796624/001",
            "git_dir": "/private/tmp/wtfix/TestZZScratchFixtures2047796624/001/.git",
            "common_dir": "/private/tmp/wtfix/TestZZScratchFixtures2047796624/001/.git",
            "status_ok": true,
            "status_error": ""
          }
        }
        """#
        static let switchFailedStashNotApplied = #"""
        {
          "workbench_id": 7,
          "branch": "feature",
          "switched": false,
          "already": false,
          "created": false,
          "needs_confirmation": [],
          "changes": 2,
          "refused": "",
          "refused_detail": "",
          "stashed": "d28fb3e5f28f33a81b916e8e0fa466c67a3f3360",
          "stash_message": "watchtower: switching from main to feature [a1c5a6ecb1af6142]",
          "stash_restored": false,
          "stash_error": "error: simulated stash failure",
          "error": "error: simulated switch failure",
          "warning": "",
          "status": {
            "workbench_id": 7,
            "git_available": true,
            "git": true,
            "note": "",
            "branch": "main",
            "detached": false,
            "unborn": false,
            "head": "db74bb7",
            "upstream": "origin/main",
            "ahead": 2,
            "behind": 0,
            "changes": 0,
            "dirty": false,
            "operation": "",
            "top_level": "/private/tmp/wtfix/TestZZScratchFixtures2047796624/001",
            "git_dir": "/private/tmp/wtfix/TestZZScratchFixtures2047796624/001/.git",
            "common_dir": "/private/tmp/wtfix/TestZZScratchFixtures2047796624/001/.git",
            "status_ok": true,
            "status_error": ""
          }
        }
        """#
        static let switchWarningStashed = #"""
        {
          "workbench_id": 7,
          "branch": "feature",
          "switched": true,
          "already": false,
          "created": false,
          "needs_confirmation": [],
          "changes": 2,
          "refused": "",
          "refused_detail": "",
          "stashed": "37ec8891211bad0cb17b8c9f07a2152b71c07e2d",
          "stash_message": "watchtower: switching from main to feature [d0a6a69fddb64948]",
          "stash_restored": false,
          "stash_error": "",
          "error": "",
          "warning": "Switched to branch 'feature'\nhook says no",
          "status": {
            "workbench_id": 7,
            "git_available": true,
            "git": true,
            "note": "",
            "branch": "feature",
            "detached": false,
            "unborn": false,
            "head": "1af1a01",
            "upstream": "",
            "ahead": 0,
            "behind": 0,
            "changes": 0,
            "dirty": false,
            "operation": "",
            "top_level": "/private/tmp/wtfix/TestZZScratchFixtures2047796624/001",
            "git_dir": "/private/tmp/wtfix/TestZZScratchFixtures2047796624/001/.git",
            "common_dir": "/private/tmp/wtfix/TestZZScratchFixtures2047796624/001/.git",
            "status_ok": true,
            "status_error": ""
          }
        }
        """#
        static let createWarning = #"""
        {
          "workbench_id": 7,
          "branch": "topic",
          "switched": true,
          "already": false,
          "created": true,
          "needs_confirmation": [],
          "changes": 0,
          "refused": "",
          "refused_detail": "",
          "stashed": "",
          "stash_message": "",
          "stash_restored": false,
          "stash_error": "",
          "error": "",
          "warning": "Switched to a new branch 'topic'\nhook says no",
          "status": {
            "workbench_id": 7,
            "git_available": true,
            "git": true,
            "note": "",
            "branch": "topic",
            "detached": false,
            "unborn": false,
            "head": "1af1a01",
            "upstream": "",
            "ahead": 0,
            "behind": 0,
            "changes": 0,
            "dirty": false,
            "operation": "",
            "top_level": "/private/tmp/wtfix/TestZZScratchFixtures2047796624/001",
            "git_dir": "/private/tmp/wtfix/TestZZScratchFixtures2047796624/001/.git",
            "common_dir": "/private/tmp/wtfix/TestZZScratchFixtures2047796624/001/.git",
            "status_ok": true,
            "status_error": ""
          }
        }
        """#
        static let createInvalidName = #"""
        {
          "workbench_id": 7,
          "branch": "a..b",
          "switched": false,
          "already": false,
          "created": false,
          "needs_confirmation": [],
          "changes": 0,
          "refused": "invalid_name",
          "refused_detail": "a..b is not a valid branch name",
          "stashed": "",
          "stash_message": "",
          "stash_restored": false,
          "stash_error": "",
          "error": "",
          "warning": "",
          "status": {
            "workbench_id": 7,
            "git_available": true,
            "git": true,
            "note": "",
            "branch": "topic",
            "detached": false,
            "unborn": false,
            "head": "1af1a01",
            "upstream": "",
            "ahead": 0,
            "behind": 0,
            "changes": 0,
            "dirty": false,
            "operation": "",
            "top_level": "/private/tmp/wtfix/TestZZScratchFixtures2047796624/001",
            "git_dir": "/private/tmp/wtfix/TestZZScratchFixtures2047796624/001/.git",
            "common_dir": "/private/tmp/wtfix/TestZZScratchFixtures2047796624/001/.git",
            "status_ok": true,
            "status_error": ""
          }
        }
        """#
    }

    func testDecodesADirtyBranchAheadOfItsUpstream() throws {
        let status = try decode(WorkbenchGitStatus.self, Fixture.statusDirtyAhead)
        XCTAssertTrue(status.git)
        XCTAssertTrue(status.statusOK)
        XCTAssertEqual(status.workbenchID, 7)
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.head, "db74bb7")
        XCTAssertEqual(status.upstream, "origin/main")
        XCTAssertEqual(status.ahead, 2)
        XCTAssertTrue(status.dirty)
        XCTAssertEqual(status.changes, 2)
        XCTAssertFalse(status.topLevel.isEmpty)
        XCTAssertEqual(status.gitDir, status.topLevel + "/.git")
        XCTAssertEqual(status.commonDir, status.gitDir)
    }

    func testStatusOfANonRepositoryAndOfAnUnreadableOne() throws {
        let none = try decode(WorkbenchGitStatus.self, Fixture.statusNotARepository)
        XCTAssertFalse(none.git)
        XCTAssertTrue(none.gitAvailable)
        XCTAssertEqual(none.note, "the folder is not a git work tree")
        XCTAssertEqual(none.statusError, "", "not a repository is no error")

        let unreadable = try decode(WorkbenchGitStatus.self, Fixture.statusUnreadable)
        XCTAssertTrue(unreadable.git)
        XCTAssertFalse(unreadable.statusOK)
        XCTAssertEqual(unreadable.statusError, "fatal: this operation must be run in a work tree")
    }

    func testAnOlderStatusDecodesWithDefaults() throws {
        let older = try decode(WorkbenchGitStatus.self, #"{"git":true,"branch":"dev"}"#)
        XCTAssertTrue(older.gitAvailable, "a CLI without the key ran git")
        XCTAssertTrue(older.statusOK, "a missing status_ok is not a failure")
        XCTAssertEqual(older.branch, "dev")
        XCTAssertEqual(older.ahead, 0)
        XCTAssertFalse(older.dirty)
    }

    func testStatusWithoutGitKeyIsAnError() {
        XCTAssertThrowsError(try decode(WorkbenchGitStatus.self, #"{"branch":"main"}"#))
    }

    func testDecodesTheBranches() throws {
        let list = try decode(WorkbenchGitBranches.self, Fixture.branches)
        XCTAssertTrue(list.branchesOK)
        XCTAssertEqual(list.note, "")
        XCTAssertEqual(list.current, "main")
        XCTAssertEqual(list.branches.map(\.name), ["feature", "main", "old", "review"])
        let byName = Dictionary(uniqueKeysWithValues: list.branches.map { ($0.name, $0) })
        XCTAssertEqual(byName["main"]?.current, true)
        XCTAssertEqual(byName["main"]?.ahead, 2)
        XCTAssertEqual(byName["old"]?.upstream, "origin/old")
        XCTAssertEqual(byName["old"]?.upstreamGone, true, "a pruned upstream")
        XCTAssertEqual(byName["main"]?.upstreamGone, false)
        XCTAssertEqual(byName["review"]?.worktreeName, "wt-review")
        XCTAssertEqual(byName["review"]?.worktree.hasSuffix("/wt-review"), true)
        XCTAssertEqual(byName["feature"]?.worktree, "")
        XCTAssertEqual(byName["main"]?.committedAt, WorkbenchGitBranch.parseTime("2026-10-02T13:19:49Z"))
        XCTAssertNotNil(byName["main"]?.committedAt)
    }

    func testBranchesOfANonRepositoryCarryTheNote() throws {
        let none = try decode(WorkbenchGitBranches.self, Fixture.branchesNotARepository)
        XCTAssertFalse(none.git)
        XCTAssertFalse(none.branchesOK)
        XCTAssertEqual(none.branchesError, "")
        XCTAssertEqual(none.note, "the folder is not a git work tree")
        XCTAssertEqual(none.branches, [], "Go sends [], never null")
        let older = try decode(WorkbenchGitBranches.self, #"{"git":false}"#)
        XCTAssertEqual(older.branches, [], "a missing list decodes as empty")
        XCTAssertEqual(older.note, "")
    }

    /// Go writes RFC3339 UTC; the date is the same instant whatever the
    /// machine's time zone, and an unparsable stamp is no date.
    func testCommittedAtIsReadInUTC() throws {
        XCTAssertEqual(WorkbenchGitBranch.parseTime("2026-10-02T09:00:00Z"), Date(timeIntervalSince1970: 1_790_931_600))
        XCTAssertEqual(WorkbenchGitBranch.parseTime("2026-10-02T11:00:00+02:00"), Date(timeIntervalSince1970: 1_790_931_600))
        XCTAssertNil(WorkbenchGitBranch.parseTime(""))
        XCTAssertNil(WorkbenchGitBranch.parseTime("yesterday"))
        let branch = try decode(WorkbenchGitBranch.self, #"{"name":"main"}"#)
        XCTAssertNil(branch.committedAt)
        XCTAssertEqual(branch.worktree, "")
        XCTAssertFalse(branch.upstreamGone)
    }

    func testDecodesAConfirmationRefusal() throws {
        let result = try decode(WorkbenchGitSwitchResult.self, Fixture.switchNeedsConfirmation)
        XCTAssertFalse(result.switched)
        XCTAssertEqual(result.branch, "feature")
        XCTAssertEqual(result.needsConfirmation, [.uncommittedChanges, .agentRunning])
        XCTAssertEqual(result.unknownConfirmations, [])
        XCTAssertEqual(result.changes, 2)
        XCTAssertEqual(result.stashed, "")
    }

    func testDecodesAGitFailedRefusal() throws {
        let result = try decode(WorkbenchGitSwitchResult.self, Fixture.switchGitFailed)
        XCTAssertEqual(result.refused, "git_failed")
        XCTAssertEqual(result.refusedDetail, "fatal: this operation must be run in a work tree")
    }

    func testDecodesAFailedSwitchWhoseStashWasPutBack() throws {
        let result = try decode(WorkbenchGitSwitchResult.self, Fixture.switchFailedStashRestored)
        XCTAssertFalse(result.switched)
        XCTAssertEqual(result.error, "fatal: simulated switch failure")
        XCTAssertEqual(result.stashed, "2dd96e0373943aad65f88eeabafecb76813fabf0", "the entry's commit id, not stash@{n}")
        XCTAssertEqual(result.stashMessage, "watchtower: switching from main to feature [83ec588ce137925b]")
        XCTAssertTrue(result.stashRestored)
        XCTAssertEqual(result.stashError, "")
    }

    func testDecodesAFailedSwitchWhoseStashCouldNotBeApplied() throws {
        let result = try decode(WorkbenchGitSwitchResult.self, Fixture.switchFailedStashNotApplied)
        XCTAssertFalse(result.stashRestored)
        XCTAssertEqual(result.stashError, "error: simulated stash failure")
        XCTAssertEqual(result.stashed, "d28fb3e5f28f33a81b916e8e0fa466c67a3f3360")
    }

    func testDecodesASwitchWithAWarningAndAStash() throws {
        let result = try decode(WorkbenchGitSwitchResult.self, Fixture.switchWarningStashed)
        XCTAssertTrue(result.switched)
        XCTAssertEqual(result.error, "")
        XCTAssertEqual(result.warning, "Switched to branch 'feature'\nhook says no")
        XCTAssertEqual(result.stashed, "37ec8891211bad0cb17b8c9f07a2152b71c07e2d")
        XCTAssertEqual(result.stashMessage, "watchtower: switching from main to feature [d0a6a69fddb64948]")
        XCTAssertFalse(result.stashRestored)
    }

    func testDecodesTheCreateEnvelopes() throws {
        let created = try decode(WorkbenchGitSwitchResult.self, Fixture.createWarning)
        XCTAssertTrue(created.created)
        XCTAssertTrue(created.switched)
        XCTAssertEqual(created.warning, "Switched to a new branch 'topic'\nhook says no")
        let invalid = try decode(WorkbenchGitSwitchResult.self, Fixture.createInvalidName)
        XCTAssertFalse(invalid.created)
        XCTAssertEqual(invalid.refused, "invalid_name")
        XCTAssertEqual(invalid.refusedDetail, "a..b is not a valid branch name")
    }

    func testAnOlderSwitchEnvelopeDecodesWithDefaults() throws {
        let refused = try decode(WorkbenchGitSwitchResult.self,
                                 #"{"switched":false,"refused":"invalid_name","refused_detail":"a..b is not a valid branch name"}"#)
        XCTAssertFalse(refused.created)
        XCTAssertEqual(refused.needsConfirmation, [])
        XCTAssertFalse(refused.stashRestored)
        XCTAssertEqual(refused.stashError, "")
        XCTAssertEqual(refused.warning, "")
    }

    func testUnknownConfirmationsAreKeptApart() throws {
        let result = try decode(WorkbenchGitSwitchResult.self,
                                #"{"switched":false,"needs_confirmation":["agent_running","lfs_locked"]}"#)
        XCTAssertEqual(result.needsConfirmation, [.agentRunning])
        XCTAssertEqual(result.unknownConfirmations, ["lfs_locked"])
    }

    /// The view model re-reads the status after every call; the
    /// envelope's copy is not decoded, so its shape cannot fail a switch.
    func testTheEnvelopesStatusIsNotRead() {
        XCTAssertNoThrow(try decode(WorkbenchGitSwitchResult.self, #"{"switched":true,"status":{"branch":"x"}}"#))
        XCTAssertNoThrow(try decode(WorkbenchGitSwitchResult.self, #"{"switched":true,"status":null}"#))
        XCTAssertNoThrow(try decode(WorkbenchGitSwitchResult.self, #"{"switched":true,"status":{}}"#))
    }
}
