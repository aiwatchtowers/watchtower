# Projects POC — Phase 4 (Desktop: shell, terminal, documents, notifications), Tasks 13–18

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Desktop half of the Projects POC up to the board: a **Projects** sidebar tab whose project page hosts an embedded Claude Code terminal (SwiftTerm), a documents pane that renders attached specs/plans as selectable text with text-anchored comment threads, and owner notifications for agent activity. The Board pane stays a placeholder until Task 19.

**Architecture:** Everything pure lives in `WatchtowerCore` with tests in `Tests/Core`: the row models, `ProjectQueries` (GRDB reads + the owner's direct writes — the targets dual-path precedent), the markdown→plain-text renderer the anchors live on (`DocumentRendering`), `CommentAnchor` (make + re-locate), `ProjectTerminalLaunch` (the argv of the login shell), `ProjectFolderPolicy` (TCC-sensitive locations) and `ProjectNotificationPolicy` (no clock, no I/O). The app target holds the process- and AppKit-owning pieces: `ProjectCLI` (wraps `watchtower project …` / `integrate … --project`), `ProjectTerminalCenter` (one SwiftTerm session per project, owned by `AppState`, survives navigation, SIGHUP→SIGKILL on close/quit), `ProjectNotificationCenter` (30 s poll, persisted per-project snapshot), the view models (`ProjectsViewModel` on `AppState`, `ProjectDocumentViewModel` owned by it) and the views. The Desktop never writes a project document file (PROJ-03): the file is only read and watched.

**Tech Stack:** SwiftUI macOS 14, Swift 5.10 language mode, GRDB 7, `swiftlang/swift-markdown` (via the existing `MarkdownDocument`), AppKit `NSTextView`, **SwiftTerm 1.20.0** (new SPM dependency, app target only), XCTest.

**Spec:** `docs/superpowers/specs/2026-09-29-project-board-poc-design.md` (§6). Plan index with binding interfaces: `docs/superpowers/plans/2026-09-29-projects-poc.md`. Read both, plus `docs/review/review-rules.md` → "Swift / Desktop conventions".

## Global Constraints

All of the index's Global Constraints apply. The ones this file touches:
- Swift inner loop: `make test-swift FILTER=<TestClass>`; never delete `WatchtowerDesktop/.build`; `make lint-diff` for Go-only edits, `make lint-swift` for Swift. The full gate (`make test-swift`, `make lint-all`) runs once at the end of the phase by the controller, never per task.
- Core code is `package`-visible, in `Sources/WatchtowerCore`, tested in `Tests/Core` (no ML stack at compile time). App-target code is internal, tested in `Tests/`.
- SwiftLint runs `--strict`: `implicit_return`, `discouraged_optional_boolean` (no `Bool?`), `function_parameter_count` ≤ 8, `cyclomatic_complexity` ≤ 15, `function_body_length` ≤ 80. Keep it that way when adapting the code below.
- No TCC-prompting APIs: no Accessibility, no `NSEvent` global monitors, no AppleEvents, no `NSWorkspace` automation. `NSOpenPanel` (powerbox) and `NSWorkspace.activateFileViewerSelecting` are fine. The embedded shell runs as a child of Watchtower, so macOS attributes its file access to Watchtower — hence the TCC-location warning in Task 14.
- The Desktop never writes a project document (PROJ-03). Owner writes are DB rows only (`project_comments` status/replies/new roots, `read_at`), recorded as owner writes for the notification policy (Task 18) so they never notify.
- Timestamps in project tables are UTC `YYYY-MM-DDTHH:MM:SSZ` text, written with `strftime('%Y-%m-%dT%H:%M:%SZ','now')` on both sides.
- Tests never spawn a real shell or `claude`: `ProjectTerminalCenter` takes an injectable session factory and signaller; `ProjectCLI` takes a `CLIRunnerProtocol`.
- Every commit message ends with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01Lo9jbbmXQcr3qHo5f3pLD8
  ```

## Review Focus (owned here)

1. **Document revised heavily between loads** (index RF #4) — duplicate occurrences of the quoted text, whitespace-only reflow, the quoted passage deleted or edited: the best prefix/suffix match wins, an ambiguous or lost quote becomes `outdated`, never silently re-attached. → Task 15 `CommentAnchorTests` (`testDuplicateQuotePicksTheOccurrenceWithTheBestContext`, `testDuplicateQuoteSurvivesTextInsertedAboveIt`, `testDuplicatesWithNoMatchingContextAreOutdated`, `testWhitespaceReflowStillLocates`, `testDeletedPassageIsOutdated`, `testEditedQuoteIsOutdatedNotFuzzyMatched`), Task 16 `testLostOpenThreadIsMarkedOutdatedAndCountsAsAnOwnerWrite`.
2. **Survives navigation** (house rule) — a terminal session and an in-flight project creation outlive the view that started them. → Task 17 `testSessionSurvivesTheViewGoingAwayAndIsReusedOnReturn`, Task 14 `testCreateSurvivesNavigatingAwayAndSelectsTheProjectOnReturn`.
3. **Terminal teardown never leaks and never mis-signals** — SIGHUP to the process group, SIGKILL only after 3 s if still alive, never a signal to pid ≤ 0 (`killpg(0, …)` would hit Watchtower's own group), quit closes every terminal. → Task 17 `testCloseSendsHangupThenKillOnlyWhenStillAlive`, `testCloseNeverSignalsANonPositivePid`, `QuitCoordinatorTests.testQuitClosesTerminalsBeforeStoppingTheDaemon`.
4. **Notifications are honest** — each notice kind, burst coalescing (≥ 3 of one kind in a project within a poll → one summary), the owner's own writes never notify, a project seen for the first time baselines silently. → Task 18 `ProjectNotificationPolicyTests`, `ProjectNotificationCenterTests`.

## Cross-phase alignment (read before starting)

- **Consumes Task 1:** `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` already carries `projects`, `project_sources`, `project_documents`, `project_comments` and `targets.project_id` exactly as spec §3. If Task 1's DDL differs from spec §3, Task 1 wins — adapt the SQL here, never the schema.
- **Consumes Task 4:** `watchtower project create --folder DIR [--name NAME] --json` prints `{"id":N,"folder":"…","name":"…"}`; `watchtower project delete N`.
- **Consumes Task 12:** `watchtower integrate claude-code --project N`, `integrate remove --project N`, and `integrate status --project N --json` printing `{"skill":"<devpack state>","hook":<bool>,"mcp":<bool>}` (see Interface errata #2 — Task 12 must emit these lowercase keys).
- **Produced for Task 19/20:** `ProjectBoardNode`, `ProjectQueries.board(_:projectID:)`, `ProjectCommentThread`, `CommentThreadView` (reusable for target threads — it takes a thread and three closures, no document state), `ProjectsViewModel.onOwnerWrite`, `ProjectPageView`'s `.board` placeholder (`ProjectPanePlaceholder`), `AppState.projectTerminalCenter.close(projectID:)` for the delete flow. `Target.projectID` is Task 20's; nothing here reads it (the board query selects by `project_id` in SQL).
- `ProjectPane`/`ProjectRoute` live in Core (`Models/Project.swift`) because the notification policy produces deep links.

---

### Task 13: Core models + `ProjectQueries`

**Depends on:** Task 1 (Swift test schema).

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Models/Project.swift`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ProjectQueries.swift`
- Create: `WatchtowerDesktop/Tests/Support/TestDatabase+Projects.swift`
- Test: `WatchtowerDesktop/Tests/Core/ProjectQueriesTests.swift`

**Interfaces:**
- Consumes: spec §3 tables in the Swift test schema (Task 1).
- Produces (all `package`, WatchtowerCore):
  - `enum ProjectPane: String { terminal, board, documents; title }`, `enum ProjectSubject: Hashable, Codable { document(Int64), target(Int64) }`, `struct ProjectRoute { projectID: Int64; pane: ProjectPane; subjectID: Int64? }`.
  - `struct Project { id: Int64, name, folderPath, description, createdAt, updatedAt: String; folderURL: URL }`.
  - `struct ProjectDocument { id, projectID: Int64, targetID: Int64?, relPath, kind, title, createdAt, updatedAt: String; displayTitle; fileURL(in:) }`.
  - `struct ProjectComment { id, projectID: Int64, targetID, documentID, parentID: Int64?, author, agentLabel, body, anchorQuote, anchorPrefix, anchorSuffix, anchorHeading, status, createdAt, readAt: String; isRoot, isAgent, isUnreadForOwner, isOpen, anchor: CommentAnchor? }` (`anchor` compiles once Task 15 lands — see Step 3's note).
  - `struct ProjectCommentThread { root: ProjectComment; replies: [ProjectComment]; id; static group(_:) }`.
  - `struct ProjectBoardNode { target: Target; children: [ProjectBoardNode]; openComments, unreadForOwner: Int; documents: [ProjectDocument]; id }`.
  - `struct ProjectSummary { project; openTargets, inProgressTargets, unreadAgentComments: Int; documentStamps: [Int64: String]; id }`.
  - `enum ProjectQueryError: LocalizedError { emptyBody, noSubject, wrongProject, notARoot(Int64), invalidStatus(String) }`.
  - `enum ProjectQueries`: `fetchAll(_:)`, `fetch(_:id:)`, `documents(_:projectID:)`, `document(_:id:)`, `comments(_:documentID:)`, `comments(_:targetID:)`, `addOwnerComment(_:projectID:targetID:documentID:anchor:body:) -> Int64`, `reply(_:to:body:) -> Int64`, `setStatus(_:commentID:status:)`, `markAgentCommentsRead(_:projectID:targetID:documentID:)`, `board(_:projectID:) -> [ProjectBoardNode]`, `unreadCounts(_:) -> [Int64: Int]`, `summaries(_:) -> [ProjectSummary]`.
  - Test support: `TestDatabase.insertProject(_:name:folder:) -> Int64`, `insertProjectTarget(_:projectID:text:status:parentID:) -> Int64`, `insertProjectDocument(_:projectID:relPath:kind:title:targetID:updatedAt:) -> Int64`, `insertProjectComment(_:projectID:author:body:targetID:documentID:parentID:status:quote:readAt:) -> Int64`.

- [ ] **Step 1: Test fixtures**

Create `WatchtowerDesktop/Tests/Support/TestDatabase+Projects.swift`:

```swift
import Foundation
import GRDB

/// Fixtures for the Projects tables (spec §3). Project targets follow the
/// index's constraint: `level='custom'`, `custom_label='project'`,
/// `source_type='chat'`, `ownership='mine'`.
extension TestDatabase {
    @discardableResult
    package static func insertProject(
        _ db: Database,
        name: String = "acme",
        folder: String = "/tmp/acme"
    ) throws -> Int64 {
        try db.execute(
            sql: "INSERT INTO projects (name, folder_path) VALUES (?, ?)",
            arguments: [name, folder]
        )
        return db.lastInsertedRowID
    }

    @discardableResult
    package static func insertProjectTarget(
        _ db: Database,
        projectID: Int64,
        text: String = "Feature",
        status: String = "todo",
        parentID: Int64? = nil
    ) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO targets (text, level, custom_label, period_start, period_end,
                    parent_id, status, ownership, source_type, project_id)
                VALUES (?, 'custom', 'project', '2026-09-29', '2026-09-29', ?, ?, 'mine', 'chat', ?)
                """,
            arguments: [text, parentID, status, projectID]
        )
        return db.lastInsertedRowID
    }

    @discardableResult
    package static func insertProjectDocument(
        _ db: Database,
        projectID: Int64,
        relPath: String = "docs/plan.md",
        kind: String = "plan",
        title: String = "",
        targetID: Int64? = nil,
        updatedAt: String = "2026-09-29T10:00:00Z"
    ) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO project_documents (project_id, target_id, rel_path, kind, title, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
            arguments: [projectID, targetID, relPath, kind, title, updatedAt]
        )
        return db.lastInsertedRowID
    }

    @discardableResult
    package static func insertProjectComment(
        _ db: Database,
        projectID: Int64,
        author: String = "agent",
        body: String = "Question?",
        targetID: Int64? = nil,
        documentID: Int64? = nil,
        parentID: Int64? = nil,
        status: String = "open",
        quote: String = "",
        readAt: String = ""
    ) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO project_comments (project_id, target_id, document_id, parent_id,
                    author, body, anchor_quote, status, read_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [projectID, targetID, documentID, parentID, author, body, quote, status, readAt]
        )
        return db.lastInsertedRowID
    }
}
```

Note `insertProjectComment` has 10 parameters: SwiftLint's `function_parameter_count` applies to `Tests/Support` too — if `make lint-swift` flags it, add `// swiftlint:disable:next function_parameter_count` above the declaration (the fixture-helper precedent in `TestDatabase.insertTarget`, which has 21).

- [ ] **Step 2: Write the failing query tests**

Create `WatchtowerDesktop/Tests/Core/ProjectQueriesTests.swift`:

```swift
import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class ProjectQueriesTests: XCTestCase {
    private var db: DatabaseQueue!

    override func setUpWithError() throws {
        db = try TestDatabase.create()
    }

    func testFetchAllSortsByNameAndFetchReadsOne() throws {
        try db.write { d in
            let beta = try TestDatabase.insertProject(d, name: "beta", folder: "/tmp/beta")
            _ = try TestDatabase.insertProject(d, name: "Alpha", folder: "/tmp/alpha")
            XCTAssertEqual(try ProjectQueries.fetchAll(d).map(\.name), ["Alpha", "beta"])
            let fetched = try XCTUnwrap(ProjectQueries.fetch(d, id: beta))
            XCTAssertEqual(fetched.folderPath, "/tmp/beta")
            XCTAssertEqual(fetched.folderURL.path, "/tmp/beta")
            XCTAssertNil(try ProjectQueries.fetch(d, id: 999))
        }
    }

    func testDocumentsNewestFirstAndDisplayTitleFallsBackToFileName() throws {
        try db.write { d in
            let p = try TestDatabase.insertProject(d)
            _ = try TestDatabase.insertProjectDocument(d, projectID: p, relPath: "docs/a.md", updatedAt: "2026-09-29T09:00:00Z")
            _ = try TestDatabase.insertProjectDocument(d, projectID: p, relPath: "docs/b.md", title: "Plan B", updatedAt: "2026-09-29T11:00:00Z")
            let docs = try ProjectQueries.documents(d, projectID: p)
            XCTAssertEqual(docs.map(\.displayTitle), ["Plan B", "a.md"])
            let project = try XCTUnwrap(ProjectQueries.fetch(d, id: p))
            XCTAssertEqual(docs[1].fileURL(in: project).path, "/tmp/acme/docs/a.md")
        }
    }

    func testOwnerCommentCarriesTheAnchorAndReplyInheritsTheRootSubject() throws {
        try db.write { d in
            let p = try TestDatabase.insertProject(d)
            let doc = try TestDatabase.insertProjectDocument(d, projectID: p)
            let anchor = CommentAnchor(quote: "retry", prefix: "before ", suffix: " after", heading: "Errors")
            let root = try ProjectQueries.addOwnerComment(
                d, projectID: p, targetID: nil, documentID: doc, anchor: anchor, body: "  Why 3?  "
            )
            let reply = try ProjectQueries.reply(d, to: root, body: "Follow-up")
            let thread = try ProjectQueries.comments(d, documentID: doc)
            XCTAssertEqual(thread.map(\.id), [root, reply])
            XCTAssertEqual(thread[0].body, "Why 3?")
            XCTAssertEqual(thread[0].author, "owner")
            XCTAssertEqual(thread[0].anchor, anchor)
            XCTAssertEqual(thread[1].parentID, root)
            XCTAssertEqual(thread[1].documentID, doc)
            XCTAssertEqual(thread[1].author, "owner")
        }
    }

    func testOwnerCommentRejectsEmptyBodyNoSubjectAndForeignDocument() throws {
        try db.write { d in
            let p = try TestDatabase.insertProject(d)
            let other = try TestDatabase.insertProject(d, name: "other", folder: "/tmp/other")
            let foreignDoc = try TestDatabase.insertProjectDocument(d, projectID: other)
            XCTAssertThrowsError(try ProjectQueries.addOwnerComment(d, projectID: p, targetID: nil, documentID: foreignDoc, anchor: nil, body: "x"))
            XCTAssertThrowsError(try ProjectQueries.addOwnerComment(d, projectID: p, targetID: nil, documentID: nil, anchor: nil, body: "x"))
            let doc = try TestDatabase.insertProjectDocument(d, projectID: p, relPath: "docs/x.md")
            XCTAssertThrowsError(try ProjectQueries.addOwnerComment(d, projectID: p, targetID: nil, documentID: doc, anchor: nil, body: "   "))
            XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM project_comments"), 0)
        }
    }

    func testSetStatusOnlyOnRootsAndOnlyKnownValues() throws {
        try db.write { d in
            let p = try TestDatabase.insertProject(d)
            let t = try TestDatabase.insertProjectTarget(d, projectID: p)
            let root = try TestDatabase.insertProjectComment(d, projectID: p, targetID: t)
            let reply = try TestDatabase.insertProjectComment(d, projectID: p, author: "owner", targetID: t, parentID: root)
            try ProjectQueries.setStatus(d, commentID: root, status: "resolved")
            XCTAssertEqual(try ProjectQueries.comments(d, targetID: t).first?.status, "resolved")
            XCTAssertThrowsError(try ProjectQueries.setStatus(d, commentID: reply, status: "resolved"))
            XCTAssertThrowsError(try ProjectQueries.setStatus(d, commentID: root, status: "closed"))
        }
    }

    func testMarkAgentCommentsReadIsScopedAndLeavesOwnerCommentsAlone() throws {
        try db.write { d in
            let p = try TestDatabase.insertProject(d)
            let t1 = try TestDatabase.insertProjectTarget(d, projectID: p, text: "One")
            let t2 = try TestDatabase.insertProjectTarget(d, projectID: p, text: "Two")
            _ = try TestDatabase.insertProjectComment(d, projectID: p, targetID: t1)
            _ = try TestDatabase.insertProjectComment(d, projectID: p, targetID: t2)
            _ = try TestDatabase.insertProjectComment(d, projectID: p, author: "owner", targetID: t1)
            XCTAssertEqual(try ProjectQueries.unreadCounts(d), [p: 2])

            try ProjectQueries.markAgentCommentsRead(d, projectID: p, targetID: t1, documentID: nil)
            XCTAssertEqual(try ProjectQueries.unreadCounts(d), [p: 1])
            let ownerReadAt = try String.fetchOne(d, sql: "SELECT read_at FROM project_comments WHERE author = 'owner'")
            XCTAssertEqual(ownerReadAt, "")

            try ProjectQueries.markAgentCommentsRead(d, projectID: p, targetID: nil, documentID: nil)
            XCTAssertEqual(try ProjectQueries.unreadCounts(d), [:])
        }
    }

    func testBoardBuildsTheTreeInStatusOrderWithCounters() throws {
        try db.write { d in
            let p = try TestDatabase.insertProject(d)
            let done = try TestDatabase.insertProjectTarget(d, projectID: p, text: "Done root", status: "done")
            let todo = try TestDatabase.insertProjectTarget(d, projectID: p, text: "Todo root")
            let active = try TestDatabase.insertProjectTarget(d, projectID: p, text: "Active root", status: "in_progress")
            let child = try TestDatabase.insertProjectTarget(d, projectID: p, text: "Task 1", parentID: active)
            _ = try TestDatabase.insertTarget(d, text: "Not a project target")
            _ = try TestDatabase.insertProjectComment(d, projectID: p, targetID: child)
            _ = try TestDatabase.insertProjectComment(d, projectID: p, author: "owner", targetID: child, status: "resolved")
            _ = try TestDatabase.insertProjectDocument(d, projectID: p, targetID: active)

            let board = try ProjectQueries.board(d, projectID: p)
            XCTAssertEqual(board.map(\.target.text), ["Active root", "Todo root", "Done root"])
            XCTAssertEqual(board[0].children.map(\.target.text), ["Task 1"])
            XCTAssertEqual(board[0].documents.count, 1)
            XCTAssertEqual(board[0].children[0].openComments, 1)
            XCTAssertEqual(board[0].children[0].unreadForOwner, 1)
            XCTAssertEqual(Set(board.map { Int64($0.target.id) }), [done, todo, active])
        }
    }

    func testSummariesCountOpenAndInProgressTargetsAndStampDocuments() throws {
        try db.write { d in
            let p = try TestDatabase.insertProject(d)
            _ = try TestDatabase.insertProjectTarget(d, projectID: p, status: "in_progress")
            _ = try TestDatabase.insertProjectTarget(d, projectID: p, status: "blocked")
            _ = try TestDatabase.insertProjectTarget(d, projectID: p, status: "done")
            let doc = try TestDatabase.insertProjectDocument(d, projectID: p, updatedAt: "2026-09-29T12:00:00Z")
            _ = try TestDatabase.insertProjectComment(d, projectID: p, documentID: doc)
            let empty = try TestDatabase.insertProject(d, name: "empty", folder: "/tmp/empty")

            let summaries = try ProjectQueries.summaries(d)
            let acme = try XCTUnwrap(summaries.first { $0.id == p })
            XCTAssertEqual(acme.openTargets, 2)
            XCTAssertEqual(acme.inProgressTargets, 1)
            XCTAssertEqual(acme.unreadAgentComments, 1)
            XCTAssertEqual(acme.documentStamps, [doc: "2026-09-29T12:00:00Z"])
            let none = try XCTUnwrap(summaries.first { $0.id == empty })
            XCTAssertEqual(none.openTargets, 0)
            XCTAssertEqual(none.documentStamps, [:])
        }
    }

    func testThreadGroupingKeepsRootsInOrderWithTheirReplies() throws {
        try db.write { d in
            let p = try TestDatabase.insertProject(d)
            let doc = try TestDatabase.insertProjectDocument(d, projectID: p)
            let first = try TestDatabase.insertProjectComment(d, projectID: p, author: "owner", documentID: doc)
            let second = try TestDatabase.insertProjectComment(d, projectID: p, author: "owner", documentID: doc)
            let reply = try TestDatabase.insertProjectComment(d, projectID: p, documentID: doc, parentID: first)
            let threads = ProjectCommentThread.group(try ProjectQueries.comments(d, documentID: doc))
            XCTAssertEqual(threads.map(\.id), [first, second])
            XCTAssertEqual(threads[0].replies.map(\.id), [reply])
            XCTAssertTrue(threads[1].replies.isEmpty)
        }
    }
}
```

- [ ] **Step 3: Run — expect a compile failure**

Run (repo root): `make test-swift FILTER=ProjectQueriesTests > /tmp/p13.log 2>&1; echo "exit=$?"`
Expected: `exit≠0`, `cannot find 'ProjectQueries' in scope` (and `CommentAnchor`).

`CommentAnchor` is Task 15's type. To keep Task 13 self-contained, create the struct's data shape now (Task 15 adds `make`/`locate` and their tests to the same file): create `WatchtowerDesktop/Sources/WatchtowerCore/Services/CommentAnchor.swift` with

```swift
import Foundation

/// A comment's anchor on a document's RENDERED plain text (spec §6.3):
/// the selected quote, up to `contextLength` characters on either side, and
/// the nearest preceding heading. Task 15 adds `make` and `locate`.
package struct CommentAnchor: Equatable, Sendable {
    package static let contextLength = 64

    package var quote: String
    package var prefix: String
    package var suffix: String
    package var heading: String

    package init(quote: String, prefix: String, suffix: String, heading: String) {
        self.quote = quote
        self.prefix = prefix
        self.suffix = suffix
        self.heading = heading
    }
}
```

- [ ] **Step 4: Implement the models**

Create `WatchtowerDesktop/Sources/WatchtowerCore/Models/Project.swift`:

```swift
import Foundation
import GRDB

/// The three panes of a project page (spec §6.1). Lives in Core because the
/// notification policy deep-links into one.
package enum ProjectPane: String, CaseIterable, Codable, Sendable {
    case terminal
    case board
    case documents

    package var title: String {
        switch self {
        case .terminal: "Terminal"
        case .board: "Board"
        case .documents: "Documents"
        }
    }
}

/// What an owner write touched, so the notification policy can tell the
/// owner's own changes from an agent's (Task 18: owner writes never notify).
package enum ProjectSubject: Hashable, Codable, Sendable {
    case document(Int64)
    case target(Int64)
}

/// Where a notification click or an in-app link lands: a project, a pane and
/// optionally the document (documents pane) or target (board pane) to open.
package struct ProjectRoute: Equatable, Sendable {
    package let projectID: Int64
    package let pane: ProjectPane
    package let subjectID: Int64?

    package init(projectID: Int64, pane: ProjectPane, subjectID: Int64? = nil) {
        self.projectID = projectID
        self.pane = pane
        self.subjectID = subjectID
    }
}

/// A `projects` row. Written only by the Go CLI (`watchtower project create`);
/// the Desktop reads it.
package struct Project: FetchableRecord, Identifiable, Equatable, Hashable, Sendable {
    package let id: Int64
    package let name: String
    package let folderPath: String
    package let description: String
    package let createdAt: String
    package let updatedAt: String

    package init(row: Row) {
        id = row["id"]
        name = row["name"] ?? ""
        folderPath = row["folder_path"] ?? ""
        description = row["description"] ?? ""
        createdAt = row["created_at"] ?? ""
        updatedAt = row["updated_at"] ?? ""
    }

    package var folderURL: URL { URL(fileURLWithPath: folderPath, isDirectory: true) }
}

/// A `project_documents` row: a spec/plan/doc file inside the project folder
/// that an agent attached. The Desktop reads the file, never writes it (PROJ-03).
package struct ProjectDocument: FetchableRecord, Identifiable, Equatable, Hashable, Sendable {
    package let id: Int64
    package let projectID: Int64
    package let targetID: Int64?
    package let relPath: String
    package let kind: String        // spec | plan | doc
    package let title: String
    package let createdAt: String
    package let updatedAt: String   // bumped by every re-attach ("revised")

    package init(row: Row) {
        id = row["id"]
        projectID = row["project_id"]
        targetID = row["target_id"]
        relPath = row["rel_path"] ?? ""
        kind = row["kind"] ?? "doc"
        title = row["title"] ?? ""
        createdAt = row["created_at"] ?? ""
        updatedAt = row["updated_at"] ?? ""
    }

    package var displayTitle: String {
        title.isEmpty ? (relPath as NSString).lastPathComponent : title
    }

    package func fileURL(in project: Project) -> URL {
        project.folderURL.appendingPathComponent(relPath)
    }
}

/// A `project_comments` row — a thread root (on a target or a document) or a
/// reply. Status is meaningful on roots only.
package struct ProjectComment: FetchableRecord, Identifiable, Equatable, Hashable, Sendable {
    package let id: Int64
    package let projectID: Int64
    package let targetID: Int64?
    package let documentID: Int64?
    package let parentID: Int64?
    package let author: String      // owner | agent
    package let agentLabel: String
    package let body: String
    package let anchorQuote: String
    package let anchorPrefix: String
    package let anchorSuffix: String
    package let anchorHeading: String
    package let status: String      // open | resolved | outdated
    package let createdAt: String
    package let readAt: String

    package init(row: Row) {
        id = row["id"]
        projectID = row["project_id"]
        targetID = row["target_id"]
        documentID = row["document_id"]
        parentID = row["parent_id"]
        author = row["author"] ?? "owner"
        agentLabel = row["agent_label"] ?? ""
        body = row["body"] ?? ""
        anchorQuote = row["anchor_quote"] ?? ""
        anchorPrefix = row["anchor_prefix"] ?? ""
        anchorSuffix = row["anchor_suffix"] ?? ""
        anchorHeading = row["anchor_heading"] ?? ""
        status = row["status"] ?? "open"
        createdAt = row["created_at"] ?? ""
        readAt = row["read_at"] ?? ""
    }

    package var isRoot: Bool { parentID == nil }
    package var isAgent: Bool { author == "agent" }
    package var isOpen: Bool { status == "open" }
    package var isUnreadForOwner: Bool { isAgent && readAt.isEmpty }

    /// The stored anchor, or nil for an unanchored comment (target threads).
    package var anchor: CommentAnchor? {
        guard !anchorQuote.isEmpty else { return nil }
        return CommentAnchor(quote: anchorQuote, prefix: anchorPrefix, suffix: anchorSuffix, heading: anchorHeading)
    }
}

/// A root comment with its replies, in creation order.
package struct ProjectCommentThread: Identifiable, Equatable, Sendable {
    package let root: ProjectComment
    package let replies: [ProjectComment]

    package var id: Int64 { root.id }

    /// Groups a flat, creation-ordered comment list (as `ProjectQueries.comments`
    /// returns it) into threads. A reply whose root is not in the list is dropped.
    package static func group(_ comments: [ProjectComment]) -> [Self] {
        let replies = Dictionary(grouping: comments.filter { !$0.isRoot }) { $0.parentID ?? 0 }
        return comments.filter(\.isRoot).map { root in
            Self(root: root, replies: replies[root.id] ?? [])
        }
    }
}

/// One node of a project board: a project target with its sub-targets and
/// the counters the board badges show.
package struct ProjectBoardNode: Identifiable, Equatable, Sendable {
    package let target: Target
    package let children: [ProjectBoardNode]
    /// Open root comments on this target.
    package let openComments: Int
    /// Agent comments on this target the owner has not seen.
    package let unreadForOwner: Int
    package let documents: [ProjectDocument]

    package var id: Int { target.id }
}

/// A project list row.
package struct ProjectSummary: Identifiable, Equatable, Sendable {
    package let project: Project
    package let openTargets: Int
    package let inProgressTargets: Int
    package let unreadAgentComments: Int
    /// Document id → `updated_at`, for "revised since last viewed".
    package let documentStamps: [Int64: String]

    package var id: Int64 { project.id }
}
```

`Target` is not `Sendable`-annotated today; if the compiler (Swift 5.10 mode) warns about `ProjectBoardNode: Sendable`, drop `Sendable` from `ProjectBoardNode` rather than touching `Target`.

- [ ] **Step 5: Implement the queries**

Create `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ProjectQueries.swift`:

```swift
import Foundation
import GRDB

package enum ProjectQueryError: LocalizedError, Equatable {
    case emptyBody
    case noSubject
    case wrongProject
    case notARoot(Int64)
    case invalidStatus(String)

    package var errorDescription: String? {
        switch self {
        case .emptyBody: "A comment needs some text."
        case .noSubject: "A comment belongs to a target or a document."
        case .wrongProject: "That target or document belongs to another project."
        case let .notARoot(id): "Comment \(id) is a reply; only a thread's first comment has a status."
        case let .invalidStatus(status): "Unknown comment status \u{201C}\(status)\u{201D}."
        }
    }
}

/// Projects (spec §3, §6). The Go CLI and the project MCP server write
/// projects, sources, documents, targets and agent comments; the Desktop
/// writes only owner comments, root statuses and `read_at` — directly, the
/// targets dual-path precedent (Go twin: `internal/db/project_comments.go`,
/// whose reply-inherits-root rule this file mirrors).
package enum ProjectQueries {
    private static let now = "strftime('%Y-%m-%dT%H:%M:%SZ','now')"
    private static let statuses: Set<String> = ["open", "resolved", "outdated"]

    // MARK: - Projects

    package static func fetchAll(_ db: Database) throws -> [Project] {
        try Project.fetchAll(db, sql: "SELECT * FROM projects ORDER BY name COLLATE NOCASE, id")
    }

    package static func fetch(_ db: Database, id: Int64) throws -> Project? {
        try Project.fetchOne(db, sql: "SELECT * FROM projects WHERE id = ?", arguments: [id])
    }

    package static func summaries(_ db: Database) throws -> [ProjectSummary] {
        let projects = try fetchAll(db)
        let unread = try unreadCounts(db)
        var open: [Int64: Int] = [:]
        var active: [Int64: Int] = [:]
        let rows = try Row.fetchAll(db, sql: """
            SELECT project_id,
                   SUM(status IN ('todo','in_progress','blocked')) AS open_count,
                   SUM(status = 'in_progress') AS active_count
            FROM targets WHERE project_id IS NOT NULL GROUP BY project_id
            """)
        for row in rows {
            open[row["project_id"]] = row["open_count"]
            active[row["project_id"]] = row["active_count"]
        }
        var stamps: [Int64: [Int64: String]] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT id, project_id, updated_at FROM project_documents") {
            stamps[row["project_id"], default: [:]][row["id"]] = row["updated_at"]
        }
        return projects.map { project in
            ProjectSummary(
                project: project,
                openTargets: open[project.id] ?? 0,
                inProgressTargets: active[project.id] ?? 0,
                unreadAgentComments: unread[project.id] ?? 0,
                documentStamps: stamps[project.id] ?? [:]
            )
        }
    }

    // MARK: - Documents

    package static func documents(_ db: Database, projectID: Int64) throws -> [ProjectDocument] {
        try ProjectDocument.fetchAll(
            db,
            sql: "SELECT * FROM project_documents WHERE project_id = ? ORDER BY updated_at DESC, id DESC",
            arguments: [projectID]
        )
    }

    package static func document(_ db: Database, id: Int64) throws -> ProjectDocument? {
        try ProjectDocument.fetchOne(db, sql: "SELECT * FROM project_documents WHERE id = ?", arguments: [id])
    }

    // MARK: - Comments

    package static func comments(_ db: Database, documentID: Int64) throws -> [ProjectComment] {
        try ProjectComment.fetchAll(
            db,
            sql: "SELECT * FROM project_comments WHERE document_id = ? ORDER BY created_at, id",
            arguments: [documentID]
        )
    }

    package static func comments(_ db: Database, targetID: Int64) throws -> [ProjectComment] {
        try ProjectComment.fetchAll(
            db,
            sql: "SELECT * FROM project_comments WHERE target_id = ? ORDER BY created_at, id",
            arguments: [targetID]
        )
    }

    /// A new owner thread on a target or a document of `projectID`.
    @discardableResult
    package static func addOwnerComment(
        _ db: Database,
        projectID: Int64,
        targetID: Int64?,
        documentID: Int64?,
        anchor: CommentAnchor?,
        body: String
    ) throws -> Int64 {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ProjectQueryError.emptyBody }
        guard targetID != nil || documentID != nil else { throw ProjectQueryError.noSubject }
        try requireInProject(db, projectID: projectID, table: "targets", id: targetID)
        try requireInProject(db, projectID: projectID, table: "project_documents", id: documentID)
        try db.execute(
            sql: """
                INSERT INTO project_comments (project_id, target_id, document_id, author, body,
                    anchor_quote, anchor_prefix, anchor_suffix, anchor_heading)
                VALUES (?, ?, ?, 'owner', ?, ?, ?, ?, ?)
                """,
            arguments: [
                projectID, targetID, documentID, text,
                anchor?.quote ?? "", anchor?.prefix ?? "", anchor?.suffix ?? "", anchor?.heading ?? ""
            ]
        )
        return db.lastInsertedRowID
    }

    /// An owner reply. It inherits the root's project, target and document —
    /// the same rule as Go `AddProjectComment`.
    @discardableResult
    package static func reply(_ db: Database, to rootID: Int64, body: String) throws -> Int64 {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ProjectQueryError.emptyBody }
        guard let root = try ProjectComment.fetchOne(
            db, sql: "SELECT * FROM project_comments WHERE id = ?", arguments: [rootID]
        ), root.isRoot else { throw ProjectQueryError.notARoot(rootID) }
        try db.execute(
            sql: """
                INSERT INTO project_comments (project_id, target_id, document_id, parent_id, author, body)
                VALUES (?, ?, ?, ?, 'owner', ?)
                """,
            arguments: [root.projectID, root.targetID, root.documentID, root.id, text]
        )
        return db.lastInsertedRowID
    }

    package static func setStatus(_ db: Database, commentID: Int64, status: String) throws {
        guard statuses.contains(status) else { throw ProjectQueryError.invalidStatus(status) }
        try db.execute(
            sql: "UPDATE project_comments SET status = ? WHERE id = ? AND parent_id IS NULL",
            arguments: [status, commentID]
        )
        if db.changesCount == 0 { throw ProjectQueryError.notARoot(commentID) }
    }

    /// Marks unread agent comments read. A nil target/document id widens the
    /// scope; both nil = the whole project.
    package static func markAgentCommentsRead(
        _ db: Database,
        projectID: Int64,
        targetID: Int64?,
        documentID: Int64?
    ) throws {
        try db.execute(
            sql: """
                UPDATE project_comments SET read_at = \(now)
                WHERE project_id = ? AND author = 'agent' AND read_at = ''
                  AND (? IS NULL OR target_id = ?)
                  AND (? IS NULL OR document_id = ?)
                """,
            arguments: [projectID, targetID, targetID, documentID, documentID]
        )
    }

    /// Unread agent comments per project (projects with none are absent).
    package static func unreadCounts(_ db: Database) throws -> [Int64: Int] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT project_id, COUNT(*) AS n FROM project_comments
            WHERE author = 'agent' AND read_at = '' GROUP BY project_id
            """)
        return Dictionary(uniqueKeysWithValues: rows.map { (row: Row) -> (Int64, Int) in
            (row["project_id"], row["n"])
        })
    }

    // MARK: - Board

    /// The project's target tree: roots (and orphans whose parent is outside
    /// the project) in status order in_progress, blocked, todo, done, others;
    /// then id. Children use the same order.
    package static func board(_ db: Database, projectID: Int64) throws -> [ProjectBoardNode] {
        let targets = try Target.fetchAll(
            db, sql: "SELECT * FROM targets WHERE project_id = ?", arguments: [projectID]
        )
        let counters = try boardCounters(db, projectID: projectID)
        let docs = Dictionary(grouping: try documents(db, projectID: projectID).filter { $0.targetID != nil }) {
            $0.targetID ?? 0
        }
        let ids = Set(targets.map(\.id))
        let byParent = Dictionary(grouping: targets) { target in
            target.parentId.flatMap { ids.contains($0) ? $0 : nil } ?? 0
        }
        func node(_ target: Target) -> ProjectBoardNode {
            let key = Int64(target.id)
            return ProjectBoardNode(
                target: target,
                children: sorted(byParent[target.id] ?? []).map(node),
                openComments: counters.open[key] ?? 0,
                unreadForOwner: counters.unread[key] ?? 0,
                documents: docs[key] ?? []
            )
        }
        return sorted(byParent[0] ?? []).map(node)
    }

    private static func boardCounters(_ db: Database, projectID: Int64) throws -> (open: [Int64: Int], unread: [Int64: Int]) {
        var open: [Int64: Int] = [:]
        var unread: [Int64: Int] = [:]
        let rows = try Row.fetchAll(db, sql: """
            SELECT target_id,
                   SUM(parent_id IS NULL AND status = 'open') AS open_count,
                   SUM(author = 'agent' AND read_at = '') AS unread_count
            FROM project_comments WHERE project_id = ? AND target_id IS NOT NULL
            GROUP BY target_id
            """, arguments: [projectID])
        for row in rows {
            open[row["target_id"]] = row["open_count"]
            unread[row["target_id"]] = row["unread_count"]
        }
        return (open, unread)
    }

    private static func sorted(_ targets: [Target]) -> [Target] {
        targets.sorted { lhs, rhs in
            let (lo, ro) = (statusRank(lhs.status), statusRank(rhs.status))
            return lo == ro ? lhs.id < rhs.id : lo < ro
        }
    }

    private static func statusRank(_ status: String) -> Int {
        switch status {
        case "in_progress": 0
        case "blocked": 1
        case "todo": 2
        case "done": 3
        default: 4
        }
    }

    private static func requireInProject(_ db: Database, projectID: Int64, table: String, id: Int64?) throws {
        guard let id else { return }
        let owner = try Int64.fetchOne(db, sql: "SELECT project_id FROM \(table) WHERE id = ?", arguments: [id])
        guard owner == projectID else { throw ProjectQueryError.wrongProject }
    }
}
```

Notes:
- `targets.parent_id` is `Int?` on `Target` and project ids are `Int64` — the board keys its counter dictionaries by `Int64(target.id)`, its tree by `Int`.
- `Row["x"]` for a `SUM(...)` over zero matching rows is `NULL`; every aggregate here is grouped, so a group always has ≥ 1 row and the sum is an integer.

- [ ] **Step 6: Run — PASS**

Run: `make test-swift FILTER=ProjectQueriesTests > /tmp/p13.log 2>&1; echo "exit=$?"`
Expected: `exit=0`, 9 tests passed. Then `make lint-swift > /tmp/p13-lint.log 2>&1; echo "exit=$?"` → `exit=0`.

- [ ] **Step 7: Commit**

```bash
git add WatchtowerDesktop/Sources/WatchtowerCore/Models/Project.swift \
        WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ProjectQueries.swift \
        WatchtowerDesktop/Sources/WatchtowerCore/Services/CommentAnchor.swift \
        WatchtowerDesktop/Tests/Support/TestDatabase+Projects.swift \
        WatchtowerDesktop/Tests/Core/ProjectQueriesTests.swift
