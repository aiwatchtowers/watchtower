import XCTest
import WatchtowerCore

/// The session's place (board #565, spec 2026-10-12-session-worktree-design
/// §4): which cwd is trusted, what a `--folder` envelope makes of it, and the
/// row's label.
final class SessionPlaceTests: XCTestCase {
    private let folder = "/tmp/acme"
    private let worktreeRoot = "/tmp/acme/.claude/worktrees/mobile-a"
    private let runStart = SessionAgentStatus.parseStamp("2026-10-12T10:00:00.000Z")

    private func cwdRow(_ path: String?, at: String?) -> SessionAgentCwd {
        SessionAgentCwd(sessionID: 1, path: path, at: at)
    }

    private func folderStatus(
        _ scope: WorkbenchFolderScope,
        branch: String = "feature/x",
        root: String = "",
        name: String = ""
    ) -> WorkbenchGitStatus {
        WorkbenchGitStatus(branch: branch, folderScope: scope, folderRoot: root, worktreeName: name)
    }

    private struct TrustCase {
        let name: String
        let row: SessionAgentCwd?
        let start: Date?
        let live: Bool
        let want: String?

        init(_ name: String, _ row: SessionAgentCwd?, _ start: Date?, _ live: Bool, _ want: String?) {
            (self.name, self.row, self.start, self.live, self.want) = (name, row, start, live, want)
        }
    }

    func testTrustedCwdTable() {
        let path = worktreeRoot
        let cases: [TrustCase] = [
            TrustCase("no row", nil, runStart, true, nil),
            TrustCase("no cwd", cwdRow(nil, at: nil), runStart, true, nil),
            TrustCase("empty cwd", cwdRow("", at: "2026-10-12T10:00:01.000Z"), runStart, true, nil),
            TrustCase("live, reported this run", cwdRow(path, at: "2026-10-12T10:00:01.000Z"), runStart, true, path),
            TrustCase("live, reported at the run start", cwdRow(path, at: "2026-10-12T10:00:00.000Z"), runStart, true, path),
            TrustCase("live, older than the run", cwdRow(path, at: "2026-10-12T09:59:59.999Z"), runStart, true, nil),
            TrustCase("live, unknown run start", cwdRow(path, at: "2026-10-12T10:00:01.000Z"), nil, true, nil),
            TrustCase("live, unreadable stamp", cwdRow(path, at: "yesterday"), runStart, true, nil),
            TrustCase("not live, last cwd", cwdRow(path, at: "2026-10-12T09:00:00.000Z"), runStart, false, path),
            TrustCase("not live, no stamp", cwdRow(path, at: nil), nil, false, path)
        ]
        for item in cases {
            XCTAssertEqual(SessionPlace.trustedCwd(row: item.row, runStart: item.start, live: item.live),
                           item.want, item.name)
        }
    }

    func testResolveTable() {
        let worktree = folderStatus(.worktree, root: worktreeRoot, name: "mobile-a")
        let cases: [(String, String?, WorkbenchGitStatus?, SessionPlace?)] = [
            ("no trusted cwd", nil, nil, .unknown),
            ("the workbench folder, no read", folder, nil, .main),
            ("the workbench folder with a slash", folder + "/", nil, .main),
            ("another folder, not read yet", worktreeRoot, nil, nil),
            ("main scope", folder + "/src", folderStatus(.main), .main),
            ("outside", "/tmp/copy", folderStatus(.outside), .main),
            ("unresolved", worktreeRoot, folderStatus(.unresolved), nil),
            ("worktree", worktreeRoot + "/src", worktree,
             .worktree(name: "mobile-a", root: URL(fileURLWithPath: worktreeRoot, isDirectory: true), status: worktree)),
            ("missing", worktreeRoot, folderStatus(.missing), .removed(name: "mobile-a", path: worktreeRoot))
        ]
        for (name, cwd, status, want) in cases {
            XCTAssertEqual(SessionPlace.resolvePlace(cwd: cwd, status: status, workbenchFolder: folder), want, name)
        }
    }

    /// The root is Go's `folder_root`, never the raw cwd: a cwd in a
    /// subfolder of the worktree still names the worktree's root.
    func testAWorktreeRootComesFromTheEnvelope() {
        let status = folderStatus(.worktree, root: worktreeRoot, name: "")
        guard case let .worktree(name, root, _)? = SessionPlace.resolvePlace(
            cwd: worktreeRoot + "/deep/dir", status: status, workbenchFolder: folder
        ) else { return XCTFail("not a worktree place") }
        XCTAssertEqual(root.path, worktreeRoot)
        XCTAssertEqual(name, "mobile-a", "falls back to the root's folder name")
    }

    func testLabels() {
        typealias Pres = SessionPlacePresentation
        let main = WorkbenchGitStatus(branch: "main")
        let worktree = folderStatus(.worktree, branch: "feature/x", root: worktreeRoot, name: "mobile-a")
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
