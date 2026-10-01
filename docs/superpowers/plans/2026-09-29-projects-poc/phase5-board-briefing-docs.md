# Projects POC — Phase 5: Board, Targets-tab exclusions, briefing, docs (Tasks 19–22)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Desktop project page a working **Board** pane, keep project targets out of every Targets-tab surface (PROJ-01, Swift side), make project deletion from the Desktop safe while Claude Code is connected (Review Focus #5, Desktop side), add a **Projects** block to the daily briefing, and ship the docs + the manual QA checklist.

**Architecture:** The board reads the tree through Phase 4's `ProjectQueries.board` and edits status/title with the existing `TargetQueries` mutators (the targets dual-path precedent — Go and Swift both write `targets`). Agent writes come from another process (`watchtower mcp --project N`), which GRDB's `ValueObservation` never sees, so the board refreshes on a cheap fingerprint poll. Deletion is `ProjectsViewModel.deleteProject(_:)` (the VM lives on `AppState`, so it survives navigation): close the terminal → `watchtower project delete N` → reload. The briefing gains `gatherProjects` (mechanical, no AI) rendered as `=== PROJECTS ===` before `=== MEMORY REVISIONS ===` (which must stay last — `memoryRevisionsSection` in the tests reads to end of prompt); `briefing.daily` v7 → v8, and `getPrompt` falls back to the default when a stored template's `%s` count no longer matches.

**Tech Stack:** Go 1.25 (`internal/briefing`, `internal/prompts`), SwiftUI macOS 14+, GRDB 7, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-29-project-board-poc-design.md` (§4.5, §6.4, §6.1 Delete, §7, §10). **Plan index (binding):** `docs/superpowers/plans/2026-09-29-projects-poc.md` — Global Constraints, Review Focus and "Tasks & cross-task interfaces" apply to every task below.

## Interface assumptions from earlier phases

This phase is written in parallel with Phases 1–4; the Phase 4 names below were confirmed by the Phase 4 author (`phase4-desktop-terminal-docs.md`). **Before each task, run its Step 0 grep.** If an earlier task landed a name or signature differently, adapt the code in THIS phase to the real one — never rename an earlier task's API. Everything assumed here is repeated under "Interface errata" at the end.

- **Phase 1 (Go, package `db`; confirmed against `phase1-go-core.md`):** `Project{ID int64; Name, FolderPath, Description, CreatedAt, UpdatedAt string}`, `ProjectDocument{ID, ProjectID int64; TargetID sql.NullInt64; RelPath, Kind, Title, CreatedAt, UpdatedAt string}`, `ProjectComment{ID, ProjectID int64; TargetID, DocumentID, ParentID sql.NullInt64; Author, AgentLabel, Body, AnchorQuote, AnchorPrefix, AnchorSuffix, AnchorHeading, Status, CreatedAt, ReadAt string}`, `ProjectCommentFilter{ProjectID, TargetID, DocumentID int64; NewForAgent bool}`; `CreateProject(name, folder string) (int64, error)`, `ListProjects() ([]Project, error)`, `ListProjectDocuments(projectID int64) ([]ProjectDocument, error)`, `UpsertProjectDocument(d ProjectDocument) (int64, bool, error)`, `AddProjectComment(c ProjectComment) (int64, error)`, `ListProjectComments(f ProjectCommentFilter) ([]ProjectComment, error)`, `CreateProjectTarget(projectID int64, parentID sql.NullInt64, title, intent string) (int64, error)`, `BoardNode{Target Target; Children []BoardNode; NewForAgent, UnreadForOwner int; Documents []ProjectDocument}`, `GetProjectBoard(projectID int64) ([]BoardNode, error)` — `BoardNode.Target` is the existing `db.Target` (`ID int`), and the call does **not** check that the project exists (an unknown id is an empty board; `gatherProjects` only asks for ids `ListProjects` just returned). `ErrNotInProject` (Task 2) is the scope sentinel; `targets.ErrProjectTarget` (Task 3) is what next-step returns for a project target. `GetTargetsForBriefing` already excludes project targets (Task 3 — `project_id IS NULL`), so the briefing's YOUR TARGETS input never carries one and PROJECTS is their only way into the briefing. `project brief` failure lines (Task 5): `Watchtower: project N no longer exists.`, `Watchtower: project N folder <path> is missing (moved or deleted?).`, `Watchtower: project N is unavailable: <reason>.`
- **Phase 4 (Swift, WatchtowerCore, all `package`):** `Project` (`id: Int64`, `name`, `folderPath`, …); `ProjectDocument` (`id: Int64`, `title`, `relPath`, …); `ProjectComment: FetchableRecord, Identifiable, Equatable, Hashable` (`id`/`projectID: Int64`; `targetID`/`documentID`/`parentID: Int64?`; `author` `"owner"|"agent"`, `agentLabel`, `body`, `anchorQuote`/`anchorPrefix`/`anchorSuffix`/`anchorHeading`, `status` `"open"|"resolved"|"outdated"`, `createdAt`, `readAt` (`""` = unread); computed `isRoot`, `isAgent`, `isOpen`, `isUnreadForOwner`, `anchor`); `ProjectCommentThread: Identifiable, Equatable` (`root`, `replies`, `id: Int64`, `static func group(_:)`); `ProjectBoardNode: Identifiable, Equatable` (`let target: Target`, `let children: [ProjectBoardNode]`, `let openComments: Int` — open roots on the target, `let unreadForOwner: Int` — agent comments with empty `read_at`, `let documents: [ProjectDocument]`, `var id: Int { target.id }`); `ProjectPane` (`.terminal|.board|.documents`), `ProjectSubject` (`.document(Int64)`, `.target(Int64)`). `enum ProjectQueries`, every function sync `throws` with `_ db: Database` first: `board(_:projectID:) -> [ProjectBoardNode]` (roots in_progress, blocked, todo, done, others; then id), `comments(_:targetID: Int64) -> [ProjectComment]` (ordered `created_at, id`), `@discardableResult addOwnerComment(_:projectID:targetID: Int64?:documentID: Int64?:anchor: CommentAnchor?:body:) -> Int64` (throws `ProjectQueryError` on empty body/no subject/foreign subject), `@discardableResult reply(_:to rootID: Int64, body:) -> Int64`, `setStatus(_:commentID:status:)` (roots only; `open|resolved|outdated`), `markAgentCommentsRead(_:projectID:targetID: Int64?:documentID: Int64?)` (nil widens), `fetch(_:id:) -> Project?`. `Target.projectID` is **not** added in Phase 4 — Task 20 adds it. Test fixtures `Tests/Support/TestDatabase+Projects.swift` (`insertProject`, `insertProjectTarget`, `insertProjectDocument`, `insertProjectComment`) exist; this phase keeps its own raw-SQL fixtures so a fixture signature change cannot break these guards.
- **Phase 4 (Swift, app target):** `CommentThreadView(thread: ProjectCommentThread, isActive: Bool = false, onReply: @escaping (String) async -> Void, onResolve: @escaping () async -> Void, onReopen: @escaping () async -> Void)`; `ProjectPageView(vm: ProjectsViewModel, project: Project)` whose `paneContent` renders `.board` as `ProjectPanePlaceholder(title: "Board")` and whose header is an `HStack` (name + folder link, install badge/Repair, pane picker); `ProjectCLI(runner:)` with `delete(projectID: Int64) async throws` (no caller yet); `ProjectTerminalCenter` (`@MainActor @Observable`, `AppState.projectTerminalCenter` — a `let`) with `close(projectID: Int64) async` (SIGHUP → SIGKILL after 3 s, removes the session); `ProjectsViewModel` (`@MainActor @Observable`, `AppState.projectsViewModel: ProjectsViewModel?`, `private(set)`, created in `AppState.initProjects(dbPool:cliRunner:notifier:)`) with `reload() async` (re-reads summaries; a deleted project drops out), `selectedProjectID: Int64?`, a private `cli: ProjectCLI`, and `onOwnerWrite: ((Int64, ProjectSubject) -> Void)?` — every owner board write must call it so the owner's own writes never notify.

## Phase-specific review focus

1. **Out-of-process writes.** The agent writes through a different process; the board must reflect them without the owner re-opening the page → Task 19 `refreshIfChanged` test writes through a second `DatabasePool` on the same file.
2. **Mark-read ordering.** Viewing a target marks its agent comments read; the unread badge must only drop after the write succeeds (review-rules "Error handling") → Task 19 failure test.
3. **A done parent with open children.** "Hide done" must not hide an open sub-target under a done parent → Task 19 outline test.
4. **Project targets leak into Targets surfaces** — list, counts, badge, tag menu, the `@` picker, and the "Wipe LLM data" button (project targets are `source_type='chat'`, which that button deletes today) → Task 20 `testProj01…` + wipe test.
5. **Delete while connected** — terminal closed before the CLI runs; a CLI failure leaves the project listed with the error shown; a project that vanishes from outside (a CLI `project delete`) closes its terminal → Task 20 flow tests.
7. **The owner's own board writes never notify** — every successful status/title/comment/reply/resolve calls `ProjectsViewModel.onOwnerWrite` with `.target(id)`; a failed write does not → Task 19 hook tests.
6. **A customized old `briefing.daily`** with 15 `%s` must not produce `%!(EXTRA …)` garbage in the prompt → Task 21 fallback test.

---

### Task 19: Board pane

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/ProjectBoardOutline.swift`
- Create: `WatchtowerDesktop/Sources/ViewModels/ProjectBoardViewModel.swift`
- Create: `WatchtowerDesktop/Sources/Views/Projects/ProjectBoardView.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Projects/ProjectPageView.swift` (Task 14 — replace the Board placeholder)
- Test: `WatchtowerDesktop/Tests/Core/ProjectBoardOutlineTests.swift`, `WatchtowerDesktop/Tests/ProjectBoardViewModelTests.swift`

**Interfaces:**
- Consumes: Phase 4 `ProjectBoardNode`, `ProjectComment`, `ProjectCommentThread`, `ProjectSubject`, `ProjectQueries.board/comments/addOwnerComment/reply/setStatus/markAgentCommentsRead`, `CommentThreadView`, `ProjectPageView`, `ProjectsViewModel.onOwnerWrite`; existing `TargetQueries.updateStatus(_:id:status:)`, `TargetQueries.updateText(_:id:text:)`, `Target.statusIcon`, `Target.statusColor`.
- Produces (Core): `struct ProjectBoardRow { node: ProjectBoardNode; depth: Int; hasChildren: Bool; id: Int }`, `enum ProjectBoardOutline { static func rows(_:collapsed:showDone:) -> [ProjectBoardRow]; static func find(_:in:) -> ProjectBoardNode? }`.
- Produces (app): `ProjectBoardViewModel(dbPool: DatabasePool, projectID: Int64)` with `roots`, `collapsed`, `showDone`, `rows`, `selectedTargetID`, `selectedNode`, `threads`, `errorMessage`, `load()`, `refreshIfChanged() -> Bool`, `select(_:)`, `toggle(_:)`, `setStatus(_:)`, `rename(_:)`, `addComment(_:)`, `reply(to:body:)`, `setThreadStatus(rootID:status:)`, `startPolling(every:)`, `stopPolling()`, `onOwnerWrite: ((Int64, ProjectSubject) -> Void)?`; `ProjectBoardView(projectID: Int64)`; `static let ProjectBoardViewModel.editableStatuses`.

- [ ] **Step 0: Confirm the Phase 4 names**

Run:
```bash
cd WatchtowerDesktop
grep -n "struct ProjectBoardNode\|struct ProjectComment\b\|struct ProjectComment:" -A14 Sources/WatchtowerCore/Models/Project.swift
grep -n "static func board\|static func comments\|static func addOwnerComment\|static func reply\|static func setStatus\|static func markAgentCommentsRead" Sources/WatchtowerCore/Database/Queries/ProjectQueries.swift
grep -n "init(\|thread:\|onReply\|onResolve\|onReopen" Sources/Views/Projects/CommentThreadView.swift
grep -n "ProjectPanePlaceholder\|case .board\|HStack" Sources/Views/Projects/ProjectPageView.swift
grep -n "onOwnerWrite\|selectedProjectID\|func reload\|private let cli\|var summaries\|var projects" Sources/ViewModels/ProjectsViewModel.swift
```
Expected: the fields and signatures listed under "Interface assumptions". Adapt the code below to any drift (never rename a Phase 4 API).

- [ ] **Step 1: Write the failing Core tests**

Create `WatchtowerDesktop/Tests/Core/ProjectBoardOutlineTests.swift`:

```swift
import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class ProjectBoardOutlineTests: XCTestCase {

    // Builds real Target rows through the DB so the fixture never drifts from
    // Target's own row decoding.
    private func target(_ id: Int, _ text: String, status: String = "todo") throws -> Target {
        let queue = try TestDatabase.create()
        return try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO targets (id, text, level, custom_label, period_start, period_end,
                        status, source_type, ownership)
                    VALUES (?, ?, 'custom', 'project', '2026-09-29', '2026-09-29', ?, 'chat', 'mine')
                    """,
                arguments: [id, text, status]
            )
            return try XCTUnwrap(TargetQueries.fetchByID(db, id: id))
        }
    }

    private func node(_ t: Target, _ children: [ProjectBoardNode] = []) -> ProjectBoardNode {
        ProjectBoardNode(target: t, children: children, openComments: 0, unreadForOwner: 0, documents: [])
    }

    func testRowsFlattenDepthFirstWithDepth() throws {
        let tree = [
            node(try target(1, "Feature"), [
                node(try target(2, "Task 1")),
                node(try target(3, "Task 2"), [node(try target(4, "Step"))]),
            ]),
            node(try target(5, "Other")),
        ]
        let rows = ProjectBoardOutline.rows(tree, collapsed: [], showDone: true)
        XCTAssertEqual(rows.map(\.id), [1, 2, 3, 4, 5])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 1, 2, 0])
        XCTAssertEqual(rows.map(\.hasChildren), [true, false, true, false, false])
    }

    func testCollapsedNodeHidesItsSubtreeButNotItself() throws {
        let tree = [node(try target(1, "Feature"), [node(try target(2, "Task"), [node(try target(3, "Step"))])])]
        let rows = ProjectBoardOutline.rows(tree, collapsed: [2], showDone: true)
        XCTAssertEqual(rows.map(\.id), [1, 2])
    }

    func testHideDoneKeepsADoneParentWithAnOpenChild() throws {
        let tree = [
            node(try target(1, "Done feature", status: "done"), [
                node(try target(2, "Open task")),
                node(try target(3, "Done task", status: "done")),
            ]),
            node(try target(4, "Dismissed", status: "dismissed")),
        ]
        let rows = ProjectBoardOutline.rows(tree, collapsed: [], showDone: false)
        XCTAssertEqual(rows.map(\.id), [1, 2], "a closed node stays while any descendant is open")
    }

    func testFindLocatesANestedNode() throws {
        let tree = [node(try target(1, "Feature"), [node(try target(2, "Task"))])]
        XCTAssertEqual(ProjectBoardOutline.find(2, in: tree)?.target.text, "Task")
        XCTAssertNil(ProjectBoardOutline.find(99, in: tree))
    }
}
```

