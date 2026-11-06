import GRDB
import XCTest
@testable import WatchtowerCore
import WatchtowerTestSupport

/// The session row's target branch and lanes (board #987).
final class SessionTargetBranchTests: XCTestCase {
    private typealias Entry = SessionTargetBranch.Entry

    /// 1 group `feature/codex-parity` ← 2 leaf (no branch) ← 3 leaf `lane/x`;
    /// 4 group `feature/other` ← 5 leaf; 6 alone, no branch; 7 a whitespace branch.
    private let targets: [Int64: Entry] = [
        1: Entry(parentID: nil, branch: "feature/codex-parity"),
        2: Entry(parentID: 1, branch: ""),
        3: Entry(parentID: 2, branch: "lane/x"),
        4: Entry(parentID: nil, branch: "feature/other"),
        5: Entry(parentID: 4, branch: ""),
        6: Entry(parentID: nil, branch: ""),
        7: Entry(parentID: 1, branch: "  ")
    ]

    private struct Case {
        let name: String
        let bound: Int64?
        let linked: [Int64]
        let want: SessionTargetBranch?
    }

    func testResolveTable() {
        let cases: [Case] = [
            Case(name: "bound, own branch", bound: 3, linked: [], want: .one("lane/x")),
            Case(name: "bound, ancestor's branch", bound: 2, linked: [], want: .one("feature/codex-parity")),
            Case(name: "bound, blank branch → ancestor", bound: 7, linked: [], want: .one("feature/codex-parity")),
            Case(name: "bound group", bound: 1, linked: [5], want: .one("feature/codex-parity")),
            Case(name: "bound, no branch anywhere", bound: 6, linked: [5], want: nil),
            Case(name: "bound, not on the board", bound: 99, linked: [5], want: nil),
            Case(name: "unbound, leaves of one group", bound: nil, linked: [2, 7], want: .one("feature/codex-parity")),
            Case(name: "unbound, two branches", bound: nil, linked: [5, 2, 3],
                 want: .several(["feature/codex-parity", "feature/other", "lane/x"])),
            Case(name: "unbound, one without a branch", bound: nil, linked: [6, 5], want: .one("feature/other")),
            Case(name: "unbound, nothing linked", bound: nil, linked: [], want: nil),
            Case(name: "unbound, unknown targets", bound: nil, linked: [98, 99], want: nil)
        ]
        for item in cases {
            XCTAssertEqual(SessionTargetBranch.resolve(boundTargetID: item.bound, linkedTargetIDs: item.linked,
                                                       targets: targets), item.want, item.name)
        }
    }

    func testAParentCycleEndsTheWalk() {
        let cyclic: [Int64: Entry] = [1: Entry(parentID: 2, branch: ""), 2: Entry(parentID: 1, branch: "")]
        XCTAssertNil(SessionTargetBranch.effectiveBranch(of: 1, targets: cyclic))
    }

    func testIndexWalksTheWholeTree() throws {
        let queue = try TestDatabase.create()
        let (group, leaf) = try queue.write { db -> (Target, Target) in
            for (id, parent, branch) in [(1, nil, "feature/x"), (2, 1, "")] as [(Int, Int?, String)] {
                try db.execute(sql: """
                    INSERT INTO targets (id, text, level, custom_label, period_start, period_end, source_type, parent_id, branch)
                    VALUES (?, 't', 'custom', 'project', '2026-11-01', '2026-11-01', 'chat', ?, ?)
                    """, arguments: [id, parent, branch])
            }
            return try (XCTUnwrap(TargetQueries.fetchByID(db, id: 1)), XCTUnwrap(TargetQueries.fetchByID(db, id: 2)))
        }
        let leafNode = WorkbenchBoardNode(target: leaf, children: [], openComments: 0, unreadForOwner: 0)
        let roots = [WorkbenchBoardNode(target: group, children: [leafNode], openComments: 0, unreadForOwner: 0)]
        let index = SessionTargetBranch.index(roots)
        XCTAssertEqual(index, [1: Entry(parentID: nil, branch: "feature/x"), 2: Entry(parentID: 1, branch: "")])
        XCTAssertEqual(SessionTargetBranch.resolve(boundTargetID: 2, linkedTargetIDs: [], targets: index), .one("feature/x"))
    }

    // MARK: - Lanes

    private let folder = "/tmp/acme"
    private let runStart = "2026-11-06T10:00:00.000Z"
    private let before = "2026-11-06T09:59:59.999Z"
    private let after = "2026-11-06T10:05:00.000Z"

    private func record(_ root: String, _ at: String) -> SessionLanes.Record {
        SessionLanes.Record(root: root, firstAt: at)
    }