git commit -m "$(cat <<'EOF'
feat(desktop): project models and queries for the Projects tab

Core row models for projects, documents, comments and the board tree, plus
ProjectQueries: reads, owner comments/replies/status, read marks, the board
and the list summaries. Owner writes mirror the Go store's reply rule.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Lo9jbbmXQcr3qHo5f3pLD8
EOF
)"
```

---
### Task 14: `ProjectCLI` + the Projects tab shell

**Depends on:** Task 13; Tasks 4 and 12 for the real CLI (tests use a fake runner, so the Swift side builds and tests without them).

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/ProjectFolderPolicy.swift`
- Create: `WatchtowerDesktop/Sources/Services/ProjectCLI.swift`
- Create: `WatchtowerDesktop/Sources/ViewModels/ProjectsViewModel.swift`
- Create: `WatchtowerDesktop/Sources/Views/Projects/ProjectsView.swift`
- Create: `WatchtowerDesktop/Sources/Views/Projects/ProjectPageView.swift`
- Modify: `WatchtowerDesktop/Sources/App/SidebarDestination.swift` (case, title, icon, `rootItems`)
- Modify: `WatchtowerDesktop/Sources/App/Navigation.swift` (`detailView` case)
- Modify: `WatchtowerDesktop/Sources/Views/Sidebar/SidebarView.swift` (badge)
- Modify: `WatchtowerDesktop/Sources/App/AppState.swift` (`projectsViewModel`, `initProjects`, `pendingProjectRoute`, `navigateToProject`)
- Modify: `WatchtowerDesktop/Tests/SidebarSectionTests.swift` (`testRootItems`)
- Test: `WatchtowerDesktop/Tests/Core/ProjectFolderPolicyTests.swift`, `WatchtowerDesktop/Tests/ProjectCLITests.swift`, `WatchtowerDesktop/Tests/ProjectsViewModelTests.swift`

**Interfaces:**
- Consumes: Task 13 (`ProjectQueries.summaries`, `ProjectSummary`, `ProjectPane`, `ProjectRoute`); CLI shapes from Tasks 4/12 (see "Cross-phase alignment").
- Produces:
  - Core: `ProjectFolderPolicy.tccSensitiveLocation(path:home:) -> String?` (returns e.g. `"~/Documents"`).
  - App: `struct ProjectCLI { init(runner:); create(folder:name:) -> ProjectCreated; install(projectID:); status(projectID:) -> ProjectInstallStatus; delete(projectID:) }`; `struct ProjectCreated { id: Int64; folder, name: String }`; `struct ProjectInstallStatus { skill: String; hook, mcp: Bool; needsRepair }`.
  - App: `@MainActor @Observable final class ProjectsViewModel` — `summaries`, `selectedProjectID`, `selectedProject`, `pane`, `isCreating`, `errorMessage`, `installStatus: [Int64: ProjectInstallStatus]`, `badgeCount`, `revisedDocumentCount(for:)`, `isRevised(_:)`, `reload()`, `createProject(folder:name:)`, `refreshInstallStatus(projectID:)`, `repairInstall(projectID:)`, `reveal(_:)`, `markDocumentViewed(_:)`, hooks `onProjectCreated: ((Project) -> Void)?` (Task 17 starts the terminal, Task 18 seeds the notification baseline), `onOwnerWrite: ((Int64, ProjectSubject) -> Void)?` (Task 16 calls it, Task 18 wires it).
  - `AppState`: `private(set) var projectsViewModel: ProjectsViewModel?`, `func initProjects(dbPool:cliRunner:)`, `var pendingProjectRoute: ProjectRoute?`, `func navigateToProject(_ route: ProjectRoute)`.
  - `SidebarDestination.projects` (root item after `.tracks`), `ProjectPageView` with `ProjectPanePlaceholder` for panes not built yet (Documents until Task 16, Terminal until Task 17, Board until Task 19).

- [ ] **Step 1: Failing Core test for the TCC-location warning**

Create `WatchtowerDesktop/Tests/Core/ProjectFolderPolicyTests.swift`:

```swift
import XCTest
@testable import WatchtowerCore

final class ProjectFolderPolicyTests: XCTestCase {
    private let home = "/Users/owner"

    func testFoldersUnderProtectedLocationsAreNamed() {
        XCTAssertEqual(ProjectFolderPolicy.tccSensitiveLocation(path: "/Users/owner/Documents/acme", home: home), "~/Documents")
        XCTAssertEqual(ProjectFolderPolicy.tccSensitiveLocation(path: "/Users/owner/Desktop", home: home), "~/Desktop")
        XCTAssertEqual(ProjectFolderPolicy.tccSensitiveLocation(path: "/Users/owner/Downloads/x/y", home: home), "~/Downloads")
        XCTAssertEqual(
            ProjectFolderPolicy.tccSensitiveLocation(path: "/Users/owner/Library/CloudStorage/Drive/acme", home: home + "/"),
            "~/Library/CloudStorage"
        )
    }

    func testOtherFoldersAndLookalikesAreNotFlagged() {
        XCTAssertNil(ProjectFolderPolicy.tccSensitiveLocation(path: "/Users/owner/code/acme", home: home))
        XCTAssertNil(ProjectFolderPolicy.tccSensitiveLocation(path: "/Users/owner/DocumentsArchive/acme", home: home))
        XCTAssertNil(ProjectFolderPolicy.tccSensitiveLocation(path: "/tmp/Documents/acme", home: home))
    }
}
```

- [ ] **Step 2: Run — expect a compile failure**

Run: `make test-swift FILTER=ProjectFolderPolicyTests > /tmp/p14a.log 2>&1; echo "exit=$?"` → `exit≠0`, `cannot find 'ProjectFolderPolicy'`.

- [ ] **Step 3: Implement `ProjectFolderPolicy`**

Create `WatchtowerDesktop/Sources/WatchtowerCore/Services/ProjectFolderPolicy.swift`:

```swift
import Foundation

/// Folder checks for the New-project flow (spec §6.2). The embedded terminal
/// runs Claude Code as Watchtower's child, so macOS attributes its file access
/// to Watchtower: a folder under one of these locations makes the first file
/// read raise a TCC prompt naming Watchtower. The POC warns before creating.
package enum ProjectFolderPolicy {
    package static let tccSensitiveLocations = ["Documents", "Desktop", "Downloads", "Library/CloudStorage"]

    /// The `~/…` location `path` lies in (or is), or nil. Both paths must be
    /// absolute and symlink-resolved by the caller.
    package static func tccSensitiveLocation(path: String, home: String) -> String? {
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        for location in tccSensitiveLocations {
            let root = base + "/" + location
            if path == root || path.hasPrefix(root + "/") {
                return "~/" + location
            }
        }
        return nil
    }
}
```

Run: `make test-swift FILTER=ProjectFolderPolicyTests > /tmp/p14a.log 2>&1; echo "exit=$?"` → `exit=0`.

- [ ] **Step 4: Failing tests for `ProjectCLI`**

Create `WatchtowerDesktop/Tests/ProjectCLITests.swift`:

```swift
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

final class ProjectCLITests: XCTestCase {
    func testCreatePassesFolderNameAndJSONAndDecodesTheEnvelope() async throws {
        let runner = FakeCLIRunner(stdout: Data(#"{"id":7,"folder":"/tmp/acme","name":"acme"}"#.utf8))
        let created = try await ProjectCLI(runner: runner).create(folder: "/tmp/acme dir", name: "Acme")
        XCTAssertEqual(created, ProjectCreated(id: 7, folder: "/tmp/acme", name: "acme"))
        XCTAssertEqual(runner.invocations, [["project", "create", "--folder", "/tmp/acme dir", "--json", "--name", "Acme"]])
    }

    func testCreateWithoutNameOmitsTheFlag() async throws {
        let runner = FakeCLIRunner(stdout: Data(#"{"id":1,"folder":"/tmp/a","name":"a"}"#.utf8))
        _ = try await ProjectCLI(runner: runner).create(folder: "/tmp/a", name: nil)
        XCTAssertEqual(runner.invocations, [["project", "create", "--folder", "/tmp/a", "--json"]])
    }

    func testInstallStatusAndDeleteArguments() async throws {
        let runner = FakeCLIRunner(stdout: Data(#"{"skill":"unchanged","hook":true,"mcp":false}"#.utf8))
        let cli = ProjectCLI(runner: runner)
        try await cli.install(projectID: 3)
        let status = try await cli.status(projectID: 3)
        try await cli.delete(projectID: 3)
        XCTAssertEqual(runner.invocations, [
            ["integrate", "claude-code", "--project", "3"],
            ["integrate", "status", "--project", "3", "--json"],
            ["project", "delete", "3"]
        ])
        XCTAssertEqual(status, ProjectInstallStatus(skill: "unchanged", hook: true, mcp: false))
        XCTAssertTrue(status.needsRepair)
    }

    func testNeedsRepairOnlyWhenSomethingIsMissing() {
        XCTAssertFalse(ProjectInstallStatus(skill: "unchanged", hook: true, mcp: true).needsRepair)
        XCTAssertFalse(ProjectInstallStatus(skill: "drifted", hook: true, mcp: true).needsRepair)
        XCTAssertTrue(ProjectInstallStatus(skill: "missing", hook: true, mcp: true).needsRepair)
        XCTAssertTrue(ProjectInstallStatus(skill: "unchanged", hook: false, mcp: true).needsRepair)
    }

    func testMalformedCreateOutputThrows() async {
        let runner = FakeCLIRunner(stdout: Data("created project 7".utf8))
        do {
            _ = try await ProjectCLI(runner: runner).create(folder: "/tmp/a", name: nil)
            XCTFail("expected a decode error")
        } catch {}
    }

    func testRunnerErrorPropagates() async {
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "folder is already bound to a project"))
        do {
            try await ProjectCLI(runner: runner).install(projectID: 1)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("already bound"))
        }
    }
}
```

- [ ] **Step 5: Run — expect a compile failure**

Run: `make test-swift FILTER=ProjectCLITests > /tmp/p14b.log 2>&1; echo "exit=$?"` → `exit≠0`, `cannot find 'ProjectCLI'`.

- [ ] **Step 6: Implement `ProjectCLI`**

Create `WatchtowerDesktop/Sources/Services/ProjectCLI.swift`:

```swift
import Foundation
import WatchtowerCore

/// `watchtower project create --json` envelope (Task 4).
struct ProjectCreated: Decodable, Equatable {
    let id: Int64
    let folder: String
    let name: String
}

/// `watchtower integrate status --project N --json` (Task 12). `skill` is a
/// devpack state (`installed`, `updated`, `unchanged`, `drifted`, `missing`,
/// `foreign`); a drifted or foreign skill is the owner's own content (PROJ-04)
/// and counts as present.
struct ProjectInstallStatus: Decodable, Equatable {
    let skill: String
    let hook: Bool
    let mcp: Bool

    var needsRepair: Bool { skill == "missing" || !hook || !mcp }
}

/// The Projects tab's CLI calls. Everything the Desktop does to the folder or
/// to project rows it does not own goes through here — never a direct write.
/// Folder paths travel as a single argv element (`Process` does no shell
/// parsing), so spaces and Unicode need no quoting.
struct ProjectCLI {
    let runner: any CLIRunnerProtocol

    func create(folder: String, name: String?) async throws -> ProjectCreated {
        var args = ["project", "create", "--folder", folder, "--json"]
        if let name, !name.isEmpty { args += ["--name", name] }
        let data = try await runner.run(args: args)
        return try JSONDecoder().decode(ProjectCreated.self, from: data)
    }

    /// Installs the skill, SessionStart hook and local MCP registration into
    /// the project folder. Idempotent — also the Repair action.
    func install(projectID: Int64) async throws {
        _ = try await runner.run(args: ["integrate", "claude-code", "--project", String(projectID)])
    }

    func status(projectID: Int64) async throws -> ProjectInstallStatus {
        let data = try await runner.run(args: ["integrate", "status", "--project", String(projectID), "--json"])
        return try JSONDecoder().decode(ProjectInstallStatus.self, from: data)
    }

    /// Removes what was installed in the folder, then the project and every
    /// row it owns (Task 4 runs the removal first). Used by Task 20.
    func delete(projectID: Int64) async throws {
        _ = try await runner.run(args: ["project", "delete", String(projectID)])
    }
}
```

Run: `make test-swift FILTER=ProjectCLITests > /tmp/p14b.log 2>&1; echo "exit=$?"` → `exit=0`.

- [ ] **Step 7: Failing tests for `ProjectsViewModel` (incl. the navigation-survival test)**

Create `WatchtowerDesktop/Tests/ProjectsViewModelTests.swift`:

