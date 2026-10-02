import XCTest
@testable import WatchtowerCore

/// The `workbench git status|branches|switch|create --json` envelopes as the
/// plan's contract (docs/superpowers/plans/2026-10-02-workbench-git-branch.md)
/// and Go's `cmd/workbench_git_test.go` key-set guards pin them.
final class WorkbenchGitDecodingTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    func testDecodesTheStatusSample() throws {
        let status = try decode(WorkbenchGitStatus.self, """
        {"workbench_id":7,"git_available":true,"git":true,"note":"",
         "branch":"main","detached":false,"unborn":false,"head":"a1b2c3d",
         "upstream":"origin/main","ahead":2,"behind":0,
         "dirty":true,"changes":5,"operation":"",
         "top_level":"/abs","git_dir":"/abs/.git/worktrees/x","common_dir":"/abs/.git",
         "status_ok":true,"status_error":""}
        """)
        XCTAssertEqual(status, WorkbenchGitStatus(
            workbenchID: 7, branch: "main", head: "a1b2c3d", upstream: "origin/main", ahead: 2,
            dirty: true, changes: 5, topLevel: "/abs", gitDir: "/abs/.git/worktrees/x", commonDir: "/abs/.git"
        ))
    }

    func testStatusOfANonRepositoryAndOfAnOlderCLI() throws {
        let none = try decode(WorkbenchGitStatus.self,
                              #"{"workbench_id":7,"git_available":false,"git":false,"note":"git is not available"}"#)
        XCTAssertFalse(none.git)
        XCTAssertFalse(none.gitAvailable)
        XCTAssertEqual(none.note, "git is not available")
        XCTAssertEqual(none.branch, "")
        XCTAssertTrue(none.statusOK, "a missing status_ok is not a failure")

        let older = try decode(WorkbenchGitStatus.self, #"{"git":true,"branch":"dev"}"#)
        XCTAssertTrue(older.gitAvailable, "a CLI without the key ran git")
        XCTAssertEqual(older.branch, "dev")
        XCTAssertEqual(older.ahead, 0)
        XCTAssertFalse(older.dirty)
    }

    func testStatusWithoutGitKeyIsAnError() {
        XCTAssertThrowsError(try decode(WorkbenchGitStatus.self, #"{"branch":"main"}"#))
    }

    func testDecodesTheBranchesSample() throws {
        let list = try decode(WorkbenchGitBranches.self, """
        {"workbench_id":7,"git_available":true,"git":true,"current":"main",
         "branches":[{"name":"main","current":true,"head":"a1b2c3d","committed_at":"2026-10-02T09:00:00Z",
                      "upstream":"origin/main","ahead":0,"behind":0,"worktree":"","worktree_name":""},
                     {"name":"feature/x","current":false,"head":"b2c3d4e","committed_at":"2026-10-01T08:30:00Z",
                      "upstream":"","ahead":0,"behind":0,"worktree":"/abs/wt/x","worktree_name":"x"}],
         "branches_ok":true,"branches_error":""}
        """)
        XCTAssertEqual(list.current, "main")
        XCTAssertEqual(list.branches.map(\.name), ["main", "feature/x"])
        XCTAssertTrue(list.branches[0].current)
        XCTAssertEqual(list.branches[1].worktreeName, "x")
        XCTAssertEqual(list.branches[0].committedAt, Date(timeIntervalSince1970: 1_790_931_600))
    }

    func testEmptyBranchesAndAFailedListing() throws {
        let empty = try decode(WorkbenchGitBranches.self,
                               #"{"workbench_id":7,"git":true,"current":"main","branches":[],"branches_ok":true,"branches_error":""}"#)
        XCTAssertEqual(empty.branches, [])
        let failed = try decode(WorkbenchGitBranches.self,
                                #"{"git":true,"branches":[],"branches_ok":false,"branches_error":"fatal: bad ref"}"#)
        XCTAssertFalse(failed.branchesOK)
        XCTAssertEqual(failed.branchesError, "fatal: bad ref")
        let older = try decode(WorkbenchGitBranches.self, #"{"git":false}"#)
        XCTAssertEqual(older.branches, [], "a missing list decodes as empty")
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
    }

    func testDecodesTheSwitchRefusalSample() throws {
        let result = try decode(WorkbenchGitSwitchResult.self, """
        {"workbench_id":7,"branch":"feature/x","switched":false,"already":false,
         "needs_confirmation":["uncommitted_changes","agent_running"],"changes":5,
         "refused":"","refused_detail":"",
         "stashed":"","stash_message":"","stash_restored":false,
         "error":"",
         "status":{}}
        """)
        XCTAssertFalse(result.switched)
        XCTAssertEqual(result.needsConfirmation, [.uncommittedChanges, .agentRunning])
        XCTAssertEqual(result.changes, 5)
        XCTAssertNil(result.status, "an empty status object is no status")
    }

    func testSwitchSuccessCarriesTheStashAndTheStatus() throws {
        let result = try decode(WorkbenchGitSwitchResult.self, """
        {"workbench_id":7,"branch":"feature/x","switched":true,"already":false,"needs_confirmation":[],
         "changes":2,"refused":"","refused_detail":"","stashed":"stash@{0}",
         "stash_message":"watchtower: switching from main to feature/x","stash_restored":false,"error":"",
         "status":{"workbench_id":7,"git_available":true,"git":true,"branch":"feature/x","head":"b2c3d4e"}}
        """)
        XCTAssertTrue(result.switched)
        XCTAssertEqual(result.needsConfirmation, [])
        XCTAssertEqual(result.stashed, "stash@{0}")
        XCTAssertEqual(result.stashMessage, "watchtower: switching from main to feature/x")
        XCTAssertEqual(result.status?.branch, "feature/x")
    }

    func testCreateEnvelopeAndAnOlderSwitchEnvelope() throws {
        let created = try decode(WorkbenchGitSwitchResult.self,
                                 #"{"workbench_id":7,"branch":"new","switched":true,"created":true,"needs_confirmation":[],"refused":""}"#)
        XCTAssertTrue(created.created)
        let refused = try decode(WorkbenchGitSwitchResult.self,
                                 #"{"switched":false,"refused":"invalid_name","refused_detail":"a..b is not a valid branch name"}"#)
        XCTAssertFalse(refused.created)
        XCTAssertEqual(refused.refused, "invalid_name")
        XCTAssertEqual(refused.needsConfirmation, [])
        XCTAssertNil(refused.status)
        XCTAssertFalse(refused.stashRestored)
    }

    func testUnknownConfirmationsAreKeptApart() throws {
        let result = try decode(WorkbenchGitSwitchResult.self,
                                #"{"switched":false,"needs_confirmation":["agent_running","lfs_locked"]}"#)
        XCTAssertEqual(result.needsConfirmation, [.agentRunning])
        XCTAssertEqual(result.unknownConfirmations, ["lfs_locked"])
    }

    func testMalformedStatusInsideTheEnvelopeFails() {
        XCTAssertThrowsError(try decode(WorkbenchGitSwitchResult.self, #"{"switched":true,"status":{"branch":"x"}}"#))
        XCTAssertNoThrow(try decode(WorkbenchGitSwitchResult.self, #"{"switched":true,"status":null}"#))
    }
}
