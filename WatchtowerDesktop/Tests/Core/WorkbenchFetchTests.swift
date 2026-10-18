import XCTest
@testable import WatchtowerCore

/// Board #563: the `workbench git fetch` envelope, `branches`' remote-only
/// list, and the popover's fetch row text. The fixtures are real Go output
/// (`internal/workbenchgit` against a throwaway repository with a bare
/// origin), indented as `cmd`'s `writeJSON` prints them; Go's
/// `cmd/workbench_git_test.go` key-set guards pin the same shape.
final class WorkbenchFetchTests: XCTestCase {
    private typealias Pres = WorkbenchFetchPresentation

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private static let fetched = #"""
    {
      "workbench_id": 7,
      "git_available": true,
      "git": true,
      "note": "",
      "remote": "origin",
      "no_remote": false,
      "fetched": true,
      "fetched_at": "2026-10-16T18:34:18.610761Z",
      "timed_out": false,
      "error": "",
      "refused": "",
      "refused_detail": ""
    }
    """#

    private static let unreachable = #"""
    {
      "workbench_id": 7,
      "git_available": true,
      "git": true,
      "note": "",
      "remote": "origin",
      "no_remote": false,
      "fetched": false,
      "fetched_at": null,
      "timed_out": false,
      "error": "ssh: connect to host 127.0.0.1 port 1: Connection refused\r\nfatal: Could not read from remote repository.\n\nPlease make sure you have the correct access rights\nand the repository exists.",
      "refused": "",
      "refused_detail": ""
    }
    """#

    private static let remoteOnly = #"""
    {
      "workbench_id": 7,
      "git_available": true,
      "git": true,
      "note": "",
      "current": "main",
      "branches": [
        {
          "name": "main",
          "current": true,
          "head": "a934cbb",
          "committed_at": "2026-10-16T18:34:15Z",
          "upstream": "origin/main",
          "upstream_gone": false,
          "ahead": 0,
          "behind": 1,
          "worktree": "",
          "worktree_name": ""
        }
      ],
      "branches_ok": true,
      "branches_error": "",
      "remote_only": [
        {
          "name": "topic",
          "ref": "origin/topic",
          "head": "87cafec",
          "committed_at": "2026-10-16T18:34:17Z"
        }
      ],
      "remote_only_error": "",
      "refused": "",
      "refused_detail": ""
    }
    """#

    func testAFetchedEnvelopeDecodes() throws {
        let result = try decode(WorkbenchGitFetchResult.self, Self.fetched)
        XCTAssertTrue(result.fetched)
        XCTAssertEqual(result.workbenchID, 7)
        XCTAssertNotNil(result.fetchedAt, "fractional seconds parse")
        XCTAssertNil(Pres.failure(result))
    }

    func testAnUnreachableRemoteIsAQuietNoteWithGitsFirstLine() throws {
        let result = try decode(WorkbenchGitFetchResult.self, Self.unreachable)
        XCTAssertFalse(result.fetched)
        XCTAssertNil(result.fetchedAt)
        XCTAssertEqual(Pres.failure(result), "Couldn't fetch origin: ssh: connect to host 127.0.0.1 port 1: Connection refused")
    }

    func testFailureTexts() {
        XCTAssertEqual(Pres.failure(WorkbenchGitFetchResult(timedOut: true, error: "git fetch timed out")),
                       "Couldn't fetch origin: it did not answer within 20 s")
        let auth = Pres.failure(WorkbenchGitFetchResult(
            error: "fatal: could not read Username for 'https://example.com': terminal prompts disabled"))
        XCTAssertEqual(auth, "Couldn't fetch origin: could not read Username for 'https://example.com': terminal prompts disabled"
            + " — Watchtower never asks for a password or key; fetch once from a terminal")
        XCTAssertNil(Pres.failure(WorkbenchGitFetchResult(noRemote: true)), "no origin is no failure")
        XCTAssertEqual(Pres.failure(WorkbenchGitFetchResult(refused: "folder_not_a_worktree", refusedDetail: "missing")),
                       "Couldn't fetch origin: " + WorkbenchBranchPresentation.folderNotAWorktreeText)
        XCTAssertEqual(Pres.failure(WorkbenchGitFetchResult(git: false, note: "not a git work tree")),
                       "Couldn't fetch origin: not a git work tree")
    }

    func testRemoteOnlyDecodesAndAnOlderCLISendsNone() throws {
        let list = try decode(WorkbenchGitBranches.self, Self.remoteOnly)
        XCTAssertEqual(list.remoteOnly.map(\.name), ["topic"])
        XCTAssertEqual(list.remoteOnly.first?.ref, "origin/topic")
        XCTAssertEqual(list.remoteOnly.first?.head, "87cafec")
        XCTAssertNotNil(list.remoteOnly.first?.committedAt)
        XCTAssertEqual(list.branches.first?.behind, 1)
        let old = try decode(WorkbenchGitBranches.self, #"{"git":true,"branches":[]}"#)
        XCTAssertEqual(old.remoteOnly, [])
        XCTAssertEqual(old.remoteOnlyError, "")
    }

    func testBackgroundFetchIsDueEveryFiveMinutesAtMost() {
        let now = Date()
        XCTAssertTrue(Pres.isBackgroundFetchDue(nil, now: now), "never fetched in this app run")
        XCTAssertFalse(Pres.isBackgroundFetchDue(GitFetchState(lastAttemptAt: now.addingTimeInterval(-299)), now: now))
        XCTAssertTrue(Pres.isBackgroundFetchDue(GitFetchState(lastAttemptAt: now.addingTimeInterval(-300)), now: now))
        XCTAssertFalse(Pres.isBackgroundFetchDue(GitFetchState(lastAttemptAt: now.addingTimeInterval(-60), failure: "x"), now: now),
                       "a failed try counts: an offline Mac does not retry on every open")
        XCTAssertFalse(Pres.isBackgroundFetchDue(GitFetchState(running: true), now: now))
        XCTAssertFalse(Pres.isBackgroundFetchDue(GitFetchState(noRemote: true), now: now))
    }

    func testCaption() {
        let now = Date()
        XCTAssertEqual(Pres.caption(nil, now: now), "Not fetched yet")
        XCTAssertEqual(Pres.caption(GitFetchState(running: true), now: now), "Fetching origin…")
        XCTAssertEqual(Pres.caption(GitFetchState(lastFetchedAt: now.addingTimeInterval(-20)), now: now), "Fetched just now")
        XCTAssertEqual(Pres.caption(GitFetchState(lastFetchedAt: now.addingTimeInterval(-150)), now: now), "Fetched 2m ago")
        XCTAssertEqual(Pres.caption(GitFetchState(lastFetchedAt: now.addingTimeInterval(-7300)), now: now), "Fetched 2h ago")
        XCTAssertEqual(Pres.caption(GitFetchState(lastFetchedAt: now.addingTimeInterval(-200_000)), now: now), "Fetched 2d ago")
        XCTAssertNil(Pres.caption(GitFetchState(noRemote: true), now: now))
    }

    func testACheckoutConfirmationNamesTheCheckout() throws {
        let result = WorkbenchGitSwitchResult(branch: "topic", needsConfirmation: [.uncommittedChanges], changes: 2)
        let confirmation = try XCTUnwrap(WorkbenchBranchPresentation.confirmation(for: result, stashing: false, checkout: true))
        XCTAssertTrue(confirmation.checkout)
        XCTAssertEqual(confirmation.title, "Check out topic from origin?")
        XCTAssertEqual(confirmation.primaryLabel, "Stash and check out")
        XCTAssertTrue(confirmation.stash)
        let agent = WorkbenchGitSwitchResult(branch: "topic", needsConfirmation: [.agentRunning])
        XCTAssertEqual(WorkbenchBranchPresentation.confirmation(for: agent, stashing: false, checkout: true)?.primaryLabel,
                       "Check out anyway")
        let plain = try XCTUnwrap(WorkbenchBranchPresentation.confirmation(for: result, stashing: false))
        XCTAssertFalse(plain.checkout, "a switch stays a switch")
        XCTAssertEqual(plain.primaryLabel, "Stash and switch")
    }
}