```swift
import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class ProjectsViewModelTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "ProjectsViewModelTests-\(UUID().uuidString)"))
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private func makeVM(_ runner: any CLIRunnerProtocol = FakeCLIRunner()) -> ProjectsViewModel {
        ProjectsViewModel(dbPool: pool, cli: ProjectCLI(runner: runner), defaults: defaults)
    }

    private func createdJSON(_ id: Int64) -> Data {
        Data(#"{"id":\#(id),"folder":"/tmp/acme","name":"acme"}"#.utf8)
    }

    func testReloadBuildsSummariesAndTheBadgeCountsUnreadAndUnviewedDocuments() async throws {
        let ids = try await pool.write { d -> (Int64, Int64) in
            let p = try TestDatabase.insertProject(d)
            let doc = try TestDatabase.insertProjectDocument(d, projectID: p)
            let t = try TestDatabase.insertProjectTarget(d, projectID: p)
            _ = try TestDatabase.insertProjectComment(d, projectID: p, targetID: t)
            return (p, doc)
        }
        let vm = makeVM()
        await vm.reload()
        XCTAssertEqual(vm.summaries.map(\.id), [ids.0])
        XCTAssertEqual(vm.badgeCount, 2, "one unread agent comment + one never-viewed document")
        XCTAssertEqual(vm.revisedDocumentCount(for: vm.summaries[0]), 1)
    }

    func testViewedDocumentStopsCountingUntilItIsRevisedAgain() async throws {
        let (p, doc) = try await pool.write { d -> (Int64, Int64) in
            let p = try TestDatabase.insertProject(d)
            return (p, try TestDatabase.insertProjectDocument(d, projectID: p, updatedAt: "2026-09-29T10:00:00Z"))
        }
        let vm = makeVM()
        await vm.reload()
        let document = try XCTUnwrap(try await pool.read { try ProjectQueries.document($0, id: doc) })
        vm.markDocumentViewed(document)
        XCTAssertEqual(vm.badgeCount, 0)
        XCTAssertFalse(vm.isRevised(document))

        // A fresh VM reads the persisted stamp: the mark survives relaunch.
        let relaunched = makeVM()
        await relaunched.reload()
        XCTAssertEqual(relaunched.badgeCount, 0)

        try await pool.write { d in
            try d.execute(sql: "UPDATE project_documents SET updated_at = '2026-09-29T11:00:00Z' WHERE id = ?", arguments: [doc])
        }
        await relaunched.reload()
        XCTAssertEqual(relaunched.badgeCount, 1, "re-attached (revised) after the owner last looked")
        XCTAssertEqual(relaunched.summaries.first?.id, p)
    }

    func testCreateRunsCreateThenInstallSelectsTheProjectAndAnnouncesIt() async throws {
        let id = try await pool.write { try TestDatabase.insertProject($0) }
        let runner = ScriptedCLIRunner(results: [
            .success(createdJSON(id)),
            .success(Data("installed".utf8)),
            .success(Data(#"{"skill":"unchanged","hook":true,"mcp":true}"#.utf8))
        ])
        let vm = makeVM(runner)
        var announced: [Int64] = []
        vm.onProjectCreated = { announced.append($0.id) }

        await vm.createProject(folder: URL(fileURLWithPath: "/tmp/acme"), name: nil)

        XCTAssertEqual(runner.invocations.map { Array($0.prefix(2)) }, [
            ["project", "create"], ["integrate", "claude-code"], ["integrate", "status"]
        ])
        XCTAssertEqual(vm.selectedProjectID, id)
        XCTAssertEqual(vm.pane, .terminal)
        XCTAssertEqual(announced, [id])
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.installStatus[id]?.needsRepair, false)
        XCTAssertFalse(vm.isCreating)
    }

    func testInstallFailureKeepsTheProjectAndPointsAtRepair() async throws {
        let id = try await pool.write { try TestDatabase.insertProject($0) }
        let runner = ScriptedCLIRunner(results: [
            .success(createdJSON(id)),
            .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "claude not found")),
            .success(Data(#"{"skill":"missing","hook":false,"mcp":false}"#.utf8))
        ])
        let vm = makeVM(runner)
        await vm.createProject(folder: URL(fileURLWithPath: "/tmp/acme"), name: nil)
        XCTAssertEqual(vm.selectedProjectID, id)
        XCTAssertTrue(vm.errorMessage?.contains("Repair") == true)
        XCTAssertEqual(vm.installStatus[id]?.needsRepair, true)
    }

    func testCreateFailureShowsTheCLIErrorAndAnnouncesNothing() async {
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "folder is already bound to a project"))
        let vm = makeVM(runner)
        var announced = false
        vm.onProjectCreated = { _ in announced = true }
        await vm.createProject(folder: URL(fileURLWithPath: "/tmp/acme"), name: nil)
        XCTAssertTrue(vm.errorMessage?.contains("already bound") == true)
        XCTAssertNil(vm.selectedProjectID)
        XCTAssertFalse(announced)
    }

    func testRepairRunsIntegrateAndRefreshesTheStatus() async throws {
        let id = try await pool.write { try TestDatabase.insertProject($0) }
        let runner = FakeCLIRunner(stdout: Data(#"{"skill":"unchanged","hook":true,"mcp":true}"#.utf8))
        let vm = makeVM(runner)
        await vm.repairInstall(projectID: id)
        XCTAssertEqual(runner.invocations, [
            ["integrate", "claude-code", "--project", String(id)],
            ["integrate", "status", "--project", String(id), "--json"]
        ])
        XCTAssertEqual(vm.installStatus[id]?.needsRepair, false)
    }

    func testRevealSelectsTheProjectAndPane() {
        let vm = makeVM()
        vm.reveal(ProjectRoute(projectID: 4, pane: .documents, subjectID: 9))
        XCTAssertEqual(vm.selectedProjectID, 4)
        XCTAssertEqual(vm.pane, .documents)
    }

    /// House rule: an async operation started from a screen survives leaving
    /// it. The VM lives on AppState, so the create keeps running while the
    /// owner is on another tab and the result is there when they return.
    func testCreateSurvivesNavigatingAwayAndSelectsTheProjectOnReturn() async throws {
        let id = try await pool.write { try TestDatabase.insertProject($0) }
        let held = HeldCLIRunner(stdout: createdJSON(id))
        let appState = AppState()
        appState.initProjects(dbPool: pool, cliRunner: held)
        let vm = try XCTUnwrap(appState.projectsViewModel)
        appState.selectedDestination = .projects

        let run = Task { await vm.createProject(folder: URL(fileURLWithPath: "/tmp/acme"), name: nil) }
        await awaitStarted(held)
        XCTAssertTrue(vm.isCreating)

        appState.selectedDestination = .inbox
        held.release()
        await run.value

        appState.selectedDestination = .projects
        XCTAssertTrue(appState.projectsViewModel === vm, "the same AppState-owned VM, not a fresh one")
        XCTAssertEqual(vm.selectedProjectID, id)
        XCTAssertFalse(vm.isCreating)
    }

    func testNavigateToProjectSetsThePendingRouteAndTheTab() {
        let appState = AppState()
        appState.navigateToProject(ProjectRoute(projectID: 2, pane: .board))
        XCTAssertEqual(appState.selectedDestination, .projects)
        XCTAssertEqual(appState.pendingProjectRoute, ProjectRoute(projectID: 2, pane: .board))
    }
}

/// Returns one scripted result per call, in order (the last one repeats).
final class ScriptedCLIRunner: CLIRunnerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<Data, Error>]
    private var recorded: [[String]] = []

    init(results: [Result<Data, Error>]) {
        self.results = results
    }

    var invocations: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func run(args: [String]) async throws -> Data {
        lock.lock()
        recorded.append(args)
        let next = results.count > 1 ? results.removeFirst() : results[0]
        lock.unlock()
        return try next.get()
    }
}
```

In the survival test `initProjects` wires `onProjectCreated` to start a terminal (Task 17) — before Task 17 lands nothing is wired, afterwards Task 17's step replaces `AppState.projectTerminalCenter.makeSession` in this test with a fake (see Task 17 Step 9), so the test never spawns a shell.

- [ ] **Step 8: Run — expect a compile failure**

Run: `make test-swift FILTER=ProjectsViewModelTests > /tmp/p14c.log 2>&1; echo "exit=$?"` → `exit≠0`, `cannot find 'ProjectsViewModel'`.

- [ ] **Step 9: Implement `ProjectsViewModel`**

Create `WatchtowerDesktop/Sources/ViewModels/ProjectsViewModel.swift`:

```swift
import Foundation
import GRDB
import Observation
import WatchtowerCore

/// The Projects tab (spec §6.1). Owned by `AppState` so a create or repair in
/// flight — and the selection — survive navigating away (house rule).
///
/// The daemon/CLI/MCP server write these tables from other processes, so
/// nothing here observes the DB: the view reloads on appear and the
/// notification center's 30 s poll reloads it (Task 18).
@MainActor
@Observable
final class ProjectsViewModel {
    /// Document id (string) → the `updated_at` the owner last opened.
    static let viewedDocumentsKey = "projects.viewedDocuments"

    private(set) var summaries: [ProjectSummary] = []
    var selectedProjectID: Int64?
    var pane: ProjectPane = .terminal
    /// The document the documents pane should open next (a deep link); the
    /// pane consumes and clears it.
    var pendingDocumentID: Int64?
    private(set) var isCreating = false
    private(set) var repairing: Set<Int64> = []
    var errorMessage: String?
    private(set) var installStatus: [Int64: ProjectInstallStatus] = [:]

    /// A project was created: Task 17 opens its terminal with the first-run
    /// prompt, Task 18 seeds its notification baseline.
    var onProjectCreated: ((Project) -> Void)?
    /// The owner changed something in a project (a comment, a status): the
    /// notification policy must not report it back (Task 18).
    var onOwnerWrite: ((Int64, ProjectSubject) -> Void)?

    let dbPool: DatabasePool
    private let cli: ProjectCLI?
    private let defaults: UserDefaults
    private var viewed: [String: String]

    init(dbPool: DatabasePool, cli: ProjectCLI?, defaults: UserDefaults = .standard) {
        self.dbPool = dbPool
        self.cli = cli
        self.defaults = defaults
        viewed = defaults.dictionary(forKey: Self.viewedDocumentsKey) as? [String: String] ?? [:]
    }

    var selectedProject: Project? {
        summaries.first { $0.id == selectedProjectID }?.project
    }

    /// Sidebar badge: unread agent comments + documents revised since last viewed.
    var badgeCount: Int {
        summaries.reduce(0) { $0 + $1.unreadAgentComments + revisedDocumentCount(for: $1) }
    }

    func revisedDocumentCount(for summary: ProjectSummary) -> Int {
        summary.documentStamps.filter { id, stamp in viewed[String(id)] != stamp }.count
    }

    func isRevised(_ document: ProjectDocument) -> Bool {
        viewed[String(document.id)] != document.updatedAt
    }

    func markDocumentViewed(_ document: ProjectDocument) {
        viewed[String(document.id)] = document.updatedAt
        defaults.set(viewed, forKey: Self.viewedDocumentsKey)
    }

    func reload() async {
        do {
            // A deleted project's documents fall out of `summaries`; their
            // stale `viewed` stamps are never read again, so none are pruned.
            summaries = try await dbPool.read { try ProjectQueries.summaries($0) }
        } catch {
            errorMessage = "Could not load projects: \(error.localizedDescription)"
        }
    }

    func reveal(_ route: ProjectRoute) {
        selectedProjectID = route.projectID
        pane = route.pane
        pendingDocumentID = route.pane == .documents ? route.subjectID : nil
    }

    /// New project… → `project create`, then the folder install. A failed
    /// install keeps the project (it exists now) and points at Repair.
    func createProject(folder: URL, name: String?) async {
        guard !isCreating else { return }
        guard let cli else {
            errorMessage = "The watchtower CLI was not found."
            return
        }
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }

        let created: ProjectCreated
        do {
            created = try await cli.create(folder: folder.path, name: name)
        } catch {
            errorMessage = "Could not create the project: \(error.localizedDescription)"
            return
        }
        do {
            try await cli.install(projectID: created.id)
        } catch {
            errorMessage = "The project was created, but installing into the folder failed — use Repair. "
                + error.localizedDescription
        }
        await reload()
        selectedProjectID = created.id
        pane = .terminal
        await refreshInstallStatus(projectID: created.id)
        if let project = selectedProject {
            onProjectCreated?(project)
        }
    }

    func refreshInstallStatus(projectID: Int64) async {
        guard let cli else { return }
        do {
            installStatus[projectID] = try await cli.status(projectID: projectID)
        } catch {
            installStatus[projectID] = nil
            errorMessage = "Could not read the install status: \(error.localizedDescription)"
        }
    }

    func repairInstall(projectID: Int64) async {
        guard let cli, !repairing.contains(projectID) else { return }
        repairing.insert(projectID)
        defer { repairing.remove(projectID) }
        do {
            try await cli.install(projectID: projectID)
            errorMessage = nil
        } catch {
            errorMessage = "Repair failed: \(error.localizedDescription)"
        }
        await refreshInstallStatus(projectID: projectID)
    }
}
```

- [ ] **Step 10: `AppState` wiring**

In `WatchtowerDesktop/Sources/App/AppState.swift`:

After `private(set) var actionStripViewModel: ActionStripViewModel?` add:

```swift
    /// Projects tab (spec §6). Owned here so create/repair and the selection
    /// survive navigation.
    private(set) var projectsViewModel: ProjectsViewModel?
    /// Set by `navigateToProject`; `ProjectsView` consumes and clears it.
    var pendingProjectRoute: ProjectRoute?
```

Next to `navigateToPerson` add:

```swift
    func navigateToProject(_ route: ProjectRoute) {
        pendingProjectRoute = route
        selectedDestination = .projects
    }
```

In `initFeatureViewModels(manager:)`, after `initActionStrip(dbPool: manager.dbPool)`:

```swift
        initProjects(dbPool: manager.dbPool)
```

Next to `initActionStrip` add:

```swift
    /// Not `private`: tests build the VM on a test pool (the
    /// `initSecretaryProfile` precedent) to prove it survives navigation.
    func initProjects(
        dbPool: DatabasePool,
        cliRunner: (any CLIRunnerProtocol)? = ProcessCLIRunner.makeDefault()
    ) {
        let vm = ProjectsViewModel(dbPool: dbPool, cli: cliRunner.map { ProjectCLI(runner: $0) })
        projectsViewModel = vm
        Task { await vm.reload() }
    }
```

- [ ] **Step 11: Sidebar destination, navigation, badge**

`WatchtowerDesktop/Sources/App/SidebarDestination.swift`: add `case projects` after `case tracks`; `title` → `case .projects: "Projects"`; `icon` → `case .projects: "folder.badge.gearshape"`; `rootItems` → `[.targets, .tracks, .projects]`. No `requiredFeatures` entry (the tab is always visible; Projects has no feature flag in this POC).

`WatchtowerDesktop/Tests/SidebarSectionTests.swift`: `testRootItems` asserts `[.targets, .tracks, .projects]`.

`WatchtowerDesktop/Sources/App/Navigation.swift`, in `detailView` after `case .tracks:`:

```swift
        case .projects:
            if let vm = appState.projectsViewModel {
                ProjectsView(vm: vm)
            } else {
                Text("Projects unavailable")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
```

`WatchtowerDesktop/Sources/Views/Sidebar/SidebarView.swift`: in `count(for:)` add `case .projects: appState.projectsViewModel?.badgeCount ?? 0`; in `badgeCount(for:)`'s color chain add `: item == .projects ? .blue` before the final `: .red`.

- [ ] **Step 12: Views**

Create `WatchtowerDesktop/Sources/Views/Projects/ProjectsView.swift`:

```swift
import AppKit
import SwiftUI
import WatchtowerCore

/// Projects tab: the project list on the left, the selected project's page on
/// the right (spec §6.1).
struct ProjectsView: View {
    @Bindable var vm: ProjectsViewModel
    @Environment(AppState.self) private var appState
    @State private var pendingFolder: URL?
    @State private var sensitiveLocation: String?

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
            Group {
                if let project = vm.selectedProject {
                    ProjectPageView(vm: vm, project: project)
                } else {
                    emptyState
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Projects")
        .onAppear {
            consumeRoute()
            Task { await vm.reload() }
        }
        .onChange(of: appState.pendingProjectRoute) { _, _ in consumeRoute() }
        .alert(
            "Folder in \(sensitiveLocation ?? "")",
            isPresented: Binding(get: { sensitiveLocation != nil }, set: { if !$0 { sensitiveLocation = nil } })
        ) {
            Button("Create anyway") { createPending() }
            Button("Choose another folder", role: .cancel) { pendingFolder = nil }
        } message: {
            Text("Claude Code in the embedded terminal runs as part of Watchtower, so macOS may ask whether Watchtower can access \(sensitiveLocation ?? "this folder"). A folder outside Documents, Desktop, Downloads and cloud storage avoids that prompt.")
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: $vm.selectedProjectID) {
                ForEach(vm.summaries) { summary in
                    row(summary).tag(Optional(summary.id))
                }
            }
            Divider()
            HStack {
                Button {
                    chooseFolder()
                } label: {
                    Label("New project…", systemImage: "plus")
                }
                .disabled(vm.isCreating)
                if vm.isCreating { ProgressView().controlSize(.small) }
                Spacer()
            }
            .padding(8)
            if let error = vm.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding([.horizontal, .bottom], 8)
            }
        }
    }

    private func row(_ summary: ProjectSummary) -> some View {
        let badge = summary.unreadAgentComments + vm.revisedDocumentCount(for: summary)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.project.name).font(.body)
                Text(summary.project.folderPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(summary.openTargets) open · \(summary.inProgressTargets) in progress")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if badge > 0 {
                Text("\(badge)")
                    .font(.caption2).fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.blue, in: Capsule())
            }
        }
        .padding(.vertical, 2)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder.badge.gearshape").font(.largeTitle).foregroundStyle(.secondary)
            Text("Pick a folder to start a project. Claude Code sets it up from there.")
                .foregroundStyle(.secondary)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Create Project"
        guard panel.runModal() == .OK, let url = panel.url?.resolvingSymlinksInPath() else { return }
        pendingFolder = url
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        if let location = ProjectFolderPolicy.tccSensitiveLocation(path: url.path, home: home) {
            sensitiveLocation = location
        } else {
            createPending()
        }
    }

    private func createPending() {
        guard let folder = pendingFolder else { return }
        pendingFolder = nil
        sensitiveLocation = nil
        Task { await vm.createProject(folder: folder, name: nil) }
    }

    private func consumeRoute() {
        guard let route = appState.pendingProjectRoute else { return }
        appState.pendingProjectRoute = nil
        vm.reveal(route)
    }
}
```

Create `WatchtowerDesktop/Sources/Views/Projects/ProjectPageView.swift`:

```swift
import AppKit
import SwiftUI
import WatchtowerCore

/// One project: header (folder, install status, Repair) and the Terminal |
/// Board | Documents panes (spec §6.1).
struct ProjectPageView: View {
    @Bindable var vm: ProjectsViewModel
    let project: Project

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            paneContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: project.id) { await vm.refreshInstallStatus(projectID: project.id) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).font(.headline)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([project.folderURL])
                } label: {
                    Text(project.folderPath).font(.caption).lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.link)
                .help("Reveal in Finder")
            }
            Spacer()
            installBadge
            Picker("", selection: $vm.pane) {
                ForEach(ProjectPane.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 280)
        }
        .padding(10)
    }

    @ViewBuilder
    private var installBadge: some View {
        if let status = vm.installStatus[project.id], status.needsRepair {
            Button {
                Task { await vm.repairInstall(projectID: project.id) }
            } label: {
                Label("Repair install", systemImage: "wrench.and.screwdriver")
            }
            .disabled(vm.repairing.contains(project.id))
            .help("Skill \(status.skill) · hook \(status.hook ? "on" : "missing") · MCP \(status.mcp ? "on" : "missing")")
        } else if vm.installStatus[project.id] != nil {
            Label("Installed", systemImage: "checkmark.seal").foregroundStyle(.secondary).font(.caption)
        }
    }

    @ViewBuilder
    private var paneContent: some View {
        switch vm.pane {
        case .terminal:
            ProjectPanePlaceholder(title: "Terminal")
        case .board:
            ProjectPanePlaceholder(title: "Board")
        case .documents:
            ProjectPanePlaceholder(title: "Documents")
        }
    }
}

/// A pane that is not built yet in this phase. Task 16 replaces Documents,
/// Task 17 Terminal, Task 19 Board.
struct ProjectPanePlaceholder: View {
    let title: String

    var body: some View {
        Text("\(title) — coming next")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 13: Run — PASS**

Run each and check `exit=0`:
```bash
make test-swift FILTER=ProjectsViewModelTests > /tmp/p14c.log 2>&1; echo "exit=$?"
make test-swift FILTER=SidebarSectionTests > /tmp/p14d.log 2>&1; echo "exit=$?"
make test-swift FILTER=ProjectCLITests > /tmp/p14b.log 2>&1; echo "exit=$?"
make lint-swift > /tmp/p14-lint.log 2>&1; echo "exit=$?"
```

- [ ] **Step 14: Commit**

```bash
git add WatchtowerDesktop/Sources/WatchtowerCore/Services/ProjectFolderPolicy.swift \
        WatchtowerDesktop/Sources/Services/ProjectCLI.swift \
        WatchtowerDesktop/Sources/ViewModels/ProjectsViewModel.swift \
        WatchtowerDesktop/Sources/Views/Projects/ProjectsView.swift \
        WatchtowerDesktop/Sources/Views/Projects/ProjectPageView.swift \
        WatchtowerDesktop/Sources/App/SidebarDestination.swift \
        WatchtowerDesktop/Sources/App/Navigation.swift \
        WatchtowerDesktop/Sources/Views/Sidebar/SidebarView.swift \
        WatchtowerDesktop/Sources/App/AppState.swift \
        WatchtowerDesktop/Tests/SidebarSectionTests.swift \
        WatchtowerDesktop/Tests/Core/ProjectFolderPolicyTests.swift \
        WatchtowerDesktop/Tests/ProjectCLITests.swift \
        WatchtowerDesktop/Tests/ProjectsViewModelTests.swift
git commit -m "$(cat <<'EOF'
feat(desktop): Projects tab shell with create, install status and repair

A Projects sidebar tab: the project list with counts and a badge, New
project via NSOpenPanel with a TCC-location warning, and a project page
with Terminal/Board/Documents panes (placeholders for now). The view model
lives on AppState so a create in flight survives navigation.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Lo9jbbmXQcr3qHo5f3pLD8
EOF
)"
```

---
### Task 15: `CommentAnchor` + the rendered plain text anchors live on

**Depends on:** Task 13 (the `CommentAnchor` data shape it created).

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/CommentAnchor.swift` (add `make`/`locate`)
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/DocumentRendering.swift`
- Test: `WatchtowerDesktop/Tests/Core/CommentAnchorTests.swift`, `WatchtowerDesktop/Tests/Core/DocumentRenderingTests.swift`

**Interfaces:**
- Consumes: `MarkdownDocument.parse(_:) -> [MarkdownBlock]` and `MarkdownInline` (the chat's swift-markdown model, `Services/Chat/MarkdownDocument.swift`) — reused, not copied.
- Produces (WatchtowerCore, `package`):
  - `CommentAnchor.make(text: String, range: Range<String.Index>, headings: [(offset: Int, title: String)]) -> CommentAnchor` — `offset` is a **UTF-16** offset into `text` (what `NSTextView`/`NSRange` speak); prefix/suffix are up to `contextLength` (64) **characters**.
  - `CommentAnchor.locate(in: String) -> Range<String.Index>?` — nil means outdated.
  - `enum DocumentStyle { heading(Int), strong, emphasis, strikethrough, code, codeBlock, quote, link(String) }`, `struct DocumentStyleRun { location, length: Int (UTF-16); style }`, `struct DocumentHeading { offset: Int (UTF-16); level: Int; title: String }`, `struct RenderedDocument { text; headings; runs; headingOffsets: [(offset: Int, title: String)] }`, `DocumentRendering.render(_ markdown: String) -> RenderedDocument`.

**Locate rules (spec §6.3, index Review Focus #4):**
1. Empty (or whitespace-only) quote → nil.
2. Candidates = every exact occurrence of the quote (overlapping allowed). None → every occurrence after collapsing each whitespace run to one space on both sides (a reflowed paragraph); matches map back to original indices. None again → nil (deleted or edited passage: never fuzzy).
3. One candidate → it. Several → score each by (common suffix of the whitespace-collapsed text before it with the stored prefix) + (common prefix of the text after it with the stored suffix); the unique best wins, ties go to the earliest of the best; **a best score of 0 → nil** — several equal copies with none of the original context means the anchored passage itself is gone, and guessing would re-attach the thread to a wrong place.

- [ ] **Step 1: Failing anchor tests**

Create `WatchtowerDesktop/Tests/Core/CommentAnchorTests.swift`:

```swift
import XCTest
@testable import WatchtowerCore

final class CommentAnchorTests: XCTestCase {
    private func range(of needle: String, in text: String, occurrence: Int = 0) throws -> Range<String.Index> {
        var start = text.startIndex
        var found: Range<String.Index>?
        for _ in 0...occurrence {
            found = text.range(of: needle, range: start..<text.endIndex)
            start = found.map { text.index(after: $0.lowerBound) } ?? text.endIndex
        }
        return try XCTUnwrap(found)
    }

    private func anchor(_ needle: String, in text: String, occurrence: Int = 0,
                        headings: [(offset: Int, title: String)] = []) throws -> CommentAnchor {
        CommentAnchor.make(text: text, range: try range(of: needle, in: text, occurrence: occurrence), headings: headings)
    }

    // MARK: make

    func testMakeTakesQuoteBoundedContextAndNearestPrecedingHeading() throws {
        let text = "Intro\n\nErrors\n\nRetry the call twice before giving up.\n\nLater\n\nMore."
        let later = (text as NSString).range(of: "Later").location
        let errors = (text as NSString).range(of: "Errors").location
        let made = try anchor("the call twice", in: text, headings: [(0, "Intro"), (errors, "Errors"), (later, "Later")])
        XCTAssertEqual(made.quote, "the call twice")
        XCTAssertEqual(made.prefix, "Intro\n\nErrors\n\nRetry ")
        XCTAssertEqual(made.suffix, " before giving up.\n\nLater\n\nMore.")
        XCTAssertEqual(made.heading, "Errors")
    }

    func testMakeCapsContextAtSixtyFourCharacters() throws {
        let text = String(repeating: "a", count: 100) + "QUOTE" + String(repeating: "b", count: 100)
        let made = try anchor("QUOTE", in: text)
        XCTAssertEqual(made.prefix.count, CommentAnchor.contextLength)
        XCTAssertEqual(made.suffix.count, CommentAnchor.contextLength)
        XCTAssertEqual(made.heading, "")
    }

    // MARK: locate — the easy cases

    func testUniqueQuoteIsFoundAgainAfterTextIsInsertedAbove() throws {
        let original = "Keep the retry budget small.\n\nSomething else."
        let made = try anchor("retry budget", in: original)
        let revised = "A brand new first paragraph.\n\n" + original
        let found = made.locate(in: revised)
        XCTAssertEqual(found.map { String(revised[$0]) }, "retry budget")
        XCTAssertEqual(found?.lowerBound, try range(of: "retry budget", in: revised).lowerBound)
    }

    func testEmptyQuoteNeverLocates() throws {
        XCTAssertNil(CommentAnchor(quote: "", prefix: "a", suffix: "b", heading: "").locate(in: "a b"))
        XCTAssertNil(CommentAnchor(quote: "  \n", prefix: "", suffix: "", heading: "").locate(in: "a  \n b"))
    }

    // MARK: locate — Review Focus #4

    func testDuplicateQuotePicksTheOccurrenceWithTheBestContext() throws {
        let text = "Step one: retry the call. Then log it.\n\nStep two: check the queue, retry the call, and alert."
        let made = try anchor("retry the call", in: text, occurrence: 1)
        let found = made.locate(in: text)
        XCTAssertEqual(found?.lowerBound, try range(of: "retry the call", in: text, occurrence: 1).lowerBound)
    }

    func testDuplicateQuoteSurvivesTextInsertedAboveIt() throws {
        let text = "Step one: retry the call. Then log it.\n\nStep two: check the queue, retry the call, and alert."
        let made = try anchor("retry the call", in: text, occurrence: 1)
        let revised = "New preface that mentions nothing.\n\n" + text.replacingOccurrences(of: "Then log it.", with: "Then log it twice.")
        let found = made.locate(in: revised)
        XCTAssertEqual(found?.lowerBound, try range(of: "retry the call", in: revised, occurrence: 1).lowerBound)
    }