`ProjectBoardNode`'s synthesized memberwise init is `internal`; `@testable import WatchtowerCore` makes it visible here, so no production init is needed.

- [ ] **Step 2: Run to verify they fail**

Run: `make test-swift FILTER=ProjectBoardOutlineTests > /tmp/p5-19a.log 2>&1; echo "exit=$?"; grep -E "error:|failed|passed" /tmp/p5-19a.log | head -20`
Expected: `exit=1`, compile error `cannot find 'ProjectBoardOutline' in scope`.

- [ ] **Step 3: Implement the Core outline**

Create `WatchtowerDesktop/Sources/WatchtowerCore/Services/ProjectBoardOutline.swift`:

```swift
import Foundation

/// One visible line of the project board: a node plus its indentation.
package struct ProjectBoardRow: Identifiable {
    package let node: ProjectBoardNode
    package let depth: Int
    package let hasChildren: Bool
    package var id: Int { node.target.id }
}

/// Pure flattening of the board tree for the Board pane. No I/O.
package enum ProjectBoardOutline {
    /// Depth-first rows. A collapsed node keeps its row and hides its subtree.
    /// With `showDone == false` a done/dismissed node is hidden only when it has
    /// no open descendant — hiding a done feature must never hide its open task.
    package static func rows(
        _ roots: [ProjectBoardNode], collapsed: Set<Int>, showDone: Bool
    ) -> [ProjectBoardRow] {
        var out: [ProjectBoardRow] = []
        append(roots, depth: 0, collapsed: collapsed, showDone: showDone, into: &out)
        return out
    }

    package static func find(_ targetID: Int, in nodes: [ProjectBoardNode]) -> ProjectBoardNode? {
        for n in nodes {
            if n.target.id == targetID { return n }
            if let hit = find(targetID, in: n.children) { return hit }
        }
        return nil
    }

    private static func append(
        _ nodes: [ProjectBoardNode], depth: Int, collapsed: Set<Int>, showDone: Bool,
        into out: inout [ProjectBoardRow]
    ) {
        for n in nodes where showDone || hasOpenWork(n) {
            out.append(ProjectBoardRow(node: n, depth: depth, hasChildren: !n.children.isEmpty))
            if !collapsed.contains(n.target.id) {
                append(n.children, depth: depth + 1, collapsed: collapsed, showDone: showDone, into: &out)
            }
        }
    }

    private static func hasOpenWork(_ n: ProjectBoardNode) -> Bool {
        if !isClosed(n.target.status) { return true }
        return n.children.contains(where: hasOpenWork)
    }

    private static func isClosed(_ status: String) -> Bool {
        status == "done" || status == "dismissed"
    }
}

```

- [ ] **Step 4: Run to verify they pass**

Run: `make test-swift FILTER=ProjectBoardOutlineTests > /tmp/p5-19a.log 2>&1; echo "exit=$?"; grep -E "error:|failed|Executed" /tmp/p5-19a.log | head -20`
Expected: `exit=0`, `Executed 4 tests, with 0 failures`.

- [ ] **Step 5: Write the failing ViewModel tests**

Create `WatchtowerDesktop/Tests/ProjectBoardViewModelTests.swift`:

```swift
import XCTest
import GRDB
import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerTestSupport

@MainActor
final class ProjectBoardViewModelTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        do {
            (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        } catch {
            XCTFail("setUp failed: \(error)")
        }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        super.tearDown()
    }

    // MARK: - Fixtures (raw SQL: the board must work on rows the Go side wrote)

    nonisolated private static func insertProject(_ db: Database, name: String = "acme") throws -> Int64 {
        try db.execute(
            sql: "INSERT INTO projects (name, folder_path) VALUES (?, ?)",
            arguments: [name, "/tmp/\(name)-\(UUID().uuidString)"]
        )
        return db.lastInsertedRowID
    }

    nonisolated private static func insertTarget(
        _ db: Database, project: Int64, text: String, parent: Int64? = nil, status: String = "todo"
    ) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO targets (text, level, custom_label, period_start, period_end,
                    parent_id, status, source_type, ownership, project_id)
                VALUES (?, 'custom', 'project', '2026-09-29', '2026-09-29', ?, ?, 'chat', 'mine', ?)
                """,
            arguments: [text, parent, status, project]
        )
        return db.lastInsertedRowID
    }

    nonisolated private static func insertComment(
        _ db: Database, project: Int64, target: Int64, author: String, body: String, parent: Int64? = nil
    ) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO project_comments (project_id, target_id, parent_id, author, body)
                VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [project, target, parent, author, body]
        )
        return db.lastInsertedRowID
    }

    private func makeVM(project: Int64) -> ProjectBoardViewModel {
        ProjectBoardViewModel(dbPool: dbManager.dbPool, projectID: project)
    }

    // MARK: - Tree

    func testLoadBuildsTheTreeForThisProjectOnly() throws {
        let (pid, feature, task) = try dbManager.dbPool.write { db -> (Int64, Int64, Int64) in
            let pid = try Self.insertProject(db)
            let other = try Self.insertProject(db, name: "other")
            let feature = try Self.insertTarget(db, project: pid, text: "Feature")
            let task = try Self.insertTarget(db, project: pid, text: "Task 1", parent: feature)
            _ = try Self.insertTarget(db, project: other, text: "Foreign")
            return (pid, feature, task)
        }
        let vm = makeVM(project: pid)
        vm.load()

        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.rows.map(\.id), [Int(feature), Int(task)])
        XCTAssertEqual(vm.rows.map(\.depth), [0, 1])
    }

    // MARK: - Status / title edits

    func testSetStatusWritesTheSelectedTargetAndReloads() throws {
        let (pid, tid) = try dbManager.dbPool.write { db -> (Int64, Int64) in
            let pid = try Self.insertProject(db)
            return (pid, try Self.insertTarget(db, project: pid, text: "Task"))
        }
        let vm = makeVM(project: pid)
        vm.load()
        vm.select(Int(tid))
        vm.setStatus("in_progress")

        let stored = try dbManager.dbPool.read { try TargetQueries.fetchByID($0, id: Int(tid)) }
        XCTAssertEqual(stored?.status, "in_progress")
        XCTAssertEqual(vm.selectedNode?.target.status, "in_progress")
    }

    func testSetStatusRejectsAStatusTheBoardDoesNotOffer() throws {
        let (pid, tid) = try dbManager.dbPool.write { db -> (Int64, Int64) in
            let pid = try Self.insertProject(db)
            return (pid, try Self.insertTarget(db, project: pid, text: "Task"))
        }
        let vm = makeVM(project: pid)
        vm.load()
        vm.select(Int(tid))
        vm.setStatus("snoozed")

        let stored = try dbManager.dbPool.read { try TargetQueries.fetchByID($0, id: Int(tid)) }
        XCTAssertEqual(stored?.status, "todo")
    }

    func testRenameTrimsAndIgnoresBlank() throws {
        let (pid, tid) = try dbManager.dbPool.write { db -> (Int64, Int64) in
            let pid = try Self.insertProject(db)
            return (pid, try Self.insertTarget(db, project: pid, text: "Old"))
        }
        let vm = makeVM(project: pid)
        vm.load()
        vm.select(Int(tid))
        vm.rename("   ")
        XCTAssertEqual(vm.selectedNode?.target.text, "Old")
        vm.rename("  New title \n")
        XCTAssertEqual(vm.selectedNode?.target.text, "New title")
    }

    // MARK: - Comments

    func testAddCommentCreatesAnOwnerRootOnTheSelectedTarget() throws {
        let (pid, tid) = try dbManager.dbPool.write { db -> (Int64, Int64) in
            let pid = try Self.insertProject(db)
            return (pid, try Self.insertTarget(db, project: pid, text: "Task"))
        }
        let vm = makeVM(project: pid)
        vm.load()
        vm.select(Int(tid))
        vm.addComment("  Use the v2 endpoint  ")

        XCTAssertEqual(vm.threads.count, 1)
        XCTAssertEqual(vm.threads.first?.root.author, "owner")
        XCTAssertEqual(vm.threads.first?.root.body, "Use the v2 endpoint")
        XCTAssertEqual(vm.selectedNode?.openComments, 1)
    }

    func testReplyAndResolveAThread() throws {
        let (pid, tid, root) = try dbManager.dbPool.write { db -> (Int64, Int64, Int64) in
            let pid = try Self.insertProject(db)
            let tid = try Self.insertTarget(db, project: pid, text: "Task")
            let root = try Self.insertComment(db, project: pid, target: tid, author: "agent", body: "Which API?")
            return (pid, tid, root)
        }
        let vm = makeVM(project: pid)
        vm.load()
        vm.select(Int(tid))
        vm.reply(to: root, body: "v2")
        vm.setThreadStatus(rootID: root, status: "resolved")

        XCTAssertEqual(vm.threads.first?.replies.map(\.body), ["v2"])
        XCTAssertEqual(vm.threads.first?.root.status, "resolved")
    }

    func testEveryOwnerWriteReportsItsTargetToTheNotificationHook() throws {
        let (pid, tid) = try dbManager.dbPool.write { db -> (Int64, Int64) in
            let pid = try Self.insertProject(db)
            return (pid, try Self.insertTarget(db, project: pid, text: "Task"))
        }
        let vm = makeVM(project: pid)
        var reported: [ProjectSubject] = []
        vm.onOwnerWrite = { project, subject in
            XCTAssertEqual(project, pid)
            reported.append(subject)
        }
        vm.load()
        vm.select(Int(tid))
        vm.setStatus("done")
        vm.rename("Renamed")
        vm.addComment("note")
        let root = try XCTUnwrap(vm.threads.first?.root.id)
        vm.reply(to: root, body: "more")
        vm.setThreadStatus(rootID: root, status: "resolved")

        XCTAssertEqual(reported, Array(repeating: .target(tid), count: 5),
                       "an owner-set done must never notify as if the agent did it")
    }

    func testAFailedWriteDoesNotReportToTheHook() throws {
        let (pid, tid) = try dbManager.dbPool.write { db -> (Int64, Int64) in
            let pid = try Self.insertProject(db)
            return (pid, try Self.insertTarget(db, project: pid, text: "Task"))
        }
        let vm = makeVM(project: pid)
        var reported = 0
        vm.onOwnerWrite = { _, _ in reported += 1 }
        vm.load()
        vm.select(Int(tid))
        vm.reply(to: 999_999, body: "orphan")   // no such root: ProjectQueries.reply throws
        XCTAssertEqual(reported, 0)
        XCTAssertNotNil(vm.errorMessage)
    }

    // MARK: - Mark read

    func testSelectingATargetMarksItsAgentCommentsRead() throws {
        let (pid, tid) = try dbManager.dbPool.write { db -> (Int64, Int64) in
            let pid = try Self.insertProject(db)
            let tid = try Self.insertTarget(db, project: pid, text: "Task")
            _ = try Self.insertComment(db, project: pid, target: tid, author: "agent", body: "Blocked on keys")
            return (pid, tid)
        }
        let vm = makeVM(project: pid)
        vm.load()
        XCTAssertEqual(vm.rows.first?.node.unreadForOwner, 1)

        vm.select(Int(tid))

        let unread = try dbManager.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM project_comments WHERE author = 'agent' AND read_at = ''")
        }
        XCTAssertEqual(unread, 0)
        XCTAssertEqual(vm.rows.first?.node.unreadForOwner, 0)
    }

    func testMarkReadFailureKeepsTheUnreadBadge() throws {
        let (pid, tid) = try dbManager.dbPool.write { db -> (Int64, Int64) in
            let pid = try Self.insertProject(db)
            let tid = try Self.insertTarget(db, project: pid, text: "Task")
            _ = try Self.insertComment(db, project: pid, target: tid, author: "agent", body: "Question")
            // Any UPDATE of project_comments fails: models a locked/readonly DB.
            try db.execute(sql: """
                CREATE TRIGGER fail_mark_read BEFORE UPDATE ON project_comments
                BEGIN SELECT RAISE(ABORT, 'mark read refused'); END
                """)
            return (pid, tid)
        }
        let vm = makeVM(project: pid)
        vm.load()
        vm.select(Int(tid))

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertEqual(vm.rows.first?.node.unreadForOwner, 1, "the badge drops only after the write succeeds")
    }

    // MARK: - Out-of-process refresh

    func testRefreshIfChangedSeesAWriteFromAnotherConnection() throws {
        let (pid, tid) = try dbManager.dbPool.write { db -> (Int64, Int64) in
            let pid = try Self.insertProject(db)
            return (pid, try Self.insertTarget(db, project: pid, text: "Task"))
        }
        let vm = makeVM(project: pid)
        vm.load()
        XCTAssertFalse(vm.refreshIfChanged(), "nothing changed yet")

        // A second pool on the same file stands in for `watchtower mcp --project`:
        // ValueObservation on dbManager.dbPool would never see this write.
        let foreign = try DatabasePool(path: dbPath)
        try foreign.write { db in
            try db.execute(sql: "UPDATE targets SET status = 'done', updated_at = '2099-01-01T00:00:00Z' WHERE id = ?",
                           arguments: [tid])
            _ = try Self.insertComment(db, project: pid, target: tid, author: "agent", body: "Done: shipped")
        }

        XCTAssertTrue(vm.refreshIfChanged())
        vm.showDone = true
        XCTAssertEqual(vm.rows.first?.node.target.status, "done")
        XCTAssertEqual(vm.rows.first?.node.unreadForOwner, 1)
    }
}
```

- [ ] **Step 6: Run to verify they fail**

Run: `make test-swift FILTER=ProjectBoardViewModelTests > /tmp/p5-19b.log 2>&1; echo "exit=$?"; grep -E "error:|failed" /tmp/p5-19b.log | head -20`
Expected: `exit=1`, `cannot find 'ProjectBoardViewModel' in scope`.

- [ ] **Step 7: Implement the ViewModel**

Create `WatchtowerDesktop/Sources/ViewModels/ProjectBoardViewModel.swift`:

```swift
import Foundation
import GRDB
import WatchtowerCore

/// The project page's Board pane: the target tree, one selected target's
/// detail and its comment threads. Owner edits are direct GRDB writes through
/// the same `TargetQueries` mutators the Targets tab uses (the targets
/// dual-path precedent). Agent writes arrive from another process
/// (`watchtower mcp --project N`), which ValueObservation cannot see, so the
/// pane polls a cheap fingerprint while it is on screen.
@MainActor
@Observable
final class ProjectBoardViewModel {
    /// Statuses the owner can set from the board. `snoozed` is a Targets-tab
    /// concept (snooze_until) with no meaning on a project board.
    static let editableStatuses = ["todo", "in_progress", "blocked", "done", "dismissed"]

    let projectID: Int64
    private(set) var roots: [ProjectBoardNode] = []
    var collapsed: Set<Int> = []
    var showDone = false
    private(set) var selectedTargetID: Int?
    private(set) var selectedComments: [ProjectComment] = []
    private(set) var errorMessage: String?

    var rows: [ProjectBoardRow] {
        ProjectBoardOutline.rows(roots, collapsed: collapsed, showDone: showDone)
    }

    var selectedNode: ProjectBoardNode? {
        selectedTargetID.flatMap { ProjectBoardOutline.find($0, in: roots) }
    }

    var threads: [ProjectCommentThread] { ProjectCommentThread.group(selectedComments) }

    /// `ProjectsViewModel.onOwnerWrite`, set by the view: every successful owner
    /// write reports its target so the notification center never announces the
    /// owner's own change (e.g. a target the owner marked done).
    var onOwnerWrite: ((Int64, ProjectSubject) -> Void)?

    private let dbPool: DatabasePool
    private var fingerprint = ""
    private var pollTask: Task<Void, Never>?

    init(dbPool: DatabasePool, projectID: Int64) {
        self.dbPool = dbPool
        self.projectID = projectID
    }

    // MARK: - Loading

    func load() {
        do {
            let pid = projectID
            let selected = selectedTargetID
            let (board, comments, stamp) = try dbPool.read { db in
                (
                    try ProjectQueries.board(db, projectID: pid),
                    try selected.map { try ProjectQueries.comments(db, targetID: Int64($0)) } ?? [],
                    try Self.fingerprint(db, projectID: pid)
                )
            }
            roots = board
            selectedComments = comments
            fingerprint = stamp
            if let selected, ProjectBoardOutline.find(selected, in: board) == nil {
                selectedTargetID = nil
                selectedComments = []
            }
        } catch {
            errorMessage = "Could not load the board: \(error.localizedDescription)"
        }
    }

    /// Reloads when anything on this project's board changed since the last
    /// load, including writes from another process. Returns whether it reloaded.
    @discardableResult
    func refreshIfChanged() -> Bool {
        let pid = projectID
        guard let current = try? dbPool.read({ try Self.fingerprint($0, projectID: pid) }),
              current != fingerprint else { return false }
        load()
        return true
    }

    func startPolling(every interval: Duration = .seconds(5)) {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                self.refreshIfChanged()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Counts plus the latest timestamps of everything the board renders. Any
    /// agent write (a new target, a status move, a comment, a resolve, a read
    /// mark) changes at least one of them.
    nonisolated private static func fingerprint(_ db: Database, projectID: Int64) throws -> String {
        let targets = try Row.fetchOne(
            db,
            sql: "SELECT COUNT(*), MAX(updated_at) FROM targets WHERE project_id = ?",
            arguments: [projectID]
        )
        let comments = try Row.fetchOne(
            db,
            sql: """
                SELECT COUNT(*), MAX(created_at), MAX(read_at),
                       SUM(CASE WHEN status = 'open' THEN 1 ELSE 0 END)
                FROM project_comments WHERE project_id = ?
                """,
            arguments: [projectID]
        )
        let docs = try Row.fetchOne(
            db,
            sql: "SELECT COUNT(*), MAX(updated_at) FROM project_documents WHERE project_id = ?",
            arguments: [projectID]
        )
        return [targets, comments, docs].map { $0?.description ?? "" }.joined(separator: "|")
    }

    // MARK: - Selection

    func select(_ targetID: Int?) {
        selectedTargetID = targetID
        errorMessage = nil
        load()
        guard let node = selectedNode, node.unreadForOwner > 0 else { return }
        do {
            let pid = projectID
            try dbPool.write { db in
                try ProjectQueries.markAgentCommentsRead(
                    db, projectID: pid, targetID: Int64(node.target.id), documentID: nil
                )
            }
            load()
        } catch {
            // The badge stays: roots were not reloaded, so unreadForOwner is unchanged.
            errorMessage = "Could not mark comments read: \(error.localizedDescription)"
        }
    }

    func toggle(_ targetID: Int) {
        if collapsed.contains(targetID) {
            collapsed.remove(targetID)
        } else {
            collapsed.insert(targetID)
        }
    }

    // MARK: - Edits

    func setStatus(_ status: String) {
        guard let id = selectedTargetID, Self.editableStatuses.contains(status) else { return }
        write("change the status") { db in try TargetQueries.updateStatus(db, id: id, status: status) }
    }

    func rename(_ text: String) {
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = selectedTargetID, !title.isEmpty else { return }
        write("rename the target") { db in try TargetQueries.updateText(db, id: id, text: title) }
    }

    func addComment(_ body: String) {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = selectedTargetID, !text.isEmpty else { return }
        let pid = projectID
        write("add the comment") { db in
            _ = try ProjectQueries.addOwnerComment(
                db, projectID: pid, targetID: Int64(id), documentID: nil, anchor: nil, body: text
            )
        }
    }

    func reply(to rootID: Int64, body: String) {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        write("reply") { db in _ = try ProjectQueries.reply(db, to: rootID, body: text) }
    }

    func setThreadStatus(rootID: Int64, status: String) {
        write("update the thread") { db in try ProjectQueries.setStatus(db, commentID: rootID, status: status) }
    }

    /// Every owner write goes through here: the write, then the hook, then a
    /// reload. The hook fires only after the write succeeded.
    private func write(_ what: String, _ body: (Database) throws -> Void) {
        do {
            try dbPool.write { db in try body(db) }
            errorMessage = nil
            if let id = selectedTargetID {
                onOwnerWrite?(projectID, .target(Int64(id)))
            }
            load()
        } catch {
            errorMessage = "Could not \(what): \(error.localizedDescription)"
        }
    }
}
```

- [ ] **Step 8: Run to verify they pass**

Run: `make test-swift FILTER=ProjectBoardViewModelTests > /tmp/p5-19b.log 2>&1; echo "exit=$?"; grep -E "error:|failed|Executed" /tmp/p5-19b.log | head -20`
Expected: `exit=0`, `Executed 11 tests, with 0 failures`.

- [ ] **Step 9: The view + wire it into the project page**

Create `WatchtowerDesktop/Sources/Views/Projects/ProjectBoardView.swift`:

```swift
import SwiftUI
import WatchtowerCore

/// Board pane of the project page: tree on the left, the selected target's
/// detail and comment threads on the right.
struct ProjectBoardView: View {
    let projectID: Int64

    @Environment(AppState.self) private var appState
    @State private var viewModel: ProjectBoardViewModel?
    @State private var titleDraft = ""
    @State private var commentDraft = ""

    var body: some View {
        Group {
            if let vm = viewModel {
                HSplitView {
                    tree(vm).frame(minWidth: 260, idealWidth: 320)
                    detail(vm).frame(minWidth: 360)
                }
            } else {
                ProgressView()
            }
        }
        .onAppear {
            if viewModel == nil, let pool = appState.databaseManager?.dbPool {
                let vm = ProjectBoardViewModel(dbPool: pool, projectID: projectID)
                vm.onOwnerWrite = { [weak projects = appState.projectsViewModel] project, subject in
                    projects?.onOwnerWrite?(project, subject)
                }
                vm.load()
                viewModel = vm
            }
            viewModel?.startPolling()
        }
        .onDisappear { viewModel?.stopPolling() }
    }

    // MARK: - Tree

    private func tree(_ vm: ProjectBoardViewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Board").font(.headline)
                Spacer()
                Toggle("Show done", isOn: Binding(get: { vm.showDone }, set: { vm.showDone = $0 }))
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
            .padding(8)
            Divider()
            if vm.rows.isEmpty {
                ContentUnavailableView(
                    "No targets yet",
                    systemImage: "square.stack.3d.up",
                    description: Text("Claude Code creates the board through the watchtower-project tools.")
                )
            } else {
                List(vm.rows, selection: Binding(get: { vm.selectedTargetID }, set: { vm.select($0) })) { row in
                    rowView(vm, row)
                }
                .listStyle(.sidebar)
            }
        }
    }

    private func rowView(_ vm: ProjectBoardViewModel, _ row: ProjectBoardRow) -> some View {
        let t = row.node.target
        return HStack(spacing: 6) {
            if row.hasChildren {
                Button { vm.toggle(row.id) } label: {
                    Image(systemName: vm.collapsed.contains(row.id) ? "chevron.right" : "chevron.down")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 10)
            }
            Image(systemName: t.statusIcon).foregroundStyle(color(t.statusColor))
            Text(t.text.components(separatedBy: "\n").first ?? t.text).lineLimit(1)
            Spacer(minLength: 4)
            if row.node.unreadForOwner > 0 {
                badge("\(row.node.unreadForOwner)", systemImage: "bubble.left.fill", color: .blue)
            }
            if row.node.openComments > 0 {
                badge("\(row.node.openComments)", systemImage: "text.bubble", color: .orange)
            }
            if !row.node.documents.isEmpty {
                badge("\(row.node.documents.count)", systemImage: "doc.text", color: .secondary)
            }
            if t.progress > 0, t.progress < 1 {
                Text("\(Int(t.progress * 100))%").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, CGFloat(row.depth) * 14)
    }

    private func badge(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(.caption2)
            .foregroundStyle(color)
    }

    // MARK: - Detail

    @ViewBuilder
    private func detail(_ vm: ProjectBoardViewModel) -> some View {
        if let node = vm.selectedNode {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let error = vm.errorMessage {
                        Text(error).font(.callout).foregroundStyle(.red)
                    }
                    TextField("Title", text: $titleDraft)
                        .font(.title3.weight(.semibold))
                        .textFieldStyle(.plain)
                        .onSubmit { vm.rename(titleDraft) }
                    Picker("Status", selection: Binding(
                        get: { node.target.status },
                        set: { vm.setStatus($0) }
                    )) {
                        ForEach(ProjectBoardViewModel.editableStatuses, id: \.self) { status in
                            Text(statusName(status)).tag(status)
                        }
                    }
                    .pickerStyle(.segmented)
                    ProgressView(value: node.target.progress)
                    if !node.target.intent.isEmpty {
                        Text(node.target.intent).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if !node.documents.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Documents").font(.headline)
                            ForEach(node.documents, id: \.id) { doc in
                                Label(doc.title.isEmpty ? doc.relPath : doc.title, systemImage: "doc.text")
                                    .font(.callout)
                            }
                        }
                    }
                    Divider()
                    Text("Comments").font(.headline)
                    ForEach(vm.threads) { thread in
                        CommentThreadView(
                            thread: thread,
                            onReply: { vm.reply(to: thread.root.id, body: $0) },
                            onResolve: { vm.setThreadStatus(rootID: thread.root.id, status: "resolved") },
                            onReopen: { vm.setThreadStatus(rootID: thread.root.id, status: "open") }
                        )
                    }
                    HStack(alignment: .bottom) {
                        TextField("Comment or answer the agent…", text: $commentDraft, axis: .vertical)
                            .lineLimit(1...6)
                        Button("Comment") {
                            vm.addComment(commentDraft)
                            commentDraft = ""
                        }
                        .disabled(commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(16)
            }
            .onAppear { titleDraft = node.target.text }
            .onChange(of: node.target.id) { titleDraft = node.target.text }
            .onChange(of: node.target.text) { titleDraft = node.target.text }
        } else {
            ContentUnavailableView("Select a target", systemImage: "square.stack.3d.up")
        }
    }

    private func statusName(_ status: String) -> String {
        switch status {
        case "todo": return "To Do"
        case "in_progress": return "In Progress"
        case "blocked": return "Blocked"
        case "done": return "Done"
        case "dismissed": return "Dismissed"
        default: return status.capitalized
        }
    }

    private func color(_ name: String) -> Color {
        switch name {
        case "blue": return .blue
        case "red": return .red
        case "green": return .green
        case "gray": return .gray
        case "purple": return .purple
        default: return .secondary
        }
    }
}
```

In `WatchtowerDesktop/Sources/Views/Projects/ProjectPageView.swift`, `paneContent`, replace the `.board` case's `ProjectPanePlaceholder(title: "Board")` with:

```swift
ProjectBoardView(projectID: project.id)
    .id(project.id)
```