    func testLanesKeepThisRunsExistingOtherWorktrees() {
        let records = [
            record("/tmp/acme", after),                                   // the main checkout
            record("/tmp/acme/.claude/worktrees/ctl", after),             // the controller's own worktree
            record("/tmp/acme/.claude/worktrees/lane-b", after),
            record("/tmp/acme/.claude/worktrees/lane-a", runStart),       // at the run start counts
            record("/tmp/acme/.claude/worktrees/lane-a", after),          // a second branch, one root
            record("/tmp/acme/.claude/worktrees/old", before),            // an earlier run
            record("/tmp/acme/.claude/worktrees/gone", after),            // removed since
            record("/tmp/acme/.claude/worktrees/odd", "yesterday")        // unreadable stamp
        ]
        let roots = SessionLanes.roots(
            records, runStart: runStart, workbenchFolder: folder,
            placeRoot: "/tmp/acme/.claude/worktrees/ctl/"
        ) { !$0.hasSuffix("/gone") }
        XCTAssertEqual(roots, ["/tmp/acme/.claude/worktrees/lane-a", "/tmp/acme/.claude/worktrees/lane-b"])
    }

    func testARepositoryAboveTheWorkbenchFolderIsTheMainCheckout() {
        let roots = SessionLanes.roots(
            [record("/tmp", after), record("/tmp/acme-lane", after)], runStart: runStart,
            workbenchFolder: folder, placeRoot: nil
        ) { _ in true }
        XCTAssertEqual(roots, ["/tmp/acme-lane"], "a sibling whose name starts like the folder is no parent")
    }

    func testNoRunStartMeansNoLanes() {
        let records = [record("/tmp/acme/.claude/worktrees/lane-a", after)]
        XCTAssertEqual(SessionLanes.roots(records, runStart: nil, workbenchFolder: folder, placeRoot: nil) { _ in true }, [])
        XCTAssertEqual(SessionLanes.roots(records, runStart: "x", workbenchFolder: folder, placeRoot: nil) { _ in true }, [])
        XCTAssertEqual(SessionLanes.roots([], runStart: runStart, workbenchFolder: folder, placeRoot: nil) { _ in true }, [])
    }

    // MARK: - Query

    func testFetchWorkLinksReadsLinksWorktreesAndTheRunStart() throws {
        let db = try TestDatabase.create()
        let projectID = try db.write { try TestDatabase.insertWorkbench($0, folder: "/repo") }
        let otherProject = try db.write { try TestDatabase.insertWorkbench($0, folder: "/other") }
        func add(_ project: Int64) throws -> Int64 {
            try db.write { db in
                try TerminalSessionQueries.create(db, .init(
                    projectID: project, kind: .claude, title: "t", folderPath: "/repo",
                    claudeSessionID: UUID().uuidString)).id
            }
        }
        let ctl = try add(projectID), idle = try add(projectID), foreign = try add(otherProject)
        try db.write { db in
            for id in [5, 6] {
                try db.execute(sql: """
                    INSERT INTO targets (id, text, level, custom_label, period_start, period_end, source_type, project_id)
                    VALUES (?, 't', 'custom', 'project', '2026-11-01', '2026-11-01', 'chat', ?)
                    """, arguments: [id, projectID])
            }
            for (session, target) in [(ctl, 6), (ctl, 5), (foreign, 5)] as [(Int64, Int)] {
                try db.execute(sql: """
                    INSERT INTO terminal_session_targets (session_id, target_id, first_at, last_at)
                    VALUES (?, ?, '2026-11-06T10:00:00Z', '2026-11-06T10:00:00Z')
                    """, arguments: [session, target])
            }
            try db.execute(sql: "UPDATE terminal_sessions SET agent_turns = ? WHERE id = ?",
                           arguments: ["{\"since\":\"\(runStart)\"}", ctl])
            for (session, root) in [(ctl, "/repo/.claude/worktrees/a"), (foreign, "/other/.claude/worktrees/z")] {
                try db.execute(
                    sql: "INSERT INTO terminal_session_worktrees (session_id, root, branch, first_at) VALUES (?, ?, '', ?)",
                    arguments: [session, root, after])
            }
        }
        let links = try db.read { try TerminalSessionQueries.fetchWorkLinks($0, projectID: projectID) }
        XCTAssertEqual(links, [ctl: SessionWorkLinks(
            linkedTargetIDs: [5, 6], worktrees: [record("/repo/.claude/worktrees/a", after)], runStart: runStart
        )])
        XCTAssertNil(links[idle])
    }
}