    func testDuplicatesWithNoMatchingContextAreOutdated() throws {
        let made = try anchor("retry the call", in: "alpha:retry the call;omega")
        // Both surviving copies have none of the original context around them:
        // the anchored passage was rewritten — refusing beats guessing.
        XCTAssertNil(made.locate(in: "1retry the call2 3retry the call4"))
    }

    func testSingleSurvivingCopyWinsEvenWithDifferentContext() throws {
        let made = try anchor("retry the call", in: "alpha:retry the call;omega")
        let revised = "The plan: retry the call once."
        XCTAssertEqual(made.locate(in: revised).map { String(revised[$0]) }, "retry the call")
    }

    func testWhitespaceReflowStillLocates() throws {
        let original = "Keep the retry budget small so a flaky service cannot stall the sync."
        let made = try anchor("retry budget small so a flaky", in: original)
        let reflowed = "Keep the retry\n  budget small so a\nflaky service cannot stall the sync."
        let found = made.locate(in: reflowed)
        XCTAssertEqual(found.map { String(reflowed[$0]) }, "retry\n  budget small so a\nflaky")
    }

    func testReflowWithDuplicatesStillUsesContext() throws {
        let original = "First: stop the sync now. Second: when idle, stop the sync now, then report."
        let made = try anchor("stop the sync now", in: original, occurrence: 1)
        let reflowed = "First: stop the\nsync now. Second: when idle, stop  the sync\nnow, then report."
        let found = made.locate(in: reflowed)
        XCTAssertEqual(found.map { String(reflowed[$0]) }, "stop  the sync\nnow")
    }

    func testDeletedPassageIsOutdated() throws {
        let made = try anchor("retry budget", in: "Keep the retry budget small.\n\nOther text.")
        XCTAssertNil(made.locate(in: "Other text.\n\nA new ending."))
    }

    func testEditedQuoteIsOutdatedNotFuzzyMatched() throws {
        let made = try anchor("retry budget small", in: "Keep the retry budget small.")
        XCTAssertNil(made.locate(in: "Keep the retry budget tiny."))
    }

    func testNonASCIITextRoundTrips() throws {
        let text = "Вступ\n\nПовтори виклик 🔁 двічі.\n\nКінець."
        let made = try anchor("виклик 🔁 двічі", in: text)
        XCTAssertEqual(made.locate(in: "Новий абзац.\n\n" + text).map { String(("Новий абзац.\n\n" + text)[$0]) }, "виклик 🔁 двічі")
    }
}
```

The fixture strings above are neutral samples (no real names or ids), per the public-repo rule.

- [ ] **Step 2: Failing rendering tests**

Create `WatchtowerDesktop/Tests/Core/DocumentRenderingTests.swift`:

```swift
import XCTest
@testable import WatchtowerCore

final class DocumentRenderingTests: XCTestCase {
    func testHeadingsParagraphsAndSoftBreaksFlattenToPlainText() {
        let doc = DocumentRendering.render("# Title\n\nSome *soft*\nwrapped text.\n\n## Errors\n\nRetry `twice`.")
        XCTAssertEqual(doc.text, "Title\n\nSome soft wrapped text.\n\nErrors\n\nRetry twice.\n\n")
        let errors = (doc.text as NSString).range(of: "Errors").location
        XCTAssertEqual(doc.headings, [
            DocumentHeading(offset: 0, level: 1, title: "Title"),
            DocumentHeading(offset: errors, level: 2, title: "Errors")
        ])
        XCTAssertEqual(doc.headingOffsets.map(\.title), ["Title", "Errors"])
        XCTAssertTrue(doc.runs.contains(DocumentStyleRun(location: 0, length: 5, style: .heading(1))))
        let soft = (doc.text as NSString).range(of: "soft")
        XCTAssertTrue(doc.runs.contains(DocumentStyleRun(location: soft.location, length: soft.length, style: .emphasis)))
        let twice = (doc.text as NSString).range(of: "twice")
        XCTAssertTrue(doc.runs.contains(DocumentStyleRun(location: twice.location, length: twice.length, style: .code)))
    }

    func testListsGetMarkersAndTaskBoxes() {
        let doc = DocumentRendering.render("- one\n- [x] two\n- [ ] three\n\n1. first\n2. second")
        XCTAssertEqual(doc.text, "• one\n☑ two\n☐ three\n\n1. first\n2. second\n\n")
    }

    func testFencedCodeIsVerbatimAndStyled() {
        let doc = DocumentRendering.render("Intro.\n\n```go\nx := 1\ny := 2\n```")
        XCTAssertEqual(doc.text, "Intro.\n\nx := 1\ny := 2\n\n")
        let code = (doc.text as NSString).range(of: "x := 1\ny := 2")
        XCTAssertTrue(doc.runs.contains(DocumentStyleRun(location: code.location, length: code.length, style: .codeBlock)))
    }

    func testLinkRunCarriesItsDestination() {
        let doc = DocumentRendering.render("See [the spec](docs/spec.md).")
        let link = (doc.text as NSString).range(of: "the spec")
        XCTAssertTrue(doc.runs.contains(DocumentStyleRun(location: link.location, length: link.length, style: .link("docs/spec.md"))))
    }

    /// The anchors live on this text, so the same markdown must always render
    /// the same text (a re-anchor on an unchanged file finds every quote).
    func testRenderingIsDeterministicAndAnchorsRoundTrip() throws {
        let markdown = "# Plan\n\n## Task 1\n\nWrite the migration.\n\n## Task 2\n\nWrite the migration tests."
        let first = DocumentRendering.render(markdown)
        XCTAssertEqual(first, DocumentRendering.render(markdown))
        let range = try XCTUnwrap(first.text.range(of: "Write the migration."))
        let anchor = CommentAnchor.make(text: first.text, range: range, headings: first.headingOffsets)
        XCTAssertEqual(anchor.heading, "Task 1")
        XCTAssertEqual(anchor.locate(in: DocumentRendering.render(markdown).text), range)
    }
}
```

- [ ] **Step 3: Run — expect a compile failure**

Run: `make test-swift FILTER='CommentAnchorTests|DocumentRenderingTests' > /tmp/p15.log 2>&1; echo "exit=$?"` → `exit≠0` (`make` has no member / `DocumentRendering` not found). If `FILTER` does not accept a regex alternation in this Makefile, run the two classes one after the other.

- [ ] **Step 4: Implement `CommentAnchor.make`/`locate`**

Replace `WatchtowerDesktop/Sources/WatchtowerCore/Services/CommentAnchor.swift` with:

```swift
import Foundation

/// A comment's anchor on a document's RENDERED plain text (spec §6.3): the
/// selected quote, up to `contextLength` characters on either side, and the
/// nearest preceding heading. Re-located on every load of a possibly revised
/// file; `locate` returning nil means the thread is outdated.
///
/// Rules (index Review Focus #4): exact matches first, then a
/// whitespace-collapsed match (reflow); several candidates are ranked by how
/// much of the stored prefix/suffix still surrounds them; no candidate — or
/// several with none of the original context — is nil. Never fuzzy.
package struct CommentAnchor: Equatable, Sendable {
    package static let contextLength = 64

    package var quote: String
    package var prefix: String
    package var suffix: String
    package var heading: String

    package init(quote: String, prefix: String, suffix: String, heading: String) {
        self.quote = quote
        self.prefix = prefix
        self.suffix = suffix
        self.heading = heading
    }

    /// `headings` carry UTF-16 offsets into `text`, in any order.
    package static func make(
        text: String,
        range: Range<String.Index>,
        headings: [(offset: Int, title: String)]
    ) -> CommentAnchor {
        let start = text.index(range.lowerBound, offsetBy: -contextLength, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: contextLength, limitedBy: text.endIndex) ?? text.endIndex
        let offset = text.utf16.distance(from: text.startIndex, to: range.lowerBound)
        let heading = headings.filter { $0.offset <= offset }.max { $0.offset < $1.offset }?.title ?? ""
        return Self(
            quote: String(text[range]),
            prefix: String(text[start..<range.lowerBound]),
            suffix: String(text[range.upperBound..<end]),
            heading: heading
        )
    }

    package func locate(in text: String) -> Range<String.Index>? {
        let needle = Array(Self.collapsed(quote).trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return nil }
        let exact = Self.exactOccurrences(of: quote, in: text)
        let candidates = exact.isEmpty ? Self.collapsedOccurrences(of: needle, in: text) : exact
        return pick(candidates, in: text)
    }

    // MARK: - Ranking

    private func pick(_ candidates: [Range<String.Index>], in text: String) -> Range<String.Index>? {
        guard candidates.count > 1 else { return candidates.first }
        let storedPrefix = Array(Self.collapsed(prefix))
        let storedSuffix = Array(Self.collapsed(suffix))
        let scored = candidates.map { candidate -> (Range<String.Index>, Int) in
            let before = Array(Self.collapsed(String(text[..<candidate.lowerBound].suffix(Self.contextLength * 2))))
            let after = Array(Self.collapsed(String(text[candidate.upperBound...].prefix(Self.contextLength * 2))))
            let score = Self.commonSuffixLength(before, storedPrefix) + Self.commonPrefixLength(after, storedSuffix)
            return (candidate, score)
        }
        guard let best = scored.map(\.1).max(), best > 0 else { return nil }
        return scored.first { $0.1 == best }?.0
    }

    private static func commonSuffixLength(_ lhs: [Character], _ rhs: [Character]) -> Int {
        zip(lhs.reversed(), rhs.reversed()).prefix { $0 == $1 }.count
    }

    private static func commonPrefixLength(_ lhs: [Character], _ rhs: [Character]) -> Int {
        zip(lhs, rhs).prefix { $0 == $1 }.count
    }

    // MARK: - Matching

    /// Every run of whitespace collapsed to one space; not trimmed.
    private static func collapsed(_ value: String) -> String {
        var out = ""
        var lastWasSpace = false
        for character in value {
            if character.isWhitespace {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(character)
                lastWasSpace = false
            }
        }
        return out
    }

    private static func exactOccurrences(of needle: String, in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var start = text.startIndex
        while start < text.endIndex,
              let hit = text.range(of: needle, options: .literal, range: start..<text.endIndex) {
            found.append(hit)
            start = text.index(after: hit.lowerBound)
        }
        return found
    }

    /// Matches `needle` (already collapsed and trimmed) against `text` with
    /// whitespace runs collapsed, returning ranges in the ORIGINAL text.
    private static func collapsedOccurrences(of needle: [Character], in text: String) -> [Range<String.Index>] {
        var chars: [Character] = []
        var origins: [String.Index] = []
        var lastWasSpace = false
        for index in text.indices {
            let character = text[index]
            if character.isWhitespace {
                if !lastWasSpace {
                    chars.append(" ")
                    origins.append(index)
                }
                lastWasSpace = true
            } else {
                chars.append(character)
                origins.append(index)
                lastWasSpace = false
            }
        }
        guard chars.count >= needle.count else { return [] }
        var found: [Range<String.Index>] = []
        for start in 0...(chars.count - needle.count) where chars[start] == needle[0] {
            guard chars[start..<(start + needle.count)].elementsEqual(needle) else { continue }
            let last = origins[start + needle.count - 1]
            found.append(origins[start]..<text.index(after: last))
        }
        return found
    }
}
```

The needle is trimmed and its last character is never a whitespace, so `last` always points at a real character of the original text and `index(after:)` ends the range right after it.

- [ ] **Step 5: Implement `DocumentRendering`**

Create `WatchtowerDesktop/Sources/WatchtowerCore/Services/DocumentRendering.swift`:

```swift
import Foundation

package enum DocumentStyle: Equatable, Sendable {
    case heading(Int)
    case strong
    case emphasis
    case strikethrough
    case code
    case codeBlock
    case quote
    case link(String)
}

/// A styled span of `RenderedDocument.text`, in UTF-16 units (`NSRange`).
package struct DocumentStyleRun: Equatable, Sendable {
    package let location: Int
    package let length: Int
    package let style: DocumentStyle

    package init(location: Int, length: Int, style: DocumentStyle) {
        self.location = location
        self.length = length
        self.style = style
    }
}

package struct DocumentHeading: Equatable, Sendable {
    /// UTF-16 offset of the heading's first character in the rendered text.
    package let offset: Int
    package let level: Int
    package let title: String

    package init(offset: Int, level: Int, title: String) {
        self.offset = offset
        self.level = level
        self.title = title
    }
}

/// A project document rendered to the plain text comments anchor on, plus
/// the style runs the app turns into an `NSAttributedString`.
package struct RenderedDocument: Equatable, Sendable {
    package let text: String
    package let headings: [DocumentHeading]
    package let runs: [DocumentStyleRun]

    /// The shape `CommentAnchor.make` takes.
    package var headingOffsets: [(offset: Int, title: String)] {
        headings.map { ($0.offset, $0.title) }
    }
}

/// Markdown → plain text + runs, over the chat's swift-markdown model
/// (`MarkdownDocument`). Deterministic: the same markdown always renders the
/// same text, which is what keeps an unchanged file's anchors valid.
package enum DocumentRendering {
    package static func render(_ markdown: String) -> RenderedDocument {
        var out = Builder()
        for block in MarkdownDocument.parse(markdown) {
            render(block, into: &out, depth: 0)
        }
        return RenderedDocument(text: out.text, headings: out.headings, runs: out.runs)
    }

    private static func render(_ block: MarkdownBlock, into out: inout Builder, depth: Int) {
        switch block {
        case let .heading(level, inlines):
            out.headings.append(DocumentHeading(offset: out.length, level: level, title: plain(inlines)))
            out.styled(.heading(level)) { render(inlines, into: &$0) }
        case let .paragraph(inlines):
            render(inlines, into: &out)
        case let .code(_, code):
            out.styled(.codeBlock) { $0.append(code) }
        case let .list(list):
            render(list, into: &out, depth: depth)
        case let .quote(children):
            out.styled(.quote) { quoted in
                for child in children { render(child, into: &quoted, depth: depth) }
            }
        case let .table(table):
            render(table, into: &out)
        case .rule:
            out.append("———")
        }
        out.endBlock()
    }

    private static func render(_ list: MarkdownList, into out: inout Builder, depth: Int) {
        let indent = String(repeating: "    ", count: depth)
        for (index, item) in list.items.enumerated() {
            let marker: String = switch item.task {
            case .checked: "☑ "
            case .unchecked: "☐ "
            case .none: list.ordered ? "\(list.start + index). " : "• "
            }
            out.append(indent + marker)
            for (position, block) in item.blocks.enumerated() {
                if position > 0 { out.newlineIfNeeded() }
                switch block {
                case let .paragraph(inlines): render(inlines, into: &out)
                case let .list(nested): render(nested, into: &out, depth: depth + 1)
                default: render(block, into: &out, depth: depth + 1)
                }
            }
            out.newlineIfNeeded()
        }
    }

    private static func render(_ table: MarkdownTable, into out: inout Builder) {
        let rows = [table.header] + table.rows
        for (index, row) in rows.enumerated() {
            if index > 0 { out.append("\n") }
            out.append(row.map(plain).joined(separator: " | "))
        }
    }

    private static func render(_ inlines: [MarkdownInline], into out: inout Builder) {
        for inline in inlines {
            switch inline {
            case let .text(value): out.append(value)
            case let .code(value): out.styled(.code) { $0.append(value) }
            case let .emphasis(children): out.styled(.emphasis) { render(children, into: &$0) }
            case let .strong(children): out.styled(.strong) { render(children, into: &$0) }
            case let .strikethrough(children): out.styled(.strikethrough) { render(children, into: &$0) }
            case let .link(destination, children): out.styled(.link(destination)) { render(children, into: &$0) }
            case .lineBreak: out.append("\n")
            case .softBreak: out.append(" ")
            }
        }
    }

    private static func plain(_ inlines: [MarkdownInline]) -> String {
        var out = Builder()
        render(inlines, into: &out)
        return out.text
    }

    private struct Builder {
        var text = ""
        /// UTF-16 length of `text`, kept incrementally (O(1) per append).
        var length = 0
        var headings: [DocumentHeading] = []
        var runs: [DocumentStyleRun] = []

        mutating func append(_ value: String) {
            text += value
            length += value.utf16.count
        }

        mutating func styled(_ style: DocumentStyle, _ body: (inout Self) -> Void) {
            let start = length
            body(&self)
            if length > start {
                runs.append(DocumentStyleRun(location: start, length: length - start, style: style))
            }
        }

        mutating func newlineIfNeeded() {
            if !text.isEmpty, !text.hasSuffix("\n") { append("\n") }
        }

        /// Every block ends with one blank line.
        mutating func endBlock() {
            guard !text.isEmpty, !text.hasSuffix("\n\n") else { return }
            append(text.hasSuffix("\n") ? "\n" : "\n\n")
        }
    }
}
```

Notes:
- A nested block inside a quote also calls `endBlock()`, so a quote renders as paragraphs separated by blank lines — the same shape as top-level text, which keeps anchors stable when the owner quotes a quoted paragraph.
- If `testListsGetMarkersAndTaskBoxes` shows an extra blank line between items, it comes from a "loose" list (cmark-gfm wraps each item's text in a paragraph either way; the `.paragraph` branch in the item loop renders it inline, so only nested non-paragraph blocks call `endBlock`) — fix the renderer, not the expected string.

- [ ] **Step 6: Run — PASS**

```bash
make test-swift FILTER=CommentAnchorTests > /tmp/p15a.log 2>&1; echo "exit=$?"
make test-swift FILTER=DocumentRenderingTests > /tmp/p15b.log 2>&1; echo "exit=$?"
make test-swift FILTER=ProjectQueriesTests > /tmp/p15c.log 2>&1; echo "exit=$?"
make lint-swift > /tmp/p15-lint.log 2>&1; echo "exit=$?"
```
Expected: every `exit=0`. Then a bounded mutation check on the committed-to-be code (once, at the end of the task): temporarily change `best > 0` to `best >= 0` in `pick` and confirm `testDuplicatesWithNoMatchingContextAreOutdated` fails; change `exact.isEmpty ? … : exact` to always use `exact` and confirm `testWhitespaceReflowStillLocates` fails; revert both (`git diff` clean for that file afterwards).

- [ ] **Step 7: Commit**

```bash
git add WatchtowerDesktop/Sources/WatchtowerCore/Services/CommentAnchor.swift \
        WatchtowerDesktop/Sources/WatchtowerCore/Services/DocumentRendering.swift \
        WatchtowerDesktop/Tests/Core/CommentAnchorTests.swift \
        WatchtowerDesktop/Tests/Core/DocumentRenderingTests.swift
git commit -m "$(cat <<'EOF'
feat(desktop): text-anchored comment anchors on rendered documents

CommentAnchor takes the quote, 64 characters of context and the nearest
heading on a document's rendered plain text, and re-locates it on a revised
file: exact match, then whitespace-reflow match, duplicates ranked by
surrounding context; a lost or ambiguous quote is outdated, never guessed.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Lo9jbbmXQcr3qHo5f3pLD8
EOF
)"
```

---
### Task 16: Documents pane with inline comments

**Depends on:** Tasks 13, 14, 15.

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Models/Project.swift` (add `ProjectDocumentListItem`)
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ProjectQueries.swift` (add `documentListItems`)
- Create: `WatchtowerDesktop/Sources/Services/DocumentFileWatcher.swift`
- Create: `WatchtowerDesktop/Sources/ViewModels/ProjectDocumentViewModel.swift`
- Modify: `WatchtowerDesktop/Sources/ViewModels/ProjectsViewModel.swift` (documents list, open document)
- Create: `WatchtowerDesktop/Sources/Views/Projects/DocumentTextView.swift` (+ `DocumentAttributedString`)
- Create: `WatchtowerDesktop/Sources/Views/Projects/CommentThreadView.swift`
- Create: `WatchtowerDesktop/Sources/Views/Projects/ProjectDocumentsView.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Projects/ProjectPageView.swift` (`.documents` pane)
- Test: `WatchtowerDesktop/Tests/Core/ProjectQueriesTests.swift` (one test added), `WatchtowerDesktop/Tests/ProjectDocumentViewModelTests.swift`, `WatchtowerDesktop/Tests/DocumentAttributedStringTests.swift`, `WatchtowerDesktop/Tests/ProjectsViewModelTests.swift` (two tests added)

**Interfaces:**
- Consumes: Task 13 queries, Task 15 `CommentAnchor`/`DocumentRendering`, Task 14 `ProjectsViewModel.onOwnerWrite`/`pendingDocumentID`/`markDocumentViewed`.
- Produces:
  - Core: `struct ProjectDocumentListItem { document: ProjectDocument; targetTitle: String?; openComments: Int; id }`, `ProjectQueries.documentListItems(_:projectID:) -> [ProjectDocumentListItem]`.
  - App: `@MainActor @Observable final class ProjectDocumentViewModel` — `project`, `document`, `rendered`, `threads`, `openThreads`, `resolvedThreads`, `outdatedThreads`, `anchoredRanges: [Int64: NSRange]`, `loadError`, `errorMessage`, `onOwnerWrite: ((ProjectSubject) -> Void)?`, `load()`, `addComment(body:selection:)`, `reply(to:body:)`, `resolve(_:)`, `reopen(_:)`, `threadID(at:)`, `startWatching()`, `stopWatching()`, `fileDidChange()`, `pendingReload`.
  - App: `ProjectsViewModel` + `documents: [ProjectDocumentListItem]`, `documentViewModel: ProjectDocumentViewModel?`, `loadDocuments()`, `openDocument(_:)`, `closeDocument()`.
  - App views: `DocumentTextView(text:selection:onClick:)`, `DocumentAttributedString.make(_:highlights:activeThreadID:)`, `CommentThreadView(thread:isActive:onReply:onResolve:onReopen:)` (reused by Task 19 for target threads), `ProjectDocumentsView(vm:)`.

**Rules (spec §6.3, PROJ-03):**
- The file is read (and watched) only — never written, never created. Every owner action is a DB write through `ProjectQueries`, and every one of them calls `onOwnerWrite(.document(id))`, including the automatic "mark outdated" (a Desktop write that can drop a document's open-owner-comment count to 0 — it must not be reported as "All comments answered").
- Re-anchor on every load: open and resolved threads with an anchor are located on the rendered text; an **open** thread whose quote is lost is set `outdated` (one write for all of them); a resolved one simply loses its highlight; an outdated thread stays outdated (the owner may Reopen it; the next load re-anchors or re-outdates it).
- An unreadable or missing file is a load error: threads are listed, **no status changes**.
- File changes are debounced (500 ms after the last event) before the reload, so a load never re-anchors against a half-written file.

- [ ] **Step 1: Failing Core test for the document list**

Append to `WatchtowerDesktop/Tests/Core/ProjectQueriesTests.swift` (inside the class):

```swift
    func testDocumentListItemsCarryTheLinkedTargetAndOpenOwnerThreads() throws {
        try db.write { d in
            let p = try TestDatabase.insertProject(d)
            let t = try TestDatabase.insertProjectTarget(d, projectID: p, text: "Payments feature")
            let linked = try TestDatabase.insertProjectDocument(d, projectID: p, relPath: "docs/plan.md", targetID: t, updatedAt: "2026-09-29T11:00:00Z")
            let loose = try TestDatabase.insertProjectDocument(d, projectID: p, relPath: "docs/notes.md", updatedAt: "2026-09-29T10:00:00Z")
            let root = try TestDatabase.insertProjectComment(d, projectID: p, author: "owner", documentID: linked, quote: "x")
            _ = try TestDatabase.insertProjectComment(d, projectID: p, author: "owner", documentID: linked, status: "resolved", quote: "y")
            _ = try TestDatabase.insertProjectComment(d, projectID: p, documentID: linked, parentID: root)

            let items = try ProjectQueries.documentListItems(d, projectID: p)
            XCTAssertEqual(items.map(\.id), [linked, loose])
            XCTAssertEqual(items[0].targetTitle, "Payments feature")
            XCTAssertEqual(items[0].openComments, 1, "open owner roots only — not resolved roots, not replies")
            XCTAssertNil(items[1].targetTitle)
            XCTAssertEqual(items[1].openComments, 0)
        }
    }
```

Run: `make test-swift FILTER=ProjectQueriesTests > /tmp/p16a.log 2>&1; echo "exit=$?"` → `exit≠0` (`documentListItems` missing).

- [ ] **Step 2: Implement the list item + query**

Append to `WatchtowerDesktop/Sources/WatchtowerCore/Models/Project.swift`:

```swift
/// A row of the Documents pane's list.
package struct ProjectDocumentListItem: Identifiable, Equatable, Sendable {
    package let document: ProjectDocument
    package let targetTitle: String?
    /// Open owner threads (roots) on the document.
    package let openComments: Int

    package var id: Int64 { document.id }
}
```

Add to `ProjectQueries` (under `// MARK: - Documents`):

```swift
    package static func documentListItems(_ db: Database, projectID: Int64) throws -> [ProjectDocumentListItem] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT d.*, t.text AS target_title,
                   (SELECT COUNT(*) FROM project_comments c
                    WHERE c.document_id = d.id AND c.parent_id IS NULL
                      AND c.author = 'owner' AND c.status = 'open') AS open_comments
            FROM project_documents d
            LEFT JOIN targets t ON t.id = d.target_id
            WHERE d.project_id = ?
            ORDER BY d.updated_at DESC, d.id DESC
            """, arguments: [projectID])
        return rows.map { row in
            ProjectDocumentListItem(
                document: ProjectDocument(row: row),
                targetTitle: row["target_title"],
                openComments: row["open_comments"]
            )
        }
    }
```

Run: `make test-swift FILTER=ProjectQueriesTests > /tmp/p16a.log 2>&1; echo "exit=$?"` → `exit=0`.

- [ ] **Step 3: Failing tests for `ProjectDocumentViewModel`**

Create `WatchtowerDesktop/Tests/ProjectDocumentViewModelTests.swift`:

