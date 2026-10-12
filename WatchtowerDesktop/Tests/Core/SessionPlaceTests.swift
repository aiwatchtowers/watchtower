import XCTest
import WatchtowerCore

/// The session's place (board #565, spec 2026-10-12-session-worktree-design
/// §4): which cwd is trusted, what a `--folder` envelope makes of it, and the
/// row's label.
final class SessionPlaceTests: XCTestCase {
    private let folder = "/tmp/acme"
    private let worktreeRoot = "/tmp/acme/.claude/worktrees/mobile-a"
    private let runStart = "2026-10-12T10:00:00.000Z"

    private func cwdRow(_ path: String?, at: String?, runStart: String? = nil) -> SessionAgentCwd {
        SessionAgentCwd(sessionID: 1, path: path, at: at, runStart: runStart)
    }

    /// The envelope of `workbench git status --folder requested`.
    private func folderStatus(
        _ scope: WorkbenchFolderScope,
        for requested: String,
        branch: String = "feature/x",
        root: String = "",
        name: String = ""
    ) -> WorkbenchGitStatus {
        WorkbenchGitStatus(branch: branch, folderRequested: requested, folderScope: scope,
                           folderRoot: root, worktreeName: name)
    }

    private struct TrustCase {
        let name: String
        let row: SessionAgentCwd?
        let live: Bool
        let want: String?

        init(_ name: String, _ row: SessionAgentCwd?, _ live: Bool, _ want: String?) {
            (self.name, self.row, self.live, self.want) = (name, row, live, want)
        }
    }

    /// The run start is the row's own run mark (`agent_turns.since`), the
    /// one Go's hooks judge a cwd against; the boundary is Go's
    /// `AgentCwd.WouldRecord` (a stamp at the run start or later belongs to
    /// the run).
    func testTrustedCwdTable() {
        let path = worktreeRoot
        let cases: [TrustCase] = [
            TrustCase("no row", nil, true, nil),
            TrustCase("no cwd", cwdRow(nil, at: nil, runStart: runStart), true, nil),
            TrustCase("empty cwd", cwdRow("", at: "2026-10-12T10:00:01.000Z", runStart: runStart), true, nil),
            TrustCase("live, reported this run", cwdRow(path, at: "2026-10-12T10:00:01.000Z", runStart: runStart), true, path),
            TrustCase("live, reported at the run start", cwdRow(path, at: runStart, runStart: runStart), true, path),
            TrustCase("live, older than the run", cwdRow(path, at: "2026-10-12T09:59:59.999Z", runStart: runStart), true, nil),
            TrustCase("live, no run mark", cwdRow(path, at: "2026-10-12T10:00:01.000Z"), true, nil),
            TrustCase("live, unreadable run mark", cwdRow(path, at: "2026-10-12T10:00:01.000Z", runStart: "x"), true, nil),
            TrustCase("live, unreadable stamp", cwdRow(path, at: "yesterday", runStart: runStart), true, nil),
            TrustCase("not live, last cwd", cwdRow(path, at: "2026-10-12T09:00:00.000Z", runStart: runStart), false, path),
            TrustCase("not live, no stamp", cwdRow(path, at: nil), false, path)
        ]
        for item in cases {
            XCTAssertEqual(SessionPlace.trustedCwd(row: item.row, live: item.live), item.want, item.name)
        }
    }

    func testResolveTable() {
        let deep = worktreeRoot + "/src"
        let worktree = folderStatus(.worktree, for: deep, root: worktreeRoot, name: "mobile-a")
        let cases: [(String, String?, WorkbenchGitStatus?, SessionPlace?)] = [
            ("no trusted cwd", nil, nil, .unknown),
            ("the workbench folder, no read", folder, nil, .main),
            ("the workbench folder with a slash", folder + "/", nil, .main),
            ("another folder, not read yet", worktreeRoot, nil, nil),
            ("main scope", folder + "/src", folderStatus(.main, for: folder + "/src"), .main),
            ("main scope, asked with a trailing slash", folder + "/src", folderStatus(.main, for: folder + "/src/"), .main),
            ("outside", "/tmp/copy", folderStatus(.outside, for: "/tmp/copy"), .main),
            ("unresolved", worktreeRoot, folderStatus(.unresolved, for: worktreeRoot), nil),
            ("worktree", deep, worktree,
             .worktree(name: "mobile-a", root: URL(fileURLWithPath: worktreeRoot, isDirectory: true), status: worktree)),
            ("missing worktree", worktreeRoot, folderStatus(.missing, for: worktreeRoot),
             .removed(name: "mobile-a", path: worktreeRoot))
        ]
        for (name, cwd, status, want) in cases {
            XCTAssertEqual(SessionPlace.resolvePlace(cwd: cwd, status: status, workbenchFolder: folder), want, name)
        }
    }

    /// Only an envelope asked about this cwd places it: the header's own
    /// status (no `--folder`, scope main) or another session's answer never
    /// makes a worktree cwd the main folder.
    func testAnEnvelopeAskedAboutAnotherFolderIsNoVerdict() {
        let header = WorkbenchGitStatus(branch: "main")
        XCTAssertEqual(header.folderScope, .main)
        XCTAssertNil(SessionPlace.resolvePlace(cwd: worktreeRoot, status: header, workbenchFolder: folder))
        XCTAssertNil(SessionPlace.resolvePlace(cwd: folder + "/src", status: header, workbenchFolder: folder),
                     "a folder inside the workbench folder needs its own read too")
        let other = folderStatus(.main, for: folder + "/docs")
        XCTAssertNil(SessionPlace.resolvePlace(cwd: worktreeRoot, status: other, workbenchFolder: folder))
    }