(`.id` makes a project switch build a fresh ViewModel instead of reusing the previous project's.)

- [ ] **Step 10: Build and lint**

Run: `cd WatchtowerDesktop && swift build > /tmp/p5-19c.log 2>&1; echo "exit=$?"; grep -E "error:" /tmp/p5-19c.log | head; cd .. && make lint-diff > /tmp/p5-19d.log 2>&1; echo "lint=$?"`
Expected: `exit=0`, `lint=0`.

- [ ] **Step 11: Commit**

```bash
git add WatchtowerDesktop/Sources/WatchtowerCore/Services/ProjectBoardOutline.swift \
  WatchtowerDesktop/Sources/ViewModels/ProjectBoardViewModel.swift \
  WatchtowerDesktop/Sources/Views/Projects/ProjectBoardView.swift \
  WatchtowerDesktop/Sources/Views/Projects/ProjectPageView.swift \
  WatchtowerDesktop/Tests/Core/ProjectBoardOutlineTests.swift \
  WatchtowerDesktop/Tests/ProjectBoardViewModelTests.swift
git commit -m "$(cat <<'EOF'
feat(projects): board pane with target tree, detail and comment threads

The Board pane of the project page: an outline of the project's targets
(collapse, hide-done that never hides an open child), the selected target's
title/status editing through the existing TargetQueries mutators, and its
owner/agent comment threads. Viewing a target marks its agent comments read
only after the write succeeds. Agent writes come from another process, so
the pane polls a fingerprint while on screen.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Lo9jbbmXQcr3qHo5f3pLD8
EOF
)"
```

---

### Task 20: Targets-tab exclusions (PROJ-01, Swift) + Desktop delete flow

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Models/Target.swift` (`projectID`)
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/TargetQueries.swift` (`fetchAll`, `fetchCounts`, `fetchDistinctTags`)
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ChatEntitySearch.swift` (`targets` — the `@` picker)
- Modify: `WatchtowerDesktop/Sources/Database/DatabaseManager.swift` (`wipeLLMData`)
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/ProjectDeleteSummary.swift`
- Modify: `WatchtowerDesktop/Sources/ViewModels/ProjectsViewModel.swift` (`deleteProject(_:)`, `closeTerminal` hook, vanished-project close in `reload()`), `WatchtowerDesktop/Sources/App/AppState.swift` (`initProjects` wires `closeTerminal`), `WatchtowerDesktop/Sources/Views/Projects/ProjectPageView.swift` (Delete button + confirmation)
- Test: `WatchtowerDesktop/Tests/Core/ProjectTargetExclusionTests.swift`, `WatchtowerDesktop/Tests/Core/ProjectDeleteSummaryTests.swift`, `WatchtowerDesktop/Tests/ProjectsViewModelDeleteTests.swift`, `WatchtowerDesktop/Tests/SidebarCountsViewModelTests.swift`, `WatchtowerDesktop/Tests/DatabaseManagerTests.swift`

**Interfaces:**
- Consumes: Phase 4 `Project`, `ProjectQueries.fetch(_:id:)`, `ProjectCLI.delete(projectID:)` (runs `project delete N`; reached through `ProjectsViewModel`'s private `cli: ProjectCLI?`), `ProjectTerminalCenter.close(projectID:) async` / `start(project:firstRun:)` / `states` / `makeSession`, `AppState.projectTerminalCenter` (a `let`), `ProjectsViewModel(dbPool:cli:defaults:)` (`summaries`, `selectedProjectID`, `reload()`), `AppState.initProjects(dbPool:cliRunner:notifier:)`, `ProjectPageView(vm:project:)`; test doubles `FakeTerminalSession(pid:)`, `RecordingProjectNotifier`, fixture `TestDatabase.insertProject(_:name:folder:)`; Phase 1 migration (`targets.project_id`, `projects`, `project_documents`, `project_comments`).
- Produces (Core): `Target.projectID: Int64?`; `struct ProjectDeleteSummary { name, folder: String; targets, documents, comments: Int; static func fetch(_:project:) throws -> ProjectDeleteSummary; var title: String; var message: String }`.
- Produces (app): on `ProjectsViewModel` — `closeTerminal: ((Int64) async -> Void)?`, `private(set) var deletingProjectID: Int64?`, `deleteError: String?`, `@discardableResult func deleteProject(_ id: Int64) async -> Bool` (closes the terminal, then `watchtower project delete N`, then reloads), `nonisolated static func vanished(previous:current:) -> [Int64]`; `reload()` also closes the terminal of any project that dropped out of the list.

- [ ] **Step 0: Confirm names**

Run:
```bash
cd WatchtowerDesktop
grep -n "projectID\|project_id" Sources/WatchtowerCore/Models/Target.swift Tests/Support/TestDatabase+Schema.swift | head
grep -n "func delete" Sources/Services/ProjectCLI.swift
grep -n "func close" Sources/Services/ProjectTerminalCenter.swift
grep -n "projectTerminalCenter\|projectsViewModel\|func initProjects" Sources/App/AppState.swift
grep -n "private let cli\|var summaries\|selectedProjectID\|func reload" -A8 Sources/ViewModels/ProjectsViewModel.swift
grep -n "HStack\|Repair" Sources/Views/Projects/ProjectPageView.swift
grep -n "class FakeTerminalSession\|class RecordingProjectNotifier\|static func insertProject(" Tests/*.swift Tests/Support/*.swift
```
Expected: `targets.project_id` present in `TestDatabase+Schema.swift` (Task 1); no `projectID` in `Target.swift`; `reload()` is the Phase 4 body (`summaries = try await dbPool.read { try ProjectQueries.summaries($0) }` in a do/catch); the Phase 4 names above.

- [ ] **Step 1: Write the failing exclusion tests (PROJ-01, Swift)**

Create `WatchtowerDesktop/Tests/Core/ProjectTargetExclusionTests.swift`:

```swift
import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// BEHAVIOR PROJ-01 (Desktop side) — a project target lives only on its
/// project's board: it never reaches the Targets tab's list, counts, tag menu,
/// or the chat `@` picker. See docs/inventory/projects.md.
final class ProjectTargetExclusionTests: XCTestCase {

    /// One ordinary target and one project target, identical in every field a
    /// reader filters on (active, overdue, due today, high priority, tagged,
    /// matching text) — so only project_id can explain a difference.
    private func seed(_ db: Database) throws {
        try db.execute(sql: "INSERT INTO projects (name, folder_path) VALUES ('acme', '/tmp/acme')")
        let projectID = db.lastInsertedRowID
        let today = TargetQueries.todayDateString()
        for (text, project) in [("Ship ordinary", nil as Int64?), ("Ship board", projectID)] {
            try db.execute(
                sql: """
                    INSERT INTO targets (text, level, custom_label, period_start, period_end, status,
                        priority, ownership, due_date, tags, source_type, project_id)
                    VALUES (?, 'custom', 'project', ?, ?, 'in_progress', 'high', 'mine', ?, ?, 'chat', ?)
                    """,
                arguments: [text, today, today, "2020-01-01T09:00",
                            project == nil ? #"["ordinary-tag"]"# : #"["board-tag"]"#, project]
            )
        }
    }

    func testProj01_FetchAllNeverReturnsAProjectTarget() throws {
        let queue = try TestDatabase.create()
        try queue.write(seed)
        let texts = try queue.read { db in
            try TargetQueries.fetchAll(db, filter: TargetFilter(includeDone: true)).map(\.text)
        }
        XCTAssertEqual(texts, ["Ship ordinary"])
    }

    func testProj01_FetchAllTagFilterNeverReturnsAProjectTarget() throws {
        let queue = try TestDatabase.create()
        try queue.write(seed)
        let texts = try queue.read { db in
            try TargetQueries.fetchAll(db, filter: TargetFilter(tag: "board-tag")).map(\.text)
        }
        XCTAssertEqual(texts, [])
    }

    func testProj01_FetchCountsIgnoreProjectTargets() throws {
        let queue = try TestDatabase.create()
        try queue.write(seed)
        let counts = try queue.read { try TargetQueries.fetchCounts($0) }
        XCTAssertEqual(counts.active, 1)
        XCTAssertEqual(counts.overdue, 1)
        XCTAssertEqual(counts.highPriority, 1)
    }

    func testProj01_DueTodayIgnoresProjectTargets() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            try self.seed(db)
            try db.execute(sql: "UPDATE targets SET due_date = ?", arguments: [TargetQueries.todayDateString() + "T23:59"])
        }
        let counts = try queue.read { try TargetQueries.fetchCounts($0) }
        XCTAssertEqual(counts.dueToday, 1)
    }

    func testProj01_DistinctTagsNeverListAProjectTargetsTag() throws {
        let queue = try TestDatabase.create()
        try queue.write(seed)
        let tags = try queue.read { try TargetQueries.fetchDistinctTags($0) }
        XCTAssertEqual(tags, ["ordinary-tag"])
    }

    func testProj01_MentionPickerNeverOffersAProjectTarget() throws {
        let queue = try TestDatabase.create()
        try queue.write(seed)
        let hits = try queue.read { try ChatEntitySearch.targets($0, query: "ship") }
        XCTAssertEqual(hits.map(\.label), ["Ship ordinary"])
    }

    func testTargetDecodesProjectID() throws {
        let queue = try TestDatabase.create()
        try queue.write(seed)
        let ids = try queue.read { db in
            try Target.fetchAll(db, sql: "SELECT * FROM targets ORDER BY id").map(\.projectID)
        }
        XCTAssertNil(ids[0])
        XCTAssertNotNil(ids[1])
    }
}
```

Append to `WatchtowerDesktop/Tests/SidebarCountsViewModelTests.swift` (inside the class):

```swift
    /// BEHAVIOR PROJ-01 — the Targets sidebar badge (activeTaskCount /
    /// overdueTaskCount) never counts a project target.
    func testProj01_TargetsBadgeIgnoresProjectTargets() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }

        try await manager.dbPool.write { db in
            _ = try TestDatabase.insertSlackAccount(db, currentUserID: "U042")
            try db.execute(sql: "INSERT INTO projects (name, folder_path) VALUES ('acme', '/tmp/acme')")
            let projectID = db.lastInsertedRowID
            _ = try TestDatabase.insertTarget(db, text: "Ordinary", dueDate: "2020-01-01T09:00")
            let boardTarget = try TestDatabase.insertTarget(db, text: "Board", dueDate: "2020-01-01T09:00", sourceType: "chat")
            try db.execute(sql: "UPDATE targets SET project_id = ? WHERE id = ?", arguments: [projectID, boardTarget])
        }

        let vm = SidebarCountsViewModel(dbPool: manager.dbPool)
        await vm.loadInitial()

        XCTAssertEqual(vm.activeTaskCount, 1)
        XCTAssertEqual(vm.overdueTaskCount, 1)
    }
```

Append to `WatchtowerDesktop/Tests/DatabaseManagerTests.swift` (inside the class):

```swift
    /// Project targets are source_type='chat', which "Wipe LLM data" deletes.
    /// A project board is durable work state (PROJ-02: only a project delete
    /// removes it), so the wipe must spare it — and its comments, which would
    /// cascade with it.
    func testWipeLLMDataPreservesProjectTargets() throws {
        try dbManager.dbPool.write { db in
            try db.execute(sql: "INSERT INTO projects (name, folder_path) VALUES ('acme', '/tmp/acme')")
            let projectID = db.lastInsertedRowID
            let boardTarget = try TestDatabase.insertTarget(db, text: "Board task", sourceType: "chat")
            try db.execute(sql: "UPDATE targets SET project_id = ? WHERE id = ?", arguments: [projectID, boardTarget])
            try db.execute(
                sql: "INSERT INTO project_comments (project_id, target_id, author, body) VALUES (?, ?, 'agent', 'q')",
                arguments: [projectID, boardTarget]
            )
            try TestDatabase.insertTarget(db, text: "Chat suggestion", sourceType: "chat")
        }

        try dbManager.wipeLLMData()

        let texts: [String] = try dbManager.dbPool.read { db in
            try String.fetchAll(db, sql: "SELECT text FROM targets ORDER BY text")
        }
        XCTAssertEqual(texts, ["Board task"])
        let comments: Int = try dbManager.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM project_comments") ?? -1
        }
        XCTAssertEqual(comments, 1)
    }
```

- [ ] **Step 2: Run to verify they fail**

Run:
```bash
make test-swift FILTER=ProjectTargetExclusionTests > /tmp/p5-20a.log 2>&1; echo "exit=$?"; grep -E "error:|failed" /tmp/p5-20a.log | head
make test-swift FILTER=SidebarCountsViewModelTests/testProj01 > /tmp/p5-20b.log 2>&1; echo "exit=$?"; grep -E "error:|failed" /tmp/p5-20b.log | head
make test-swift FILTER=DatabaseManagerTests/testWipeLLMDataPreservesProjectTargets > /tmp/p5-20c.log 2>&1; echo "exit=$?"; grep -E "error:|failed" /tmp/p5-20c.log | head
```
Expected: the first run fails to compile (`value of type 'Target' has no member 'projectID'`) — Step 3a fixes that, and without 3b/3c the remaining six tests then fail on their assertions (`["Ship ordinary", "Ship board"]`, `active 2`, …). The badge test fails `XCTAssertEqual failed: ("2") is not equal to ("1")`; the wipe test fails `("[]") is not equal to ("["Board task"]")`.

- [ ] **Step 3: Implement the exclusions**

3a. `WatchtowerDesktop/Sources/WatchtowerCore/Models/Target.swift` — add the property after `nextStepAt`:

```swift
    package let nextStepAt: String      // when nextStep was generated
    package let projectID: Int64?       // non-nil = lives only on that project's board (PROJ-01)
```

add the coding key after `nextStepAt`:

```swift
        case nextStepAt       = "next_step_at"
        case projectID        = "project_id"
```

and in `init(row:)` after `nextStepAt = …`:

```swift
        nextStepAt       = row["next_step_at"] ?? ""
        projectID        = row["project_id"]
```

3b. `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/TargetQueries.swift` — in `fetchAll`, make the exclusion the first condition:

```swift
        // BEHAVIOR PROJ-01 — project targets live only on their board
        // (ProjectQueries.board); no Targets-tab reader ever sees one.
        var conditions: [String] = ["project_id IS NULL"]
        var args: [any DatabaseValueConvertible] = []
```

(the existing `if !conditions.isEmpty` stays; it is now always true.) In `fetchCounts`, add the predicate to all four queries — replace the function body's four SQL strings with:

```swift
        let active = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM targets WHERE project_id IS NULL AND status IN ('todo', 'in_progress', 'blocked')"
        ) ?? 0
        let now = nowDatetimeString()
        let overdue = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM targets
                WHERE project_id IS NULL AND status IN ('todo', 'in_progress', 'blocked')
                AND due_date != '' AND due_date < ?
                """,
            arguments: [now]
        ) ?? 0
        let today = todayDateString()
        let dueToday = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM targets
                WHERE project_id IS NULL AND status IN ('todo', 'in_progress', 'blocked')
                AND due_date != '' AND due_date >= ? AND due_date < ?
                """,
            arguments: [today, today + "T24:00"]
        ) ?? 0
        let highPriority = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM targets
                WHERE project_id IS NULL AND status IN ('todo', 'in_progress', 'blocked')
                AND priority = 'high'
                """
        ) ?? 0
```

In `fetchDistinctTags`:

```swift
                SELECT DISTINCT value FROM targets, json_each(targets.tags)
                WHERE targets.project_id IS NULL AND json_valid(targets.tags) AND value <> ''
                ORDER BY value COLLATE NOCASE
```

3c. `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ChatEntitySearch.swift`, `targets(_:query:limit:)`:

```swift
                SELECT id, text, status FROM targets
                WHERE project_id IS NULL AND status NOT IN ('done', 'dismissed') AND \(match.sql)
```

3d. `WatchtowerDesktop/Sources/Database/DatabaseManager.swift`, `wipeLLMData()`:

```swift
            // Targets: only AI-sourced ones — user-created (manual/jira/slack/promoted_subitem)
            // are preserved, and so is every project board (PROJ-02: only a project
            // delete removes its targets; their comments would cascade with them).
            try db.execute(sql: """
                DELETE FROM targets
                WHERE source_type IN ('extract','track','digest','briefing','chat','inbox')
                  AND project_id IS NULL
                """)
```

- [ ] **Step 4: Run to verify they pass**

Run the three commands from Step 2.
Expected: all `exit=0`; `Executed 7 tests, with 0 failures` for `ProjectTargetExclusionTests`. Then run the neighbours the change touches: `make test-swift FILTER=TargetQueries > /tmp/p5-20d.log 2>&1; echo "exit=$?"` and `make test-swift FILTER=ChatEntitySearchTests > /tmp/p5-20e.log 2>&1; echo "exit=$?"` — both `exit=0`.

- [ ] **Step 5: Commit the exclusions**

```bash
git add WatchtowerDesktop/Sources/WatchtowerCore/Models/Target.swift \
  WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/TargetQueries.swift \
  WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ChatEntitySearch.swift \
  WatchtowerDesktop/Sources/Database/DatabaseManager.swift \
  WatchtowerDesktop/Tests/Core/ProjectTargetExclusionTests.swift \
  WatchtowerDesktop/Tests/SidebarCountsViewModelTests.swift \
  WatchtowerDesktop/Tests/DatabaseManagerTests.swift
git commit -m "$(cat <<'EOF'
feat(projects): keep project targets out of the Targets tab (PROJ-01)

Target gains projectID. TargetQueries.fetchAll/fetchCounts/fetchDistinctTags
(and so the Targets badge) and the chat @ picker exclude project_id IS NOT
NULL. "Wipe LLM data" no longer deletes project targets, which are
source_type='chat': a board is durable state that only a project delete
removes.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Lo9jbbmXQcr3qHo5f3pLD8
EOF
)"
```

- [ ] **Step 6: Write the failing delete-flow tests**

Create `WatchtowerDesktop/Tests/Core/ProjectDeleteSummaryTests.swift`:

```swift
import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class ProjectDeleteSummaryTests: XCTestCase {

    func testFetchCountsOnlyThisProjectsRows() throws {
        let queue = try TestDatabase.create()
        let project = try queue.write { db -> Project in
            try db.execute(sql: "INSERT INTO projects (name, folder_path) VALUES ('acme', '/tmp/acme')")
            let pid = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO projects (name, folder_path) VALUES ('other', '/tmp/other')")
            let other = db.lastInsertedRowID
            for (text, p) in [("a", pid), ("b", pid), ("c", other)] {
                try db.execute(
                    sql: """
                        INSERT INTO targets (text, level, custom_label, period_start, period_end,
                            status, source_type, ownership, project_id)
                        VALUES (?, 'custom', 'project', '2026-09-29', '2026-09-29', 'todo', 'chat', 'mine', ?)
                        """,
                    arguments: [text, p]
                )
            }
            try db.execute(sql: "INSERT INTO project_documents (project_id, rel_path) VALUES (?, 'docs/plan.md')",
                           arguments: [pid])
            let doc = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO project_comments (project_id, document_id, author, body) VALUES (?, ?, 'owner', 'x')",
                           arguments: [pid, doc])
            return try XCTUnwrap(ProjectQueries.fetch(db, id: pid))
        }
        let summary = try queue.read { try ProjectDeleteSummary.fetch($0, project: project) }
        XCTAssertEqual(summary.targets, 2)
        XCTAssertEqual(summary.documents, 1)
        XCTAssertEqual(summary.comments, 1)
        XCTAssertEqual(summary.folder, "/tmp/acme")
    }

    func testMessageListsWhatIsRemovedAndWhatIsKept() {
        let s = ProjectDeleteSummary(name: "acme", folder: "/tmp/acme", targets: 1, documents: 2, comments: 0)
        XCTAssertEqual(s.title, "Delete project “acme”?")
        XCTAssertTrue(s.message.contains("1 target, 2 documents and 0 comments"))
        XCTAssertTrue(s.message.contains("watchtower-project skill"))
        XCTAssertTrue(s.message.contains("SessionStart hook"))
        XCTAssertTrue(s.message.contains("MCP registration"))
        XCTAssertTrue(s.message.contains(".git/info/exclude"))
        XCTAssertTrue(s.message.contains("/tmp/acme"))
        XCTAssertTrue(s.message.contains("files themselves stay"), "attached documents are never deleted from disk")
        XCTAssertTrue(s.message.contains("terminal"), "the owner is told the running session is closed")
    }
}
```

Create `WatchtowerDesktop/Tests/ProjectsViewModelDeleteTests.swift`:

```swift
import XCTest
import GRDB
import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerTestSupport

/// Review Focus #5 (Desktop side): deleting a project while Claude Code is
/// connected closes its terminal first, and a failed delete keeps it listed.
@MainActor
final class ProjectsViewModelDeleteTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "ProjectsViewModelDeleteTests-\(UUID().uuidString)"))
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    /// Stands in for `watchtower project delete N`: records the call and, unless
    /// told to fail, deletes the row the way the CLI's transaction would.
    private final class DeletingCLIRunner: CLIRunnerProtocol, @unchecked Sendable {
        let pool: DatabasePool
        var fail = false
        private(set) var calls: [[String]] = []
        init(pool: DatabasePool) { self.pool = pool }

        func run(args: [String]) async throws -> Data {
            calls.append(args)
            if fail { throw CLIRunnerError.nonZeroExit(code: 1, stderr: "database is locked") }
            if args.count == 3, args[0] == "project", args[1] == "delete", let id = Int64(args[2]) {
                try await pool.write { try $0.execute(sql: "DELETE FROM projects WHERE id = ?", arguments: [id]) }
            }
            return Data()
        }
    }

    private func makeVM(_ runner: DeletingCLIRunner) -> ProjectsViewModel {
        ProjectsViewModel(dbPool: pool, cli: ProjectCLI(runner: runner), defaults: defaults)
    }

    func testDeleteClosesTheTerminalBeforeTheCLIRunsThenDropsTheProject() async throws {
        let id = try await pool.write { try TestDatabase.insertProject($0) }
        let runner = DeletingCLIRunner(pool: pool)
        let vm = makeVM(runner)
        await vm.reload()
        vm.selectedProjectID = id
        var closedBeforeCLI: [Int64] = []
        vm.closeTerminal = { closed in
            if runner.calls.isEmpty { closedBeforeCLI.append(closed) }
        }

        let ok = await vm.deleteProject(id)

        XCTAssertTrue(ok)
        XCTAssertEqual(closedBeforeCLI, [id], "the terminal closes before `project delete` runs")
        XCTAssertEqual(runner.calls, [["project", "delete", String(id)]])
        XCTAssertTrue(vm.summaries.isEmpty)
        XCTAssertNil(vm.selectedProjectID)
        XCTAssertNil(vm.deleteError)
        XCTAssertNil(vm.deletingProjectID)
    }

    func testCLIFailureKeepsTheProjectAndShowsTheError() async throws {
        let id = try await pool.write { try TestDatabase.insertProject($0) }
        let runner = DeletingCLIRunner(pool: pool)
        runner.fail = true
        let vm = makeVM(runner)
        await vm.reload()

        let ok = await vm.deleteProject(id)

        XCTAssertFalse(ok)
        XCTAssertEqual(vm.summaries.map(\.id), [id])
        XCTAssertNotNil(vm.deleteError)
        XCTAssertTrue(vm.deleteError?.contains("database is locked") ?? false)
        XCTAssertNil(vm.deletingProjectID)
    }

    func testASecondDeleteWhileOneRunsIsRefused() async throws {
        let (a, b) = try await pool.write { d in
            (try TestDatabase.insertProject(d, name: "a", folder: "/tmp/a"),
             try TestDatabase.insertProject(d, name: "b", folder: "/tmp/b"))
        }
        let runner = DeletingCLIRunner(pool: pool)
        let vm = makeVM(runner)
        await vm.reload()
        let gate = AsyncStream<Void>.makeStream()
        // Holds the first delete inside closeTerminal; finishing the stream
        // releases it and every later call (reload's vanished-close) at once.
        vm.closeTerminal = { _ in for await _ in gate.stream { break } }

        let first = Task { await vm.deleteProject(a) }
        while vm.deletingProjectID == nil { await Task.yield() }
        let second = await vm.deleteProject(b)
        gate.continuation.yield()
        gate.continuation.finish()
        _ = await first.value

        XCTAssertFalse(second)
        XCTAssertEqual(runner.calls, [["project", "delete", String(a)]])
    }

    func testReloadClosesTheTerminalOfAProjectDeletedFromOutside() async throws {
        let (a, b) = try await pool.write { d in
            (try TestDatabase.insertProject(d, name: "a", folder: "/tmp/a"),
             try TestDatabase.insertProject(d, name: "b", folder: "/tmp/b"))
        }
        let vm = makeVM(DeletingCLIRunner(pool: pool))
        await vm.reload()
        var closed: [Int64] = []
        vm.closeTerminal = { closed.append($0) }

        // `watchtower project delete` from a terminal, not through the VM.
        try await pool.write { try $0.execute(sql: "DELETE FROM projects WHERE id = ?", arguments: [a]) }
        await vm.reload()

        XCTAssertEqual(closed, [a])
        XCTAssertEqual(vm.summaries.map(\.id), [b])
    }

    func testVanishedListsIDsThatDisappeared() {
        XCTAssertEqual(ProjectsViewModel.vanished(previous: [1, 2, 3], current: [3, 1]), [2])
        XCTAssertEqual(ProjectsViewModel.vanished(previous: [], current: [1]), [])
    }

    /// AppState wiring: initProjects hands the VM ProjectTerminalCenter.close,
    /// so a delete really ends the project's terminal session.
    func testInitProjectsWiresDeleteToTheTerminalCenter() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wt-delete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = try await pool.write { try TestDatabase.insertProject($0, name: "acme", folder: folder.path) }
        let project = try XCTUnwrap(try await pool.read { try ProjectQueries.fetch($0, id: id) })

        let appState = AppState()
        // pid 0: close() never signals a real process group.
        let session = FakeTerminalSession(pid: 0)
        appState.projectTerminalCenter.makeSession = { session }
        appState.initProjects(dbPool: pool, cliRunner: DeletingCLIRunner(pool: pool), notifier: RecordingProjectNotifier())
        let vm = try XCTUnwrap(appState.projectsViewModel)
        await vm.reload()
        appState.projectTerminalCenter.start(project: project)
        XCTAssertNotNil(appState.projectTerminalCenter.states[id])

        let ok = await vm.deleteProject(id)

        XCTAssertTrue(ok)
        XCTAssertNil(appState.projectTerminalCenter.states[id])
        XCTAssertTrue(session.detached)
    }
}
```

- [ ] **Step 7: Run to verify they fail**

Run: `make test-swift FILTER='ProjectDeleteSummaryTests|ProjectsViewModelDeleteTests' > /tmp/p5-20f.log 2>&1; echo "exit=$?"; grep -E "error:|failed" /tmp/p5-20f.log | head`
Expected: `exit=1`, `cannot find 'ProjectDeleteSummary' in scope`, `value of type 'ProjectsViewModel' has no member 'deleteProject'`.

- [ ] **Step 8: Implement the summary and `deleteProject`**

Create `WatchtowerDesktop/Sources/WatchtowerCore/Services/ProjectDeleteSummary.swift`:

```swift
import Foundation
import GRDB

/// What a project delete removes, for the confirmation dialog (spec §6.1:
/// "confirmation lists what is removed, incl. the folder cleanup").
package struct ProjectDeleteSummary: Equatable {
    package let name: String
    package let folder: String
    package let targets: Int
    package let documents: Int
    package let comments: Int

    package init(name: String, folder: String, targets: Int, documents: Int, comments: Int) {
        self.name = name
        self.folder = folder
        self.targets = targets
        self.documents = documents
        self.comments = comments
    }

    package static func fetch(_ db: Database, project: Project) throws -> ProjectDeleteSummary {
        func count(_ table: String) throws -> Int {
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE project_id = ?",
                             arguments: [project.id]) ?? 0
        }
        return ProjectDeleteSummary(
            name: project.name,
            folder: project.folderPath,
            targets: try count("targets"),
            documents: try count("project_documents"),
            comments: try count("project_comments")
        )
    }

    package var title: String { "Delete project “\(name)”?" }

    package var message: String {
        """
        Watchtower removes the board: \(Self.plural(targets, "target")), \
        \(Self.plural(documents, "document")) and \(Self.plural(comments, "comment")). \
        The document files themselves stay in the folder.

        In \(folder) it removes what it installed: the watchtower-project skill, \
        the SessionStart hook in .claude/settings.local.json, the watchtower-project \
        MCP registration, and the .git/info/exclude lines it added. Nothing else \
        in the folder is touched.

        The project's terminal session is closed first.
        """
    }

    private static func plural(_ n: Int, _ word: String) -> String {
        "\(n) \(word)\(n == 1 ? "" : "s")"
    }
}
```

In `WatchtowerDesktop/Sources/ViewModels/ProjectsViewModel.swift`, add next to `onOwnerWrite`:

```swift
    /// Closes a project's embedded terminal (SIGHUP → SIGKILL). AppState wires
    /// it to ProjectTerminalCenter.close in initProjects; closing a project
    /// with no terminal is a no-op, so calling it twice is harmless.
    var closeTerminal: ((Int64) async -> Void)?
    /// The project a delete is running for; the page disables Delete meanwhile.
    private(set) var deletingProjectID: Int64?
    /// Why the last delete failed; the page shows it in an alert.
    var deleteError: String?
```

and next to `reload()`:

```swift
    /// Deletes a project (spec §6.1, Review Focus #5). Order matters: the
    /// terminal — and with it the Claude Code session writing through
    /// `mcp --project` — closes first, then `watchtower project delete N`
    /// removes the rows and the folder install, then the list reloads. A CLI
    /// failure keeps the project listed and reports the CLI's error. A second
    /// call while one runs is refused.
    @discardableResult
    func deleteProject(_ id: Int64) async -> Bool {
        guard deletingProjectID == nil else { return false }
        guard let cli else {
            deleteError = "The watchtower CLI was not found."
            return false
        }
        deletingProjectID = id
        deleteError = nil
        defer { deletingProjectID = nil }
        await closeTerminal?(id)
        do {
            try await cli.delete(projectID: id)
        } catch {
            deleteError = "Could not delete the project: \(error.localizedDescription)"
            return false
        }
        if selectedProjectID == id { selectedProjectID = nil }
        await reload()
        return true
    }

    nonisolated static func vanished(previous: [Int64], current: [Int64]) -> [Int64] {
        let now = Set(current)
        return previous.filter { !now.contains($0) }
    }
```

Replace the body of `reload()` so a project deleted from outside (`watchtower project delete N` in a terminal) also ends its embedded terminal:

```swift
    func reload() async {
        let previousIDs = summaries.map(\.id)
        do {
            // A deleted project's documents fall out of `summaries`; their
            // stale `viewed` stamps are never read again, so none are pruned.
            summaries = try await dbPool.read { try ProjectQueries.summaries($0) }
        } catch {
            errorMessage = "Could not load projects: \(error.localizedDescription)"
            return
        }
        for id in Self.vanished(previous: previousIDs, current: summaries.map(\.id)) {
            await closeTerminal?(id)
        }
    }
```

In `WatchtowerDesktop/Sources/App/AppState.swift`, `initProjects(dbPool:cliRunner:notifier:)`, right after `let vm = ProjectsViewModel(...)`:

```swift
        vm.closeTerminal = { [weak self] id in await self?.projectTerminalCenter.close(projectID: id) }
```

In `ProjectPageView.swift`, add to the view:

```swift
    @State private var deleteSummary: ProjectDeleteSummary?
    @State private var deleteSummaryError: String?
```

a button in the header `HStack` (next to Repair):

```swift
            Button(role: .destructive) {
                guard let pool = appState.databaseManager?.dbPool else { return }
                do {
                    deleteSummary = try pool.read { try ProjectDeleteSummary.fetch($0, project: project) }
                } catch {
                    // Never confirm a delete against unknown counts.
                    deleteSummaryError = error.localizedDescription
                }
            } label: {
                Label("Delete…", systemImage: "trash")
            }
            .disabled(vm.deletingProjectID != nil)
```

and on the page's root view:

```swift
        .confirmationDialog(
            deleteSummary?.title ?? "",
            isPresented: Binding(get: { deleteSummary != nil }, set: { if !$0 { deleteSummary = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Project", role: .destructive) {
                let id = project.id
                Task { await vm.deleteProject(id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteSummary?.message ?? "")
        }
        .alert(
            "Could not delete the project",
            isPresented: Binding(
                get: { vm.deleteError != nil },
                set: { if !$0 { vm.deleteError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm.deleteError ?? "")
        }
        .alert(
            "Could not read the project",
            isPresented: Binding(get: { deleteSummaryError != nil }, set: { if !$0 { deleteSummaryError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteSummaryError ?? "")
        }
```

(`vm` is `ProjectPageView`'s own `ProjectsViewModel`, which lives on AppState — the delete survives navigating away from the page.)

- [ ] **Step 9: Run to verify they pass**

Run: `make test-swift FILTER='ProjectDeleteSummaryTests|ProjectsViewModelDeleteTests' > /tmp/p5-20f.log 2>&1; echo "exit=$?"; grep -E "error:|failed|Executed" /tmp/p5-20f.log | head`
Expected: `exit=0`, `Executed 8 tests, with 0 failures`. Also rerun Phase 4's own suite, whose `reload()` this step changed: `make test-swift FILTER=ProjectsViewModelTests > /tmp/p5-20i.log 2>&1; echo "exit=$?"` → `exit=0`. Then `cd WatchtowerDesktop && swift build > /tmp/p5-20g.log 2>&1; echo "exit=$?"` → `exit=0`; `make lint-diff > /tmp/p5-20h.log 2>&1; echo "lint=$?"` → `lint=0`.

- [ ] **Step 10: Commit the delete flow**

```bash
git add WatchtowerDesktop/Sources/WatchtowerCore/Services/ProjectDeleteSummary.swift \
  WatchtowerDesktop/Sources/ViewModels/ProjectsViewModel.swift \
  WatchtowerDesktop/Sources/App/AppState.swift \
  WatchtowerDesktop/Sources/Views/Projects/ProjectPageView.swift \
  WatchtowerDesktop/Tests/Core/ProjectDeleteSummaryTests.swift \
  WatchtowerDesktop/Tests/ProjectsViewModelDeleteTests.swift
git commit -m "$(cat <<'EOF'
feat(projects): delete a project from the Desktop

Delete… on the project page confirms with what goes (targets, documents,
comments and the folder install; document files stay), then closes the
project's terminal, runs `watchtower project delete`, and reloads the list
(ProjectsViewModel.deleteProject). A CLI failure keeps the project and shows
the error. A project deleted from the CLI closes its embedded terminal when
it drops out of the list on reload.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Lo9jbbmXQcr3qHo5f3pLD8
EOF
)"
```

---

### Task 21: Briefing Projects section

**Files:**
- Create: `internal/briefing/projects.go`, `internal/briefing/projects_test.go`
- Modify: `internal/briefing/pipeline.go` (`RunForDate`, `getPrompt`), `internal/briefing/validate.go` (`project` ids), `internal/briefing/prompt.go` (verb list), `internal/prompts/defaults.go` (`defaultBriefingDaily`, `DefaultVersions`)
- Modify: `WatchtowerDesktop/Sources/Views/Briefings/BriefingDetailView.swift` (`sourceLabel` for `project`)

**Interfaces:**
- Consumes: Phase 1 `db.ListProjects`, `db.GetProjectBoard`, `db.ListProjectComments`, `db.ListProjectDocuments`, `db.BoardNode`; existing `(*Pipeline).revisionWindowStart(userID, date string) time.Time`.
- Produces: `func (p *Pipeline) gatherProjects(since time.Time) (string, bool)`; `const noProjectActivity = "(no project activity)"`; `func countVerbs(tmpl string) int`; `func (p *Pipeline) storedPrompt(id, role string) (string, int)`; `(*shownIDs).addProject(id int64)`; `briefing.daily` v8 with 16 `%s` (the 15th = PROJECTS, the 16th = MEMORY REVISIONS).

- [ ] **Step 0: Confirm the Phase 1 names**

Run: `grep -n "func (db \*DB) ListProjects\|func (db \*DB) GetProjectBoard\|func (db \*DB) ListProjectComments\|func (db \*DB) ListProjectDocuments\|func (db \*DB) CreateProjectTarget\|func (db \*DB) AddProjectComment\|func (db \*DB) UpsertProjectDocument\|func (db \*DB) CreateProject\|type BoardNode" internal/db/*.go`
Expected: every name from "Interface assumptions". Adapt below if a signature differs.

- [ ] **Step 1: Write the failing tests**

Create `internal/briefing/projects_test.go`:

```go
package briefing

import (
	"context"
	"database/sql"
	"io"
	"log"
	"strings"
	"testing"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/prompts"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func seedProject(t *testing.T, d *db.DB, name string) int64 {
	t.Helper()
	id, err := d.CreateProject(name, t.TempDir())
	require.NoError(t, err)
	return id
}

func seedProjectTarget(t *testing.T, d *db.DB, projectID int64, parent int64, title, status, updatedAt string) int64 {
	t.Helper()
	p := sql.NullInt64{}
	if parent != 0 {
		p = sql.NullInt64{Int64: parent, Valid: true}
	}
	id, err := d.CreateProjectTarget(projectID, p, title, "")
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE targets SET status = ?, updated_at = ? WHERE id = ?`, status, updatedAt, id)
	require.NoError(t, err)
	return id
}

func TestGatherProjects_NoProjectsRendersThePlaceholder(t *testing.T) {
	pipe := New(testDB(t), testConfig(), &mockGenerator{}, log.New(io.Discard, "", 0))
	ctx, has := pipe.gatherProjects(time.Now().Add(-24 * time.Hour))
	assert.False(t, has)
	assert.Equal(t, noProjectActivity, ctx)
}

func TestGatherProjects_ReportsActivityAndSkipsQuietProjects(t *testing.T) {
	d := testDB(t)
	since := time.Date(2026, 9, 28, 8, 0, 0, 0, time.UTC)
	busy := seedProject(t, d, "acme")
	quiet := seedProject(t, d, "quiet")

	feature := seedProjectTarget(t, d, busy, 0, "Payments feature", "in_progress", "2026-09-29T09:00:00Z")
	seedProjectTarget(t, d, busy, feature, "Task 3: wire the API", "blocked", "2026-09-29T09:00:00Z")
	seedProjectTarget(t, d, busy, feature, "Task 1: schema", "done", "2026-09-29T07:00:00Z")
	seedProjectTarget(t, d, busy, feature, "Task 0: spike", "done", "2026-09-20T07:00:00Z")
	seedProjectTarget(t, d, quiet, 0, "Idle idea", "todo", "2026-09-01T00:00:00Z")

	_, err := d.AddProjectComment(db.ProjectComment{
		ProjectID: busy, TargetID: sql.NullInt64{Int64: feature, Valid: true},
		Author: "agent", Body: "Which currency list?",
	})
	require.NoError(t, err)
	docID, _, err := d.UpsertProjectDocument(db.ProjectDocument{ProjectID: busy, RelPath: "docs/plan.md", Kind: "plan", Title: "Payments plan"})
	require.NoError(t, err)
	_, err = d.AddProjectComment(db.ProjectComment{
		ProjectID: busy, DocumentID: sql.NullInt64{Int64: docID, Valid: true},
		Author: "owner", Body: "Split task 3", AnchorQuote: "Task 3",
	})
	require.NoError(t, err)

	pipe := New(d, testConfig(), &mockGenerator{}, log.New(io.Discard, "", 0))
	pipe.shown = newShownIDs()
	ctx, has := pipe.gatherProjects(since)

	require.True(t, has)
	assert.Contains(t, ctx, "[project_id=")
	assert.Contains(t, ctx, "acme")
	assert.Contains(t, ctx, "In progress (1): Payments feature")
	assert.Contains(t, ctx, "Blocked (1): Task 3: wire the API")
	assert.Contains(t, ctx, "Done since the last briefing (1): Task 1: schema")
	assert.NotContains(t, ctx, "Task 0: spike", "done before the window")
	assert.Contains(t, ctx, "Unread agent comments: 1")
	assert.Contains(t, ctx, "Documents with open owner comments (1): Payments plan")
	assert.NotContains(t, ctx, "quiet", "a project with no activity is omitted")
	assert.True(t, pipe.shown.projects[busy])
}

func TestGatherProjects_CapsItemsPerLine(t *testing.T) {
	d := testDB(t)
	pid := seedProject(t, d, "acme")
	for i := 0; i < maxProjectItems+2; i++ {
		seedProjectTarget(t, d, pid, 0, "Task "+strings.Repeat("x", i+1), "in_progress", "2026-09-29T09:00:00Z")
	}
	pipe := New(d, testConfig(), &mockGenerator{}, log.New(io.Discard, "", 0))
	ctx, _ := pipe.gatherProjects(time.Now().Add(-24 * time.Hour))
	assert.Contains(t, ctx, "(+2 more)")
}

func TestBriefingHasDataWithProjectsOnly(t *testing.T) {
	d := testDB(t)
	require.NoError(t, d.UpsertWorkspace(db.Workspace{ID: "T1", Name: "test", Domain: "test"}))
	_, err := d.CreateSlackAccount(db.SlackAccount{CurrentUserID: "U001"})
	require.NoError(t, err)
	pid := seedProject(t, d, "acme")
	seedProjectTarget(t, d, pid, 0, "Payments feature", "in_progress", time.Now().UTC().Format("2006-01-02T15:04:05Z"))

	gen := &capturingGenerator{response: `{"attention":[],"your_day":[],"what_happened":[],"team_pulse":[],"coaching":[]}`}
	pipe := New(d, testConfig(), gen, log.New(io.Discard, "", 0))
	id, err := pipe.RunForDate(context.Background(), time.Now().Format("2006-01-02"))
	require.NoError(t, err)
	assert.Greater(t, id, 0, "project activity alone is enough for a briefing")
	assert.Contains(t, gen.systemMsg, "=== PROJECTS ===")
	assert.Contains(t, gen.systemMsg, "Payments feature")
	assert.NotContains(t, gen.systemMsg, "%!", "every verb got exactly one argument")
}

// A briefing.daily row the owner customized before v8 carries one %s fewer.
// Formatting it with the v8 arguments would shift PROJECTS into the MEMORY
// REVISIONS slot and append %!(EXTRA ...) to the prompt; getPrompt must fall
// back to the shipped default instead.
func TestGetPrompt_CustomizedTemplateWithOldVerbCountFallsBackToDefault(t *testing.T) {
	d := testDB(t)
	require.NoError(t, d.UpsertWorkspace(db.Workspace{ID: "T1", Name: "test", Domain: "test"}))
	_, err := d.CreateSlackAccount(db.SlackAccount{CurrentUserID: "U001"})
	require.NoError(t, err)
	pid := seedProject(t, d, "acme")
	seedProjectTarget(t, d, pid, 0, "Payments feature", "in_progress", time.Now().UTC().Format("2006-01-02T15:04:05Z"))

	const sentinel = "SENTINEL-PRE-V8-BRIEFING-7C21"
	verbs := countVerbs(prompts.Defaults[prompts.BriefingDaily])
	require.Equal(t, 16, verbs, "v8 carries 16 verbs")
	old := sentinel + "\n" + strings.Repeat("%s\n", verbs-1)

	store := prompts.New(d, nil)
	require.NoError(t, store.Seed())
	require.NoError(t, store.Update(prompts.BriefingDaily, old, "customized before v8"))

	gen := &capturingGenerator{response: `{"attention":[],"your_day":[],"what_happened":[],"team_pulse":[],"coaching":[]}`}
	pipe := New(d, testConfig(), gen, log.New(io.Discard, "", 0))
	pipe.SetPromptStore(store)
	id, err := pipe.RunForDate(context.Background(), time.Now().Format("2006-01-02"))
	require.NoError(t, err)

	assert.NotContains(t, gen.systemMsg, sentinel, "the mismatched template must not be used")
	assert.NotContains(t, gen.systemMsg, "%!")
	assert.Contains(t, gen.systemMsg, "=== PROJECTS ===")
	stored, err := d.GetBriefingByID(id)
	require.NoError(t, err)
	assert.Equal(t, 0, stored.PromptVersion, "a fallback records the default arm's version 0")
}

func TestCountVerbs_IgnoresEscapedPercent(t *testing.T) {
	assert.Equal(t, 2, countVerbs("a %s b %s c 100%%s"))
}

func TestValidateIDs_ProjectSourceMustBeShown(t *testing.T) {
	s := newShownIDs()
	s.addProject(3)
	r := &BriefingResult{Attention: []AttentionItem{
		{Text: "a", SourceType: "project", SourceID: "3"},
		{Text: "b", SourceType: "project", SourceID: "9"},
	}}
	assert.Equal(t, 1, s.validateIDs(r))
	assert.Equal(t, "3", r.Attention[0].SourceID)
	assert.Equal(t, "", r.Attention[1].SourceID)
}

func TestBriefingDailyVersionAtLeastEight(t *testing.T) {
	// v8 introduced the PROJECTS block.
	assert.GreaterOrEqual(t, prompts.DefaultVersions[prompts.BriefingDaily], 8)
}
```

(`AttentionItem` is the existing element type of `BriefingResult.Attention` — confirm with `grep -n "Attention " internal/briefing/*.go`; `GetBriefingByID` returns `(*db.Briefing, error)` as in `pipeline_test.go`.)

- [ ] **Step 2: Run to verify they fail**

Run: `go test ./internal/briefing -run 'TestGatherProjects|TestBriefingHasDataWithProjectsOnly|TestGetPrompt_|TestCountVerbs|TestValidateIDs_Project|TestBriefingDailyVersionAtLeastEight' > /tmp/p5-21a.log 2>&1; echo "exit=$?"; head -20 /tmp/p5-21a.log`
Expected: `exit=1`, `undefined: noProjectActivity`, `pipe.gatherProjects undefined`, `undefined: countVerbs`, `s.addProject undefined`.

- [ ] **Step 3: Implement `gatherProjects`**

Create `internal/briefing/projects.go`:

```go
package briefing

import (
	"fmt"
	"strings"
	"time"

	"watchtower/internal/db"
)

// noProjectActivity is the PROJECTS placeholder when no project has anything
// to report; the template tells the model to ignore projects entirely then,
// and it keeps the Sprintf argument count fixed.
const noProjectActivity = "(no project activity)"

// maxBriefingProjects and maxProjectItems keep the block short: the briefing
// points at the board, it does not reproduce it.
const (
	maxBriefingProjects = 5
	maxProjectItems     = 5
)

// projectActivity is one project's slice of the briefing. Mechanical, no AI.
type projectActivity struct {
	inProgress, blocked, doneSince []string
	unreadAgent                    int
	docsAwaiting                   []string
}

func (a projectActivity) empty() bool {
	return len(a.inProgress) == 0 && len(a.blocked) == 0 && len(a.doneSince) == 0 &&
		a.unreadAgent == 0 && len(a.docsAwaiting) == 0
}

// gatherProjects renders the PROJECTS block: per project with activity — in
// progress, blocked, done since `since` (the previous briefing), unread agent
// comments, and documents whose owner comments still wait for the agent. A
// project that fails to load is logged and skipped; the rest still render.
func (p *Pipeline) gatherProjects(since time.Time) (string, bool) {
	projects, err := p.db.ListProjects()
	if err != nil {
		p.logger.Printf("briefing: error loading projects: %v", err)
		return noProjectActivity, false
	}
	sinceTS := since.UTC().Format("2006-01-02T15:04:05Z")
	var sb strings.Builder
	shown := 0
	for i := range projects {
		if shown >= maxBriefingProjects {
			break
		}
		a, err := p.projectActivity(projects[i].ID, sinceTS)
		if err != nil {
			p.logger.Printf("briefing: project %d: %v", projects[i].ID, err)
			continue
		}
		if a.empty() {
			continue
		}
		p.shown.addProject(projects[i].ID)
		sb.WriteString(renderProjectActivity(projects[i], a))
		shown++
	}
	if shown == 0 {
		return noProjectActivity, false
	}
	return sb.String(), true
}

func (p *Pipeline) projectActivity(projectID int64, sinceTS string) (projectActivity, error) {
	var a projectActivity
	board, err := p.db.GetProjectBoard(projectID)
	if err != nil {
		return a, fmt.Errorf("board: %w", err)
	}
	comments, err := p.db.ListProjectComments(db.ProjectCommentFilter{ProjectID: projectID})
	if err != nil {
		return a, fmt.Errorf("comments: %w", err)
	}
	docs, err := p.db.ListProjectDocuments(projectID)
	if err != nil {
		return a, fmt.Errorf("documents: %w", err)
	}
	a.addTargets(board, sinceTS)
	a.addComments(comments, docs)
	return a, nil
}

func (a *projectActivity) addTargets(nodes []db.BoardNode, sinceTS string) {
	for _, n := range nodes {
		title := firstLine(n.Target.Text)
		switch {
		case n.Target.Status == "in_progress":
			a.inProgress = append(a.inProgress, title)
		case n.Target.Status == "blocked":
			a.blocked = append(a.blocked, title)
		case n.Target.Status == "done" && n.Target.UpdatedAt >= sinceTS:
			a.doneSince = append(a.doneSince, title)
		}
		a.addTargets(n.Children, sinceTS)
	}
}

func (a *projectActivity) addComments(comments []db.ProjectComment, docs []db.ProjectDocument) {
	awaiting := map[int64]bool{}
	for _, c := range comments {
		if c.Author == "agent" && c.ReadAt == "" {
			a.unreadAgent++
		}
		if c.Author == "owner" && c.Status == "open" && !c.ParentID.Valid && c.DocumentID.Valid {
			awaiting[c.DocumentID.Int64] = true
		}
	}
	for _, d := range docs {
		if awaiting[d.ID] {
			a.docsAwaiting = append(a.docsAwaiting, documentTitle(d))
		}
	}
}

func renderProjectActivity(pr db.Project, a projectActivity) string {
	var sb strings.Builder
	fmt.Fprintf(&sb, "--- [project_id=%d] %s (%s) ---\n", pr.ID, pr.Name, pr.FolderPath)
	writeProjectLine(&sb, "In progress", a.inProgress)
	writeProjectLine(&sb, "Blocked", a.blocked)
	writeProjectLine(&sb, "Done since the last briefing", a.doneSince)
	if a.unreadAgent > 0 {
		fmt.Fprintf(&sb, "Unread agent comments: %d\n", a.unreadAgent)
	}
	writeProjectLine(&sb, "Documents with open owner comments", a.docsAwaiting)
	return sb.String()
}

func writeProjectLine(sb *strings.Builder, label string, items []string) {
	if len(items) == 0 {
		return
	}
	shown := items
	more := ""
	if len(items) > maxProjectItems {
		shown = items[:maxProjectItems]
		more = fmt.Sprintf(" (+%d more)", len(items)-maxProjectItems)
	}
	fmt.Fprintf(sb, "%s (%d): %s%s\n", label, len(items), strings.Join(shown, "; "), more)
}

func documentTitle(d db.ProjectDocument) string {
	if d.Title != "" {
		return d.Title
	}
	return d.RelPath
}

func firstLine(s string) string {
	line, _, _ := strings.Cut(s, "\n")
	return strings.TrimSpace(line)
}
```

(If `firstLine` already exists in package `briefing` — `grep -n "func firstLine" internal/briefing/*.go` — drop this copy.)

In `internal/briefing/validate.go`: add `projects map[int64]bool` to `shownIDs`, initialise it in `newShownIDs` (`projects: map[int64]bool{},`), add

```go
func (s *shownIDs) addProject(id int64) {
	if s != nil {
		s.projects[id] = true
	}
}
```

and a case in `resolveAttentionSource` before `default`:

```go
	case "project":
		id, err := strconv.ParseInt(strings.TrimSpace(sourceID), 10, 64)
		if err != nil || !s.projects[id] {
			return "", false
		}
		return strconv.FormatInt(id, 10), true
```

- [ ] **Step 4: Wire it into `RunForDate`, `hasData`, the prompt args, and the verb-count fallback**

In `internal/briefing/pipeline.go`, `RunForDate`, after `memRevisionsCtx := …`:

```go
	projectsCtx, hasRealProjects := p.gatherProjects(p.revisionWindowStart(currentUserID, date))
```

replace the `hasData` expression (a sixth `||` would push `RunForDate` toward the cyclomatic gate; the helper takes it out of the function instead):

```go
	hasData := hasAnyData(digestsCtx, dailyDigestCtx, hasRealTracks, hasRealTargets, hasRealInbox, hasRealProjects)
```

and add next to `learnedPrefs`:

```go
// hasAnyData reports whether the briefing has real material: a digest, the
// daily rollup, or any of the gathered sections that found real rows
// (suggestion/placeholder text alone never counts).
func hasAnyData(digests, dailyRollup string, found ...bool) bool {
	if digests != "" || dailyRollup != "" {
		return true
	}
	for _, f := range found {
		if f {
			return true
		}
	}
	return false
}
```

and the Sprintf argument list (PROJECTS goes before MEMORY REVISIONS, which stays last):

```go
		jiraCtx,
		projectsCtx,
		memRevisionsCtx,
	)
```

Replace `getPrompt` with:

```go
func (p *Pipeline) getPrompt(id, role string) (string, int) {
	tmpl, version := p.storedPrompt(id, role)
	if tmpl == "" {
		tmpl, version = prompts.Defaults[id], 0
	}
	if roleInstr := prompts.GetRoleInstruction(role); roleInstr != "" {
		tmpl = roleInstr + "\n\n" + tmpl
	}
	return tmpl, version
}

// storedPrompt returns the prompt store's template, or "" when there is no
// store, the lookup fails, or the stored template's %s count differs from the
// shipped default's. The last case is a row the owner customized before a
// version added a section: formatting it with the new argument list would
// shift every later section and append %!(EXTRA ...) to the prompt.
func (p *Pipeline) storedPrompt(id, role string) (string, int) {
	if p.promptStore == nil {
		return "", 0
	}
	tmpl, version, err := p.promptStore.GetForRole(id, role)
	if err != nil {
		return "", 0
	}
	if got, want := countVerbs(tmpl), countVerbs(prompts.Defaults[id]); got != want {
		p.logger.Printf("briefing: stored %s template has %d placeholders, the default has %d — using the default (reset the prompt in Settings to pick up the new sections)", id, got, want)
		return "", 0
	}
	return tmpl, version
}

// countVerbs counts %s verbs, not counting an escaped %%s.
func countVerbs(tmpl string) int {
	return strings.Count(tmpl, "%s") - strings.Count(tmpl, "%%s")
}
```

In `internal/briefing/prompt.go`, change "uses 14 format verbs" to "uses 16 format verbs" and append:

```go
//  15. projectsCtx    — Watchtower projects with board/comment activity since the previous briefing
//  16. memRevisionsCtx — notable memory belief revisions (always last)
```

- [ ] **Step 5: The template, v8**

In `internal/prompts/defaults.go`, `defaultBriefingDaily`:

1. In the JSON example, change `"source_type": "track|digest|people|inbox|target"` to `"source_type": "track|digest|people|inbox|target|project"`.
2. Insert this rule line directly before the `- MEMORY REVISIONS:` rule:

```
- PROJECTS: the PROJECTS section lists the user's Watchtower projects — folder-bound boards that coding agents work on — with activity since the previous briefing. Bring a project into "attention" only for a blocked target, unread agent comments (an agent may be waiting for an answer), or documents whose comments still wait for the agent; use source_type="project" and source_id=the project_id. Never put a project's targets into "your_day" or into target_id — they live on the project board, not among the user's targets. If the section reads "(no project activity)", do not mention projects at all.
```

3. Insert this section between `=== JIRA CONTEXT ===\n%s` and `=== MEMORY REVISIONS ===`:

```
=== PROJECTS ===
%s

```

so the template tail reads:

```
=== JIRA CONTEXT ===
%s

=== PROJECTS ===
%s

=== MEMORY REVISIONS ===
%s`
```

4. Bump the version:

```go
	BriefingDaily:              8, // v8: PROJECTS block (Watchtower projects, spec 2026-09-29)
```

- [ ] **Step 6: Run to verify they pass**

Run:
```bash
go test ./internal/briefing > /tmp/p5-21b.log 2>&1; echo "exit=$?"; tail -5 /tmp/p5-21b.log
go test ./internal/prompts > /tmp/p5-21c.log 2>&1; echo "exit=$?"; tail -5 /tmp/p5-21c.log
```
Expected: both `exit=0` (`ok watchtower/internal/briefing`, `ok watchtower/internal/prompts`). `TestPipelineRunForDate_UsesCustomizedPromptAndRecordsVersion` still passes — it derives its verb count from the default. The memory-revisions tests still pass because MEMORY REVISIONS stays the last section.

- [ ] **Step 7: Desktop label for a project source**

In `WatchtowerDesktop/Sources/Views/Briefings/BriefingDetailView.swift`, `sourceLabel(type:)`, add before `default:`:

```swift
            case "project": return ("folder", "Project")
```

(No navigation case: a project deep link rides Phase 4's project selection; the label alone keeps the attention row readable.) Run `cd WatchtowerDesktop && swift build > /tmp/p5-21d.log 2>&1; echo "exit=$?"` → `exit=0`.

- [ ] **Step 8: Lint and commit**

Run: `make lint-diff > /tmp/p5-21e.log 2>&1; echo "lint=$?"` → `lint=0` (the new functions are all well under the cyclomatic gate; `getPrompt` got simpler).

```bash
git add internal/briefing/projects.go internal/briefing/projects_test.go internal/briefing/pipeline.go \
  internal/briefing/validate.go internal/briefing/prompt.go internal/prompts/defaults.go \
  WatchtowerDesktop/Sources/Views/Briefings/BriefingDetailView.swift
git commit -m "$(cat <<'EOF'
feat(briefing): Projects section in the daily briefing (briefing.daily v8)

gatherProjects renders, per project with activity, the targets in progress,
blocked and done since the previous briefing, unread agent comments, and
documents whose owner comments still wait for the agent — mechanical, no
AI. Project activity alone is enough for a briefing. Attention items may
cite source_type="project", validated against the projects shown.

A stored briefing.daily whose %s count no longer matches the default (a row
customized before v8) now falls back to the default instead of shifting
every later section and appending %!(EXTRA ...).

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Lo9jbbmXQcr3qHo5f3pLD8
EOF
)"
```

---

### Task 22: Docs + manual QA checklist

**Files:**
- Modify: `CLAUDE.md` (feature note), `docs/app-guide.md` (Projects section + two cross-references), `docs/inventory/dev-surface.md`, `docs/inventory/projects.md`, `docs/inventory/targets.md` (changelog lines)
- No code, no tests. The QA checklist goes into the PR body, not the repo.

**Interfaces:** none.

- [ ] **Step 0: Check what earlier tasks already wrote**

Run:
```bash
grep -n "2026-09-29" docs/inventory/dev-surface.md docs/inventory/projects.md docs/inventory/targets.md
grep -n "### Projects" CLAUDE.md docs/app-guide.md
```
Expected: Task 9's DEV-06 / DEV-01 / DEV-05 amendment entry in `dev-surface.md` and the file-creation entry in `projects.md`; nothing in `targets.md`; no `### Projects` heading yet (the AI Chat's `**Projects**` paragraph in app-guide is a bold run-in, not a heading). The lines below are **additional** entries — do not repeat what Task 9 wrote; if Task 9's entry already covers a sentence below, drop that sentence.

- [ ] **Step 1: CLAUDE.md feature note**

Insert immediately before `### Catch-Up — absence recap (2026-09-04)` in `CLAUDE.md`:

```markdown
### Projects — Claude Code works a folder-bound board (2026-09-29, POC)
- A **project** is a folder (`projects`, migration `00081`; `folder_path` symlink-resolved and UNIQUE) with sources (`project_sources`), attached markdown documents (`project_documents`, `rel_path` inside the folder), owner↔agent comments (`project_comments`: on a target, on a document with a text anchor `anchor_quote/prefix/suffix/heading`, or a reply; roots `open|resolved|outdated`) and a board of ordinary `targets` rows carrying `project_id` (`level='custom'`, `custom_label='project'`, `source_type='chat'`). Separate from the AI Chat's `chat_projects`, which stay as they are.
- **PROJ-01:** a project target never reaches a non-board reader — `TargetFilter.ProjectID` 0 = exclude (the default for every existing caller), plus `project_id IS NULL` in next-step, briefing targets, counts, due-notify, catch-up, memory mirrors, day plan, channel stats and the extract/dedup snapshots; Swift `TargetQueries.fetchAll/fetchCounts/fetchDistinctTags` (so the Targets badge), the chat `@` picker, and "Wipe LLM data" (which would otherwise delete them as `source_type='chat'`).
- Work is done by Claude Code in the folder — the owner's own terminal or the Desktop's embedded SwiftTerm terminal (`ProjectTerminalCenter` on AppState, login shell `exec claude`, SIGHUP → SIGKILL after 3 s, closed by `QuitCoordinator`). Both see the board through `watchtower mcp --project N` (**DEV-06**: writes only project N's rows, applied directly under `tools.Binding.DirectApply` with an `agent_actions` audit row, never an `External` tool; plain `watchtower mcp` stays read-only, DEV-01) and a `SessionStart` hook running `watchtower project brief --project N` (≤ 4000 chars, always exit 0).
- `watchtower integrate claude-code --project N` installs, locally and never committed: the `watchtower-project` skill (setup, plan = board, comment discipline; DEV-04 marker + digest), the hook merged into `.claude/settings.local.json` (a malformed file is left byte-identical and reported), `claude mcp add --scope local watchtower-project`, and `.git/info/exclude` lines; `integrate remove --project N` undoes exactly those (**PROJ-04** never overwrites the owner's own content). `watchtower project create|list|show|board|delete|brief`; `delete` runs the removal first and deletes rows in one transaction (**PROJ-02** nothing left behind).
- Desktop: sidebar **Projects** tab (list + badge = unread agent comments + revised documents), project page Terminal | Board | Documents. Documents render in a selectable `NSTextView`; a comment anchors on the rendered plain text and is re-located on every file change by the pure `CommentAnchor` (exact quote → best prefix/suffix among duplicates → else `outdated`, never re-attached elsewhere); the Desktop never writes a project document (**PROJ-03**). The board edits status/title with the `TargetQueries` mutators and polls a fingerprint because agent writes come from another process. `ProjectsViewModel.deleteProject` closes the terminal, runs `project delete`, reloads; a project deleted from the CLI closes its terminal on the next reload. `ProjectNotificationCenter` (pure `ProjectNotificationPolicy`, 30 s poll, per-project watermark, bursts ≥ 3 coalesced, never the owner's own writes; `projects.notifications` default on) notifies on an agent question, a document ready for review, all comments answered, a target done.
- Briefing: `gatherProjects` adds a `=== PROJECTS ===` block (`briefing.daily` v8, before MEMORY REVISIONS, which stays last; project activity alone is enough for a briefing); a stored template whose `%s` count differs from the default falls back to the default.
- v1 limits (accepted): a folder under `~/Documents`, `~/Desktop`, `~/Downloads` or `~/Library/CloudStorage` makes macOS attribute Claude Code's file access to Watchtower (the New-project flow warns); `project_sources` is informational (not used for search); project documents are not indexed into `kb`; no multi-agent locking. Contracts `docs/inventory/projects.md` (PROJ-01..04), DEV-06 in `docs/inventory/dev-surface.md`. Spec `docs/superpowers/specs/2026-09-29-project-board-poc-design.md`, plan `docs/superpowers/plans/2026-09-29-projects-poc.md`.
```

- [ ] **Step 2: `docs/app-guide.md`**

2a. Insert this section immediately before `### AI Chat`:

```markdown
### Projects
A project is a folder on your Mac — for example a code repository — that a coding agent (Claude Code) works in, with a **board** that outlives any one agent session. Watchtower keeps the overview: what is being worked on, what is blocked, which plans and specs are waiting for your review, and the questions the agent left for you. (This is separate from the AI Chat's own "Projects", which group chats.)

**New project…** — choose or create a folder. Watchtower creates the project, sets the folder up for Claude Code (a `watchtower-project` skill, a session-start hook and a local MCP connection — all local to your Mac and excluded from git), and opens the project with its terminal running Claude Code, which reads the folder's README and docs, fills in the project description and sources, and proposes a first board. Nothing is created until you agree in the terminal. A folder inside Documents, Desktop, Downloads or a cloud-synced folder shows a warning first: macOS may ask you to allow Watchtower access to it.

**Terminal** — Claude Code running in the project folder, the same as in your own terminal app: the same login, permissions and project memory. It keeps running while you use other tabs; **Restart** appears when it exits, and quitting Watchtower closes it. You can equally work from your own terminal — both see the same board.

**Board** — the project's targets as a tree (a feature and its sub-targets; a written plan becomes one sub-target per task). Each row shows its status, progress and badges: a blue bubble for agent comments you have not read, an orange count of open comment threads, and a document icon for attached plans or specs. **Show done** reveals finished work (a finished feature with an open task under it always stays visible). Select a target to rename it, change its status, and read or answer its comment threads — agents use comments to ask you questions without stopping their work, and to post a short summary when a task is done. Opening a target marks its agent comments read.

**Documents** — plans, specs and notes the agent attached. Open one to read it rendered; select text and **Comment** to leave a note on exactly that passage. The agent reads your open comments before revising the file, replies and resolves each one. When the file changes, your comments follow their text; a comment whose passage was rewritten away moves to **Outdated** instead of landing on the wrong paragraph. You can reply, resolve and reopen; Watchtower never edits the document itself.

**Notifications** — Watchtower tells you when an agent asks something on a target, when a document is ready for review, when all your comments on a document are answered, and when an agent finishes a target. Several at once in one project arrive as one summary. Clicking opens the Board or Documents pane. Settings → Notifications has the switch (on by default).

**Delete…** — the confirmation lists what goes: the board's targets, the attached documents' entries and the comments, plus what Watchtower installed in the folder (the skill, the hook, the MCP connection and its git-exclude lines). The document files and everything else in the folder stay. The project's terminal is closed first. If the delete fails, the project stays and the reason is shown.

Project targets appear only on their board — never in Tasks, the Day Plan, next steps or Catch Up. The daily briefing has its own mention of project activity.
```

2b. In `### Tasks`, append to the first paragraph ("Personal action items — …"): ` Targets of a Projects board are not listed here; they live on their project's board.`

2c. In `### Briefings`, after the **Coaching Corner** paragraph, add:

```markdown
**Projects** — when a project had activity since the previous briefing (a blocked target, unread agent comments, documents whose comments wait for the agent), the briefing can bring it into Needs Attention, labeled *Project*. Project activity alone is enough for a briefing to be generated.
```

- [ ] **Step 3: Inventory changelog lines**

Prepend to the `## Changelog` list of `docs/inventory/projects.md` (newest first, after Task 9's creation entry if it is dated the same day):

```markdown
- 2026-09-29 (Phase 5 of the Projects POC, spec `docs/superpowers/specs/2026-09-29-project-board-poc-design.md`): **PROJ-01** gains its Desktop guards — `testProj01_FetchAllNeverReturnsAProjectTarget`, `testProj01_FetchAllTagFilterNeverReturnsAProjectTarget`, `testProj01_FetchCountsIgnoreProjectTargets`, `testProj01_DueTodayIgnoresProjectTargets`, `testProj01_DistinctTagsNeverListAProjectTargetsTag`, `testProj01_MentionPickerNeverOffersAProjectTarget` (`Tests/Core/ProjectTargetExclusionTests.swift`) and `testProj01_TargetsBadgeIgnoresProjectTargets` (`Tests/SidebarCountsViewModelTests.swift`); the Observable now lists the Swift readers (`TargetQueries.fetchAll/fetchCounts/fetchDistinctTags`, `ChatEntitySearch.targets`). **PROJ-02** is strengthened on the Desktop side: "Wipe LLM data" (`DatabaseManager.wipeLLMData`) no longer deletes project targets, which are `source_type='chat'` (guard `testWipeLLMDataPreservesProjectTargets`) — only a project delete removes a board; the Desktop delete (`ProjectsViewModel.deleteProject`) closes the project's terminal before running `watchtower project delete`, keeps the project listed on a CLI failure, and closes the terminal of a project deleted from outside (`ProjectsViewModelDeleteTests`). The daily briefing reads project boards through `gatherProjects` into its own PROJECTS block (`briefing.daily` v8) — a board reader by design, not a PROJ-01 leak: project targets still never enter the briefing's YOUR TARGETS input (`GetTargetsForBriefing`) nor `target_id`.
```

Prepend to the `## Changelog` list of `docs/inventory/dev-surface.md`:

```markdown
- 2026-09-29: the Projects POC's install lands on the DEV-04 installer rules unchanged — the `watchtower-project` skill carries the `x-watchtower-pack` marker and `.watchtower-shipped` digest and is embedded separately (`//go:embed projectskill/*/SKILL.md`), so plain `integrate claude-code` never installs it; `integrate remove --project N` deletes only marker-carrying files, our own `SessionStart` entry and the exclude lines it added. No DEV-01..05 semantics beyond Task 9's DEV-01/DEV-05 amendments and the new DEV-06 changed.
```

Prepend to the `## Changelog` list of `docs/inventory/targets.md`:

```markdown
- 2026-09-29 (Projects POC, spec `docs/superpowers/specs/2026-09-29-project-board-poc-design.md`): `targets` gains `project_id`; a project target lives only on its project board and never appears in the Targets tab, its badge, its tag menu or the chat `@` picker (PROJ-01, `docs/inventory/projects.md`). A project target therefore never opens the target Discuss chat, so TGT-BRIEF-01..03 do not apply to it — its writers are the project tools under DEV-06 and the board's direct `TargetQueries.updateStatus/updateText` edits (the existing INBOX-02 cascade and parent-progress recompute ride along unchanged). No TGT-BRIEF contract or guard changed.
```

- [ ] **Step 4: Verify the docs build nothing and leak nothing**

Run:
```bash
git diff --stat
bash scripts/leak-check.sh > /tmp/p5-22.log 2>&1; echo "leak=$?"
```
Expected: only the five doc files changed; `leak=0` (the texts use no real names, ids or paths — `/tmp/acme`-style samples only).

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md docs/app-guide.md docs/inventory/dev-surface.md docs/inventory/projects.md docs/inventory/targets.md
git commit -m "$(cat <<'EOF'
docs(projects): feature note, app guide and inventory changelogs

CLAUDE.md gains the Projects feature note; docs/app-guide.md a Projects
section (terminal, board, documents with comments, notifications, delete)
plus the Tasks/Briefings cross-references; the projects, dev-surface and
targets inventories record the Phase 5 guards and the board/Targets split.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Lo9jbbmXQcr3qHo5f3pLD8
EOF
)"
```

- [ ] **Step 6: Manual QA checklist for the PR body**

Paste this into the PR description (under "## Manual QA"), ticking each item after doing it on a `make app-dev` build with the daemon running. Use a scratch clone of this repository for the end-to-end run, not the working copy.

```markdown
## Manual QA