```swift
import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class ProjectDocumentViewModelTests: XCTestCase {
    private var pool: DatabasePool!
    private var dbPath: String!
    private var folder: URL!
    private var fileURL: URL!
    private var project: Project!
    private var document: ProjectDocument!

    private let plan = """
    # Plan

    ## Task 1

    Keep the retry budget small so a flaky service cannot stall the sync.

    ## Task 2

    Write the migration tests.
    """

    override func setUpWithError() throws {
        (pool, dbPath) = try TestDatabase.createPool()
        // A folder name with a space and non-ASCII (index Review Focus #1).
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wt project ü \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("docs"), withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("docs/plan.md")
        try plan.write(to: fileURL, atomically: true, encoding: .utf8)
        let ids = try pool.write { d -> (Int64, Int64) in
            let p = try TestDatabase.insertProject(d, folder: folder.path)
            return (p, try TestDatabase.insertProjectDocument(d, projectID: p, relPath: "docs/plan.md", title: "Plan"))
        }
        project = try pool.read { try ProjectQueries.fetch($0, id: ids.0) }
        document = try pool.read { try ProjectQueries.document($0, id: ids.1) }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        TestDatabase.cleanup(path: dbPath)
        super.tearDown()
    }

    private func makeVM() -> ProjectDocumentViewModel {
        ProjectDocumentViewModel(dbPool: pool, project: project, document: document, reloadDelay: .milliseconds(10))
    }

    private func selection(_ needle: String, in vm: ProjectDocumentViewModel) throws -> NSRange {
        let text = try XCTUnwrap(vm.rendered?.text)
        return (text as NSString).range(of: needle)
    }

    private func status(_ id: Int64) throws -> String? {
        try pool.read { try String.fetchOne($0, sql: "SELECT status FROM project_comments WHERE id = ?", arguments: [id]) }
    }

    func testLoadRendersAnchorsThreadsAndMarksAgentRepliesRead() async throws {
        let vm = makeVM()
        await vm.load()
        await vm.addComment(body: "Why small?", selection: try selection("retry budget small", in: vm))
        let root = try XCTUnwrap(vm.threads.first?.id)
        try await pool.write { d in
            _ = try TestDatabase.insertProjectComment(d, projectID: self.project.id, body: "Because…", documentID: self.document.id, parentID: root)
        }

        await vm.load()
        XCTAssertEqual(vm.threads.first?.replies.count, 1)
        XCTAssertEqual(vm.anchoredRanges[root], try selection("retry budget small", in: vm))
        let unread = try await pool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM project_comments WHERE author = 'agent' AND read_at = ''")
        }
        XCTAssertEqual(unread, 0)
    }

    func testAddCommentAnchorsTheSelectionOnRenderedTextAndReportsAnOwnerWrite() async throws {
        let vm = makeVM()
        var writes: [ProjectSubject] = []
        vm.onOwnerWrite = { writes.append($0) }
        await vm.load()
        await vm.addComment(body: "Why small?", selection: try selection("retry budget small", in: vm))

        let row = try XCTUnwrap(try await pool.read { try ProjectQueries.comments($0, documentID: self.document.id) }.first)
        XCTAssertEqual(row.author, "owner")
        XCTAssertEqual(row.anchorQuote, "retry budget small")
        XCTAssertEqual(row.anchorHeading, "Task 1")
        XCTAssertTrue(row.anchorPrefix.hasSuffix("Keep the "))
        XCTAssertTrue(row.anchorSuffix.hasPrefix(" so a flaky"))
        XCTAssertEqual(writes, [.document(document.id)])
    }

    func testEmptySelectionOrBodyWritesNothing() async throws {
        let vm = makeVM()
        await vm.load()
        await vm.addComment(body: "x", selection: NSRange(location: 3, length: 0))
        await vm.addComment(body: "   ", selection: try selection("retry", in: vm))
        let count = try await pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM project_comments") }
        XCTAssertEqual(count, 0)
    }

    func testLostOpenThreadIsMarkedOutdatedAndCountsAsAnOwnerWrite() async throws {
        let vm = makeVM()
        await vm.load()
        await vm.addComment(body: "Why small?", selection: try selection("retry budget small", in: vm))
        let root = try XCTUnwrap(vm.threads.first?.id)
        var writes: [ProjectSubject] = []
        vm.onOwnerWrite = { writes.append($0) }

        try plan.replacingOccurrences(of: "Keep the retry budget small so a flaky service cannot stall the sync.", with: "Rewritten.")
            .write(to: fileURL, atomically: true, encoding: .utf8)
        await vm.load()

        XCTAssertEqual(try status(root), "outdated")
        XCTAssertNil(vm.anchoredRanges[root])
        XCTAssertEqual(vm.outdatedThreads.map(\.id), [root])
        XCTAssertEqual(writes, [.document(document.id)], "the Desktop's own write — never reported as an agent answer")
    }

    func testReflowedParagraphKeepsTheThreadOpen() async throws {
        let vm = makeVM()
        await vm.load()
        await vm.addComment(body: "Why small?", selection: try selection("retry budget small", in: vm))
        let root = try XCTUnwrap(vm.threads.first?.id)
        try plan.replacingOccurrences(of: "Keep the retry budget small", with: "Keep the retry\nbudget   small")
            .write(to: fileURL, atomically: true, encoding: .utf8)
        await vm.load()
        XCTAssertEqual(try status(root), "open")
        XCTAssertNotNil(vm.anchoredRanges[root])
    }

    func testResolvedThreadWhoseQuoteIsLostStaysResolved() async throws {
        let vm = makeVM()
        await vm.load()
        await vm.addComment(body: "Why small?", selection: try selection("retry budget small", in: vm))
        let root = try XCTUnwrap(vm.threads.first?.id)
        await vm.resolve(root)
        try "# Plan\n\nAll new.".write(to: fileURL, atomically: true, encoding: .utf8)
        await vm.load()
        XCTAssertEqual(try status(root), "resolved")
        XCTAssertEqual(vm.resolvedThreads.map(\.id), [root])
    }

    func testMissingFileIsALoadErrorAndChangesNoStatus() async throws {
        let vm = makeVM()
        await vm.load()
        await vm.addComment(body: "Why small?", selection: try selection("retry budget small", in: vm))
        let root = try XCTUnwrap(vm.threads.first?.id)
        try FileManager.default.removeItem(at: fileURL)
        await vm.load()
        XCTAssertNotNil(vm.loadError)
        XCTAssertNil(vm.rendered)
        XCTAssertEqual(try status(root), "open")
        XCTAssertEqual(vm.threads.map(\.id), [root])
    }

    func testReplyResolveReopenWriteAndReportEachTime() async throws {
        let vm = makeVM()
        await vm.load()
        await vm.addComment(body: "Why small?", selection: try selection("retry budget small", in: vm))
        let root = try XCTUnwrap(vm.threads.first?.id)
        var writes = 0
        vm.onOwnerWrite = { _ in writes += 1 }

        await vm.reply(to: root, body: "Also: which service?")
        await vm.resolve(root)
        XCTAssertEqual(try status(root), "resolved")
        await vm.reopen(root)
        XCTAssertEqual(try status(root), "open")
        XCTAssertEqual(vm.threads.first?.replies.map(\.body), ["Also: which service?"])
        XCTAssertEqual(writes, 3)
    }

    func testThreadIDAtALocationInsideItsHighlight() async throws {
        let vm = makeVM()
        await vm.load()
        let range = try selection("retry budget small", in: vm)
        await vm.addComment(body: "Why small?", selection: range)
        let root = try XCTUnwrap(vm.threads.first?.id)
        XCTAssertEqual(vm.threadID(at: range.location + 2), root)
        XCTAssertNil(vm.threadID(at: 0))
    }

    func testFileChangeReloadsAfterTheDebounce() async throws {
        let vm = makeVM()
        await vm.load()
        try (plan + "\n\n## Task 3\n\nNew task.").write(to: fileURL, atomically: true, encoding: .utf8)
        vm.fileDidChange()
        vm.fileDidChange()   // a burst of events collapses into one reload
        await vm.pendingReload?.value
        XCTAssertTrue(vm.rendered?.text.contains("New task.") == true)
    }

    /// BEHAVIOR PROJ-03 — see docs/inventory/projects.md
    func testProj03DesktopNeverWritesTheDocument() async throws {
        let before = try Data(contentsOf: fileURL)
        let modified = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
        let vm = makeVM()
        vm.startWatching()
        await vm.load()
        await vm.addComment(body: "Why small?", selection: try selection("retry budget small", in: vm))
        let root = try XCTUnwrap(vm.threads.first?.id)
        await vm.reply(to: root, body: "More")
        await vm.resolve(root)
        await vm.reopen(root)
        vm.stopWatching()
        XCTAssertEqual(try Data(contentsOf: fileURL), before)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date, modified)
    }
}
```

Add two tests to `WatchtowerDesktop/Tests/ProjectsViewModelTests.swift` (inside the class):

```swift
    func testOpenDocumentMarksItViewedAndKeepsItsViewModelAcrossPaneSwitches() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("docs"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "# Plan".write(to: folder.appendingPathComponent("docs/plan.md"), atomically: true, encoding: .utf8)
        let p = try await pool.write { d -> Int64 in
            let p = try TestDatabase.insertProject(d, folder: folder.path)
            _ = try TestDatabase.insertProjectDocument(d, projectID: p)
            return p
        }
        let vm = makeVM()
        await vm.reload()
        vm.selectedProjectID = p
        await vm.loadDocuments()
        let doc = try XCTUnwrap(vm.documents.first?.document)

        await vm.openDocument(doc)
        let opened = try XCTUnwrap(vm.documentViewModel)
        XCTAssertFalse(vm.isRevised(doc))
        vm.pane = .terminal
        vm.pane = .documents
        XCTAssertTrue(vm.documentViewModel === opened)
        XCTAssertEqual(opened.rendered?.text, "Plan\n\n")
        vm.closeDocument()
    }

    func testSwitchingProjectClosesTheOpenDocument() async throws {
        let (p1, p2) = try await pool.write { d -> (Int64, Int64) in
            let p1 = try TestDatabase.insertProject(d, name: "one", folder: "/tmp/one")
            _ = try TestDatabase.insertProjectDocument(d, projectID: p1)
            return (p1, try TestDatabase.insertProject(d, name: "two", folder: "/tmp/two"))
        }
        let vm = makeVM()
        await vm.reload()
        vm.selectedProjectID = p1
        await vm.loadDocuments()
        await vm.openDocument(try XCTUnwrap(vm.documents.first?.document))
        XCTAssertNotNil(vm.documentViewModel)
        vm.selectedProjectID = p2
        XCTAssertNil(vm.documentViewModel)
    }
```

- [ ] **Step 4: Run — expect a compile failure**

Run: `make test-swift FILTER=ProjectDocumentViewModelTests > /tmp/p16b.log 2>&1; echo "exit=$?"` → `exit≠0`, `cannot find 'ProjectDocumentViewModel'`.

- [ ] **Step 5: Implement `DocumentFileWatcher`**

Create `WatchtowerDesktop/Sources/Services/DocumentFileWatcher.swift`:

```swift
import Foundation

/// Watches one file for changes with a vnode `DispatchSource` (no polling,
/// no TCC-sensitive API beyond reading the file itself). Editors and Claude
/// Code often replace a file atomically (write a temp file, rename it over),
/// which deletes the watched inode — the watcher then re-opens the path, and
/// while the path is missing it retries every `retryInterval`.
@MainActor
final class DocumentFileWatcher {
    private let path: String
    private let retryInterval: TimeInterval
    private let onChange: @MainActor () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var stopped = false

    init(url: URL, retryInterval: TimeInterval = 2, onChange: @escaping @MainActor () -> Void) {
        path = url.path
        self.retryInterval = retryInterval
        self.onChange = onChange
        arm()
    }

    func stop() {
        stopped = true
        source?.cancel()
        source = nil
    }

    private func arm() {
        source?.cancel()
        source = nil
        guard !stopped else { return }
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + retryInterval) { [weak self] in
                MainActor.assumeIsolated { self?.arm() }
            }
            return
        }
        let watched = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .attrib],
            queue: .main
        )
        watched.setEventHandler { [weak self, weak watched] in
            MainActor.assumeIsolated {
                guard let self, let watched else { return }
                let events = watched.data
                self.onChange()
                if events.contains(.delete) || events.contains(.rename) { self.arm() }
            }
        }
        watched.setCancelHandler { close(descriptor) }
        source = watched
        watched.resume()
    }
}
```

- [ ] **Step 6: Implement `ProjectDocumentViewModel`**

Create `WatchtowerDesktop/Sources/ViewModels/ProjectDocumentViewModel.swift`:

```swift
import Foundation
import GRDB
import Observation
import WatchtowerCore

/// One open project document: its rendered text, its comment threads and
/// their anchors (spec §6.3). Owned by `ProjectsViewModel`, so it outlives
/// pane switches. Reads and watches the file; never writes it (PROJ-03).
@MainActor
@Observable
final class ProjectDocumentViewModel {
    let project: Project
    private(set) var document: ProjectDocument
    private(set) var rendered: RenderedDocument?
    private(set) var threads: [ProjectCommentThread] = []
    /// Root comment id → its located range in `rendered.text`.
    private(set) var anchoredRanges: [Int64: NSRange] = [:]
    private(set) var loadError: String?
    var errorMessage: String?
    /// The reload a file change scheduled (exposed for tests).
    private(set) var pendingReload: Task<Void, Never>?

    var onOwnerWrite: ((ProjectSubject) -> Void)?

    private let dbPool: DatabasePool
    private let readFile: (URL) throws -> String
    private let reloadDelay: Duration
    private var watcher: DocumentFileWatcher?

    init(
        dbPool: DatabasePool,
        project: Project,
        document: ProjectDocument,
        reloadDelay: Duration = .milliseconds(500),
        readFile: @escaping (URL) throws -> String = { try String(contentsOf: $0, encoding: .utf8) }
    ) {
        self.dbPool = dbPool
        self.project = project
        self.document = document
        self.reloadDelay = reloadDelay
        self.readFile = readFile
    }

    var openThreads: [ProjectCommentThread] {
        threads.filter { $0.root.status == "open" }
            .sorted { (anchoredRanges[$0.id]?.location ?? .max) < (anchoredRanges[$1.id]?.location ?? .max) }
    }

    var resolvedThreads: [ProjectCommentThread] { threads.filter { $0.root.status == "resolved" } }
    var outdatedThreads: [ProjectCommentThread] { threads.filter { $0.root.status == "outdated" } }

    func threadID(at location: Int) -> Int64? {
        anchoredRanges.first { NSLocationInRange(location, $0.value) }?.key
    }

    // MARK: - Loading

    func load() async {
        let id = document.id
        do {
            let (fresh, comments) = try await dbPool.read { db in
                (try ProjectQueries.document(db, id: id), try ProjectQueries.comments(db, documentID: id))
            }
            if let fresh { document = fresh }
            threads = ProjectCommentThread.group(comments)
        } catch {
            errorMessage = "Could not load comments: \(error.localizedDescription)"
            return
        }
        guard let text = readDocumentText() else { return }
        let doc = DocumentRendering.render(text)
        rendered = doc
        let lost = reanchor(on: doc.text)
        if !lost.isEmpty { await markOutdated(lost) }
        await markRepliesRead()
    }

    private func readDocumentText() -> String? {
        do {
            let text = try readFile(document.fileURL(in: project))
            loadError = nil
            return text
        } catch {
            rendered = nil
            anchoredRanges = [:]
            loadError = "Could not read \(document.relPath): \(error.localizedDescription)"
            return nil
        }
    }

    /// Locates every anchored open/resolved root; returns the open ones lost.
    private func reanchor(on text: String) -> [Int64] {
        var ranges: [Int64: NSRange] = [:]
        var lost: [Int64] = []
        for thread in threads where thread.root.status != "outdated" {
            guard let anchor = thread.root.anchor else { continue }
            if let found = anchor.locate(in: text) {
                ranges[thread.id] = NSRange(found, in: text)
            } else if thread.root.isOpen {
                lost.append(thread.id)
            }
        }
        anchoredRanges = ranges
        return lost
    }

    private func markOutdated(_ ids: [Int64]) async {
        do {
            try await dbPool.write { db in
                for id in ids { try ProjectQueries.setStatus(db, commentID: id, status: "outdated") }
            }
            onOwnerWrite?(.document(document.id))
            await reloadThreads()
        } catch {
            errorMessage = "Could not mark lost comments outdated: \(error.localizedDescription)"
        }
    }

    private func markRepliesRead() async {
        let hasUnread = threads.contains { thread in
            thread.root.isUnreadForOwner || thread.replies.contains(where: \.isUnreadForOwner)
        }
        guard hasUnread else { return }
        let (projectID, documentID) = (project.id, document.id)
        do {
            try await dbPool.write { db in
                try ProjectQueries.markAgentCommentsRead(db, projectID: projectID, targetID: nil, documentID: documentID)
            }
            await reloadThreads()
        } catch {
            errorMessage = "Could not mark replies read: \(error.localizedDescription)"
        }
    }

    private func reloadThreads() async {
        let id = document.id
        do {
            let comments = try await dbPool.read { try ProjectQueries.comments($0, documentID: id) }
            threads = ProjectCommentThread.group(comments)
        } catch {
            errorMessage = "Could not reload comments: \(error.localizedDescription)"
        }
    }

    // MARK: - Owner actions

    func addComment(body: String, selection: NSRange) async {
        guard let rendered, selection.length > 0,
              let range = Range(selection, in: rendered.text),
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let anchor = CommentAnchor.make(text: rendered.text, range: range, headings: rendered.headingOffsets)
        let (projectID, documentID) = (project.id, document.id)
        await ownerWrite { db in
            _ = try ProjectQueries.addOwnerComment(
                db, projectID: projectID, targetID: nil, documentID: documentID, anchor: anchor, body: body
            )
        }
        anchoredRanges = anchoredRangesAfterAdd(rendered.text)
    }

    func reply(to rootID: Int64, body: String) async {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await ownerWrite { db in _ = try ProjectQueries.reply(db, to: rootID, body: body) }
    }

    func resolve(_ rootID: Int64) async {
        await ownerWrite { db in try ProjectQueries.setStatus(db, commentID: rootID, status: "resolved") }
    }

    func reopen(_ rootID: Int64) async {
        await ownerWrite { db in try ProjectQueries.setStatus(db, commentID: rootID, status: "open") }
    }

    private func ownerWrite(_ write: @escaping @Sendable (Database) throws -> Void) async {
        do {
            try await dbPool.write(write)
            errorMessage = nil
            onOwnerWrite?(.document(document.id))
            await reloadThreads()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func anchoredRangesAfterAdd(_ text: String) -> [Int64: NSRange] {
        var ranges = anchoredRanges
        for thread in threads where ranges[thread.id] == nil && thread.root.isOpen {
            if let found = thread.root.anchor?.locate(in: text) { ranges[thread.id] = NSRange(found, in: text) }
        }
        return ranges
    }

    // MARK: - Watching

    func startWatching() {
        guard watcher == nil else { return }
        watcher = DocumentFileWatcher(url: document.fileURL(in: project)) { [weak self] in
            self?.fileDidChange()
        }
    }

    func stopWatching() {
        watcher?.stop()
        watcher = nil
        pendingReload?.cancel()
        pendingReload = nil
    }

    /// Debounced: a burst of vnode events becomes one reload `reloadDelay`
    /// after the last one, so a half-written file is never re-anchored.
    func fileDidChange() {
        pendingReload?.cancel()
        let delay = reloadDelay
        pendingReload = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.load()
        }
    }
}
```

`anchoredRangesAfterAdd` gives the new thread its highlight without a full reload (a full `load()` would re-read the file — fine too, but the owner just made the selection on the text already on screen).

- [ ] **Step 7: `ProjectsViewModel` — documents list + open document**

In `WatchtowerDesktop/Sources/ViewModels/ProjectsViewModel.swift`:

Replace `var selectedProjectID: Int64?` with:

```swift
    var selectedProjectID: Int64? {
        didSet {
            if selectedProjectID != oldValue {
                closeDocument()
                documents = []
            }
        }
    }
```

Add stored properties after `installStatus`:

```swift
    private(set) var documents: [ProjectDocumentListItem] = []
    /// The open document. Kept here (not in the view) so it survives pane
    /// switches and tab changes with its watcher running.
    private(set) var documentViewModel: ProjectDocumentViewModel?
```

Add methods:

```swift
    func loadDocuments() async {
        guard let projectID = selectedProjectID else { return }
        do {
            documents = try await dbPool.read { try ProjectQueries.documentListItems($0, projectID: projectID) }
        } catch {
            errorMessage = "Could not load documents: \(error.localizedDescription)"
        }
    }

    func openDocument(_ document: ProjectDocument) async {
        guard let project = selectedProject, project.id == document.projectID else { return }
        if documentViewModel?.document.id != document.id {
            closeDocument()
            let docVM = ProjectDocumentViewModel(dbPool: dbPool, project: project, document: document)
            docVM.onOwnerWrite = { [weak self] subject in self?.onOwnerWrite?(project.id, subject) }
            docVM.startWatching()
            documentViewModel = docVM
        }
        await documentViewModel?.load()
        if let loaded = documentViewModel?.document { markDocumentViewed(loaded) }
        await loadDocuments()
        await reload()
    }

    func closeDocument() {
        documentViewModel?.stopWatching()
        documentViewModel = nil
    }
```

- [ ] **Step 8: Views**

Create `WatchtowerDesktop/Sources/Views/Projects/DocumentTextView.swift`:

```swift
import AppKit
import SwiftUI
import WatchtowerCore

/// Rendered document → `NSAttributedString`: fonts per style run, then a
/// yellow background on every anchored thread (stronger on the active one).
enum DocumentAttributedString {
    static let bodyFont = NSFont.systemFont(ofSize: 14)
    static let highlight = NSColor.systemYellow.withAlphaComponent(0.25)
    static let activeHighlight = NSColor.systemYellow.withAlphaComponent(0.55)

    static func make(_ doc: RenderedDocument, highlights: [Int64: NSRange], activeThreadID: Int64?) -> NSAttributedString {
        let out = NSMutableAttributedString(
            string: doc.text,
            attributes: [.font: bodyFont, .foregroundColor: NSColor.labelColor]
        )
        let length = out.length
        for run in doc.runs where run.location + run.length <= length {
            out.addAttributes(attributes(for: run.style), range: NSRange(location: run.location, length: run.length))
        }
        for (id, range) in highlights where NSMaxRange(range) <= length {
            out.addAttribute(.backgroundColor, value: id == activeThreadID ? activeHighlight : highlight, range: range)
        }
        return out
    }

    static func attributes(for style: DocumentStyle) -> [NSAttributedString.Key: Any] {
        switch style {
        case let .heading(level):
            [.font: NSFont.systemFont(ofSize: level == 1 ? 22 : level == 2 ? 18 : 15, weight: .semibold)]
        case .strong:
            [.font: NSFont.boldSystemFont(ofSize: 14)]
        case .emphasis:
            [.font: NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)]
        case .strikethrough:
            [.strikethroughStyle: NSUnderlineStyle.single.rawValue]
        case .code, .codeBlock:
            [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
             .backgroundColor: NSColor.quaternaryLabelColor]
        case .quote:
            [.foregroundColor: NSColor.secondaryLabelColor]
        case .link:
            // Styled only: a click selects text for commenting, it never opens
            // a URL from a document the agent wrote.
            [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        }
    }
}

/// A read-only, selectable `NSTextView` (SwiftUI `Text` cannot report a
/// selection range). Reports the selection, and a zero-length click's
/// location so the pane can open the thread under it.
struct DocumentTextView: NSViewRepresentable {
    let text: NSAttributedString
    @Binding var selection: NSRange
    let onClick: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 20, height: 16)
        textView.delegate = context.coordinator
        context.coordinator.apply(text, to: textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.apply(text, to: textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: DocumentTextView
        private var shown: NSAttributedString?
        private var applying = false

        init(parent: DocumentTextView) {
            self.parent = parent
        }

        /// Replaces the text only when it changed, keeping the selection and
        /// scroll position (a highlight change re-renders the same text).
        func apply(_ text: NSAttributedString, to textView: NSTextView) {
            guard shown !== text else { return }
            shown = text
            applying = true
            let selected = textView.selectedRange()
            let visible = textView.visibleRect
            textView.textStorage?.setAttributedString(text)
            if NSMaxRange(selected) <= text.length { textView.setSelectedRange(selected) }
            textView.scrollToVisible(visible)
            applying = false
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !applying, let textView = notification.object as? NSTextView else { return }
            let range = textView.selectedRange()
            DispatchQueue.main.async { [parent] in
                parent.selection = range
                if range.length == 0 { parent.onClick(range.location) }
            }
        }
    }
}
```

The selection is published on the next main-queue turn: `textViewDidChangeSelection` can fire inside a SwiftUI update pass (e.g. from `setSelectedRange` of another code path), and writing a `@Binding` there is the "modifying state during view update" warning.

Create `WatchtowerDesktop/Sources/Views/Projects/CommentThreadView.swift`:

```swift
import SwiftUI
import WatchtowerCore

/// One comment thread: the quote (document threads), root + replies, and the
/// owner's reply / resolve / reopen. No document state — Task 19 reuses it for
/// target threads.
struct CommentThreadView: View {
    let thread: ProjectCommentThread
    var isActive = false
    let onReply: (String) async -> Void
    let onResolve: () async -> Void
    let onReopen: () async -> Void
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !thread.root.anchorQuote.isEmpty {
                Text("\u{201C}\(thread.root.anchorQuote)\u{201D}")
                    .font(.caption).italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            ForEach([thread.root] + thread.replies) { comment in
                VStack(alignment: .leading, spacing: 2) {
                    Text(author(comment)).font(.caption).fontWeight(.semibold)
                    Text(comment.body).font(.callout).textSelection(.enabled)
                }
            }
            if thread.root.status != "open" {
                Text(thread.root.status == "resolved" ? "Resolved" : "Outdated — the quoted text changed")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            TextField("Reply", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
            HStack {
                Button("Reply") {
                    let text = draft
                    draft = ""
                    Task { await onReply(text) }
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
                if thread.root.status == "open" {
                    Button("Resolve") { Task { await onResolve() } }
                } else {
                    Button("Reopen") { Task { await onReopen() } }
                }
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.yellow.opacity(0.15) : Color(nsColor: .controlBackgroundColor))
        )
    }

    private func author(_ comment: ProjectComment) -> String {
        guard comment.isAgent else { return "You" }
        return comment.agentLabel.isEmpty ? "Agent" : comment.agentLabel
    }
}
```

Create `WatchtowerDesktop/Sources/Views/Projects/ProjectDocumentsView.swift`:

```swift
import SwiftUI
import WatchtowerCore

/// Documents pane (spec §6.3): attached documents on the left, the open one
/// in the middle as selectable text, its threads on the right.
struct ProjectDocumentsView: View {
    @Bindable var vm: ProjectsViewModel
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var activeThreadID: Int64?
    @State private var composing = false
    @State private var draft = ""

    var body: some View {
        HSplitView {
            list.frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
            if let docVM = vm.documentViewModel {
                documentView(docVM).frame(minWidth: 360, maxWidth: .infinity)
                threads(docVM).frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
            } else {
                Text(vm.documents.isEmpty
                     ? "No documents yet. Claude Code attaches specs and plans here as it writes them."
                     : "Select a document.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: vm.selectedProjectID) {
            await vm.loadDocuments()
            await openPending()
        }
        .onChange(of: vm.pendingDocumentID) { _, _ in Task { await openPending() } }
    }

    private var list: some View {
        List(vm.documents, selection: Binding(
            get: { vm.documentViewModel?.document.id },
            set: { id in
                guard let item = vm.documents.first { $0.id == id } else { return }
                Task { await vm.openDocument(item.document) }
            }
        )) { item in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.document.displayTitle)
                    Text([item.document.kind, item.targetTitle].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if vm.isRevised(item.document) {
                    Circle().fill(Color.blue).frame(width: 6, height: 6).help("Revised since you last opened it")
                }
                if item.openComments > 0 {
                    Text("\(item.openComments)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .tag(Optional(item.id))
        }
    }

    private func documentView(_ docVM: ProjectDocumentViewModel) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(docVM.document.relPath).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Comment") { composing = true }
                    .disabled(selection.length == 0 || docVM.rendered == nil)
                    .popover(isPresented: $composing) { composer(docVM) }
            }
            .padding(8)
            Divider()
            if let rendered = docVM.rendered {
                DocumentTextView(
                    text: DocumentAttributedString.make(rendered, highlights: docVM.anchoredRanges, activeThreadID: activeThreadID),
                    selection: $selection,
                    onClick: { activeThreadID = docVM.threadID(at: $0) ?? activeThreadID }
                )
            } else {
                Text(docVM.loadError ?? "Loading…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error = docVM.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).padding(6)
            }
        }
    }

    private func composer(_ docVM: ProjectDocumentViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Comment on the selection").font(.headline)
            TextEditor(text: $draft).frame(width: 320, height: 100)
            HStack {
                Spacer()
                Button("Cancel") { composing = false }
                Button("Comment") {
                    let (text, range) = (draft, selection)
                    draft = ""
                    composing = false
                    Task { await docVM.addComment(body: text, selection: range) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
    }

    private func threads(_ docVM: ProjectDocumentViewModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(docVM.openThreads) { thread($0, docVM) }
                if !docVM.resolvedThreads.isEmpty {
                    DisclosureGroup("Resolved (\(docVM.resolvedThreads.count))") {
                        ForEach(docVM.resolvedThreads) { thread($0, docVM) }
                    }
                }
                if !docVM.outdatedThreads.isEmpty {
                    DisclosureGroup("Outdated (\(docVM.outdatedThreads.count))") {
                        ForEach(docVM.outdatedThreads) { thread($0, docVM) }
                    }
                }
            }
            .padding(10)
        }
    }

    private func thread(_ thread: ProjectCommentThread, _ docVM: ProjectDocumentViewModel) -> some View {
        CommentThreadView(
            thread: thread,
            isActive: thread.id == activeThreadID,
            onReply: { await docVM.reply(to: thread.id, body: $0) },
            onResolve: { await docVM.resolve(thread.id) },
            onReopen: { await docVM.reopen(thread.id) }
        )
        .onTapGesture { activeThreadID = thread.id }
    }

    private func openPending() async {
        guard let id = vm.pendingDocumentID else { return }
        if vm.documents.isEmpty { await vm.loadDocuments() }
        guard let item = vm.documents.first { $0.id == id } else { return }
        vm.pendingDocumentID = nil
        await vm.openDocument(item.document)
    }
}
```