    /// A missing cwd is a removed worktree only when it was one; any other
    /// missing folder is unknown (shown as the main folder, counted as maybe
    /// in any worktree by the agent check).
    func testAMissingFolderIsRemovedOnlyWhenItWasAWorktree() {
        let build = folder + "/build"
        XCTAssertEqual(SessionPlace.resolvePlace(cwd: build, status: folderStatus(.missing, for: build),
                                                 workbenchFolder: folder), .unknown)
        XCTAssertEqual(SessionPlace.resolvePlace(cwd: "/tmp/gone", status: folderStatus(.missing, for: "/tmp/gone"),
                                                 workbenchFolder: folder), .unknown)
        let deep = worktreeRoot + "/deep/dir"
        XCTAssertEqual(SessionPlace.resolvePlace(cwd: deep, status: folderStatus(.missing, for: deep),
                                                 workbenchFolder: folder),
                       .removed(name: "mobile-a", path: deep), "named after the worktree, not the cwd's folder")
    }

    /// A worktree outside `.claude/worktrees` is known removed only from the
    /// place it last had.
    func testAMissingFolderInTheLastKnownWorktreeIsRemoved() {
        let root = "/tmp/elsewhere/feature-b"
        let lastStatus = folderStatus(.worktree, for: root, root: root, name: "feature-b")
        let last = SessionPlace.worktree(name: "feature-b", root: URL(fileURLWithPath: root, isDirectory: true),
                                         status: lastStatus)
        let deep = root + "/pkg"
        let missing = folderStatus(.missing, for: deep)
        XCTAssertEqual(SessionPlace.resolvePlace(cwd: deep, status: missing, workbenchFolder: folder, last: last),
                       .removed(name: "feature-b", path: deep))
        XCTAssertEqual(SessionPlace.resolvePlace(cwd: deep, status: missing, workbenchFolder: folder, last: .main),
                       .unknown)
        let stillRemoved = SessionPlace.removed(name: "feature-b", path: deep)
        XCTAssertEqual(SessionPlace.resolvePlace(cwd: deep, status: missing, workbenchFolder: folder,
                                                 last: stillRemoved), stillRemoved)
        let sibling = "/tmp/elsewhere/feature-bb"
        let siblingPlace = SessionPlace.resolvePlace(cwd: sibling, status: folderStatus(.missing, for: sibling),
                                                     workbenchFolder: folder, last: last)
        XCTAssertEqual(siblingPlace, .unknown, "a sibling sharing the root's prefix is not inside it")
    }

    /// The root is Go's `folder_root`, never the raw cwd: a cwd in a
    /// subfolder of the worktree still names the worktree's root.
    func testAWorktreeRootComesFromTheEnvelope() {
        let deep = worktreeRoot + "/deep/dir"
        let status = folderStatus(.worktree, for: deep, root: worktreeRoot, name: "")
        guard case let .worktree(name, root, _)? = SessionPlace.resolvePlace(
            cwd: deep, status: status, workbenchFolder: folder
        ) else { return XCTFail("not a worktree place") }
        XCTAssertEqual(root.path, worktreeRoot)
        XCTAssertEqual(name, "mobile-a", "falls back to the root's folder name")
    }

    func testLabels() {
        typealias Pres = SessionPlacePresentation
        let main = WorkbenchGitStatus(branch: "main")
        let worktree = folderStatus(.worktree, for: worktreeRoot, branch: "feature/x", root: worktreeRoot, name: "mobile-a")
        let worktreePlace = SessionPlace.worktree(
            name: "mobile-a", root: URL(fileURLWithPath: worktreeRoot, isDirectory: true), status: worktree
        )
        XCTAssertEqual(Pres.placeLabel(worktreePlace, mainStatus: main).text, "⑂ mobile-a · feature/x")
        XCTAssertEqual(Pres.placeLabel(worktreePlace, mainStatus: main).systemImage, "arrow.triangle.branch")
        XCTAssertEqual(Pres.placeLabel(.main, mainStatus: main).text, "main folder · main")
        XCTAssertEqual(Pres.placeLabel(.unknown, mainStatus: main).text, "main folder · main")
        XCTAssertEqual(Pres.placeLabel(.unknown, mainStatus: nil).text, "main folder")
        let removed = Pres.placeLabel(.removed(name: "mobile-a", path: worktreeRoot), mainStatus: main)
        XCTAssertEqual(removed.text, "worktree removed")
        XCTAssertTrue(removed.help.contains(worktreeRoot))
    }

    func testLabelsForADetachedAnUnbornAndAnUnreadableBranch() {
        typealias Pres = SessionPlacePresentation
        let detached = WorkbenchGitStatus(branch: "", detached: true, head: "1a2b3c4")
        XCTAssertEqual(Pres.placeLabel(.main, mainStatus: detached).text, "main folder · 1a2b3c4")
        let unborn = WorkbenchGitStatus(branch: "trunk", unborn: true)
        XCTAssertEqual(Pres.placeLabel(.main, mainStatus: unborn).text, "main folder · trunk")
        let unreadable = WorkbenchGitStatus(branch: "main", statusOK: false)
        XCTAssertEqual(Pres.placeLabel(.main, mainStatus: unreadable).text, "main folder")
        let noGit = WorkbenchGitStatus(git: false)
        XCTAssertEqual(Pres.placeLabel(.unknown, mainStatus: noGit).text, "main folder")
        let worktreeUnreadable = WorkbenchGitStatus(branch: "x", statusOK: false, folderScope: .worktree)
        let place = SessionPlace.worktree(name: "mobile-a", root: URL(fileURLWithPath: worktreeRoot),
                                          status: worktreeUnreadable)
        XCTAssertEqual(Pres.placeLabel(place, mainStatus: nil).text, "⑂ mobile-a")
    }
}
