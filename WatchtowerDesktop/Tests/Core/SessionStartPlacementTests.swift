import XCTest
@testable import WatchtowerCore

final class SessionStartPlacementTests: XCTestCase {
    private func status(git: Bool = true, available: Bool = true, unborn: Bool = false, ok: Bool = true) -> WorkbenchGitStatus {
        WorkbenchGitStatus(gitAvailable: available, git: git, unborn: unborn, statusOK: ok)
    }

    private func row(folderPath: String, worktreeBranch: String? = nil) -> TerminalSession {
        TerminalSession(
            id: 1, projectID: 1, kind: .claude, title: "S", titleSource: .auto, targetID: nil,
            folderPath: folderPath, claudeSessionID: "uuid", createdAt: "2026-10-14T10:00:00.000Z",
            lastActiveAt: "2026-10-14T10:00:00.000Z", worktreeBranch: worktreeBranch
        )
    }

    func testAutoUsesTheFolderWhenFree() {
        XCTAssertEqual(SessionStartPlacement.decide(choice: .auto, gitStatus: status(), occupied: false), .folder(note: nil))
    }

    func testAutoUsesAWorktreeWhenOccupied() {
        XCTAssertEqual(SessionStartPlacement.decide(choice: .auto, gitStatus: status(), occupied: true), .worktree)
    }

    func testOverridesWin() {
        XCTAssertEqual(SessionStartPlacement.decide(choice: .folder, gitStatus: status(), occupied: true), .folder(note: nil))
        XCTAssertEqual(SessionStartPlacement.decide(choice: .worktree, gitStatus: status(), occupied: false), .worktree)
    }

    func testNoWorktreeWithoutGitOrACommit() {
        let cases: [WorkbenchGitStatus?] = [status(git: false), status(available: false), status(unborn: true), status(ok: false), nil]
        for s in cases {
            guard case .folder(let note) = SessionStartPlacement.decide(choice: .auto, gitStatus: s, occupied: true) else {
                return XCTFail("\(String(describing: s))")
            }
            XCTAssertNotNil(note, "an implied worktree that cannot be made says why")
            XCTAssertNotNil(SessionStartPlacement.unavailableReason(s))
        }
        XCTAssertEqual(SessionStartPlacement.decide(choice: .auto, gitStatus: status(git: false), occupied: false), .folder(note: nil),
                       "a lone session in a plain folder needs no note")
        XCTAssertNil(SessionStartPlacement.unavailableReason(status()))
    }

    func testOccupancyFollowsThePlace() {
        let folder = "/repo"
        let plain = row(folderPath: folder)
        let placed = row(folderPath: "/repo/.claude/worktrees/a", worktreeBranch: "wt/a")
        XCTAssertTrue(
            SessionStartPlacement.occupies(row: plain, place: .unknown, workbenchFolder: folder), "fresh, before its first hook"
        )
        XCTAssertTrue(SessionStartPlacement.occupies(row: plain, place: .main, workbenchFolder: folder))
        XCTAssertFalse(
            SessionStartPlacement.occupies(row: placed, place: .unknown, workbenchFolder: folder), "placed, before its first hook"
        )
        XCTAssertTrue(SessionStartPlacement.occupies(row: placed, place: .main, workbenchFolder: folder), "an agent that cd'd back")
        let removed = SessionPlace.removed(name: "x", path: "/repo/.claude/worktrees/x")
        XCTAssertFalse(SessionStartPlacement.occupies(row: plain, place: removed, workbenchFolder: folder))
    }

    func testSlug() {
        let text = "Параллельные Sessions & worktrees!"
        XCTAssertEqual(SessionStartPlacement.slug(targetID: 229, targetText: text, sessionNumber: 3), "229-sessions-worktrees")
        XCTAssertEqual(SessionStartPlacement.slug(targetID: nil, targetText: nil, sessionNumber: 3), "session-3")
        let long = SessionStartPlacement.slug(targetID: 1, targetText: String(repeating: "word ", count: 30), sessionNumber: 1)
        XCTAssertLessThanOrEqual(long.count, 40)
        XCTAssertFalse(SessionStartPlacement.slug(targetID: 1, targetText: String(repeating: "ab ", count: 30), sessionNumber: 1).hasSuffix("-"))
    }

    func testWorktreeTopOfACwd() {
        XCTAssertEqual(SessionStartPlacement.worktreeTop(ofCwd: "/r/.claude/worktrees/a"), "/r/.claude/worktrees/a")
        XCTAssertEqual(SessionStartPlacement.worktreeTop(ofCwd: "/r/.claude/worktrees/a/app/web"), "/r/.claude/worktrees/a")
        XCTAssertNil(SessionStartPlacement.worktreeTop(ofCwd: "/r/elsewhere"))
        XCTAssertNil(SessionStartPlacement.worktreeTop(ofCwd: "/r/.claude/worktrees"))
    }

    private func held(_ id: Int64, _ folder: String, at createdAt: String) -> TerminalSession {
        var r = row(folderPath: folder, worktreeBranch: "wt/x")
        r.id = id
        r.title = "s\(id)"
        r.createdAt = createdAt
        return r
    }

    func testLaterHolderIsALaterRowInTheSameWorktree() {
        let top = "/r/.claude/worktrees/session-10-2"
        let me = held(10, top, at: "2026-10-14T10:00:00Z")
        let later = held(12, top + "/app", at: "2026-10-15T10:00:00Z")
        let latest = held(13, top, at: "2026-10-16T10:00:00Z")
        let holder = SessionStartPlacement.laterHolder(of: top, row: me, among: [me, later, latest])
        XCTAssertEqual(holder?.id, 13, "the latest of the later rows")
    }

    func testLaterHolderIgnoresItselfEarlierRowsAndOtherWorktrees() {
        let top = "/r/.claude/worktrees/session-10-2"
        let me = held(10, top, at: "2026-10-14T10:00:00Z")
        let earlier = held(4, top, at: "2026-10-01T10:00:00Z")
        let sibling = held(11, "/r/.claude/worktrees/session-10-20", at: "2026-10-15T10:00:00Z")
        let mainFolder = held(12, "/r", at: "2026-10-15T10:00:00Z")
        XCTAssertNil(SessionStartPlacement.laterHolder(of: top, row: me, among: [me, earlier, sibling, mainFolder]))
        XCTAssertNil(SessionStartPlacement.laterHolder(of: top, row: me, among: []))
    }

    func testLaterHolderBreaksATieOnTheSameSecondById() {
        let top = "/r/.claude/worktrees/a"
        let me = held(10, top, at: "2026-10-14T10:00:00Z")
        let sameSecondHigher = held(11, top, at: "2026-10-14T10:00:00Z")
        let sameSecondLower = held(9, top, at: "2026-10-14T10:00:00Z")
        XCTAssertEqual(SessionStartPlacement.laterHolder(of: top, row: me, among: [sameSecondLower, sameSecondHigher])?.id, 11)
        XCTAssertNil(SessionStartPlacement.laterHolder(of: top, row: me, among: [sameSecondLower]))
    }
}