In `ProjectPageView.paneContent` replace the `.documents` case with `ProjectDocumentsView(vm: vm)`.

- [ ] **Step 9: Small test for the attributed string**

Create `WatchtowerDesktop/Tests/DocumentAttributedStringTests.swift`:

```swift
import XCTest
import AppKit
@testable import WatchtowerDesktop
import WatchtowerCore

final class DocumentAttributedStringTests: XCTestCase {
    func testHighlightsMarkAnchoredRangesAndTheActiveOneIsStronger() {
        let doc = DocumentRendering.render("# Plan\n\nKeep the retry budget small.")
        let range = (doc.text as NSString).range(of: "retry budget")
        let other = (doc.text as NSString).range(of: "small")
        let out = DocumentAttributedString.make(doc, highlights: [1: range, 2: other], activeThreadID: 1)
        XCTAssertEqual(out.string, doc.text)
        let active = out.attribute(.backgroundColor, at: range.location, effectiveRange: nil) as? NSColor
        let passive = out.attribute(.backgroundColor, at: other.location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(active, DocumentAttributedString.activeHighlight)
        XCTAssertEqual(passive, DocumentAttributedString.highlight)
        let headingFont = out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(headingFont?.pointSize, 22)
    }

    func testOutOfBoundsRangesAreIgnoredNotCrashed() {
        let doc = DocumentRendering.render("Short.")
        let out = DocumentAttributedString.make(doc, highlights: [1: NSRange(location: 3, length: 500)], activeThreadID: nil)
        XCTAssertNil(out.attribute(.backgroundColor, at: 3, effectiveRange: nil))
    }
}
```

- [ ] **Step 10: Run — PASS**

```bash
make test-swift FILTER=ProjectDocumentViewModelTests > /tmp/p16b.log 2>&1; echo "exit=$?"
make test-swift FILTER=ProjectsViewModelTests > /tmp/p16c.log 2>&1; echo "exit=$?"
make test-swift FILTER=DocumentAttributedStringTests > /tmp/p16d.log 2>&1; echo "exit=$?"
make test-swift FILTER=ProjectQueriesTests > /tmp/p16a.log 2>&1; echo "exit=$?"
make lint-swift > /tmp/p16-lint.log 2>&1; echo "exit=$?"
```
Expected: every `exit=0`. Manual smoke (no test can cover AppKit selection): `make app-dev`, open a project with an attached plan, select a sentence → Comment → the sentence turns yellow and the thread appears on the right; edit the file in another editor → within a second the view shows the new text and the thread stays on its sentence.

- [ ] **Step 11: Commit**

```bash
git add WatchtowerDesktop/Sources/WatchtowerCore/Models/Project.swift \
        WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ProjectQueries.swift \
        WatchtowerDesktop/Sources/Services/DocumentFileWatcher.swift \
        WatchtowerDesktop/Sources/ViewModels/ProjectDocumentViewModel.swift \
        WatchtowerDesktop/Sources/ViewModels/ProjectsViewModel.swift \
        WatchtowerDesktop/Sources/Views/Projects/DocumentTextView.swift \
        WatchtowerDesktop/Sources/Views/Projects/CommentThreadView.swift \
        WatchtowerDesktop/Sources/Views/Projects/ProjectDocumentsView.swift \
        WatchtowerDesktop/Sources/Views/Projects/ProjectPageView.swift \
        WatchtowerDesktop/Tests/Core/ProjectQueriesTests.swift \
        WatchtowerDesktop/Tests/ProjectDocumentViewModelTests.swift \
        WatchtowerDesktop/Tests/ProjectsViewModelTests.swift \
        WatchtowerDesktop/Tests/DocumentAttributedStringTests.swift
git commit -m "$(cat <<'EOF'
feat(desktop): project documents with inline, text-anchored comments

Attached specs and plans render as selectable text; selecting a passage
opens a comment thread anchored on the rendered text. The view watches the
file, re-anchors threads on every change and marks lost ones outdated. The
Desktop only reads the file (PROJ-03).

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Lo9jbbmXQcr3qHo5f3pLD8
EOF
)"
```

---
### Task 17: Embedded terminal (SwiftTerm)

**Depends on:** Task 14.

**Files:**
- Modify: `WatchtowerDesktop/Package.swift` (+ `WatchtowerDesktop/Package.resolved`)
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/ProjectTerminalLaunch.swift`
- Create: `WatchtowerDesktop/Sources/Services/ProjectTerminalCenter.swift` (center, session protocol, signaller, `SwiftTermSession`)
- Create: `WatchtowerDesktop/Sources/Views/Projects/ProjectTerminalView.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Projects/ProjectPageView.swift` (`.terminal` pane)
- Modify: `WatchtowerDesktop/Sources/App/AppState.swift` (`projectTerminalCenter`, `onProjectCreated` wiring)
- Modify: `WatchtowerDesktop/Sources/App/QuitCoordinator.swift`, `WatchtowerDesktop/Sources/App/TrayAppDelegate.swift` (`closeTerminals`)
- Modify: `WatchtowerDesktop/Tests/ProjectsViewModelTests.swift` (fake session in the survival test)
- Test: `WatchtowerDesktop/Tests/Core/ProjectTerminalLaunchTests.swift`, `WatchtowerDesktop/Tests/ProjectTerminalCenterTests.swift`, `WatchtowerDesktop/Tests/QuitCoordinatorTests.swift` (one test added)

**Interfaces:**
- Consumes: `Project` (Task 13), `ProjectsViewModel.onProjectCreated` (Task 14).
- Produces:
  - Core: `struct ProjectTerminalLaunch { executable: String; args: [String]; currentDirectory: String; static firstRunPrompt; static make(shell:folder:firstRun:) }`.
  - App: `@MainActor protocol ProjectTerminalSession: AnyObject { view: NSView; pid: pid_t; onExit: ((Int32?) -> Void)?; start(_:); detach() }`; `struct ProcessGroupSignaller { signal, isAlive, sleep; static live }`; `@MainActor @Observable final class ProjectTerminalCenter { enum State { running, exited(Int32?), unavailable(String) }; states; makeSession; session(for:); start(project:firstRun:); close(projectID:) async; closeAll() async }`; `final class SwiftTermSession`.
  - `AppState.projectTerminalCenter` (a `let`, no DB needed); `QuitCoordinator.shouldTerminate(… closeTerminals: …)` and `TrayAppDelegate.terminateDecision(… closeTerminals: …)`, both defaulted to `{}`.

**SwiftTerm (verified against the `v1.20.0` tag source, `Sources/SwiftTerm/Mac/MacLocalTerminalView.swift` and `LocalProcess.swift`):** latest tag `v1.20.0`; MIT license; manifest `swift-tools-version:6.0` (fine — the repo already requires a Swift 6 toolchain for FluidAudio), platform floor macOS 11. API used: `LocalProcessTerminalView(frame:)`, `.processDelegate: LocalProcessTerminalViewDelegate?` (four requirements: `sizeChanged(source:newCols:newRows:)`, `setTerminalTitle(source:title:)`, `hostCurrentDirectoryUpdate(source:directory:)`, `processTerminated(source:exitCode:)`), `startProcess(executable:args:environment:execName:currentDirectory:)`, `.process: LocalProcess!` with `.shellPid: pid_t`, `.font: NSFont`, `Terminal.getEnvironmentVariables(termName:trueColor:)`. The child is started with `forkpty` + `setsid`, so `shellPid` leads its own process group — `killpg(shellPid, …)` reaches `claude` (the shell `exec`s it, same pid) and everything it spawned in that group. Delegate callbacks arrive on the main queue (`LocalProcess` defaults `dispatchQueue` to `.main`). **Not used:** `terminate()` — it sends SIGTERM to `shellPid` unconditionally, even after the child was reaped, which could hit a reused pid.

**Teardown rule:** close = `killpg(pid, SIGHUP)`; poll every 100 ms up to 3 s while the session has not reported exit and `kill(pid, 0) == 0`; then `killpg(pid, SIGKILL)` only if still alive. Never signal a pid ≤ 0 (`killpg(0, …)` targets Watchtower's own group). Quit closes every terminal (concurrently, so quit waits ≤ ~3 s in total), after the chat sessions and before the daemon stop.

- [ ] **Step 1: Add the dependency**

In `WatchtowerDesktop/Package.swift`, add to `dependencies` (after the `swift-markdown` entry):

```swift
        // Embedded terminal for the Projects tab (Claude Code in the project
        // folder). MIT. App target only — WatchtowerCore stays AppKit-free.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.20.0"),
```

and to the `WatchtowerDesktop` executable target's `dependencies`:

```swift
                .product(name: "SwiftTerm", package: "SwiftTerm"),
```

Run: `cd WatchtowerDesktop && swift package resolve > /tmp/p17-resolve.log 2>&1; echo "exit=$?"` → `exit=0`; `git diff --stat Package.resolved` shows the new pin (`swiftterm`, `1.20.0` or a later 1.x).

- [ ] **Step 2: Failing Core test for the launch argv**

Create `WatchtowerDesktop/Tests/Core/ProjectTerminalLaunchTests.swift`:

```swift
import XCTest
@testable import WatchtowerCore

final class ProjectTerminalLaunchTests: XCTestCase {
    func testLoginShellExecsClaudeInTheFolder() {
        let launch = ProjectTerminalLaunch.make(shell: "/bin/bash", folder: "/tmp/acme dir", firstRun: false)
        XCTAssertEqual(launch.executable, "/bin/bash")
        XCTAssertEqual(launch.args, ["-l", "-c", "exec claude"])
        XCTAssertEqual(launch.currentDirectory, "/tmp/acme dir")
    }

    func testFirstRunPassesTheFixedSetupPromptSingleQuoted() {
        let launch = ProjectTerminalLaunch.make(shell: "/bin/zsh", folder: "/tmp/acme", firstRun: true)
        XCTAssertEqual(launch.args, [
            "-l", "-c", "exec claude 'Set up this Watchtower project using the watchtower-project skill.'"
        ])
        // The prompt is fixed text: no owner data, and nothing the single
        // quotes would need escaping for.
        XCTAssertFalse(ProjectTerminalLaunch.firstRunPrompt.contains("'"))
    }

    func testMissingOrRelativeShellFallsBackToZsh() {
        XCTAssertEqual(ProjectTerminalLaunch.make(shell: nil, folder: "/tmp", firstRun: false).executable, "/bin/zsh")
        XCTAssertEqual(ProjectTerminalLaunch.make(shell: "", folder: "/tmp", firstRun: false).executable, "/bin/zsh")
        XCTAssertEqual(ProjectTerminalLaunch.make(shell: "zsh", folder: "/tmp", firstRun: false).executable, "/bin/zsh")
    }
}
```

Run: `make test-swift FILTER=ProjectTerminalLaunchTests > /tmp/p17a.log 2>&1; echo "exit=$?"` → `exit≠0`.

- [ ] **Step 3: Implement `ProjectTerminalLaunch`**

Create `WatchtowerDesktop/Sources/WatchtowerCore/Services/ProjectTerminalLaunch.swift`:

```swift
import Foundation

/// How the Projects terminal starts Claude Code (spec §6.2): the owner's own
/// login shell, so `PATH` and `claude`'s auth are exactly theirs, `exec`ing
/// `claude` in the project folder. A new project gets the fixed first-run
/// prompt — never owner data on the command line.
package struct ProjectTerminalLaunch: Equatable, Sendable {
    package static let firstRunPrompt = "Set up this Watchtower project using the watchtower-project skill."
    package static let fallbackShell = "/bin/zsh"

    package let executable: String
    package let args: [String]
    package let currentDirectory: String

    package static func make(shell: String?, folder: String, firstRun: Bool) -> ProjectTerminalLaunch {
        let executable = shell.flatMap { $0.hasPrefix("/") ? $0 : nil } ?? fallbackShell
        let command = firstRun ? "exec claude '\(firstRunPrompt)'" : "exec claude"
        return Self(executable: executable, args: ["-l", "-c", command], currentDirectory: folder)
    }
}
```

Run: `make test-swift FILTER=ProjectTerminalLaunchTests > /tmp/p17a.log 2>&1; echo "exit=$?"` → `exit=0`.

- [ ] **Step 4: Failing tests for `ProjectTerminalCenter`**

Create `WatchtowerDesktop/Tests/ProjectTerminalCenterTests.swift`:

```swift
import XCTest
import AppKit
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class FakeTerminalSession: ProjectTerminalSession {
    let view = NSView()
    var pid: pid_t
    var onExit: ((Int32?) -> Void)?
    private(set) var launches: [ProjectTerminalLaunch] = []
    private(set) var detached = false

    init(pid: pid_t = 4242) {
        self.pid = pid
    }

    func start(_ launch: ProjectTerminalLaunch) { launches.append(launch) }
    func detach() { detached = true }
    func exit(_ code: Int32?) { onExit?(code) }
}

@MainActor
final class ProjectTerminalCenterTests: XCTestCase {
    private var folder: URL!
    private var sessions: [FakeTerminalSession] = []
    private var signals: [(pid_t, Int32)] = []
    private var slept: Duration = .zero
    private var alive = true
    private var exitOnHangup = true

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt term \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        sessions = []
        signals = []
        slept = .zero
        alive = true
        exitOnHangup = true
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private func project(id: Int64 = 1, folder path: String? = nil) throws -> Project {
        let queue = try TestDatabase.create()
        return try queue.write { d in
            try d.execute(sql: "INSERT INTO projects (id, name, folder_path) VALUES (?, 'acme', ?)", arguments: [id, path ?? folder.path])
            return try XCTUnwrap(ProjectQueries.fetch(d, id: id))
        }
    }

    private func makeCenter(pid: pid_t = 4242) -> ProjectTerminalCenter {
        let center = ProjectTerminalCenter(
            makeSession: { [weak self] in
                let session = FakeTerminalSession(pid: pid)
                self?.sessions.append(session)
                return session
            },
            signaller: ProcessGroupSignaller(
                signal: { [weak self] pid, sig in
                    guard let self else { return }
                    self.signals.append((pid, sig))
                    if sig == SIGHUP, self.exitOnHangup { self.sessions.last?.exit(nil) }
                    if sig == SIGKILL { self.alive = false }
                },
                isAlive: { [weak self] _ in self?.alive ?? false },
                sleep: { [weak self] step in self?.slept += step }
            )
        )
        center.shell = { "/bin/zsh" }
        return center
    }

    func testStartLaunchesTheLoginShellInTheFolder() throws {
        let center = makeCenter()
        let p = try project()
        center.start(project: p, firstRun: true)
        XCTAssertEqual(center.states[p.id], .running)
        XCTAssertEqual(sessions.first?.launches, [ProjectTerminalLaunch.make(shell: "/bin/zsh", folder: folder.path, firstRun: true)])
    }

    func testStartWhileRunningIsANoOp() throws {
        let center = makeCenter()
        let p = try project()
        center.start(project: p, firstRun: true)
        center.start(project: p, firstRun: false)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].launches.count, 1)
    }

    /// House rule: the terminal outlives the view that shows it. The view only
    /// hosts the session's NSView; tearing the host down leaves the process
    /// and its scrollback in the center, and coming back re-hosts the same one.
    func testSessionSurvivesTheViewGoingAwayAndIsReusedOnReturn() throws {
        let appState = AppState()
        appState.projectTerminalCenter.makeSession = { [weak self] in
            let session = FakeTerminalSession()
            self?.sessions.append(session)
            return session
        }
        appState.projectTerminalCenter.shell = { "/bin/zsh" }
        let center = appState.projectTerminalCenter
        let p = try project()
        appState.selectedDestination = .projects
        center.start(project: p)

        let host = NSView()
        let first = try XCTUnwrap(center.session(for: p.id))
        host.addSubview(first.view)
        first.view.removeFromSuperview()          // the pane's view is dismantled
        appState.selectedDestination = .inbox     // navigate away …
        appState.selectedDestination = .projects  // … and back

        center.start(project: p)                  // the pane asks again on appear
        XCTAssertTrue(center.session(for: p.id) === first)
        XCTAssertEqual(center.states[p.id], .running)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].launches.count, 1)
    }

    func testExitShowsExitedAndStartRelaunchesInTheSameSessionWithoutThePrompt() throws {
        let center = makeCenter()
        let p = try project()
        center.start(project: p, firstRun: true)
        sessions[0].exit(0)
        XCTAssertEqual(center.states[p.id], .exited(0))
        center.start(project: p)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].launches.last?.args, ["-l", "-c", "exec claude"])
        XCTAssertEqual(center.states[p.id], .running)
    }

    func testCloseSendsHangupThenKillOnlyWhenStillAlive() async throws {
        let center = makeCenter()
        let p = try project()

        // Polite exit: SIGHUP is enough.
        center.start(project: p)
        await center.close(projectID: p.id)
        XCTAssertEqual(signals.map(\.1), [SIGHUP])
        XCTAssertEqual(signals.map(\.0), [4242])
        XCTAssertTrue(sessions[0].detached)
        XCTAssertNil(center.states[p.id])
        XCTAssertNil(center.session(for: p.id))

        // Stubborn child: SIGKILL after the 3 s grace.
        signals = []
        exitOnHangup = false
        alive = true
        center.start(project: p)
        await center.close(projectID: p.id)
        XCTAssertEqual(signals.map(\.1), [SIGHUP, SIGKILL])
        XCTAssertEqual(slept, ProjectTerminalCenter.killGrace)
    }

    func testCloseNeverSignalsANonPositivePid() async throws {
        let center = makeCenter(pid: 0)
        let p = try project()
        center.start(project: p)
        await center.close(projectID: p.id)
        XCTAssertTrue(signals.isEmpty, "killpg(0, …) would signal Watchtower's own process group")
        XCTAssertTrue(sessions[0].detached)
    }

    func testCloseOfAnExitedSessionSendsNothing() async throws {
        let center = makeCenter()
        let p = try project()
        center.start(project: p)
        sessions[0].exit(1)
        await center.close(projectID: p.id)
        XCTAssertTrue(signals.isEmpty)
    }

    func testMissingFolderIsUnavailableAndStartsNothing() throws {
        let center = makeCenter()
        let p = try project(folder: "/tmp/does-not-exist-\(UUID().uuidString)")
        center.start(project: p, firstRun: true)
        guard case .unavailable = center.states[p.id] else {
            return XCTFail("expected unavailable, got \(String(describing: center.states[p.id]))")
        }
        XCTAssertTrue(sessions.isEmpty)
    }

    func testCloseAllClosesEverySession() async throws {
        let center = makeCenter()
        let one = try project(id: 1)
        let two = try project(id: 2)
        center.start(project: one)
        center.start(project: two)
        await center.closeAll()
        XCTAssertEqual(signals.filter { $0.1 == SIGHUP }.count, 2)
        XCTAssertTrue(center.states.isEmpty)
    }
}
```

Add to `WatchtowerDesktop/Tests/QuitCoordinatorTests.swift` (inside `QuitCoordinatorTests`):

```swift
    /// Every embedded project terminal is closed on quit — after the chat
    /// sessions, before the daemon stop — so no `claude` outlives the app.
    func testQuitClosesTerminalsBeforeStoppingTheDaemon() async {
        var order: [String] = []
        let replied = expectation(description: "replied")
        let reply = QuitCoordinator.shouldTerminate(
            hasBlockingWork: false,
            confirmQuit: { true },
            closeChatSessions: { order.append("chat") },
            closeTerminals: { order.append("terminals") },
            stopDaemon: { order.append("daemon") },
            reply: { ok in XCTAssertTrue(ok); replied.fulfill() })
        XCTAssertEqual(reply, .terminateLater)
        await fulfillment(of: [replied], timeout: 5)
        XCTAssertEqual(order, ["chat", "terminals", "daemon"])
    }
```

In `WatchtowerDesktop/Tests/ProjectsViewModelTests.swift`, in `testCreateSurvivesNavigatingAwayAndSelectsTheProjectOnReturn`, right after `let appState = AppState()` add:

```swift
        appState.projectTerminalCenter.makeSession = { FakeTerminalSession() }
```

- [ ] **Step 5: Run — expect a compile failure**

Run: `make test-swift FILTER=ProjectTerminalCenterTests > /tmp/p17b.log 2>&1; echo "exit=$?"` → `exit≠0`.

- [ ] **Step 6: Implement the center, the session and the signaller**

Create `WatchtowerDesktop/Sources/Services/ProjectTerminalCenter.swift`:

```swift
import AppKit
import Darwin
import Observation
import SwiftTerm
import WatchtowerCore

/// One running terminal. The center owns it; a view only hosts `view`.
@MainActor
protocol ProjectTerminalSession: AnyObject {
    var view: NSView { get }
    /// The shell's pid, which `exec claude` keeps; 0 before start.
    var pid: pid_t { get }
    var onExit: ((Int32?) -> Void)? { get set }
    func start(_ launch: ProjectTerminalLaunch)
    /// Drops the session's view from any host once the process is gone.
    func detach()
}

/// Process-group signalling seam, so tests never signal a real process.
struct ProcessGroupSignaller {
    var signal: (pid_t, Int32) -> Void
    var isAlive: (pid_t) -> Bool
    var sleep: (Duration) async -> Void

    static let live = Self(
        signal: { pid, sig in _ = killpg(pid, sig) },
        isAlive: { pid in kill(pid, 0) == 0 },
        sleep: { step in try? await Task.sleep(for: step) }
    )
}

/// Embedded Claude Code terminals, one per project (spec §6.2). Owned by
/// `AppState`, so a session — process and scrollback — survives navigation
/// (house rule); closing or quitting hangs the process group up, then kills
/// it after `killGrace` if it is still alive.
@MainActor
@Observable
final class ProjectTerminalCenter {
    enum State: Equatable {
        case running
        case exited(Int32?)
        case unavailable(String)
    }

    static let killGrace: Duration = .seconds(3)
    static let pollStep: Duration = .milliseconds(100)

    private(set) var states: [Int64: State] = [:]
    @ObservationIgnored private var sessions: [Int64: any ProjectTerminalSession] = [:]
    @ObservationIgnored var makeSession: () -> any ProjectTerminalSession
    @ObservationIgnored var shell: () -> String? = { ProcessInfo.processInfo.environment["SHELL"] }
    @ObservationIgnored private let signaller: ProcessGroupSignaller

    init(
        makeSession: @escaping () -> any ProjectTerminalSession = { SwiftTermSession() },
        signaller: ProcessGroupSignaller = .live
    ) {
        self.makeSession = makeSession
        self.signaller = signaller
    }

    func session(for projectID: Int64) -> (any ProjectTerminalSession)? {
        sessions[projectID]
    }

    /// Starts `claude` in the project folder unless it is already running.
    /// After an exit it relaunches in the same session (scrollback kept).
    func start(project: Project, firstRun: Bool = false) {
        if states[project.id] == .running { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project.folderPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            states[project.id] = .unavailable("The folder \(project.folderPath) no longer exists.")
            return
        }
        let session = sessions[project.id] ?? makeSession()
        let projectID = project.id
        session.onExit = { [weak self] code in
            self?.states[projectID] = .exited(code)
        }
        sessions[projectID] = session
        states[projectID] = .running
        session.start(.make(shell: shell(), folder: project.folderPath, firstRun: firstRun))
    }

    func close(projectID: Int64) async {
        guard let session = sessions.removeValue(forKey: projectID) else {
            states[projectID] = nil
            return
        }
        let pid = session.pid
        if pid > 0, states[projectID] == .running {
            signaller.signal(pid, SIGHUP)
            var waited: Duration = .zero
            while waited < Self.killGrace, isRunning(projectID, pid) {
                await signaller.sleep(Self.pollStep)
                waited += Self.pollStep
            }
            if isRunning(projectID, pid) { signaller.signal(pid, SIGKILL) }
        }
        session.onExit = nil
        session.detach()
        states[projectID] = nil
    }

    /// Quit path: every terminal at once, so the wait is one grace, not N.
    func closeAll() async {
        let ids = Array(sessions.keys)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { @MainActor in await self.close(projectID: id) }
            }
        }
    }

    private func isRunning(_ projectID: Int64, _ pid: pid_t) -> Bool {
        states[projectID] == .running && signaller.isAlive(pid)
    }
}

/// The real session: a SwiftTerm `LocalProcessTerminalView` running the
/// launch in a pty. Keystrokes, copy/paste and resize are SwiftTerm's own
/// (no Accessibility, no event monitors — no TCC prompt).
@MainActor
final class SwiftTermSession: NSObject, ProjectTerminalSession, LocalProcessTerminalViewDelegate {
    private let terminal: LocalProcessTerminalView
    var onExit: ((Int32?) -> Void)?

    override init() {
        terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        super.init()
        terminal.processDelegate = self
        terminal.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    }

    var view: NSView { terminal }
    var pid: pid_t { terminal.process?.shellPid ?? 0 }

    func start(_ launch: ProjectTerminalLaunch) {
        var environment = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        environment.append("SHELL=\(launch.executable)")
        terminal.startProcess(
            executable: launch.executable,
            args: launch.args,
            environment: environment,
            execName: nil,
            currentDirectory: launch.currentDirectory
        )
    }