### TCC (P0 — any unexpected prompt fails the PR)
- [ ] New project on a folder **outside** `~/Documents`, `~/Desktop`, `~/Downloads`, `~/Library/CloudStorage` (e.g. `~/Code/acme-clone`): no warning, and no macOS privacy prompt at any point — project create, integrate, terminal start, Claude Code reading/writing files, document view, file watching, delete.
- [ ] New project on a folder under `~/Documents`: the New-project flow shows the location warning **before** anything runs; cancelling leaves no project row.
- [ ] Same for `~/Desktop`, `~/Downloads` and a folder under `~/Library/CloudStorage` (any synced provider): warning shown each time. If continued, note which prompt macOS shows and that denying it does not crash the app or leave the project half-created.
- [ ] System Settings → Privacy & Security → Accessibility / Input Monitoring / Automation: Watchtower is not listed after the whole run.

### Terminal
- [ ] Terminal opens in the project folder running `claude` from the login shell (`which claude` inside a shell escape matches the owner's own terminal); auth is the owner's own.
- [ ] Navigate to another tab and back: the same session, scrollback intact.
- [ ] Exit Claude Code (`/exit`): Restart appears and starts a fresh session.
- [ ] Quit Watchtower with the terminal running: the `claude` process is gone within ~3 s (`pgrep -fl claude` shows none from that folder).
- [ ] A folder path with a space and a non-ASCII character works end to end.
- [ ] Move the project folder away with a session closed, then start one: the hook prints `Watchtower: project N folder <path> is missing (moved or deleted?).`, CC still starts, and the Desktop terminal shows the folder-missing state instead of launching.

### End to end (spec §10), on a scratch clone of this repository
- [ ] New project → terminal opens, CC runs setup: description and sources are set (`watchtower project show N`), a first board is proposed and created only after answering "yes".
- [ ] A fresh CC session — embedded and in iTerm/Terminal.app — prints the brief at start; `/mcp` lists `watchtower-project`.
- [ ] Agree a feature and let CC write its spec + plan: both appear under Documents; the board shows the feature with one sub-target per plan task; "ready for review" notifications arrive (a burst of ≥ 3 in one poll arrives as one summary).
- [ ] Comment a paragraph of the plan in the Desktop: no notification for this owner write; the next brief lists the comment.
- [ ] CC revises the plan and resolves the comment with a reply: "All comments on ‹plan› answered" notification; the document view shows the new text and the resolved thread in place without reopening.
- [ ] Rewrite the commented paragraph by hand in an editor so the quote disappears: the thread moves to Outdated.
- [ ] Run an SDD task: its sub-target goes in_progress → done with a summary comment; "‹target› done" notification; the Board updates within ~5 s without reopening the page; opening the target clears its unread badge.
- [ ] On the Board: rename a target and change its status; `watchtower project board N --json` shows both.
- [ ] Project targets never appear in Tasks (list, counts, badge, tag menu), the chat `@` picker, the day-plan input (`watchtower day-plan generate` then inspect), or next-step (`targets` next-step never runs for them).
- [ ] The next daily briefing (`watchtower briefing generate` on a day without one) mentions the project in Needs Attention when a target is blocked or an agent comment is unread, labeled Project.
- [ ] Settings → Wipe LLM data keeps the project board and its comments.

### Delete (Review Focus #5)
- [ ] With the terminal running and CC connected, Delete… lists targets/documents/comments counts and the folder cleanup; confirming closes the terminal first, then the project disappears from the list.
- [ ] In the folder afterwards: `git status` is clean, `claude mcp list` has no `watchtower-project`, `.claude/settings.local.json` keeps every non-Watchtower key, `.git/info/exclude` has none of our lines; the document files are still there.
- [ ] `watchtower project list` has no row; no `targets` row with that `project_id` remains.
- [ ] A CC session still running in iTerm after the delete: every project tool answers `project N no longer exists`; a new session's hook prints exactly `Watchtower: project N no longer exists.` and CC starts normally.
- [ ] Delete a second project from the CLI (`watchtower project delete N`) while its Desktop terminal is open: the project drops out of the list and its terminal closes.
```

---

## Interface errata

The Phase 1 (`phase1-go-core.md`) and Phase 4 (`phase4-desktop-terminal-docs.md`) names are confirmed and used as-is above. What this phase adds on top of them:

1. **`ProjectsViewModel` gains `deleteProject(_:) async -> Bool`, `closeTerminal`, `deletingProjectID`, `deleteError` and `static vanished(previous:current:)` (Task 20)**, and its `reload()` body gains the vanished-project terminal close. `cli` stays private. `initProjects` sets `vm.closeTerminal` to `projectTerminalCenter.close(projectID:)`. Phase 4's `ProjectsViewModelTests` must stay green after the `reload()` edit.
2. **`Target.projectID: Int64?` is added in Task 20.** `Target.id`/`parentId` stay `Int`, so the board converts with `Int64(id)` at every `ProjectQueries` call and for `ProjectSubject.target(_:)`.
3. **The board badge counts open threads** (`ProjectBoardNode.openComments`). The Go `BoardNode.NewForAgent` has no Swift counterpart and is used only by `project brief`.
4. **`BriefingDetailView` label.** Task 21 touches one Swift view, which the index does not list for that task. It adds a `project` source label: a one-line display change, no navigation.