    func detach() {
        terminal.removeFromSuperview()
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        // LocalProcess delivers on the main queue (its default dispatch queue).
        MainActor.assumeIsolated { onExit?(exitCode) }
    }
}
```

Notes:
- `Terminal.getEnvironmentVariables` copies `LOGNAME`/`USER`/`HOME` from the app's environment and sets `TERM`/`COLORTERM`/`LANG`; `PATH` is left to the login shell's profile on purpose (the owner's own `PATH`, not the app's launchd one).
- If the Swift 5.10 compiler rejects `MainActor.assumeIsolated` capturing `onExit` from a `nonisolated` context, use `DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.onExit?(exitCode) } }`.
- `detach()` does not call SwiftTerm's `terminate()` (see the header note); the pty fds are released when the session object is deallocated with the center's entry.

- [ ] **Step 7: The view**

Create `WatchtowerDesktop/Sources/Views/Projects/ProjectTerminalView.swift`:

```swift
import AppKit
import SwiftUI
import WatchtowerCore

/// Terminal pane (spec §6.2). Shows the project's session from
/// `AppState.projectTerminalCenter`; never owns the process itself.
struct ProjectTerminalView: View {
    let project: Project
    @Environment(AppState.self) private var appState

    var body: some View {
        let center = appState.projectTerminalCenter
        VStack(spacing: 0) {
            switch center.states[project.id] {
            case .running?:
                host(center)
            case let .exited(code)?:
                host(center)
                Divider()
                HStack {
                    Text(code.map { "Claude Code exited (code \($0))." } ?? "Claude Code exited.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restart") { center.start(project: project) }
                }
                .padding(8)
            case let .unavailable(message)?:
                Text(message).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            case nil:
                VStack(spacing: 8) {
                    Text("Run Claude Code in \(project.folderPath).").foregroundStyle(.secondary)
                    Button("Start Claude Code") { center.start(project: project) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func host(_ center: ProjectTerminalCenter) -> some View {
        if let session = center.session(for: project.id) {
            TerminalHost(session: session)
        }
    }
}

/// Hosts a session's NSView. Dismantling the host only removes the view from
/// the hierarchy — the center keeps it (and the process) alive.
private struct TerminalHost: NSViewRepresentable {
    let session: any ProjectTerminalSession

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        attach(to: container)
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }

    private func attach(to container: NSView) {
        let terminal = session.view
        guard terminal.superview !== container else { return }
        terminal.removeFromSuperview()
        terminal.frame = container.bounds
        terminal.autoresizingMask = [.width, .height]
        container.addSubview(terminal)
        DispatchQueue.main.async { terminal.window?.makeFirstResponder(terminal) }
    }
}
```

In `ProjectPageView.paneContent` replace the `.terminal` case with `ProjectTerminalView(project: project)`.

- [ ] **Step 8: `AppState`, quit**

`WatchtowerDesktop/Sources/App/AppState.swift` — after `let voiceRegistryCenter = VoiceRegistryCenter()` add:

```swift
    /// Embedded Claude Code terminals, one per project. No DB needed; closed
    /// on quit by `QuitCoordinator` (via `TrayAppDelegate`).
    let projectTerminalCenter = ProjectTerminalCenter()
```

In `initProjects`, before `projectsViewModel = vm`:

```swift
        vm.onProjectCreated = { [weak self] project in
            self?.projectTerminalCenter.start(project: project, firstRun: true)
        }
```

`WatchtowerDesktop/Sources/App/QuitCoordinator.swift` — add a `closeTerminals` parameter after `closeChatSessions` and await it right after `closeChatSessions()`:

```swift
    static func shouldTerminate(
        hasBlockingWork: Bool,
        confirmQuit: () -> Bool,
        closeChatSessions: @escaping () async -> Void = {},
        closeTerminals: @escaping () async -> Void = {},
        stopDaemon: @escaping () async -> Void,
        reply: @escaping (Bool) -> Void
    ) -> NSApplication.TerminateReply {
        if hasBlockingWork && !confirmQuit() {
            return .terminateCancel
        }
        Task { @MainActor in
            // CHAT-03: every chat session gets `close`, then SIGTERM after
            // its grace — bounded, and each keeps its partial text (CHAT-01).
            await closeChatSessions()
            // Project terminals: SIGHUP to each process group, SIGKILL after
            // 3 s — no `claude` outlives the app.
            await closeTerminals()
            await stopDaemon()
            // Always let termination proceed: a stuck daemon must never trap
            // the user in a quit — the next launch adopts or replaces it.
            reply(true)
        }
        return .terminateLater
    }
```

`WatchtowerDesktop/Sources/App/TrayAppDelegate.swift` — `applicationShouldTerminate` passes `closeTerminals: { await AppState.shared.projectTerminalCenter.closeAll() }` after `closeChatSessions:`; `terminateDecision` gains the same defaulted `closeTerminals` parameter and forwards it to `QuitCoordinator.shouldTerminate`.

An open terminal does NOT count as blocking work for the quit confirmation: Claude Code resumes its own sessions (`claude --continue`), so quitting loses no owner text.

- [ ] **Step 9: Run — PASS**

```bash
make test-swift FILTER=ProjectTerminalCenterTests > /tmp/p17b.log 2>&1; echo "exit=$?"
make test-swift FILTER=QuitCoordinatorTests > /tmp/p17c.log 2>&1; echo "exit=$?"
make test-swift FILTER=TrayAppDelegateTests > /tmp/p17d.log 2>&1; echo "exit=$?"
make test-swift FILTER=ProjectsViewModelTests > /tmp/p17e.log 2>&1; echo "exit=$?"
make test-swift FILTER=ProjectTerminalLaunchTests > /tmp/p17a.log 2>&1; echo "exit=$?"
make lint-swift > /tmp/p17-lint.log 2>&1; echo "exit=$?"
```
Expected: every `exit=0`. After the runs, `pgrep -fl 'exec claude'` prints nothing (no test started a real session).

Manual smoke (`make app-dev`, on a folder outside `~/Documents`/`~/Desktop`/`~/Downloads`/cloud storage): Terminal pane → Start Claude Code → the prompt appears and typing works; switch to another tab and back → same scrollback; `/exit` → "Claude Code exited" + Restart; Cmd+Q → `pgrep -fl claude` shows no child of Watchtower; no TCC prompt at any point.

- [ ] **Step 10: Commit**

```bash
git add WatchtowerDesktop/Package.swift WatchtowerDesktop/Package.resolved \
        WatchtowerDesktop/Sources/WatchtowerCore/Services/ProjectTerminalLaunch.swift \
        WatchtowerDesktop/Sources/Services/ProjectTerminalCenter.swift \
        WatchtowerDesktop/Sources/Views/Projects/ProjectTerminalView.swift \
        WatchtowerDesktop/Sources/Views/Projects/ProjectPageView.swift \
        WatchtowerDesktop/Sources/App/AppState.swift \
        WatchtowerDesktop/Sources/App/QuitCoordinator.swift \
        WatchtowerDesktop/Sources/App/TrayAppDelegate.swift \
        WatchtowerDesktop/Tests/Core/ProjectTerminalLaunchTests.swift \
        WatchtowerDesktop/Tests/ProjectTerminalCenterTests.swift \
        WatchtowerDesktop/Tests/QuitCoordinatorTests.swift \
        WatchtowerDesktop/Tests/ProjectsViewModelTests.swift
git commit -m "$(cat <<'EOF'
feat(desktop): embedded Claude Code terminal per project (SwiftTerm)

The Terminal pane runs the owner's login shell exec'ing claude in the
project folder, with the fixed setup prompt for a new project. Sessions
live in an AppState center and survive navigation; close and quit hang the
process group up and kill it after 3 s only if it is still alive.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Lo9jbbmXQcr3qHo5f3pLD8
EOF
)"
```

---
### Task 18: Owner notifications

**Depends on:** Tasks 13, 14, 16 (owner-write hook), 17 (`initProjects` wiring it extends).

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/ProjectNotificationPolicy.swift`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ProjectQueries+Activity.swift`
- Create: `WatchtowerDesktop/Sources/Services/ProjectNotificationCenter.swift`
- Modify: `WatchtowerDesktop/Sources/Services/NotificationService.swift` (`sendProjectNotice`)
- Modify: `WatchtowerDesktop/Sources/App/WatchtowerApp.swift` (`NotificationDelegate.route` case `"project"`)
- Modify: `WatchtowerDesktop/Sources/App/NotificationForwarding.swift` (routed keys)
- Modify: `WatchtowerDesktop/Sources/App/AppState.swift` (`projectNotificationCenter`, wiring in `initProjects`)
- Modify: `WatchtowerDesktop/Sources/Views/Settings/NotificationSettings.swift` (toggle)
- Modify: `WatchtowerDesktop/Tests/ProjectsViewModelTests.swift` (fake notifier in the survival test)
- Test: `WatchtowerDesktop/Tests/Core/ProjectNotificationPolicyTests.swift`, `WatchtowerDesktop/Tests/Core/ProjectQueriesTests.swift` (one test added), `WatchtowerDesktop/Tests/ProjectNotificationCenterTests.swift`, `WatchtowerDesktop/Tests/NotificationRouteTests.swift` (two tests added)

**Interfaces:**
- Consumes: `ProjectQueries.documentListItems` (Task 16), `ProjectSubject`/`ProjectRoute`/`ProjectPane` (Task 13), `ProjectsViewModel.onOwnerWrite`/`onProjectCreated`/`reload()`, `AppState.navigateToProject` (Task 14).
- Produces:
  - Core: `enum ProjectNoticeKind { agentAsks, documentReady, commentsAnswered, targetDone }`; `struct ProjectNotice { kind; projectID; title; body; route: ProjectRoute; identifier }`; `enum ProjectNotificationPolicy { coalesceThreshold = 3; struct Question; struct DocumentState; struct TargetState; struct Snapshot { projectID; projectName; lastAgentCommentID; questions; documents; targets; ownerTouched; static empty(projectID:projectName:); persisted }; static decide(previous: Snapshot, current: Snapshot) -> [ProjectNotice] }`; `ProjectQueries.activitySnapshot(_:project:afterAgentCommentID:)`.
  - App: `protocol ProjectNotifying { sendProjectNotice(_:) }` (`NotificationService` conforms); `@MainActor @Observable final class ProjectNotificationCenter { static enabledKey = "projects.notifications"; init(dbPool:notifier:defaults:); start(); stop(); poll() async; recordOwnerWrite(projectID:subject:); seedBaseline(project:); onPolled }`; `AppState.projectNotificationCenter`; `AppState.initProjects(dbPool:cliRunner:notifier:)`.
  - Push `userInfo`: `["type": "project", "projectId": Int64, "pane": "<ProjectPane raw>", "subjectId": Int64?]`, routed to `AppState.navigateToProject`.

**Policy (spec §6.5):**
- `agentAsks` — an agent **root** comment on a target with id > the previous snapshot's `lastAgentCommentID` → "Agent asks on ‹target›" (Board, that target).
- `documentReady` — a document absent from the previous snapshot, or whose `updated_at` changed (attached or re-attached = revised) → "‹doc› ready for review" (Documents, that document). The Desktop never writes documents (PROJ-03), so this is always the agent.
- `commentsAnswered` — a document that had ≥ 1 open owner comment and now has 0, unless the owner touched that document since the last poll (owner resolve, owner "mark outdated") → "All comments on ‹doc› answered".
- `targetDone` — a known target whose status moved to `done`, unless the owner touched it → "‹target› done". (Owner board edits are Task 19; they report through the same `onOwnerWrite` hook.)
- Owner comments never appear in `questions` (author filter), so an owner write never notifies.
- ≥ `coalesceThreshold` (3) notices of one kind in one project in one poll → one summary notice for that kind (deep link to the pane, no subject).
- A project seen for the first time (no persisted snapshot) baselines silently. A project created in-app seeds an **empty** baseline first, so what CC attaches during setup is reported.
- The snapshot advances even while notifications are off (toggle or Quiet Hours), so re-enabling never floods.

- [ ] **Step 1: Failing policy tests**

Create `WatchtowerDesktop/Tests/Core/ProjectNotificationPolicyTests.swift`:

```swift
import XCTest
@testable import WatchtowerCore

final class ProjectNotificationPolicyTests: XCTestCase {
    typealias Policy = ProjectNotificationPolicy

    private func snapshot(
        last: Int64 = 0,
        questions: [Policy.Question] = [],
        documents: [Int64: Policy.DocumentState] = [:],
        targets: [Int64: Policy.TargetState] = [:],
        ownerTouched: Set<ProjectSubject> = []
    ) -> Policy.Snapshot {
        Policy.Snapshot(
            projectID: 1, projectName: "acme", lastAgentCommentID: last, questions: questions,
            documents: documents, targets: targets, ownerTouched: ownerTouched
        )
    }

    private func question(_ id: Int64, target: Int64 = 10) -> Policy.Question {
        Policy.Question(id: id, targetID: target, targetTitle: "Task \(target)", body: "Which queue should retry?")
    }

    private func doc(_ title: String, _ stamp: String, open: Int = 0) -> Policy.DocumentState {
        Policy.DocumentState(title: title, updatedAt: stamp, openOwnerComments: open)
    }

    // MARK: each kind

    func testAgentQuestionNotifiesWithABoardDeepLink() {
        let notices = Policy.decide(previous: snapshot(last: 4), current: snapshot(last: 5, questions: [question(5)]))
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notices[0].kind, .agentAsks)
        XCTAssertEqual(notices[0].title, "Agent asks on Task 10")
        XCTAssertEqual(notices[0].body, "acme: Which queue should retry?")
        XCTAssertEqual(notices[0].route, ProjectRoute(projectID: 1, pane: .board, subjectID: 10))
    }

    func testQuestionAtOrBelowTheWatermarkIsIgnored() {
        let notices = Policy.decide(previous: snapshot(last: 5), current: snapshot(last: 5, questions: [question(5), question(3)]))
        XCTAssertTrue(notices.isEmpty)
    }

    func testNewOrRevisedDocumentIsReadyForReviewAndAnUnchangedOneIsNot() {
        let previous = snapshot(documents: [1: doc("Spec", "t1"), 2: doc("Notes", "t1")])
        let current = snapshot(documents: [1: doc("Spec", "t2"), 2: doc("Notes", "t1"), 3: doc("Plan", "t2")])
        let notices = Policy.decide(previous: previous, current: current)
        XCTAssertEqual(notices.map(\.title), ["Spec ready for review", "Plan ready for review"])
        XCTAssertEqual(notices.map(\.route), [
            ProjectRoute(projectID: 1, pane: .documents, subjectID: 1),
            ProjectRoute(projectID: 1, pane: .documents, subjectID: 3)
        ])
        XCTAssertNotEqual(notices[0].identifier, Policy.decide(
            previous: current, current: snapshot(documents: [1: doc("Spec", "t3")])
        ).first?.identifier, "each revision is its own notification")
    }

    func testLastOpenOwnerCommentResolvedAnnouncesAllAnswered() {
        let previous = snapshot(documents: [1: doc("Plan", "t1", open: 2), 2: doc("Spec", "t1", open: 2)])
        let current = snapshot(documents: [1: doc("Plan", "t1", open: 0), 2: doc("Spec", "t1", open: 1)])
        let notices = Policy.decide(previous: previous, current: current)
        XCTAssertEqual(notices.map(\.kind), [.commentsAnswered])
        XCTAssertEqual(notices.first?.title, "All comments on Plan answered")
        XCTAssertEqual(notices.first?.route, ProjectRoute(projectID: 1, pane: .documents, subjectID: 1))
    }

    func testDocumentThatNeverHadOpenCommentsAnnouncesNothingAnswered() {
        let notices = Policy.decide(
            previous: snapshot(documents: [1: doc("Plan", "t1", open: 0)]),
            current: snapshot(documents: [1: doc("Plan", "t1", open: 0)])
        )
        XCTAssertTrue(notices.isEmpty)
    }

    func testTargetMovedToDoneNotifiesAndOtherMovesDoNot() {
        let previous = snapshot(targets: [
            1: .init(title: "Task 1", status: "in_progress"),
            2: .init(title: "Task 2", status: "done"),
            3: .init(title: "Task 3", status: "todo")
        ])
        let current = snapshot(targets: [
            1: .init(title: "Task 1", status: "done"),
            2: .init(title: "Task 2", status: "done"),
            3: .init(title: "Task 3", status: "in_progress"),
            4: .init(title: "Task 4", status: "done")
        ])
        let notices = Policy.decide(previous: previous, current: current)
        XCTAssertEqual(notices.map(\.title), ["Task 1 done"])
        XCTAssertEqual(notices.first?.route, ProjectRoute(projectID: 1, pane: .board, subjectID: 1))
    }

    // MARK: owner writes

    func testOwnerWritesNeverNotify() {
        let previous = snapshot(
            documents: [1: doc("Plan", "t1", open: 1)],
            targets: [7: .init(title: "Task 7", status: "todo")]
        )
        let current = snapshot(
            documents: [1: doc("Plan", "t1", open: 0)],
            targets: [7: .init(title: "Task 7", status: "done")],
            ownerTouched: [.document(1), .target(7)]
        )
        XCTAssertTrue(Policy.decide(previous: previous, current: current).isEmpty)
    }

    // MARK: coalescing

    func testThreeOrMoreOfOneKindCoalesceIntoOneSummary() {
        let current = snapshot(last: 9, questions: [question(7, target: 1), question(8, target: 2), question(9, target: 3)])
        let notices = Policy.decide(previous: snapshot(last: 6), current: current)
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notices[0].title, "3 agent questions")
        XCTAssertEqual(notices[0].body, "acme")
        XCTAssertEqual(notices[0].route, ProjectRoute(projectID: 1, pane: .board))
    }

    func testTwoOfAKindStayIndividualAndKindsCoalesceSeparately() {
        let previous = snapshot(targets: [1: .init(title: "A", status: "todo"), 2: .init(title: "B", status: "todo"),
                                          3: .init(title: "C", status: "todo")])
        let current = snapshot(
            last: 2,
            questions: [question(1), question(2)],
            documents: [1: doc("D1", "t"), 2: doc("D2", "t"), 3: doc("D3", "t"), 4: doc("D4", "t")],
            targets: [1: .init(title: "A", status: "done"), 2: .init(title: "B", status: "done"),
                      3: .init(title: "C", status: "done")]
        )
        let notices = Policy.decide(previous: previous, current: current)
        XCTAssertEqual(notices.map(\.kind), [.agentAsks, .agentAsks, .documentReady, .targetDone])
        XCTAssertEqual(notices[2].title, "4 documents ready for review")
        XCTAssertEqual(notices[3].title, "3 targets done")
    }

    func testPersistedSnapshotDropsTransientParts() {
        let current = snapshot(last: 3, questions: [question(3)], ownerTouched: [.document(1)])
        XCTAssertTrue(current.persisted.questions.isEmpty)
        XCTAssertTrue(current.persisted.ownerTouched.isEmpty)
        XCTAssertEqual(current.persisted.lastAgentCommentID, 3)
    }
}
```

Append to `WatchtowerDesktop/Tests/Core/ProjectQueriesTests.swift` (inside the class):

```swift
    func testActivitySnapshotCollectsAgentQuestionsDocumentsAndTargets() throws {
        try db.write { d in
            let p = try TestDatabase.insertProject(d)
            let t = try TestDatabase.insertProjectTarget(d, projectID: p, text: "Task 1", status: "in_progress")
            let old = try TestDatabase.insertProjectComment(d, projectID: p, body: "old?", targetID: t)
            let owner = try TestDatabase.insertProjectComment(d, projectID: p, author: "owner", body: "mine", targetID: t)
            let reply = try TestDatabase.insertProjectComment(d, projectID: p, body: "a reply", targetID: t, parentID: owner)
            let fresh = try TestDatabase.insertProjectComment(d, projectID: p, body: "new?", targetID: t)
            let doc = try TestDatabase.insertProjectDocument(d, projectID: p, title: "Plan", updatedAt: "2026-09-29T12:00:00Z")
            _ = try TestDatabase.insertProjectComment(d, projectID: p, author: "owner", documentID: doc, quote: "x")
            let project = try XCTUnwrap(ProjectQueries.fetch(d, id: p))

            let snap = try ProjectQueries.activitySnapshot(d, project: project, afterAgentCommentID: old)
            XCTAssertEqual(snap.projectName, "acme")
            XCTAssertEqual(snap.questions.map(\.id), [fresh], "agent roots past the watermark; not owner comments, not replies (\(reply))")
            XCTAssertEqual(snap.questions.first?.targetTitle, "Task 1")
            XCTAssertEqual(snap.lastAgentCommentID, fresh)
            XCTAssertEqual(snap.documents[doc], .init(title: "Plan", updatedAt: "2026-09-29T12:00:00Z", openOwnerComments: 1))
            XCTAssertEqual(snap.targets[t], .init(title: "Task 1", status: "in_progress"))
            XCTAssertTrue(snap.ownerTouched.isEmpty)
        }
    }
```

- [ ] **Step 2: Run — expect a compile failure**

Run: `make test-swift FILTER=ProjectNotificationPolicyTests > /tmp/p18a.log 2>&1; echo "exit=$?"` → `exit≠0`.

- [ ] **Step 3: Implement the policy**

Create `WatchtowerDesktop/Sources/WatchtowerCore/Services/ProjectNotificationPolicy.swift`:

```swift
import Foundation

package enum ProjectNoticeKind: String, Codable, Sendable {
    case agentAsks
    case documentReady
    case commentsAnswered
    case targetDone
}

package struct ProjectNotice: Equatable, Sendable {
    package let kind: ProjectNoticeKind
    package let projectID: Int64
    package let title: String
    package let body: String
    package let route: ProjectRoute
    /// Stable per event, so a re-post replaces instead of stacking.
    package let identifier: String
}

/// Which project events become owner notifications (spec §6.5). Pure: the
/// center feeds it the previous and current snapshot of each project; no
/// clock, no I/O.
package enum ProjectNotificationPolicy {
    package static let coalesceThreshold = 3

    package struct Question: Codable, Equatable, Sendable {
        package let id: Int64
        package let targetID: Int64
        package let targetTitle: String
        package let body: String

        package init(id: Int64, targetID: Int64, targetTitle: String, body: String) {
            self.id = id
            self.targetID = targetID
            self.targetTitle = targetTitle
            self.body = body
        }
    }

    package struct DocumentState: Codable, Equatable, Sendable {
        package let title: String
        package let updatedAt: String
        package let openOwnerComments: Int

        package init(title: String, updatedAt: String, openOwnerComments: Int) {
            self.title = title
            self.updatedAt = updatedAt
            self.openOwnerComments = openOwnerComments
        }
    }

    package struct TargetState: Codable, Equatable, Sendable {
        package let title: String
        package let status: String

        package init(title: String, status: String) {
            self.title = title
            self.status = status
        }
    }

    /// One project's state at a poll. `questions` holds only the agent root
    /// comments past the previous watermark; `ownerTouched` what the owner
    /// changed since the previous poll. Both are transient (`persisted`).
    package struct Snapshot: Codable, Equatable, Sendable {
        package var projectID: Int64
        package var projectName: String
        package var lastAgentCommentID: Int64
        package var questions: [Question]
        package var documents: [Int64: DocumentState]
        package var targets: [Int64: TargetState]
        package var ownerTouched: Set<ProjectSubject>

        package init(
            projectID: Int64,
            projectName: String,
            lastAgentCommentID: Int64,
            questions: [Question],
            documents: [Int64: DocumentState],
            targets: [Int64: TargetState],
            ownerTouched: Set<ProjectSubject>
        ) {
            self.projectID = projectID
            self.projectName = projectName
            self.lastAgentCommentID = lastAgentCommentID
            self.questions = questions
            self.documents = documents
            self.targets = targets
            self.ownerTouched = ownerTouched
        }

        /// The baseline of a project just created in-app: everything after it counts.
        package static func empty(projectID: Int64, projectName: String) -> Self {
            Self(projectID: projectID, projectName: projectName, lastAgentCommentID: 0,
                 questions: [], documents: [:], targets: [:], ownerTouched: [])
        }

        package var persisted: Self {
            var copy = self
            copy.questions = []
            copy.ownerTouched = []
            return copy
        }
    }

    package static func decide(previous: Snapshot, current: Snapshot) -> [ProjectNotice] {
        [
            coalesce(questions(previous, current), kind: .agentAsks, in: current),
            coalesce(readyDocuments(previous, current), kind: .documentReady, in: current),
            coalesce(answeredDocuments(previous, current), kind: .commentsAnswered, in: current),
            coalesce(doneTargets(previous, current), kind: .targetDone, in: current)
        ].flatMap { $0 }
    }

    // MARK: - Events

    private static func questions(_ previous: Snapshot, _ current: Snapshot) -> [ProjectNotice] {
        current.questions.filter { $0.id > previous.lastAgentCommentID }.map { question in
            notice(.agentAsks, current,
                   title: "Agent asks on \(question.targetTitle)",
                   body: "\(current.projectName): \(question.body.prefix(200))",
                   route: ProjectRoute(projectID: current.projectID, pane: .board, subjectID: question.targetID),
                   key: "\(question.id)")
        }
    }

    private static func readyDocuments(_ previous: Snapshot, _ current: Snapshot) -> [ProjectNotice] {
        current.documents.sorted { $0.key < $1.key }.compactMap { id, doc in
            guard previous.documents[id]?.updatedAt != doc.updatedAt else { return nil }
            return notice(.documentReady, current,
                          title: "\(doc.title) ready for review", body: current.projectName,
                          route: ProjectRoute(projectID: current.projectID, pane: .documents, subjectID: id),
                          key: "\(id)-\(doc.updatedAt)")
        }
    }

    private static func answeredDocuments(_ previous: Snapshot, _ current: Snapshot) -> [ProjectNotice] {
        current.documents.sorted { $0.key < $1.key }.compactMap { id, doc in
            guard let before = previous.documents[id], before.openOwnerComments > 0, doc.openOwnerComments == 0,
                  !current.ownerTouched.contains(.document(id)) else { return nil }
            return notice(.commentsAnswered, current,
                          title: "All comments on \(doc.title) answered", body: current.projectName,
                          route: ProjectRoute(projectID: current.projectID, pane: .documents, subjectID: id),
                          key: "\(id)-\(doc.updatedAt)")
        }
    }

    private static func doneTargets(_ previous: Snapshot, _ current: Snapshot) -> [ProjectNotice] {
        current.targets.sorted { $0.key < $1.key }.compactMap { id, target in
            guard target.status == "done", let before = previous.targets[id], before.status != "done",
                  !current.ownerTouched.contains(.target(id)) else { return nil }
            return notice(.targetDone, current,
                          title: "\(target.title) done", body: current.projectName,
                          route: ProjectRoute(projectID: current.projectID, pane: .board, subjectID: id),
                          key: "\(id)")
        }
    }

    // MARK: - Shaping

    private static func coalesce(_ notices: [ProjectNotice], kind: ProjectNoticeKind, in snapshot: Snapshot) -> [ProjectNotice] {
        guard notices.count >= coalesceThreshold else { return notices }
        let pane: ProjectPane = kind == .agentAsks || kind == .targetDone ? .board : .documents
        return [notice(kind, snapshot,
                       title: summaryTitle(kind, count: notices.count), body: snapshot.projectName,
                       route: ProjectRoute(projectID: snapshot.projectID, pane: pane),
                       key: "summary-" + notices.map(\.identifier).joined(separator: ",").hashValueString)]
    }

    private static func summaryTitle(_ kind: ProjectNoticeKind, count: Int) -> String {
        switch kind {
        case .agentAsks: "\(count) agent questions"
        case .documentReady: "\(count) documents ready for review"
        case .commentsAnswered: "All comments answered on \(count) documents"
        case .targetDone: "\(count) targets done"
        }
    }

    private static func notice(
        _ kind: ProjectNoticeKind, _ snapshot: Snapshot, title: String, body: String, route: ProjectRoute, key: String
    ) -> ProjectNotice {
        ProjectNotice(kind: kind, projectID: snapshot.projectID, title: title, body: body, route: route,
                      identifier: "project-\(snapshot.projectID)-\(kind.rawValue)-\(key)")
    }
}

private extension String {
    /// A short, stable (FNV-1a) digest — Swift's `hashValue` is seeded per
    /// process and would give every relaunch a new identifier.
    var hashValueString: String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
```

Create `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ProjectQueries+Activity.swift`:

```swift
import Foundation
import GRDB

extension ProjectQueries {
    /// What the notification policy compares between polls (spec §6.5).
    /// `questions` = agent root comments on targets with id > the watermark.
    package static func activitySnapshot(
        _ db: Database,
        project: Project,
        afterAgentCommentID: Int64
    ) throws -> ProjectNotificationPolicy.Snapshot {
        let last = try Int64.fetchOne(db, sql: """
            SELECT COALESCE(MAX(id), 0) FROM project_comments
            WHERE project_id = ? AND author = 'agent' AND parent_id IS NULL AND target_id IS NOT NULL
            """, arguments: [project.id]) ?? 0
        let questions = try Row.fetchAll(db, sql: """
            SELECT c.id, c.target_id, c.body, t.text AS target_title
            FROM project_comments c JOIN targets t ON t.id = c.target_id
            WHERE c.project_id = ? AND c.author = 'agent' AND c.parent_id IS NULL AND c.id > ?
            ORDER BY c.id
            """, arguments: [project.id, afterAgentCommentID]).map { row in
            ProjectNotificationPolicy.Question(
                id: row["id"], targetID: row["target_id"], targetTitle: row["target_title"], body: row["body"]
            )
        }
        var documents: [Int64: ProjectNotificationPolicy.DocumentState] = [:]
        for item in try documentListItems(db, projectID: project.id) {
            documents[item.id] = .init(
                title: item.document.displayTitle, updatedAt: item.document.updatedAt, openOwnerComments: item.openComments
            )
        }
        var targets: [Int64: ProjectNotificationPolicy.TargetState] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT id, text, status FROM targets WHERE project_id = ?", arguments: [project.id]) {
            targets[row["id"]] = .init(title: row["text"], status: row["status"])
        }
        return ProjectNotificationPolicy.Snapshot(
            projectID: project.id, projectName: project.name, lastAgentCommentID: last,
            questions: questions, documents: documents, targets: targets, ownerTouched: []
        )
    }
}
```

Run:
```bash
make test-swift FILTER=ProjectNotificationPolicyTests > /tmp/p18a.log 2>&1; echo "exit=$?"
make test-swift FILTER=ProjectQueriesTests > /tmp/p18b.log 2>&1; echo "exit=$?"
```
→ both `exit=0`.

- [ ] **Step 4: Failing tests for the center**

Create `WatchtowerDesktop/Tests/ProjectNotificationCenterTests.swift`:

```swift
import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

final class RecordingProjectNotifier: ProjectNotifying, @unchecked Sendable {
    private(set) var sent: [ProjectNotice] = []
    func sendProjectNotice(_ notice: ProjectNotice) { sent.append(notice) }
}

@MainActor
final class ProjectNotificationCenterTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var notifier: RecordingProjectNotifier!
    private var projectID: Int64!
    private var targetID: Int64!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "ProjectNotificationCenterTests-\(UUID().uuidString)"))
        notifier = RecordingProjectNotifier()
        (projectID, targetID) = try pool.write { d in
            let p = try TestDatabase.insertProject(d)
            return (p, try TestDatabase.insertProjectTarget(d, projectID: p, text: "Task 1"))
        }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private func makeCenter() -> ProjectNotificationCenter {
        ProjectNotificationCenter(dbPool: pool, notifier: notifier, defaults: defaults)
    }

    private func write(_ body: @escaping (Database) throws -> Void) async throws {
        try await pool.write { try body($0) }
    }

    func testFirstPollBaselinesSilentlyThenReportsWhatIsNew() async throws {
        try await write { _ = try TestDatabase.insertProjectComment($0, projectID: self.projectID, targetID: self.targetID) }
        let center = makeCenter()
        await center.poll()
        XCTAssertTrue(notifier.sent.isEmpty, "a project seen for the first time never replays its history")

        try await write { _ = try TestDatabase.insertProjectComment($0, projectID: self.projectID, body: "Which queue?", targetID: self.targetID) }
        await center.poll()
        XCTAssertEqual(notifier.sent.map(\.title), ["Agent asks on Task 1"])
        await center.poll()
        XCTAssertEqual(notifier.sent.count, 1, "the watermark moved: no repeat")
    }

    func testWatermarkSurvivesRelaunch() async throws {
        await makeCenter().poll()
        try await write { _ = try TestDatabase.insertProjectComment($0, projectID: self.projectID, targetID: self.targetID) }
        await makeCenter().poll()   // a new center = a relaunched app, same defaults
        XCTAssertEqual(notifier.sent.count, 1)
        await makeCenter().poll()
        XCTAssertEqual(notifier.sent.count, 1)
    }

    func testOwnerCommentNeverNotifies() async throws {
        let center = makeCenter()
        await center.poll()
        try await write { _ = try TestDatabase.insertProjectComment($0, projectID: self.projectID, author: "owner", targetID: self.targetID) }
        await center.poll()
        XCTAssertTrue(notifier.sent.isEmpty)
    }

    func testOwnerResolvingTheLastCommentDoesNotAnnounceAllAnswered() async throws {
        var root: Int64 = 0
        try await write { d in
            let doc = try TestDatabase.insertProjectDocument(d, projectID: self.projectID, title: "Plan")
            root = try TestDatabase.insertProjectComment(d, projectID: self.projectID, author: "owner", documentID: doc, quote: "x")
        }
        let center = makeCenter()
        await center.poll()
        let doc = try await pool.read { try Int64.fetchOne($0, sql: "SELECT id FROM project_documents") }
        try await write { try ProjectQueries.setStatus($0, commentID: root, status: "resolved") }
        center.recordOwnerWrite(projectID: projectID, subject: .document(try XCTUnwrap(doc)))
        await center.poll()
        XCTAssertTrue(notifier.sent.isEmpty)
    }

    func testAgentResolvingTheLastCommentAnnouncesAllAnswered() async throws {
        var root: Int64 = 0
        try await write { d in
            let doc = try TestDatabase.insertProjectDocument(d, projectID: self.projectID, title: "Plan")
            root = try TestDatabase.insertProjectComment(d, projectID: self.projectID, author: "owner", documentID: doc, quote: "x")
        }
        let center = makeCenter()
        await center.poll()
        try await write { try $0.execute(sql: "UPDATE project_comments SET status = 'resolved' WHERE id = ?", arguments: [root]) }
        await center.poll()
        XCTAssertEqual(notifier.sent.map(\.title), ["All comments on Plan answered"])
        XCTAssertEqual(notifier.sent.first?.route.pane, .documents)
    }

    func testSeededBaselineReportsADocumentAttachedRightAfterCreate() async throws {
        let center = makeCenter()
        let project = try XCTUnwrap(try await pool.read { try ProjectQueries.fetch($0, id: self.projectID) })
        center.seedBaseline(project: project)
        try await write { _ = try TestDatabase.insertProjectDocument($0, projectID: self.projectID, title: "Spec") }
        await center.poll()
        XCTAssertEqual(notifier.sent.map(\.title), ["Spec ready for review"])
    }

    func testDisabledOrQuietHoursSendNothingButStillAdvanceTheWatermark() async throws {
        let center = makeCenter()
        await center.poll()
        defaults.set(false, forKey: ProjectNotificationCenter.enabledKey)
        try await write { _ = try TestDatabase.insertProjectComment($0, projectID: self.projectID, targetID: self.targetID) }
        await center.poll()
        XCTAssertTrue(notifier.sent.isEmpty)

        defaults.set(true, forKey: ProjectNotificationCenter.enabledKey)
        defaults.set(true, forKey: "quietHoursEnabled")
        try await write { _ = try TestDatabase.insertProjectComment($0, projectID: self.projectID, targetID: self.targetID) }
        await center.poll()
        XCTAssertTrue(notifier.sent.isEmpty)

        defaults.set(false, forKey: "quietHoursEnabled")
        await center.poll()
        XCTAssertTrue(notifier.sent.isEmpty, "turning notifications back on never replays what happened while off")
    }

    func testPollReloadsTheProjectsList() async {
        let center = makeCenter()
        var reloaded = 0
        center.onPolled = { reloaded += 1 }
        await center.poll()
        XCTAssertEqual(reloaded, 1)
    }

    func testDeletedProjectSnapshotIsPruned() async throws {
        let center = makeCenter()
        await center.poll()
        XCTAssertNotNil(defaults.data(forKey: ProjectNotificationCenter.snapshotKey(projectID)))
        try await write { try $0.execute(sql: "DELETE FROM projects WHERE id = ?", arguments: [self.projectID]) }
        await center.poll()
        XCTAssertNil(defaults.data(forKey: ProjectNotificationCenter.snapshotKey(projectID)))
    }
}
```

Add to `WatchtowerDesktop/Tests/NotificationRouteTests.swift` (inside the test class, next to `testNavigationTypesRouteToTheirTab`):

```swift
    /// A project push opens its project on the pane the notice named — pure
    /// navigation, so the forwarded path routes it the same way.
    func testProjectPushOpensItsPane() async {
        for forwarded in [true, false] {
            let appState = AppState()
            await NotificationDelegate.route(
                actionID: UNNotificationDefaultActionIdentifier,
                userInfo: ["type": "project", "projectId": Int64(3), "pane": "documents", "subjectId": Int64(8)],
                appState: appState,
                forwarded: forwarded
            )
            XCTAssertEqual(appState.selectedDestination, .projects, "forwarded: \(forwarded)")
            XCTAssertEqual(appState.pendingProjectRoute, ProjectRoute(projectID: 3, pane: .documents, subjectID: 8))
        }
    }

    func testProjectKeysSurviveForwarding() throws {
        let json = try XCTUnwrap(NotificationForwarding.encode(
            actionID: UNNotificationDefaultActionIdentifier,
            userInfo: ["type": "project", "projectId": Int64(3), "pane": "board", "subjectId": Int64(8)]
        ))
        let info = try XCTUnwrap(NotificationForwarding.decode(json)).userInfo
        XCTAssertEqual(info["projectId"] as? Int64, 3)
        XCTAssertEqual(info["subjectId"] as? Int64, 8)
        XCTAssertEqual(info["pane"] as? String, "board")
    }
```

(If `NotificationRouteTests` does not already `import WatchtowerCore`, add it for `ProjectRoute`.)

In `WatchtowerDesktop/Tests/ProjectsViewModelTests.swift`, `testCreateSurvivesNavigatingAwayAndSelectsTheProjectOnReturn`: change the call to `appState.initProjects(dbPool: pool, cliRunner: held, notifier: RecordingProjectNotifier())` — no test may reach the real `UNUserNotificationCenter` (it crashes without an app bundle under `swift test`).

Run: `make test-swift FILTER=ProjectNotificationCenterTests > /tmp/p18c.log 2>&1; echo "exit=$?"` → `exit≠0`.

- [ ] **Step 5: Implement the center, the push, the routing**

Create `WatchtowerDesktop/Sources/Services/ProjectNotificationCenter.swift`:

```swift
import Foundation
import GRDB
import Observation
import WatchtowerCore

/// Native-push seam (the `MeetingReminderNotifying` shape), so the center is
/// testable without `UNUserNotificationCenter`.
protocol ProjectNotifying {
    func sendProjectNotice(_ notice: ProjectNotice)
}

extension NotificationService: ProjectNotifying {}

/// Owner notifications for project activity (spec §6.5). A 30 s poll — the
/// agent writes from another process (the project MCP server), so GRDB
/// observation never fires. Per project it compares the persisted snapshot
/// with the current one through the pure `ProjectNotificationPolicy`.
@MainActor
@Observable
final class ProjectNotificationCenter {
    /// `@AppStorage` key of the Settings toggle; absent = on.
    static let enabledKey = "projects.notifications"
    static let pollInterval: Duration = .seconds(30)

    static func snapshotKey(_ projectID: Int64) -> String { "projects.notificationSnapshot.\(projectID)" }

    /// After every poll — the Projects list reloads here (its data changes in
    /// other processes too).
    @ObservationIgnored var onPolled: (() async -> Void)?

    @ObservationIgnored private var ownerTouched: [Int64: Set<ProjectSubject>] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    private let dbPool: DatabasePool
    private let notifier: ProjectNotifying
    private let defaults: UserDefaults

    init(dbPool: DatabasePool, notifier: ProjectNotifying = NotificationService.shared, defaults: UserDefaults = .standard) {
        self.dbPool = dbPool
        self.notifier = notifier
        self.defaults = defaults
    }

    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// The owner changed `subject`: the next poll must not report it.
    func recordOwnerWrite(projectID: Int64, subject: ProjectSubject) {
        ownerTouched[projectID, default: []].insert(subject)
    }

    /// A project created in-app starts from an empty baseline, so what Claude
    /// Code attaches during setup is reported (a project the center merely
    /// discovers baselines silently instead).
    func seedBaseline(project: Project) {
        save(.empty(projectID: project.id, projectName: project.name))
    }

    private var sending: Bool {
        let enabled = defaults.object(forKey: Self.enabledKey) == nil || defaults.bool(forKey: Self.enabledKey)
        return enabled && !defaults.bool(forKey: "quietHoursEnabled")
    }

    func poll() async {
        do {
            let projects = try await dbPool.read { try ProjectQueries.fetchAll($0) }
            for project in projects {
                try await poll(project)
            }
            prune(keeping: Set(projects.map(\.id)))
        } catch {
            print("[ProjectNotifications] poll error: \(error.localizedDescription)")
        }
        await onPolled?()
    }

    private func poll(_ project: Project) async throws {
        let previous = load(project.id)
        let touchedBefore = ownerTouched[project.id] ?? []
        let watermark = previous?.lastAgentCommentID ?? 0
        var current = try await dbPool.read {
            try ProjectQueries.activitySnapshot($0, project: project, afterAgentCommentID: watermark)
        }
        // Writes recorded while the read ran stay pending for the next poll
        // too: their effect may or may not be in this snapshot.
        current.ownerTouched = ownerTouched[project.id] ?? []
        ownerTouched[project.id] = current.ownerTouched.subtracting(touchedBefore)
        if let previous, sending {
            for notice in ProjectNotificationPolicy.decide(previous: previous, current: current) {
                notifier.sendProjectNotice(notice)
            }
        }
        save(current.persisted)
    }

    private func load(_ projectID: Int64) -> ProjectNotificationPolicy.Snapshot? {
        guard let data = defaults.data(forKey: Self.snapshotKey(projectID)) else { return nil }
        do {
            return try JSONDecoder().decode(ProjectNotificationPolicy.Snapshot.self, from: data)
        } catch {
            // Undecodable ≠ absent: say so, then re-baseline silently rather
            // than replay the project's whole history.
            print("[ProjectNotifications] snapshot for project \(projectID) unreadable, re-baselining: \(error)")
            return nil
        }
    }

    private func save(_ snapshot: ProjectNotificationPolicy.Snapshot) {
        do {
            defaults.set(try JSONEncoder().encode(snapshot), forKey: Self.snapshotKey(snapshot.projectID))
        } catch {
            print("[ProjectNotifications] could not save snapshot for project \(snapshot.projectID): \(error)")
        }
    }

    private func prune(keeping ids: Set<Int64>) {
        let prefix = Self.snapshotKey(0).dropLast()
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            if let id = Int64(key.dropFirst(prefix.count)), !ids.contains(id) {
                defaults.removeObject(forKey: key)
            }
        }
    }
}
```

`Self.snapshotKey(0).dropLast()` is the key prefix `projects.notificationSnapshot.` (the trailing `0` dropped).

`WatchtowerDesktop/Sources/Services/NotificationService.swift` — add after `sendVoicesToLabelNotification`:

```swift
    /// Project activity (spec §6.5). The identifier comes from the policy and
    /// is stable per event, so a re-post replaces rather than stacks; the
    /// payload deep-links to the project pane (`NotificationDelegate.route`).
    func sendProjectNotice(_ notice: ProjectNotice) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = String(notice.body.prefix(200))
        content.sound = .default
        var info: [String: Any] = [
            "type": "project",
            "projectId": notice.route.projectID,
            "pane": notice.route.pane.rawValue
        ]
        if let subject = notice.route.subjectID { info["subjectId"] = subject }
        content.userInfo = info
        let request = UNNotificationRequest(identifier: notice.identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
```

`WatchtowerDesktop/Sources/App/WatchtowerApp.swift` — in `NotificationDelegate.route`, before `default:`:

```swift
        case "project":
            if let route = projectRoute(userInfo) {
                appState?.navigateToProject(route)
            } else {
                appState?.selectedDestination = .projects
            }
```

and add to `NotificationDelegate`:

```swift
    /// The project deep link of a push (`NotificationService.sendProjectNotice`).
    /// Ids arrive as Int64 when self-received and restored by
    /// `ForwardedNotificationResponse.userInfo` when forwarded; an NSNumber is
    /// accepted too (the `voice_label` precedent).
    static func projectRoute(_ userInfo: [AnyHashable: Any]) -> ProjectRoute? {
        func int64(_ key: String) -> Int64? {
            userInfo[key] as? Int64 ?? (userInfo[key] as? NSNumber)?.int64Value
        }
        guard let projectID = int64("projectId") else { return nil }
        let pane = (userInfo["pane"] as? String).flatMap(ProjectPane.init(rawValue:)) ?? .board
        return ProjectRoute(projectID: projectID, pane: pane, subjectID: int64("subjectId"))
    }
```

Update the doc comment above `route` that lists the forwarded keys: `(type, digestId, ideaId, transcriptID, projectId, pane, subjectId)`.

`WatchtowerDesktop/Sources/App/NotificationForwarding.swift`:

```swift
    static let projectIDKey = "projectId"
    static let projectSubjectIDKey = "subjectId"
    static let projectPaneKey = "pane"

    static let routedKeys = ["type", digestIDKey, ideaIDKey, transcriptIDKey, projectIDKey, projectSubjectIDKey, projectPaneKey]
```

and in `ForwardedNotificationResponse.userInfo` add:

```swift
        info[NotificationForwarding.projectIDKey] = payload[NotificationForwarding.projectIDKey].flatMap(Int64.init)
        info[NotificationForwarding.projectSubjectIDKey] = payload[NotificationForwarding.projectSubjectIDKey].flatMap(Int64.init)
```

(`encode` already stringifies `Int64` values.) A forwarded project push only navigates — it arms nothing, so it needs no downgrade branch.

`WatchtowerDesktop/Sources/App/AppState.swift`:

```swift
    /// Owner notifications for project activity; polls every 30 s.
    private(set) var projectNotificationCenter: ProjectNotificationCenter?
```

and `initProjects` becomes:

```swift
    func initProjects(
        dbPool: DatabasePool,
        cliRunner: (any CLIRunnerProtocol)? = ProcessCLIRunner.makeDefault(),
        notifier: ProjectNotifying = NotificationService.shared
    ) {
        let vm = ProjectsViewModel(dbPool: dbPool, cli: cliRunner.map { ProjectCLI(runner: $0) })
        let notices = ProjectNotificationCenter(dbPool: dbPool, notifier: notifier)
        vm.onProjectCreated = { [weak self, weak notices] project in
            notices?.seedBaseline(project: project)
            self?.projectTerminalCenter.start(project: project, firstRun: true)
        }
        vm.onOwnerWrite = { [weak notices] projectID, subject in
            notices?.recordOwnerWrite(projectID: projectID, subject: subject)
        }
        notices.onPolled = { [weak vm] in await vm?.reload() }
        projectsViewModel = vm
        projectNotificationCenter = notices
        // The first poll also loads the list (onPolled → reload).
        notices.start()
    }
```

(`seedBaseline` runs before the terminal starts, so nothing the first-run setup writes can predate the baseline.) Notification permission is already requested at launch by `startDigestWatcher`; without it `UNUserNotificationCenter.add` is a silent no-op, the same as every other push.

`WatchtowerDesktop/Sources/Views/Settings/NotificationSettings.swift` — add the storage:

```swift
    @AppStorage(ProjectNotificationCenter.enabledKey) private var notifyProjects = true
```

and in `Section("Notification Types")`:

```swift
                Toggle("Project notifications", isOn: $notifyProjects)
                    .help("Agent questions, documents ready for review, answered comments, finished targets")
```

- [ ] **Step 6: Run — PASS**

```bash
make test-swift FILTER=ProjectNotificationCenterTests > /tmp/p18c.log 2>&1; echo "exit=$?"
make test-swift FILTER=ProjectNotificationPolicyTests > /tmp/p18a.log 2>&1; echo "exit=$?"
make test-swift FILTER=NotificationRouteTests > /tmp/p18d.log 2>&1; echo "exit=$?"
make test-swift FILTER=ProjectsViewModelTests > /tmp/p18e.log 2>&1; echo "exit=$?"
make test-swift FILTER=ProjectQueriesTests > /tmp/p18b.log 2>&1; echo "exit=$?"
make lint-swift > /tmp/p18-lint.log 2>&1; echo "exit=$?"
```
Expected: every `exit=0`. Bounded mutation check (once): remove the `!current.ownerTouched.contains(.document(id))` clause → `testOwnerWritesNeverNotify` and `testOwnerResolvingTheLastCommentDoesNotAnnounceAllAnswered` fail; change `coalesceThreshold` to 4 → `testThreeOrMoreOfOneKindCoalesceIntoOneSummary` fails; revert.

Manual smoke (`make app-dev`): in the embedded terminal ask Claude Code to "add a comment on the first target asking me a question" → within 30 s a banner "Agent asks on ‹target›"; clicking it opens the project on the Board pane.

- [ ] **Step 7: Commit**

```bash
git add WatchtowerDesktop/Sources/WatchtowerCore/Services/ProjectNotificationPolicy.swift \
        WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ProjectQueries+Activity.swift \
        WatchtowerDesktop/Sources/Services/ProjectNotificationCenter.swift \
        WatchtowerDesktop/Sources/Services/NotificationService.swift \
        WatchtowerDesktop/Sources/App/WatchtowerApp.swift \
        WatchtowerDesktop/Sources/App/NotificationForwarding.swift \
        WatchtowerDesktop/Sources/App/AppState.swift \
        WatchtowerDesktop/Sources/Views/Settings/NotificationSettings.swift \
        WatchtowerDesktop/Tests/Core/ProjectNotificationPolicyTests.swift \
        WatchtowerDesktop/Tests/Core/ProjectQueriesTests.swift \
        WatchtowerDesktop/Tests/ProjectNotificationCenterTests.swift \
        WatchtowerDesktop/Tests/NotificationRouteTests.swift \
        WatchtowerDesktop/Tests/ProjectsViewModelTests.swift
git commit -m "$(cat <<'EOF'
feat(desktop): owner notifications for project activity

A 30 s poll compares each project's persisted snapshot with the current
one: an agent question on a target, a document attached or revised, the
last open comment on a document answered, a target done. Bursts coalesce,
the owner's own writes never notify, and a click opens the project pane.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Lo9jbbmXQcr3qHo5f3pLD8
EOF
)"
```

---

## Phase gate (controller, once)

After Task 18: `bash scripts/dev-health.sh`, then `make test-swift > /tmp/p4-gate.log 2>&1; echo "exit=$?"` and `make lint-all > /tmp/p4-lint.log 2>&1; echo "exit=$?"`. Both must be `exit=0` (read the XCTest failures above the swift-testing summary, not only the last line). Then the manual checklist items from Tasks 16–18 on a real build (`make app-dev`), including: New project on a folder with a space in its name; a folder under `~/Documents` shows the warning; no TCC prompt for a folder outside the protected locations.

## Interface errata

1. **`ProjectCLI` does not wrap `project list` or `integrate remove`.** The Desktop reads projects straight from the DB (`ProjectQueries.fetchAll`/`summaries`), which is what every other tab does; wrapping `list` would add a second, divergent read path. `integrate remove --project N` is never called on its own by the Desktop — `project delete` runs the removal (Task 4), and Task 20's delete flow calls `ProjectCLI.delete`. Adding unused wrappers would also trip Periphery.
2. **`integrate status --project N --json` shape.** The Desktop decodes `{"skill":"<devpack State>","hook":<bool>,"mcp":<bool>}` (lowercase keys; `skill` is one of `installed|updated|unchanged|drifted|missing|foreign`). Task 12's `ProjectStatus{ Skill Status; Hook, MCP bool }` has no JSON tags in the index; Task 12 must marshal exactly these keys — a struct with `json:"skill"`, `json:"hook"`, `json:"mcp"` (and `Skill` reduced to its `State` string) — or this decoder needs to change with it.
3. **`ProjectQueries` signatures take the GRDB `Database` first** (`fetchAll(_ db:)`, `fetch(_:id:)`, `comments(_:documentID:)`, `reply(_:to:body:)`, …) — the house shape of every `*Queries` enum; the index listed them without it. `addOwnerComment(...)` is concretely `addOwnerComment(_:projectID:targetID:documentID:anchor:body:)`.
4. **Extra Core API beyond the index list:** `ProjectQueries.document(_:id:)`, `summaries(_:)`, `documentListItems(_:projectID:)`, `activitySnapshot(_:project:afterAgentCommentID:)`; models `ProjectSummary`, `ProjectDocumentListItem`, `ProjectCommentThread`, `ProjectSubject`, `ProjectRoute`, `ProjectPane`; `DocumentRendering`/`RenderedDocument` (the rendered plain text anchors need, spec §6.3); `ProjectFolderPolicy`; `ProjectTerminalLaunch`. `CommentAnchor` is created (data shape only) in Task 13 because `ProjectComment.anchor` returns it; Task 15 adds `make`/`locate`.
5. **`CommentAnchor.make`'s `headings` offsets are UTF-16** (what `NSTextView`/`NSRange` give), while prefix/suffix length (64) counts `Character`s. The index did not pin the unit.
6. **`ProjectNotificationPolicy.decide(previous:current:)`** keeps the index's signature; `Snapshot` is nested (`ProjectNotificationPolicy.Snapshot`) and carries the owner's own writes (`ownerTouched`) — that is how "never the owner's own writes" stays pure. `ProjectNotice` is a top-level type.
7. **`ProjectTerminalCenter` owns one SwiftTerm `LocalProcessTerminalView` per project**, not a bare `LocalProcess`: the process's pty output only has somewhere to go through the view, and keeping the view in the center is what preserves scrollback across navigation. It never calls SwiftTerm's `terminate()` (unconditional SIGTERM to a possibly reaped pid); teardown is `killpg` SIGHUP → SIGKILL after 3 s.
8. **`AppState.initProjects` gains `notifier:`** (defaulted) so no test reaches `UNUserNotificationCenter`; `QuitCoordinator.shouldTerminate`/`TrayAppDelegate.terminateDecision` gain a defaulted `closeTerminals:` between `closeChatSessions:` and `stopDaemon:`.
9. **No feature flag for the tab.** Spec D1 calls Projects "its own feature", but no phase registers a `features` id for it, so `SidebarDestination.projects.requiredFeatures` is nil (always visible). If Task 9/22 adds a feature id, add it there in the same change.
