# Projects POC — Phase 1: Go core — Tasks 1–5

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The data layer and CLI of the Projects feature: migration 00081 (`projects`, `project_sources`, `project_documents`, `project_comments`, `targets.project_id`), the project store, project targets that never leave their board (PROJ-01), the board query, and the `watchtower project create|list|show|board|delete|brief` commands — `brief` being the SessionStart hook body Phase 3 installs.

**Architecture:** Everything lives in `internal/db` (store, comments, board, project targets) and `cmd` (`project.go`, `project_brief.go`). Existing target readers get a `project_id IS NULL` predicate; `GetTargets` gets a `TargetFilter.ProjectID` scope whose zero value excludes project targets, so every existing caller is excluded without an edit. The brief renderer is a pure function over the board, the new-for-agent comments and the documents, capped at 4000 runes.

**Tech Stack:** Go 1.25, cobra, modernc SQLite + goose, testify. Swift only for the test-schema mirror (Task 1).

**Spec:** `docs/superpowers/specs/2026-09-29-project-board-poc-design.md` (§3 data, §4.1 db layer, §4.4 CLI). The plan index `docs/superpowers/plans/2026-09-29-projects-poc.md` holds the Global Constraints, Review Focus and the binding cross-task interfaces — read both first.

## Constraints for this phase (from the index, restated)

- Everything in the repo in English; placeholders only in fixtures (`acme`, `example.com`, `t.TempDir()`, `/tmp/acme`).
- Migration `internal/db/migrations/00081_projects.sql`; mirrored in `internal/db/schema.sql`, `TestAllTablesExist`, the schema golden (`go test ./internal/db/ -run TestSchemaGolden -update`), and `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift`.
- Project targets: `level='custom'`, `custom_label='project'`, `period_start=period_end=<UTC YYYY-MM-DD of creation>`, `source_type='chat'`, `ownership='mine'`, `status='todo'`.
- `project brief` output ≤ 4000 chars, always exit 0.
- Inner loop only: `go test ./internal/<pkg>` (no `-count=1`), `go test ./cmd -run '<Name>'`, `make test-swift FILTER=<Class>`, `make lint-diff`. The full gate runs once per phase, by the controller.
- Functions stay small (sentrux complexity gate); no SQL built by concatenating a non-constant string into a call argument (gosec G202).
- Run `gofmt -w` on every touched Go file before `make lint-diff` (struct-field and comment alignment in the edit snippets below is re-flowed by gofmt, not hand-kept). Never name a variable after a builtin (`real`, `min`, `len`, …): the `predeclared` linter is on.
- One commit per task, staging only the files the task lists (never `git add -A`); every commit message ends with the two lines
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_01Lo9jbbmXQcr3qHo5f3pLD8`.

## Review Focus items this phase owns

- **Folder edge cases** (index item 1): Task 2 — `TestResolveProjectFolder_ResolvesSymlinksSpacesAndUnicode`, `TestResolveProjectFolder_RefusesMissingAndNonDirectories`, `TestResolveProjectFolder_RelativePathBecomesAbsolute`, `TestCreateProject_SecondBindingOfTheSameFolderIsRefused`; Task 4 — `TestProject_CreateStoresTheResolvedFolderAndDefaultsTheName`, `TestProject_CreateRefusesMissingAndAlreadyBoundFolders`; Task 5 — `TestProjectBrief_MissingFolderPrintsOneLine`.
- **Project deleted while CC is connected** (index item 5, the hook half): Task 5 — `TestProjectBrief_DeletedProjectPrintsOneLineAndExitsZero`.
- **PROJ-01**: Task 3 — `TestProj01_ProjectTargetsNeverReachNonBoardReaders` (every `internal/db` reader of spec §4.1) plus its package-local companions `TestProj01_DayPlanGatherExcludesProjectTargets` (`internal/dayplan`), `TestProj01_ExtractSnapshotExcludesProjectTargets` and `TestProj01_NextStepSkipsProjectTarget` (`internal/targets`).

## Decisions this file makes (spec ambiguities resolved)

- **Flat comment threads.** `AddProjectComment` re-points a reply to a reply at the thread root, so every reply's `parent_id` is its root's id. The reply inherits the root's `target_id`/`document_id` and carries no anchor.
- **"Newer" means a higher id.** "Owner replies newer than their thread's latest agent reply" compares comment ids (rowids grow monotonically), not `created_at`, whose one-second resolution would tie. One SQL fragment, `newForAgentPredicate`, serves both `ListProjectComments` and the board counters.
- **`WithTx` and `ErrNotInProject` land in Task 2**, not Task 3: document upserts and comment scope checks need them first. `WithTx`'s callback must only use the `*sql.Tx` it is given (the pool has one connection; calling `db.X` inside would deadlock).
- **`CreateProjectTargetsTx` takes a batch.** Items reference an earlier item of the same batch by a 1-based `BatchParent` (Task 7 maps `parent_key` onto it), or an existing target of the same project by `ParentID`, never both. Validation happens per item inside the caller's transaction, so one bad item rolls back the whole plan.
- **`TargetFilter.ProjectID` is applied through one helper, `projectScope`**, called unconditionally by `GetTargets`: 0 → `project_id IS NULL`, N → `project_id = N`. `GetTargetByID` stays unscoped — the project tools (Task 7) load a target by id and check its project themselves.
- **`internal/targets/pipeline.go` needs no code change.** Its extract and link snapshots call `GetTargets` with a zero `ProjectID`, so they already exclude project targets; `TestProj01_ExtractSnapshotExcludesProjectTargets` pins it. `GenerateNextStep` (single target) returns `targets.ErrProjectTarget` before any AI call and records no attempt.
- **`channel_stats.go`** can never match a project target today (they are `source_type='chat'`, the CTEs join `digest`/`inbox` sources), but gets the predicate anyway; the guard test gives the project target a `digest` source to prove the predicate, not the coincidence, excludes it.
- **`UpdateTarget` writes `project_id`** (full-row update, round-trips the value it loaded). `CreateTarget` inserts `t.ProjectID`.
- **The 00081 Down deletes project targets before dropping the column** — otherwise a rollback would turn every board item into a personal target visible in the Targets tab.
- **Document re-attach merge.** `UpsertProjectDocument` on an existing `(project, rel_path)` keeps the stored kind/title/target when the new value is empty/unset, and always bumps `updated_at`.
- **Board shape.** `GetProjectBoard` does not check that the project exists (an unknown id yields an empty board); CLI callers call `GetProject` first. Siblings are ordered in_progress, blocked, todo, done, then dismissed/snoozed, then id. A target whose parent is outside the project's set is a root. A parent cycle (not creatable through any project writer) is skipped rather than recursed.
- **Brief budget in runes.** 4000 = `utf8.RuneCountInString`. Header (name/folder line clipped to 240 runes) and the two rule lines are fixed; the rest is split between the open tree and the comments (half each when there are comments). A section that overflows ends with `… N more targets (project_board)` / `… N more comments (list_comments)`. Closed = `done`/`dismissed`; a closed node is omitted but its open children are listed at its depth.
- **`project brief` skips the root pre-run.** `rootCmd`'s `PersistentPreRunE` (`ensureSchemaFormat`) loads the config and would fail the hook with a non-zero exit on a malformed `config.yaml` before `RunE` runs; `projectBriefCmd` overrides it with a no-op (the `extract-pdf-text` precedent), so every failure — config included — becomes the one-line brief. `TestProjectBrief_UnreadableConfigPrintsOneLine` pins it.
- **CLI DB access reuses `openJiraCmdDB`** (the generic config → workspace → `db.Open` preamble; `openActionsCmd` precedent).
- **`project list --json` carries no counts.** The Desktop computes list badges through GRDB (Task 13); `show` carries per-status counts.
- **PROJ-02 is split.** Task 2's `TestProj02_DeleteProjectLeavesNoRows` guards the DB half (no project, target, source, document or comment row); Task 12 adds the folder half (no installed file or registration).

---

## Task 1: Migration 00081 + schema mirrors

**Files:**
- Create: `internal/db/migrations/00081_projects.sql`
- Create: `internal/db/projects_migration_test.go`
- Create: `WatchtowerDesktop/Tests/Core/ProjectSchemaMirrorTests.swift`
- Modify: `internal/db/schema.sql` (targets table + index; new block at the end of the file)
- Modify: `internal/db/db_test.go` (`TestAllTablesExist`)
- Modify: `internal/db/testdata/schema_v73.golden` (regenerated)
- Modify: `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: tables `projects`, `project_sources`, `project_documents`, `project_comments` exactly as spec §3; `targets.project_id INTEGER REFERENCES projects(id) ON DELETE CASCADE` + `idx_targets_project`; child indexes `idx_project_documents_target`, `idx_project_comments_project`, `idx_project_comments_target`, `idx_project_comments_document`, `idx_project_comments_parent`.

- [ ] **Step 1: Write the failing migration tests**

Create `internal/db/projects_migration_test.go`:

```go
package db

import (
	"path/filepath"
	"testing"

	"github.com/pressly/goose/v3"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestMigration00081_CreatesProjectTablesAndTargetsColumn pins the spec §3
// shape: four project tables with their columns, and targets.project_id with
// its index.
func TestMigration00081_CreatesProjectTablesAndTargetsColumn(t *testing.T) {
	d := openTestDB(t)

	want := map[string][]string{
		"projects":          {"id", "name", "folder_path", "description", "created_at", "updated_at"},
		"project_sources":   {"id", "project_id", "kind", "ref", "label"},
		"project_documents": {"id", "project_id", "target_id", "rel_path", "kind", "title", "created_at", "updated_at"},
		"project_comments": {"id", "project_id", "target_id", "document_id", "parent_id", "author", "agent_label",
			"body", "anchor_quote", "anchor_prefix", "anchor_suffix", "anchor_heading", "status", "created_at", "read_at"},
	}
	for table, cols := range want {
		got := columnNames(t, d.DB, table)
		for _, c := range cols {
			assert.True(t, got[c], "%s.%s missing", table, c)
		}
	}
	assert.True(t, columnNames(t, d.DB, "targets")["project_id"], "targets.project_id missing")

	for _, idx := range []string{"idx_targets_project", "idx_project_documents_target", "idx_project_comments_project",
		"idx_project_comments_target", "idx_project_comments_document", "idx_project_comments_parent"} {
		var name string
		require.NoError(t, d.QueryRow(`SELECT name FROM sqlite_master WHERE type = 'index' AND name = ?`, idx).Scan(&name),
			"index %s missing", idx)
	}
}

// TestMigration00081_ConstraintsHold: the UNIQUE folder, the kind/author/
// status CHECKs, the "a comment hangs off something" CHECK, and the cascade
// from a project to its targets and their comments.
func TestMigration00081_ConstraintsHold(t *testing.T) {
	d := openTestDB(t)
	res, err := d.Exec(`INSERT INTO projects (name, folder_path) VALUES ('acme', '/tmp/acme')`)
	require.NoError(t, err)
	pid, err := res.LastInsertId()
	require.NoError(t, err)

	_, err = d.Exec(`INSERT INTO projects (name, folder_path) VALUES ('again', '/tmp/acme')`)
	assert.Error(t, err, "folder_path is UNIQUE")
	_, err = d.Exec(`INSERT INTO project_sources (project_id, kind, ref) VALUES (?, 'wiki', 'x')`, pid)
	assert.Error(t, err, "project_sources.kind CHECK")
	_, err = d.Exec(`INSERT INTO project_documents (project_id, rel_path, kind) VALUES (?, 'a.md', 'memo')`, pid)
	assert.Error(t, err, "project_documents.kind CHECK")
	_, err = d.Exec(`INSERT INTO project_comments (project_id, author, body) VALUES (?, 'owner', 'orphan')`, pid)
	assert.Error(t, err, "a comment needs a target, a document or a parent")

	res, err = d.Exec(`INSERT INTO targets (text, period_start, period_end, project_id)
		VALUES ('board item', '2026-09-29', '2026-09-29', ?)`, pid)
	require.NoError(t, err)
	tid, err := res.LastInsertId()
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO project_comments (project_id, target_id, author, body) VALUES (?, ?, 'bot', 'x')`, pid, tid)
	assert.Error(t, err, "project_comments.author CHECK")
	_, err = d.Exec(`INSERT INTO project_comments (project_id, target_id, author, body, status)
		VALUES (?, ?, 'agent', 'x', 'closed')`, pid, tid)
	assert.Error(t, err, "project_comments.status CHECK")
	_, err = d.Exec(`INSERT INTO project_comments (project_id, target_id, author, body) VALUES (?, ?, 'agent', 'blocked?')`, pid, tid)
	require.NoError(t, err)

	_, err = d.Exec(`DELETE FROM projects WHERE id = ?`, pid)
	require.NoError(t, err)
	var n int
	require.NoError(t, d.QueryRow(`SELECT (SELECT COUNT(*) FROM targets) + (SELECT COUNT(*) FROM project_comments)`).Scan(&n))
	assert.Zero(t, n, "deleting a project cascades to its targets and their comments")
}

// TestMigration00081_DownDropsProjectsAndTheirTargets: other tests roll back
// through 00081 (goose.DownTo to older versions), so its Down must be real —
// and it must take the project targets with it, or a rollback would turn every
// board item into a personal target.
func TestMigration00081_DownDropsProjectsAndTheirTargets(t *testing.T) {
	d, err := Open(filepath.Join(t.TempDir(), "projects-cycle.db"))
	require.NoError(t, err)
	defer d.Close()

	_, err = d.Exec(`INSERT INTO targets (text, period_start, period_end) VALUES ('personal', '2026-09-29', '2026-09-29')`)
	require.NoError(t, err)
	res, err := d.Exec(`INSERT INTO projects (name, folder_path) VALUES ('acme', '/tmp/acme')`)
	require.NoError(t, err)
	pid, err := res.LastInsertId()
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO targets (text, period_start, period_end, project_id)
		VALUES ('board item', '2026-09-29', '2026-09-29', ?)`, pid)
	require.NoError(t, err)

	// DownTo(80), not a bare Down: a later migration can move the tip past 00081.
	require.NoError(t, goose.DownTo(d.DB, "migrations", 80))
	assert.False(t, columnNames(t, d.DB, "targets")["project_id"], "Down removes targets.project_id")
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM targets`).Scan(&n))
	assert.Equal(t, 1, n, "Down keeps personal targets and drops project targets")
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'project%'`).Scan(&n))
	assert.Zero(t, n, "Down drops every project table")

	require.NoError(t, goose.Up(d.DB, "migrations"))
	assert.True(t, columnNames(t, d.DB, "targets")["project_id"], "re-Up restores the column")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `go test ./internal/db/ -run 'TestMigration00081'`
Expected: FAIL — `projects.id missing` assertions / `no such table: projects`.

- [ ] **Step 3: Write migration 00081**

Create `internal/db/migrations/00081_projects.sql`:

```sql
-- +goose Up
-- Projects POC (spec docs/superpowers/specs/2026-09-29-project-board-poc-design.md §3):
-- a folder-bound project, its sources, the documents Claude Code attaches and
-- the owner<->agent comments on targets and documents. targets.project_id puts
-- a target on exactly one project board; a project target never reaches a
-- non-board reader (PROJ-01, docs/inventory/projects.md).
CREATE TABLE projects (
    id          INTEGER PRIMARY KEY,
    name        TEXT NOT NULL,
    folder_path TEXT NOT NULL UNIQUE,          -- absolute, symlinks resolved
    description TEXT NOT NULL DEFAULT '',
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE TABLE project_sources (
    id         INTEGER PRIMARY KEY,
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    kind       TEXT NOT NULL CHECK(kind IN ('slack_channel','jira_project','confluence_space','person','link')),
    ref        TEXT NOT NULL,
    label      TEXT NOT NULL DEFAULT '',
    UNIQUE(project_id, kind, ref)
);

CREATE TABLE project_documents (
    id         INTEGER PRIMARY KEY,
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    target_id  INTEGER REFERENCES targets(id) ON DELETE SET NULL,
    rel_path   TEXT NOT NULL,
    kind       TEXT NOT NULL DEFAULT 'doc' CHECK(kind IN ('spec','plan','doc')),
    title      TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),  -- re-attach bumps it ("revised")
    UNIQUE(project_id, rel_path)
);
CREATE INDEX idx_project_documents_target ON project_documents(target_id);

CREATE TABLE project_comments (
    id             INTEGER PRIMARY KEY,
    project_id     INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    target_id      INTEGER REFERENCES targets(id) ON DELETE CASCADE,
    document_id    INTEGER REFERENCES project_documents(id) ON DELETE CASCADE,
    parent_id      INTEGER REFERENCES project_comments(id) ON DELETE CASCADE,
    author         TEXT NOT NULL CHECK(author IN ('owner','agent')),
    agent_label    TEXT NOT NULL DEFAULT '',
    body           TEXT NOT NULL,
    anchor_quote   TEXT NOT NULL DEFAULT '',
    anchor_prefix  TEXT NOT NULL DEFAULT '',
    anchor_suffix  TEXT NOT NULL DEFAULT '',
    anchor_heading TEXT NOT NULL DEFAULT '',
    status         TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','resolved','outdated')),
    created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    read_at        TEXT NOT NULL DEFAULT '',
    CHECK (target_id IS NOT NULL OR document_id IS NOT NULL OR parent_id IS NOT NULL)
);
CREATE INDEX idx_project_comments_project  ON project_comments(project_id, created_at);
CREATE INDEX idx_project_comments_target   ON project_comments(target_id);
CREATE INDEX idx_project_comments_document ON project_comments(document_id);
CREATE INDEX idx_project_comments_parent   ON project_comments(parent_id);

ALTER TABLE targets ADD COLUMN project_id INTEGER REFERENCES projects(id) ON DELETE CASCADE;
CREATE INDEX idx_targets_project ON targets(project_id);

-- +goose Down
-- Project targets go with their projects: left behind without project_id they
-- would surface as personal targets in every reader.
DELETE FROM targets WHERE project_id IS NOT NULL;
DROP INDEX IF EXISTS idx_targets_project;
ALTER TABLE targets DROP COLUMN project_id;
DROP TABLE IF EXISTS project_comments;
DROP TABLE IF EXISTS project_documents;
DROP TABLE IF EXISTS project_sources;
DROP TABLE IF EXISTS projects;
```

- [ ] **Step 4: Mirror into `internal/db/schema.sql`**

In the `targets` table, replace

```sql
    next_step_attempted_at TEXT NOT NULL DEFAULT ''    -- UTC ISO8601 of the most recent attempt (success or failure)
);
```

with

```sql
    next_step_attempted_at TEXT NOT NULL DEFAULT '',   -- UTC ISO8601 of the most recent attempt (success or failure)
    project_id          INTEGER REFERENCES projects(id) ON DELETE CASCADE  -- set = lives only on that project's board (00081)
);
```

and after the line `    WHERE notified_at = '' AND due_date != '';` (end of `idx_targets_due_unfired`) add

```sql
CREATE INDEX IF NOT EXISTS idx_targets_project     ON targets(project_id);
```

Append at the very end of the file (after the last `END;` of `chat_conversations_fts_au`):

```sql

-- Projects (00081, spec 2026-09-29-project-board-poc-design.md): a folder-bound
-- project worked on by Claude Code through `watchtower mcp --project N`. Its
-- targets carry targets.project_id and appear only on its board. Documents are
-- files inside folder_path (rel_path); comments hang off a target, a document
-- or a thread root (parent_id; replies are flat, parent_id = the root).
-- author 'agent' comments are unread for the owner while read_at = ''.
CREATE TABLE IF NOT EXISTS projects (
    id          INTEGER PRIMARY KEY,
    name        TEXT NOT NULL,
    folder_path TEXT NOT NULL UNIQUE,
    description TEXT NOT NULL DEFAULT '',
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE TABLE IF NOT EXISTS project_sources (
    id         INTEGER PRIMARY KEY,
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    kind       TEXT NOT NULL CHECK(kind IN ('slack_channel','jira_project','confluence_space','person','link')),
    ref        TEXT NOT NULL,
    label      TEXT NOT NULL DEFAULT '',
    UNIQUE(project_id, kind, ref)
);

CREATE TABLE IF NOT EXISTS project_documents (
    id         INTEGER PRIMARY KEY,
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    target_id  INTEGER REFERENCES targets(id) ON DELETE SET NULL,
    rel_path   TEXT NOT NULL,
    kind       TEXT NOT NULL DEFAULT 'doc' CHECK(kind IN ('spec','plan','doc')),
    title      TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    UNIQUE(project_id, rel_path)
);
CREATE INDEX IF NOT EXISTS idx_project_documents_target ON project_documents(target_id);

CREATE TABLE IF NOT EXISTS project_comments (
    id             INTEGER PRIMARY KEY,
    project_id     INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    target_id      INTEGER REFERENCES targets(id) ON DELETE CASCADE,
    document_id    INTEGER REFERENCES project_documents(id) ON DELETE CASCADE,
    parent_id      INTEGER REFERENCES project_comments(id) ON DELETE CASCADE,
    author         TEXT NOT NULL CHECK(author IN ('owner','agent')),
    agent_label    TEXT NOT NULL DEFAULT '',
    body           TEXT NOT NULL,
    anchor_quote   TEXT NOT NULL DEFAULT '',
    anchor_prefix  TEXT NOT NULL DEFAULT '',
    anchor_suffix  TEXT NOT NULL DEFAULT '',
    anchor_heading TEXT NOT NULL DEFAULT '',
    status         TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','resolved','outdated')),
    created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    read_at        TEXT NOT NULL DEFAULT '',
    CHECK (target_id IS NOT NULL OR document_id IS NOT NULL OR parent_id IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS idx_project_comments_project  ON project_comments(project_id, created_at);
CREATE INDEX IF NOT EXISTS idx_project_comments_target   ON project_comments(target_id);
CREATE INDEX IF NOT EXISTS idx_project_comments_document ON project_comments(document_id);
CREATE INDEX IF NOT EXISTS idx_project_comments_parent   ON project_comments(parent_id);
```

- [ ] **Step 5: Register the tables in `TestAllTablesExist`**

In `internal/db/db_test.go`, replace

```go
		"chat_artifacts", "chat_projects", "chat_project_sources", "chat_fts", "chat_title_fts",
	}
```

with

```go
		"chat_artifacts", "chat_projects", "chat_project_sources", "chat_fts", "chat_title_fts",
		"projects", "project_sources", "project_documents", "project_comments",
	}
```

- [ ] **Step 6: Regenerate the schema golden**

Run: `go test ./internal/db/ -run TestSchemaGolden -update -v`
Expected: PASS with the log line `wrote testdata/schema_v73.golden (… bytes)` (the file name stays `schema_v73.golden`; the test hardcodes it).

- [ ] **Step 7: Run the Go tests**

Run: `go test ./internal/db/ -run 'TestMigration00081|TestMigrationIdempotent|TestAllTablesExist|TestSchemaGolden'`
Expected: PASS.

Run: `go test ./internal/db/`
Expected: PASS. If a `goose.DownTo` test elsewhere in the package fails, the 00081 Down is wrong — fix the SQL, never the test.

- [ ] **Step 8: Write the failing Swift mirror test**

Create `WatchtowerDesktop/Tests/Core/ProjectSchemaMirrorTests.swift`:

```swift
import XCTest
import GRDB
import WatchtowerTestSupport

/// The test schema mirror must carry migration 00081 (projects) so Desktop
/// queries written against it see the real shape.
final class ProjectSchemaMirrorTests: XCTestCase {
    func testMirrorHasProjectTablesAndTargetsProjectID() throws {
        let queue = try TestDatabase.create()
        try queue.read { db in
            for table in ["projects", "project_sources", "project_documents", "project_comments"] {
                XCTAssertTrue(try db.tableExists(table), "missing \(table)")
            }
            let columns = try db.columns(in: "targets").map(\.name)
            XCTAssertTrue(columns.contains("project_id"))
        }
    }

    func testDeletingAProjectCascadesToItsTargetsAndComments() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            try db.execute(sql: "INSERT INTO projects (name, folder_path) VALUES ('acme', '/tmp/acme')")
            let projectID = db.lastInsertedRowID
            try db.execute(
                sql: """
                INSERT INTO targets (text, period_start, period_end, project_id)
                VALUES ('board item', '2026-09-29', '2026-09-29', ?)
                """,
                arguments: [projectID]
            )
            let targetID = db.lastInsertedRowID
            try db.execute(
                sql: "INSERT INTO project_comments (project_id, target_id, author, body) VALUES (?, ?, 'agent', 'q')",
                arguments: [projectID, targetID]
            )
            try db.execute(sql: "DELETE FROM projects WHERE id = ?", arguments: [projectID])
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM targets"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM project_comments"), 0)
        }
    }
}
```

Run: `make test-swift FILTER=ProjectSchemaMirrorTests`
Expected: FAIL — `missing projects`, and `no such table: projects` in the second test.

- [ ] **Step 9: Mirror into the Swift test schema**

In `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift`, in the `targets` table replace

```
        next_step_attempts     INTEGER NOT NULL DEFAULT 0,
        next_step_attempted_at TEXT NOT NULL DEFAULT ''
    );
```

with

```
        next_step_attempts     INTEGER NOT NULL DEFAULT 0,
        next_step_attempted_at TEXT NOT NULL DEFAULT '',
        project_id          INTEGER REFERENCES projects(id) ON DELETE CASCADE
    );
```

After the two lines

```
    CREATE INDEX IF NOT EXISTS idx_targets_due_unfired ON targets(due_date)
        WHERE notified_at = '' AND due_date != '';
```

add

```
    CREATE INDEX IF NOT EXISTS idx_targets_project     ON targets(project_id);
```

Before the closing `    """` of the `schema` literal (right after the last `    END;` of `chat_conversations_fts_au`) add:

```

    CREATE TABLE IF NOT EXISTS projects (
        id          INTEGER PRIMARY KEY,
        name        TEXT NOT NULL,
        folder_path TEXT NOT NULL UNIQUE,
        description TEXT NOT NULL DEFAULT '',
        created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
        updated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
    );

    CREATE TABLE IF NOT EXISTS project_sources (
        id         INTEGER PRIMARY KEY,
        project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
        kind       TEXT NOT NULL CHECK(kind IN ('slack_channel','jira_project','confluence_space','person','link')),
        ref        TEXT NOT NULL,
        label      TEXT NOT NULL DEFAULT '',
        UNIQUE(project_id, kind, ref)
    );

    CREATE TABLE IF NOT EXISTS project_documents (
        id         INTEGER PRIMARY KEY,
        project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
        target_id  INTEGER REFERENCES targets(id) ON DELETE SET NULL,
        rel_path   TEXT NOT NULL,
        kind       TEXT NOT NULL DEFAULT 'doc' CHECK(kind IN ('spec','plan','doc')),
        title      TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
        updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
        UNIQUE(project_id, rel_path)
    );
    CREATE INDEX IF NOT EXISTS idx_project_documents_target ON project_documents(target_id);

    CREATE TABLE IF NOT EXISTS project_comments (
        id             INTEGER PRIMARY KEY,
        project_id     INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
        target_id      INTEGER REFERENCES targets(id) ON DELETE CASCADE,
        document_id    INTEGER REFERENCES project_documents(id) ON DELETE CASCADE,
        parent_id      INTEGER REFERENCES project_comments(id) ON DELETE CASCADE,
        author         TEXT NOT NULL CHECK(author IN ('owner','agent')),
        agent_label    TEXT NOT NULL DEFAULT '',
        body           TEXT NOT NULL,
        anchor_quote   TEXT NOT NULL DEFAULT '',
        anchor_prefix  TEXT NOT NULL DEFAULT '',
        anchor_suffix  TEXT NOT NULL DEFAULT '',
        anchor_heading TEXT NOT NULL DEFAULT '',
        status         TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','resolved','outdated')),
        created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
        read_at        TEXT NOT NULL DEFAULT '',
        CHECK (target_id IS NOT NULL OR document_id IS NOT NULL OR parent_id IS NOT NULL)
    );
    CREATE INDEX IF NOT EXISTS idx_project_comments_project  ON project_comments(project_id, created_at);
    CREATE INDEX IF NOT EXISTS idx_project_comments_target   ON project_comments(target_id);
    CREATE INDEX IF NOT EXISTS idx_project_comments_document ON project_comments(document_id);
    CREATE INDEX IF NOT EXISTS idx_project_comments_parent   ON project_comments(parent_id);
```

- [ ] **Step 10: Run the Swift tests**

Run: `make test-swift FILTER=ProjectSchemaMirrorTests`
Expected: PASS (2 tests).

Run: `make test-swift FILTER=TargetQueries`
Expected: PASS — the existing target query suites still load the mirror.

- [ ] **Step 11: Lint**

Run: `make lint-diff`
Expected: no new issues.

- [ ] **Step 12: Commit**

```bash
git add internal/db/migrations/00081_projects.sql internal/db/projects_migration_test.go \
  internal/db/schema.sql internal/db/db_test.go internal/db/testdata/schema_v73.golden \
  WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift WatchtowerDesktop/Tests/Core/ProjectSchemaMirrorTests.swift
git commit -m "feat(db): projects tables and targets.project_id (migration 00081)" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Lo9jbbmXQcr3qHo5f3pLD8"
```

---

## Task 2: Project store (`internal/db/projects.go`, `project_comments.go`)

**Files:**
- Create: `internal/db/projects.go`
- Create: `internal/db/project_comments.go`
- Create: `internal/db/projects_test.go`
- Create: `internal/db/project_comments_test.go`

**Interfaces:**
- Consumes: Task 1 tables; `targetsQuerier` (`internal/db/targets.go`).
- Produces (package `db`), the index signatures verbatim plus two additions (see the errata):
  ```go
  type Project struct{ ID int64; Name, FolderPath, Description, CreatedAt, UpdatedAt string }
  type ProjectSource struct{ ID, ProjectID int64; Kind, Ref, Label string }
  type ProjectDocument struct{ ID, ProjectID int64; TargetID sql.NullInt64; RelPath, Kind, Title, CreatedAt, UpdatedAt string }
  type ProjectComment struct{ ID, ProjectID int64; TargetID, DocumentID, ParentID sql.NullInt64; Author, AgentLabel, Body, AnchorQuote, AnchorPrefix, AnchorSuffix, AnchorHeading, Status, CreatedAt, ReadAt string }
  type ProjectCommentFilter struct{ ProjectID, TargetID, DocumentID int64; NewForAgent bool }
  var ErrProjectFolderTaken, ErrProjectNotFound error
  var ErrNotInProject = errors.New("does not belong to this project")           // addition
  func (db *DB) WithTx(fn func(*sql.Tx) error) error                            // addition (moved from Task 3)
  func ResolveProjectFolder(dir string) (string, error)
  func (db *DB) CreateProject(name, folder string) (int64, error)
  func (db *DB) GetProject(id int64) (*Project, error)
  func (db *DB) ListProjects() ([]Project, error)
  func (db *DB) UpdateProjectDescription(id int64, description string) error
  func (db *DB) DeleteProject(id int64) error
  func (db *DB) AddProjectSource(s ProjectSource) (int64, error)
  func (db *DB) RemoveProjectSource(projectID, sourceID int64) error
  func (db *DB) ListProjectSources(projectID int64) ([]ProjectSource, error)
  func (db *DB) UpsertProjectDocument(d ProjectDocument) (id int64, created bool, err error)
  func (db *DB) GetProjectDocument(id int64) (*ProjectDocument, error)
  func (db *DB) ListProjectDocuments(projectID int64) ([]ProjectDocument, error)
  func (db *DB) AddProjectComment(c ProjectComment) (int64, error)
  func (db *DB) GetProjectComment(id int64) (*ProjectComment, error)
  func (db *DB) ListProjectComments(f ProjectCommentFilter) ([]ProjectComment, error)
  func (db *DB) SetProjectCommentStatus(id int64, status string) error
  func (db *DB) MarkProjectCommentsRead(projectID, targetID, documentID int64) error
  ```
  Unexported, used by Tasks 3–4: `checkTargetInProject(q targetsQuerier, projectID, targetID int64) error`, `requireProject(q targetsQuerier, projectID int64) error`, `newForAgentPredicate` (SQL fragment over alias `c`).

- [ ] **Step 1: Write the failing store tests**

Create `internal/db/projects_test.go`:

```go
package db

import (
	"database/sql"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// newTestProject creates a project bound to a fresh temp folder.
func newTestProject(t *testing.T, d *DB) int64 {
	t.Helper()
	id, err := d.CreateProject("acme", t.TempDir())
	require.NoError(t, err)
	return id
}

func nullID(id int64) sql.NullInt64 { return sql.NullInt64{Int64: id, Valid: true} }

// insertProjectTargetRow plants a project target with raw SQL, independent of
// CreateProjectTarget (Task 3).
func insertProjectTargetRow(t *testing.T, d *DB, projectID int64, text string) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO targets (text, level, custom_label, period_start, period_end, source_type, project_id)
		VALUES (?, 'custom', 'project', '2026-09-29', '2026-09-29', 'chat', ?)`, text, projectID)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

func TestResolveProjectFolder_ResolvesSymlinksSpacesAndUnicode(t *testing.T) {
	base := t.TempDir()
	realDir := filepath.Join(base, "my проект dir")
	require.NoError(t, os.Mkdir(realDir, 0o755))
	link := filepath.Join(base, "link to it")
	require.NoError(t, os.Symlink(realDir, link))
	want, err := filepath.EvalSymlinks(realDir)
	require.NoError(t, err)

	got, err := ResolveProjectFolder(link)
	require.NoError(t, err)
	assert.Equal(t, want, got, "the symlink is resolved to the real folder")
	assert.True(t, filepath.IsAbs(got))
}

func TestResolveProjectFolder_RefusesMissingAndNonDirectories(t *testing.T) {
	base := t.TempDir()
	_, err := ResolveProjectFolder(filepath.Join(base, "gone"))
	assert.Error(t, err, "a missing folder is refused")

	file := filepath.Join(base, "README.md")
	require.NoError(t, os.WriteFile(file, []byte("x"), 0o600))
	_, err = ResolveProjectFolder(file)
	assert.ErrorContains(t, err, "not a directory")

	_, err = ResolveProjectFolder("  ")
	assert.Error(t, err, "an empty folder is refused")
}

func TestResolveProjectFolder_RelativePathBecomesAbsolute(t *testing.T) {
	base := t.TempDir()
	t.Chdir(base)
	require.NoError(t, os.Mkdir("repo", 0o755))
	want, err := filepath.EvalSymlinks(filepath.Join(base, "repo"))
	require.NoError(t, err)

	got, err := ResolveProjectFolder("repo")
	require.NoError(t, err)
	assert.Equal(t, want, got)
}

func TestCreateProject_SecondBindingOfTheSameFolderIsRefused(t *testing.T) {
	d := openTestDB(t)
	folder := t.TempDir()
	id, err := d.CreateProject("acme", folder)
	require.NoError(t, err)
	assert.Positive(t, id)

	_, err = d.CreateProject("again", folder)
	assert.ErrorIs(t, err, ErrProjectFolderTaken)
	_, err = d.CreateProject("relative", "relative/dir")
	assert.Error(t, err, "an unresolved relative folder is refused")
	_, err = d.CreateProject("  ", t.TempDir())
	assert.Error(t, err, "an empty name is refused")
}

func TestGetProject_RoundTripsAndReportsNotFound(t *testing.T) {
	d := openTestDB(t)
	folder := t.TempDir()
	id, err := d.CreateProject("acme", folder)
	require.NoError(t, err)

	p, err := d.GetProject(id)
	require.NoError(t, err)
	assert.Equal(t, "acme", p.Name)
	assert.Equal(t, folder, p.FolderPath)
	assert.Empty(t, p.Description)
	assert.NotEmpty(t, p.CreatedAt)

	_, err = d.GetProject(id + 100)
	assert.ErrorIs(t, err, ErrProjectNotFound)

	list, err := d.ListProjects()
	require.NoError(t, err)
	require.Len(t, list, 1)
	assert.Equal(t, id, list[0].ID)
}

func TestUpdateProjectDescription(t *testing.T) {
	d := openTestDB(t)
	id := newTestProject(t, d)
	require.NoError(t, d.UpdateProjectDescription(id, "A CLI and a desktop app."))
	p, err := d.GetProject(id)
	require.NoError(t, err)
	assert.Equal(t, "A CLI and a desktop app.", p.Description)
	assert.ErrorIs(t, d.UpdateProjectDescription(id+100, "x"), ErrProjectNotFound)
}

func TestProjectSources_AddIsIdempotentAndRemoveIsScoped(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	other := newTestProject(t, d)

	src := ProjectSource{ProjectID: pid, Kind: "slack_channel", Ref: "1:C1", Label: "#eng"}
	id1, err := d.AddProjectSource(src)
	require.NoError(t, err)
	id2, err := d.AddProjectSource(src)
	require.NoError(t, err)
	assert.Equal(t, id1, id2, "a duplicate add returns the existing row")

	_, err = d.AddProjectSource(ProjectSource{ProjectID: pid, Kind: "wiki", Ref: "x"})
	assert.Error(t, err, "unknown kind")
	_, err = d.AddProjectSource(ProjectSource{ProjectID: pid, Kind: "link", Ref: "  "})
	assert.Error(t, err, "empty ref")

	assert.ErrorIs(t, d.RemoveProjectSource(other, id1), ErrNotInProject)
	require.NoError(t, d.RemoveProjectSource(pid, id1))
	list, err := d.ListProjectSources(pid)
	require.NoError(t, err)
	assert.Empty(t, list)
}

func TestUpsertProjectDocument_CreatesThenRevises(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	tid := insertProjectTargetRow(t, d, pid, "feature")

	id, created, err := d.UpsertProjectDocument(ProjectDocument{ProjectID: pid, RelPath: "docs/plan.md",
		Kind: "plan", Title: "Plan", TargetID: nullID(tid)})
	require.NoError(t, err)
	assert.True(t, created)

	_, err = d.Exec(`UPDATE project_documents SET updated_at = '2000-01-01T00:00:00Z' WHERE id = ?`, id)
	require.NoError(t, err)
	again, created, err := d.UpsertProjectDocument(ProjectDocument{ProjectID: pid, RelPath: "docs/plan.md"})
	require.NoError(t, err)
	assert.Equal(t, id, again)
	assert.False(t, created)

	doc, err := d.GetProjectDocument(id)
	require.NoError(t, err)
	assert.Equal(t, "plan", doc.Kind, "an empty kind keeps the stored one")
	assert.Equal(t, "Plan", doc.Title, "an empty title keeps the stored one")
	assert.Equal(t, nullID(tid), doc.TargetID, "an unset target keeps the stored link")
	assert.NotEqual(t, "2000-01-01T00:00:00Z", doc.UpdatedAt, "re-attach marks the document revised")

	list, err := d.ListProjectDocuments(pid)
	require.NoError(t, err)
	assert.Len(t, list, 1)
}

func TestUpsertProjectDocument_RefusesBadInput(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	foreign := insertProjectTargetRow(t, d, newTestProject(t, d), "other board")

	_, _, err := d.UpsertProjectDocument(ProjectDocument{ProjectID: pid, RelPath: "a.md", TargetID: nullID(foreign)})
	assert.ErrorIs(t, err, ErrNotInProject)
	_, _, err = d.UpsertProjectDocument(ProjectDocument{ProjectID: pid, RelPath: "a.md", Kind: "memo"})
	assert.Error(t, err, "unknown kind")
	_, _, err = d.UpsertProjectDocument(ProjectDocument{ProjectID: pid, RelPath: " "})
	assert.Error(t, err, "empty path")
	_, _, err = d.UpsertProjectDocument(ProjectDocument{ProjectID: pid, RelPath: "/etc/passwd"})
	assert.Error(t, err, "absolute path")
}

// TestProj02_DeleteProjectLeavesNoRows is the DB half of PROJ-02
// (docs/inventory/projects.md): deleting a project leaves no project, target,
// source, document or comment row of it, and touches no other project.
// Task 12 adds the folder half.
func TestProj02_DeleteProjectLeavesNoRows(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	keep := newTestProject(t, d)

	parent := insertProjectTargetRow(t, d, pid, "feature")
	_, err := d.Exec(`INSERT INTO targets (text, period_start, period_end, project_id, parent_id)
		VALUES ('task', '2026-09-29', '2026-09-29', ?, ?)`, pid, parent)
	require.NoError(t, err)
	keepTarget := insertProjectTargetRow(t, d, keep, "other board")
	docID, _, err := d.UpsertProjectDocument(ProjectDocument{ProjectID: pid, RelPath: "docs/spec.md", Kind: "spec"})
	require.NoError(t, err)
	root, err := d.AddProjectComment(ProjectComment{ProjectID: pid, DocumentID: nullID(docID), Author: "owner",
		Body: "why?", AnchorQuote: "the quote"})
	require.NoError(t, err)
	_, err = d.AddProjectComment(ProjectComment{ProjectID: pid, ParentID: nullID(root), Author: "agent", Body: "because"})
	require.NoError(t, err)
	_, err = d.AddProjectComment(ProjectComment{ProjectID: pid, TargetID: nullID(parent), Author: "agent", Body: "blocked"})
	require.NoError(t, err)
	_, err = d.AddProjectSource(ProjectSource{ProjectID: pid, Kind: "link", Ref: "https://example.com"})
	require.NoError(t, err)

	require.NoError(t, d.DeleteProject(pid))

	for _, q := range []string{
		`SELECT COUNT(*) FROM projects WHERE id = ?`,
		`SELECT COUNT(*) FROM targets WHERE project_id = ?`,
		`SELECT COUNT(*) FROM project_sources WHERE project_id = ?`,
		`SELECT COUNT(*) FROM project_documents WHERE project_id = ?`,
		`SELECT COUNT(*) FROM project_comments WHERE project_id = ?`,
	} {
		var n int
		require.NoError(t, d.QueryRow(q, pid).Scan(&n))
		assert.Zero(t, n, q)
	}
	_, err = d.GetTargetByID(int(keepTarget))
	assert.NoError(t, err, "another project's board is untouched")
	assert.ErrorIs(t, d.DeleteProject(pid), ErrProjectNotFound)
}
```

Create `internal/db/project_comments_test.go`:

```go
package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func addComment(t *testing.T, d *DB, c ProjectComment) int64 {
	t.Helper()
	id, err := d.AddProjectComment(c)
	require.NoError(t, err)
	return id
}

func commentIDs(cs []ProjectComment) []int64 {
	ids := make([]int64, 0, len(cs))
	for _, c := range cs {
		ids = append(ids, c.ID)
	}
	return ids
}

func TestAddProjectComment_ReplyInheritsTheRootAndThreadsStayFlat(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	docID, _, err := d.UpsertProjectDocument(ProjectDocument{ProjectID: pid, RelPath: "docs/plan.md", Kind: "plan"})
	require.NoError(t, err)

	root := addComment(t, d, ProjectComment{ProjectID: pid, DocumentID: nullID(docID), Author: "owner",
		Body: "split this", AnchorQuote: "Task 3", AnchorHeading: "Tasks"})
	reply := addComment(t, d, ProjectComment{ProjectID: pid, ParentID: nullID(root), Author: "agent", Body: "done"})
	nested := addComment(t, d, ProjectComment{ProjectID: pid, ParentID: nullID(reply), Author: "owner",
		Body: "thanks", AnchorQuote: "ignored on a reply"})

	got, err := d.GetProjectComment(nested)
	require.NoError(t, err)
	assert.Equal(t, nullID(root), got.ParentID, "a reply to a reply hangs off the thread root")
	assert.Equal(t, nullID(docID), got.DocumentID, "a reply inherits the root's document")
	assert.Empty(t, got.AnchorQuote, "only a root carries an anchor")
	assert.Equal(t, "open", got.Status)
}

func TestAddProjectComment_RefusesRefsOutsideTheProject(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	other := newTestProject(t, d)
	foreignTarget := insertProjectTargetRow(t, d, other, "other board")
	foreignDoc, _, err := d.UpsertProjectDocument(ProjectDocument{ProjectID: other, RelPath: "a.md"})
	require.NoError(t, err)
	foreignRoot := addComment(t, d, ProjectComment{ProjectID: other, TargetID: nullID(foreignTarget), Author: "owner", Body: "x"})
	personal, err := d.CreateTarget(Target{Text: "personal", Status: "todo", Priority: "medium", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)

	for name, c := range map[string]ProjectComment{
		"target of another project":   {ProjectID: pid, TargetID: nullID(foreignTarget), Author: "agent", Body: "x"},
		"personal target":             {ProjectID: pid, TargetID: nullID(personal), Author: "agent", Body: "x"},
		"document of another project": {ProjectID: pid, DocumentID: nullID(foreignDoc), Author: "agent", Body: "x"},
		"thread of another project":   {ProjectID: pid, ParentID: nullID(foreignRoot), Author: "agent", Body: "x"},
	} {
		_, err := d.AddProjectComment(c)
		assert.ErrorIs(t, err, ErrNotInProject, name)
	}

	tid := insertProjectTargetRow(t, d, pid, "mine")
	_, err = d.AddProjectComment(ProjectComment{ProjectID: pid, Author: "agent", Body: "x"})
	assert.Error(t, err, "a comment needs a target, a document or a parent")
	_, err = d.AddProjectComment(ProjectComment{ProjectID: pid, TargetID: nullID(tid), Author: "bot", Body: "x"})
	assert.Error(t, err, "unknown author")
	_, err = d.AddProjectComment(ProjectComment{ProjectID: pid, TargetID: nullID(tid), Author: "agent", Body: "  "})
	assert.Error(t, err, "empty body")
}

// TestListProjectComments_NewForAgent pins spec §3: new for the agent = open
// owner roots, plus owner replies newer than their thread's latest agent reply.
func TestListProjectComments_NewForAgent(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	tid := insertProjectTargetRow(t, d, pid, "feature")
	docID, _, err := d.UpsertProjectDocument(ProjectDocument{ProjectID: pid, RelPath: "docs/plan.md", Kind: "plan"})
	require.NoError(t, err)
	onTarget := func(author, body string) ProjectComment {
		return ProjectComment{ProjectID: pid, TargetID: nullID(tid), Author: author, Body: body}
	}
	reply := func(root int64, author, body string) ProjectComment {
		return ProjectComment{ProjectID: pid, ParentID: nullID(root), Author: author, Body: body}
	}

	openRoot := addComment(t, d, onTarget("owner", "A: open owner root"))
	resolvedRoot := addComment(t, d, onTarget("owner", "B: resolved owner root"))
	require.NoError(t, d.SetProjectCommentStatus(resolvedRoot, "resolved"))
	agentRoot := addComment(t, d, onTarget("agent", "C: agent asks"))
	ownerAnswer := addComment(t, d, reply(agentRoot, "owner", "C1: owner answers"))
	docRoot := addComment(t, d, ProjectComment{ProjectID: pid, DocumentID: nullID(docID), Author: "owner", Body: "D: on the plan"})
	addComment(t, d, reply(docRoot, "agent", "D1: agent replies"))
	ownerFollowUp := addComment(t, d, reply(docRoot, "owner", "D2: owner follows up"))
	secondRoot := addComment(t, d, onTarget("owner", "E: another open root"))
	addComment(t, d, reply(secondRoot, "owner", "E1: before the agent reply"))
	addComment(t, d, reply(secondRoot, "agent", "E2: agent replies"))

	got, err := d.ListProjectComments(ProjectCommentFilter{ProjectID: pid, NewForAgent: true})
	require.NoError(t, err)
	assert.Equal(t, []int64{openRoot, ownerAnswer, docRoot, ownerFollowUp, secondRoot}, commentIDs(got))

	onDoc, err := d.ListProjectComments(ProjectCommentFilter{ProjectID: pid, DocumentID: docID})
	require.NoError(t, err)
	assert.Len(t, onDoc, 3, "the document filter returns the whole thread")
}

func TestSetProjectCommentStatus_RootsOnly(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	tid := insertProjectTargetRow(t, d, pid, "feature")
	root := addComment(t, d, ProjectComment{ProjectID: pid, TargetID: nullID(tid), Author: "owner", Body: "q"})
	reply := addComment(t, d, ProjectComment{ProjectID: pid, ParentID: nullID(root), Author: "agent", Body: "a"})

	require.NoError(t, d.SetProjectCommentStatus(root, "resolved"))
	require.NoError(t, d.SetProjectCommentStatus(root, "open"), "the owner can reopen")
	assert.Error(t, d.SetProjectCommentStatus(reply, "resolved"), "status is meaningful on roots only")
	assert.Error(t, d.SetProjectCommentStatus(root, "closed"), "unknown status")
}

func TestMarkProjectCommentsRead_OnlyAgentCommentsOfTheScope(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	t1 := insertProjectTargetRow(t, d, pid, "one")
	t2 := insertProjectTargetRow(t, d, pid, "two")
	agentOnT1 := addComment(t, d, ProjectComment{ProjectID: pid, TargetID: nullID(t1), Author: "agent", Body: "a"})
	agentOnT2 := addComment(t, d, ProjectComment{ProjectID: pid, TargetID: nullID(t2), Author: "agent", Body: "b"})
	ownerOnT1 := addComment(t, d, ProjectComment{ProjectID: pid, TargetID: nullID(t1), Author: "owner", Body: "c"})

	require.NoError(t, d.MarkProjectCommentsRead(pid, t1, 0))

	read := func(id int64) string {
		c, err := d.GetProjectComment(id)
		require.NoError(t, err)
		return c.ReadAt
	}
	assert.NotEmpty(t, read(agentOnT1))
	assert.Empty(t, read(agentOnT2), "another target's comments stay unread")
	assert.Empty(t, read(ownerOnT1), "owner comments are never marked")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `go test ./internal/db/ -run 'TestResolveProjectFolder|TestCreateProject|TestGetProject|TestUpdateProjectDescription|TestProjectSources|TestUpsertProjectDocument|TestProj02|TestAddProjectComment|TestListProjectComments|TestSetProjectCommentStatus|TestMarkProjectCommentsRead'`
Expected: FAIL to compile — `undefined: ResolveProjectFolder`, `d.CreateProject undefined`, `undefined: ProjectComment`, etc.

- [ ] **Step 3: Implement `internal/db/projects.go`**

```go
package db

import (
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Project is a folder-bound project (Projects POC, migration 00081). Its
// targets, documents and comments live only on its board (PROJ-01,
// docs/inventory/projects.md).
type Project struct {
	ID          int64
	Name        string
	FolderPath  string // absolute, symlinks resolved (ResolveProjectFolder)
	Description string
	CreatedAt   string
	UpdatedAt   string
}

// ProjectSource is a source the project's docs name (a channel, a Jira
// project, a Confluence space, a person, a link).
type ProjectSource struct {
	ID        int64
	ProjectID int64
	Kind      string
	Ref       string
	Label     string
}

// ProjectDocument is a file inside the project folder (a spec, a plan, a doc)
// that Claude Code attached for owner review.
type ProjectDocument struct {
	ID        int64
	ProjectID int64
	TargetID  sql.NullInt64
	RelPath   string // relative to the project folder
	Kind      string // spec | plan | doc
	Title     string
	CreatedAt string
	UpdatedAt string // bumped by every re-attach ("revised")
}

var (
	ErrProjectFolderTaken = errors.New("folder is already bound to a project")
	ErrProjectNotFound    = errors.New("project not found")
	// ErrNotInProject is returned when a target, document, source or comment
	// named by a project write belongs to another project, or to none.
	ErrNotInProject = errors.New("does not belong to this project")
)

var (
	projectSourceKinds   = map[string]bool{"slack_channel": true, "jira_project": true, "confluence_space": true, "person": true, "link": true}
	projectDocumentKinds = map[string]bool{"spec": true, "plan": true, "doc": true}
)

const projectCols = `id, name, folder_path, description, created_at, updated_at`

// WithTx runs fn in one transaction, committing when it returns nil. fn must
// use only the *sql.Tx it is given: the pool holds a single connection, so a
// db.X call inside fn would wait on itself.
func (db *DB) WithTx(fn func(*sql.Tx) error) error {
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("beginning transaction: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	if err := fn(tx); err != nil {
		return err
	}
	return tx.Commit()
}

// ResolveProjectFolder turns dir into the absolute, symlink-resolved path of
// an existing directory — the only form CreateProject stores, so two spellings
// of one folder can never bind two projects.
func ResolveProjectFolder(dir string) (string, error) {
	if strings.TrimSpace(dir) == "" {
		return "", errors.New("project folder is required")
	}
	abs, err := filepath.Abs(dir)
	if err != nil {
		return "", fmt.Errorf("resolving folder %q: %w", dir, err)
	}
	resolved, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return "", fmt.Errorf("resolving folder %q: %w", dir, err)
	}
	info, err := os.Stat(resolved)
	if err != nil {
		return "", fmt.Errorf("resolving folder %q: %w", dir, err)
	}
	if !info.IsDir() {
		return "", fmt.Errorf("%s is not a directory", resolved)
	}
	return resolved, nil
}

// CreateProject binds a new project to folder, which must already be resolved
// (ResolveProjectFolder). A folder bound to another project fails with
// ErrProjectFolderTaken.
func (db *DB) CreateProject(name, folder string) (int64, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return 0, errors.New("project name is required")
	}
	if !filepath.IsAbs(folder) {
		return 0, fmt.Errorf("project folder %q must be an absolute, resolved path", folder)
	}
	res, err := db.Exec(`INSERT INTO projects (name, folder_path) VALUES (?, ?)`, name, folder)
	if err != nil {
		if strings.Contains(err.Error(), "UNIQUE constraint failed: projects.folder_path") {
			return 0, fmt.Errorf("%s: %w", folder, ErrProjectFolderTaken)
		}
		return 0, fmt.Errorf("inserting project: %w", err)
	}
	return res.LastInsertId()
}

func scanProject(row interface{ Scan(...any) error }) (*Project, error) {
	var p Project
	if err := row.Scan(&p.ID, &p.Name, &p.FolderPath, &p.Description, &p.CreatedAt, &p.UpdatedAt); err != nil {
		return nil, err
	}
	return &p, nil
}

// GetProject returns project id, or ErrProjectNotFound.
func (db *DB) GetProject(id int64) (*Project, error) {
	p, err := scanProject(db.QueryRow(`SELECT `+projectCols+` FROM projects WHERE id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, fmt.Errorf("project %d: %w", id, ErrProjectNotFound)
	}
	if err != nil {
		return nil, fmt.Errorf("getting project %d: %w", id, err)
	}
	return p, nil
}

// ListProjects returns every project in id order.
func (db *DB) ListProjects() ([]Project, error) {
	rows, err := db.Query(`SELECT ` + projectCols + ` FROM projects ORDER BY id`)
	if err != nil {
		return nil, fmt.Errorf("listing projects: %w", err)
	}
	defer rows.Close()
	var out []Project
	for rows.Next() {
		p, err := scanProject(rows)
		if err != nil {
			return nil, fmt.Errorf("scanning project: %w", err)
		}
		out = append(out, *p)
	}
	return out, rows.Err()
}

// UpdateProjectDescription replaces the project's description.
func (db *DB) UpdateProjectDescription(id int64, description string) error {
	res, err := db.Exec(`UPDATE projects SET description = ?,
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?`, description, id)
	if err != nil {
		return fmt.Errorf("updating project %d: %w", id, err)
	}
	return requireAffected(res, fmt.Errorf("project %d: %w", id, ErrProjectNotFound))
}

// DeleteProject removes the project; the foreign keys cascade to its targets,
// sources, documents and comments inside the same statement, so the delete is
// all-or-nothing (PROJ-02). The folder install is removed by the caller.
func (db *DB) DeleteProject(id int64) error {
	res, err := db.Exec(`DELETE FROM projects WHERE id = ?`, id)
	if err != nil {
		return fmt.Errorf("deleting project %d: %w", id, err)
	}
	return requireAffected(res, fmt.Errorf("project %d: %w", id, ErrProjectNotFound))
}

func requireAffected(res sql.Result, notFound error) error {
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return notFound
	}
	return nil
}

// requireProject fails with ErrProjectNotFound unless project id exists.
func requireProject(q targetsQuerier, id int64) error {
	var one int
	err := q.QueryRow(`SELECT 1 FROM projects WHERE id = ?`, id).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("project %d: %w", id, ErrProjectNotFound)
	}
	if err != nil {
		return fmt.Errorf("checking project %d: %w", id, err)
	}
	return nil
}

const (
	targetProjectQuery   = `SELECT project_id FROM targets WHERE id = ?`
	documentProjectQuery = `SELECT project_id FROM project_documents WHERE id = ?`
)

// checkTargetInProject fails with ErrNotInProject unless target id is on
// project projectID's board.
func checkTargetInProject(q targetsQuerier, projectID, id int64) error {
	return checkOwnedBy(q, targetProjectQuery, "target", projectID, id)
}

func checkDocumentInProject(q targetsQuerier, projectID, id int64) error {
	return checkOwnedBy(q, documentProjectQuery, "document", projectID, id)
}

func checkOwnedBy(q targetsQuerier, query, noun string, projectID, id int64) error {
	var owner sql.NullInt64
	err := q.QueryRow(query, id).Scan(&owner)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return fmt.Errorf("%s %d does not exist: %w", noun, id, ErrNotInProject)
	case err != nil:
		return fmt.Errorf("checking %s %d: %w", noun, id, err)
	case !owner.Valid || owner.Int64 != projectID:
		return fmt.Errorf("%s %d: %w", noun, id, ErrNotInProject)
	}
	return nil
}

// AddProjectSource adds a source; adding an existing (kind, ref) again returns
// the existing row's id.
func (db *DB) AddProjectSource(s ProjectSource) (int64, error) {
	if !projectSourceKinds[s.Kind] {
		return 0, fmt.Errorf("invalid project source kind %q", s.Kind)
	}
	if strings.TrimSpace(s.Ref) == "" {
		return 0, errors.New("project source ref is required")
	}
	if _, err := db.Exec(`INSERT INTO project_sources (project_id, kind, ref, label) VALUES (?, ?, ?, ?)
		ON CONFLICT(project_id, kind, ref) DO NOTHING`, s.ProjectID, s.Kind, s.Ref, s.Label); err != nil {
		return 0, fmt.Errorf("adding project source: %w", err)
	}
	var id int64
	if err := db.QueryRow(`SELECT id FROM project_sources WHERE project_id = ? AND kind = ? AND ref = ?`,
		s.ProjectID, s.Kind, s.Ref).Scan(&id); err != nil {
		return 0, fmt.Errorf("reading project source id: %w", err)
	}
	return id, nil
}

// RemoveProjectSource deletes one source of the project.
func (db *DB) RemoveProjectSource(projectID, sourceID int64) error {
	res, err := db.Exec(`DELETE FROM project_sources WHERE id = ? AND project_id = ?`, sourceID, projectID)
	if err != nil {
		return fmt.Errorf("removing project source %d: %w", sourceID, err)
	}
	return requireAffected(res, fmt.Errorf("project source %d: %w", sourceID, ErrNotInProject))
}

// ListProjectSources returns the project's sources by kind, then id.
func (db *DB) ListProjectSources(projectID int64) ([]ProjectSource, error) {
	rows, err := db.Query(`SELECT id, project_id, kind, ref, label FROM project_sources
		WHERE project_id = ? ORDER BY kind, id`, projectID)
	if err != nil {
		return nil, fmt.Errorf("listing project sources: %w", err)
	}
	defer rows.Close()
	var out []ProjectSource
	for rows.Next() {
		var s ProjectSource
		if err := rows.Scan(&s.ID, &s.ProjectID, &s.Kind, &s.Ref, &s.Label); err != nil {
			return nil, fmt.Errorf("scanning project source: %w", err)
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

const projectDocumentCols = `id, project_id, target_id, rel_path, kind, title, created_at, updated_at`

func scanProjectDocument(row interface{ Scan(...any) error }) (*ProjectDocument, error) {
	var d ProjectDocument
	if err := row.Scan(&d.ID, &d.ProjectID, &d.TargetID, &d.RelPath, &d.Kind, &d.Title, &d.CreatedAt, &d.UpdatedAt); err != nil {
		return nil, err
	}
	return &d, nil
}

func validateProjectDocument(d ProjectDocument) error {
	if strings.TrimSpace(d.RelPath) == "" || filepath.IsAbs(d.RelPath) {
		return fmt.Errorf("document path %q must be relative to the project folder", d.RelPath)
	}
	if d.Kind != "" && !projectDocumentKinds[d.Kind] {
		return fmt.Errorf("invalid document kind %q", d.Kind)
	}
	return nil
}

// UpsertProjectDocument attaches d. On an existing (project, rel_path) it
// bumps updated_at ("revised") and replaces kind/title/target only with the
// values d sets; created reports whether a new row was inserted. Whether
// rel_path stays inside the folder is the caller's check (Task 8).
func (db *DB) UpsertProjectDocument(d ProjectDocument) (id int64, created bool, err error) {
	if err := validateProjectDocument(d); err != nil {
		return 0, false, err
	}
	err = db.WithTx(func(tx *sql.Tx) error {
		if d.TargetID.Valid {
			if err := checkTargetInProject(tx, d.ProjectID, d.TargetID.Int64); err != nil {
				return err
			}
		}
		qerr := tx.QueryRow(`SELECT id FROM project_documents WHERE project_id = ? AND rel_path = ?`,
			d.ProjectID, d.RelPath).Scan(&id)
		if errors.Is(qerr, sql.ErrNoRows) {
			created = true
			id, qerr = insertProjectDocument(tx, d)
			return qerr
		}
		if qerr != nil {
			return fmt.Errorf("looking up document %q: %w", d.RelPath, qerr)
		}
		return reviseProjectDocument(tx, id, d)
	})
	if err != nil {
		return 0, false, err
	}
	return id, created, nil
}

func insertProjectDocument(tx *sql.Tx, d ProjectDocument) (int64, error) {
	kind := d.Kind
	if kind == "" {
		kind = "doc"
	}
	res, err := tx.Exec(`INSERT INTO project_documents (project_id, target_id, rel_path, kind, title)
		VALUES (?, ?, ?, ?, ?)`, d.ProjectID, d.TargetID, d.RelPath, kind, d.Title)
	if err != nil {
		return 0, fmt.Errorf("inserting document %q: %w", d.RelPath, err)
	}
	return res.LastInsertId()
}

func reviseProjectDocument(tx *sql.Tx, id int64, d ProjectDocument) error {
	_, err := tx.Exec(`UPDATE project_documents SET
		kind = CASE WHEN ? = '' THEN kind ELSE ? END,
		title = CASE WHEN ? = '' THEN title ELSE ? END,
		target_id = COALESCE(?, target_id),
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE id = ?`, d.Kind, d.Kind, d.Title, d.Title, d.TargetID, id)
	if err != nil {
		return fmt.Errorf("revising document %d: %w", id, err)
	}
	return nil
}

// GetProjectDocument returns document id (a wrapped sql.ErrNoRows when absent).
func (db *DB) GetProjectDocument(id int64) (*ProjectDocument, error) {
	d, err := scanProjectDocument(db.QueryRow(`SELECT `+projectDocumentCols+` FROM project_documents WHERE id = ?`, id))
	if err != nil {
		return nil, fmt.Errorf("getting document %d: %w", id, err)
	}
	return d, nil
}

// ListProjectDocuments returns the project's documents in id order.
func (db *DB) ListProjectDocuments(projectID int64) ([]ProjectDocument, error) {
	rows, err := db.Query(`SELECT `+projectDocumentCols+` FROM project_documents WHERE project_id = ? ORDER BY id`, projectID)
	if err != nil {
		return nil, fmt.Errorf("listing documents: %w", err)
	}
	defer rows.Close()
	var out []ProjectDocument
	for rows.Next() {
		d, err := scanProjectDocument(rows)
		if err != nil {
			return nil, fmt.Errorf("scanning document: %w", err)
		}
		out = append(out, *d)
	}
	return out, rows.Err()
}
```

- [ ] **Step 4: Implement `internal/db/project_comments.go`**

```go
package db

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
)

// ProjectComment is a comment on a project target or document, or a reply in
// a thread (ParentID = the thread root; threads are flat). Status is
// meaningful on roots only; an agent comment is unread for the owner while
// ReadAt is empty.
type ProjectComment struct {
	ID            int64
	ProjectID     int64
	TargetID      sql.NullInt64
	DocumentID    sql.NullInt64
	ParentID      sql.NullInt64
	Author        string // owner | agent
	AgentLabel    string
	Body          string
	AnchorQuote   string
	AnchorPrefix  string
	AnchorSuffix  string
	AnchorHeading string
	Status        string // open | resolved | outdated
	CreatedAt     string
	ReadAt        string
}

// ProjectCommentFilter selects comments; a zero id matches any.
type ProjectCommentFilter struct {
	ProjectID  int64
	TargetID   int64
	DocumentID int64
	// NewForAgent keeps only what the agent has not answered yet (spec §3).
	NewForAgent bool
}

const projectCommentCols = `c.id, c.project_id, c.target_id, c.document_id, c.parent_id, c.author, c.agent_label,
	c.body, c.anchor_quote, c.anchor_prefix, c.anchor_suffix, c.anchor_heading, c.status, c.created_at, c.read_at`

// newForAgentPredicate (over alias c): open owner roots, plus owner replies
// newer than their thread's latest agent comment (the agent root counts).
// "Newer" compares ids — rowids grow monotonically, created_at ties within a
// second. Replies always point at their root (AddProjectComment flattens).
const newForAgentPredicate = `(c.author = 'owner' AND (
	(c.parent_id IS NULL AND c.status = 'open')
	OR (c.parent_id IS NOT NULL AND c.id > COALESCE((
		SELECT MAX(a.id) FROM project_comments a
		WHERE a.author = 'agent' AND (a.id = c.parent_id OR a.parent_id = c.parent_id)), 0))))`

var projectCommentStatuses = map[string]bool{"open": true, "resolved": true, "outdated": true}

func scanProjectComment(row interface{ Scan(...any) error }) (*ProjectComment, error) {
	var c ProjectComment
	if err := row.Scan(&c.ID, &c.ProjectID, &c.TargetID, &c.DocumentID, &c.ParentID, &c.Author, &c.AgentLabel,
		&c.Body, &c.AnchorQuote, &c.AnchorPrefix, &c.AnchorSuffix, &c.AnchorHeading, &c.Status, &c.CreatedAt, &c.ReadAt); err != nil {
		return nil, err
	}
	return &c, nil
}

// AddProjectComment stores c. A reply (ParentID set) is re-pointed at its
// thread root and inherits the root's target/document; a root must name a
// target or a document of the same project. Every reference is checked
// against c.ProjectID (ErrNotInProject).
func (db *DB) AddProjectComment(c ProjectComment) (int64, error) {
	if c.Author != "owner" && c.Author != "agent" {
		return 0, fmt.Errorf("invalid comment author %q", c.Author)
	}
	if strings.TrimSpace(c.Body) == "" {
		return 0, errors.New("comment body is required")
	}
	var id int64
	err := db.WithTx(func(tx *sql.Tx) error {
		placed, err := placeProjectComment(tx, c)
		if err != nil {
			return err
		}
		id, err = insertProjectComment(tx, placed)
		return err
	})
	if err != nil {
		return 0, err
	}
	return id, nil
}

func placeProjectComment(q targetsQuerier, c ProjectComment) (ProjectComment, error) {
	if c.ParentID.Valid {
		return placeReply(q, c)
	}
	if !c.TargetID.Valid && !c.DocumentID.Valid {
		return c, errors.New("a comment needs a target, a document or a parent")
	}
	if c.TargetID.Valid {
		if err := checkTargetInProject(q, c.ProjectID, c.TargetID.Int64); err != nil {
			return c, err
		}
	}
	if c.DocumentID.Valid {
		if err := checkDocumentInProject(q, c.ProjectID, c.DocumentID.Int64); err != nil {
			return c, err
		}
	}
	return c, nil
}

func placeReply(q targetsQuerier, c ProjectComment) (ProjectComment, error) {
	parent, err := scanProjectComment(q.QueryRow(`SELECT `+projectCommentCols+` FROM project_comments c WHERE c.id = ?`, c.ParentID.Int64))
	if errors.Is(err, sql.ErrNoRows) {
		return c, fmt.Errorf("comment %d does not exist: %w", c.ParentID.Int64, ErrNotInProject)
	}
	if err != nil {
		return c, fmt.Errorf("loading comment %d: %w", c.ParentID.Int64, err)
	}
	if parent.ProjectID != c.ProjectID {
		return c, fmt.Errorf("comment %d: %w", parent.ID, ErrNotInProject)
	}
	root := parent.ID
	if parent.ParentID.Valid {
		root = parent.ParentID.Int64
	}
	c.ParentID = sql.NullInt64{Int64: root, Valid: true}
	c.TargetID, c.DocumentID = parent.TargetID, parent.DocumentID
	c.AnchorQuote, c.AnchorPrefix, c.AnchorSuffix, c.AnchorHeading = "", "", "", ""
	return c, nil
}

func insertProjectComment(tx *sql.Tx, c ProjectComment) (int64, error) {
	res, err := tx.Exec(`INSERT INTO project_comments
		(project_id, target_id, document_id, parent_id, author, agent_label, body,
		 anchor_quote, anchor_prefix, anchor_suffix, anchor_heading)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		c.ProjectID, c.TargetID, c.DocumentID, c.ParentID, c.Author, c.AgentLabel, c.Body,
		c.AnchorQuote, c.AnchorPrefix, c.AnchorSuffix, c.AnchorHeading)
	if err != nil {
		return 0, fmt.Errorf("inserting comment: %w", err)
	}
	return res.LastInsertId()
}

// GetProjectComment returns comment id (a wrapped sql.ErrNoRows when absent).
func (db *DB) GetProjectComment(id int64) (*ProjectComment, error) {
	c, err := scanProjectComment(db.QueryRow(`SELECT `+projectCommentCols+` FROM project_comments c WHERE c.id = ?`, id))
	if err != nil {
		return nil, fmt.Errorf("getting comment %d: %w", id, err)
	}
	return c, nil
}

// ListProjectComments returns the comments f selects, oldest first.
func (db *DB) ListProjectComments(f ProjectCommentFilter) ([]ProjectComment, error) {
	where, args := projectCommentWhere(f)
	query := `SELECT ` + projectCommentCols + ` FROM project_comments c` + where + ` ORDER BY c.created_at, c.id`
	rows, err := db.Query(query, args...)
	if err != nil {
		return nil, fmt.Errorf("listing comments: %w", err)
	}
	defer rows.Close()
	var out []ProjectComment
	for rows.Next() {
		c, err := scanProjectComment(rows)
		if err != nil {
			return nil, fmt.Errorf("scanning comment: %w", err)
		}
		out = append(out, *c)
	}
	return out, rows.Err()
}

func projectCommentWhere(f ProjectCommentFilter) (string, []any) {
	var conds []string
	var args []any
	for _, scope := range []struct {
		col string
		id  int64
	}{{"c.project_id", f.ProjectID}, {"c.target_id", f.TargetID}, {"c.document_id", f.DocumentID}} {
		if scope.id > 0 {
			conds = append(conds, scope.col+" = ?")
			args = append(args, scope.id)
		}
	}
	if f.NewForAgent {
		conds = append(conds, newForAgentPredicate)
	}
	if len(conds) == 0 {
		return "", nil
	}
	return " WHERE " + strings.Join(conds, " AND "), args
}

// SetProjectCommentStatus sets a thread root's status (open to reopen).
func (db *DB) SetProjectCommentStatus(id int64, status string) error {
	if !projectCommentStatuses[status] {
		return fmt.Errorf("invalid comment status %q", status)
	}
	res, err := db.Exec(`UPDATE project_comments SET status = ? WHERE id = ? AND parent_id IS NULL`, status, id)
	if err != nil {
		return fmt.Errorf("setting comment %d status: %w", id, err)
	}
	return requireAffected(res, fmt.Errorf("comment %d is not a thread root or does not exist", id))
}

// MarkProjectCommentsRead stamps read_at on the project's unread agent
// comments, narrowed to one target and/or document when those ids are set.
func (db *DB) MarkProjectCommentsRead(projectID, targetID, documentID int64) error {
	_, err := db.Exec(`UPDATE project_comments SET read_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE project_id = ? AND author = 'agent' AND read_at = ''
		  AND (? = 0 OR target_id = ?) AND (? = 0 OR document_id = ?)`,
		projectID, targetID, targetID, documentID, documentID)
	if err != nil {
		return fmt.Errorf("marking comments read: %w", err)
	}
	return nil
}
```

- [ ] **Step 5: Run the tests**

Run: `go test ./internal/db/ -run 'TestResolveProjectFolder|TestCreateProject|TestGetProject|TestUpdateProjectDescription|TestProjectSources|TestUpsertProjectDocument|TestProj02|TestAddProjectComment|TestListProjectComments|TestSetProjectCommentStatus|TestMarkProjectCommentsRead'`
Expected: PASS.

Run: `go test ./internal/db/`
Expected: PASS.

- [ ] **Step 6: Lint**

Run: `make lint-diff`
Expected: no new issues.

- [ ] **Step 7: Commit**

```bash
git add internal/db/projects.go internal/db/project_comments.go internal/db/projects_test.go internal/db/project_comments_test.go
git commit -m "feat(db): project store — projects, sources, documents, comments" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Lo9jbbmXQcr3qHo5f3pLD8"
```

---

## Task 3: Targets `project_id` + exclusions (PROJ-01)

**Files:**
- Create: `internal/db/project_targets.go`
- Create: `internal/db/project_targets_test.go`
- Create: `internal/db/proj01_guard_test.go`
- Modify: `internal/db/models.go` (`Target`, `TargetFilter`)
- Modify: `internal/db/targets.go` (`targetSelectCols`, `scanTarget`, `CreateTarget`, `UpdateTarget`, `GetTargetsNeedingNextStep`, `GetTargets`, `GetTargetCounts`, `GetTargetsForBriefing`; new `projectScope`)
- Modify: `internal/db/targets_promote.go`, `internal/db/targets_remind.go`, `internal/db/catchup.go`, `internal/db/memory.go` (`ListTargetsForMirror`), `internal/db/channel_stats.go`
- Modify: `internal/dayplan/gather.go`, `internal/dayplan/gather_test.go`
- Modify: `internal/targets/nextstep.go`, `internal/targets/nextstep_test.go`, `internal/targets/pipeline_test.go`
- No change: `internal/targets/pipeline.go` — its snapshots call `GetTargets` with a zero `ProjectID` (see Decisions); pinned by `TestProj01_ExtractSnapshotExcludesProjectTargets`.

**Interfaces:**
- Consumes: Task 2 `WithTx`, `requireProject`, `checkTargetInProject`, `ErrNotInProject`, `ErrProjectNotFound`.
- Produces:
  ```go
  // db.Target gains
  ProjectID sql.NullInt64
  // db.TargetFilter gains
  ProjectID int64 // 0 = exclude project targets (every existing caller); N = only project N's
  type ProjectTargetInput struct{ Title, Intent string; ParentID sql.NullInt64; BatchParent int } // BatchParent: 1-based earlier batch item, 0 = none
  func (db *DB) CreateProjectTarget(projectID int64, parentID sql.NullInt64, title, intent string) (int64, error)
  func (db *DB) CreateProjectTargetsTx(tx *sql.Tx, projectID int64, items []ProjectTargetInput) ([]int64, error)
  // package targets
  var ErrProjectTarget = errors.New("project targets have no next step")
  ```

- [ ] **Step 1: Write the failing project-target tests**

Create `internal/db/project_targets_test.go`:

```go
package db

import (
	"database/sql"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestCreateProjectTarget_UsesTheBoardDefaults(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	before := time.Now().UTC().Format("2006-01-02")
	id, err := d.CreateProjectTarget(pid, sql.NullInt64{}, "  Ship the board  ", "why it matters")
	require.NoError(t, err)
	after := time.Now().UTC().Format("2006-01-02")

	tg, err := d.GetTargetByID(int(id))
	require.NoError(t, err)
	assert.Equal(t, nullID(pid), tg.ProjectID)
	assert.Equal(t, "Ship the board", tg.Text)
	assert.Equal(t, "why it matters", tg.Intent)
	assert.Equal(t, "custom", tg.Level)
	assert.Equal(t, "project", tg.CustomLabel)
	assert.Contains(t, []string{before, after}, tg.PeriodStart)
	assert.Equal(t, tg.PeriodStart, tg.PeriodEnd)
	assert.Equal(t, "chat", tg.SourceType)
	assert.Equal(t, "mine", tg.Ownership)
	assert.Equal(t, "todo", tg.Status)
}

func TestCreateProjectTargetsTx_NestedBatchParents(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	var ids []int64
	require.NoError(t, d.WithTx(func(tx *sql.Tx) error {
		var err error
		ids, err = d.CreateProjectTargetsTx(tx, pid, []ProjectTargetInput{
			{Title: "feature"},
			{Title: "task 1", Intent: "docs/plan.md task 1", BatchParent: 1},
			{Title: "step 1.1", BatchParent: 2},
		})
		return err
	}))
	require.Len(t, ids, 3)

	task, err := d.GetTargetByID(int(ids[1]))
	require.NoError(t, err)
	assert.Equal(t, nullID(ids[0]), task.ParentID)
	step, err := d.GetTargetByID(int(ids[2]))
	require.NoError(t, err)
	assert.Equal(t, nullID(ids[1]), step.ParentID)
}

// TestCreateProjectTargetsTx_BatchIsAllOrNothing: one bad item (here the last)
// leaves nothing of the batch behind once the caller's tx rolls back.
func TestCreateProjectTargetsTx_BatchIsAllOrNothing(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	err := d.WithTx(func(tx *sql.Tx) error {
		_, err := d.CreateProjectTargetsTx(tx, pid, []ProjectTargetInput{
			{Title: "feature"},
			{Title: "task 1", BatchParent: 1},
			{Title: "   "},
		})
		return err
	})
	assert.ErrorContains(t, err, "target 3 of 3")

	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM targets WHERE project_id = ?`, pid).Scan(&n))
	assert.Zero(t, n)
}

func TestCreateProjectTargetsTx_RefusesParentsOutsideTheProject(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	foreign, err := d.CreateProjectTarget(newTestProject(t, d), sql.NullInt64{}, "other board", "")
	require.NoError(t, err)
	personal, err := d.CreateTarget(Target{Text: "personal", Status: "todo", Priority: "medium", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)

	create := func(items ...ProjectTargetInput) error {
		return d.WithTx(func(tx *sql.Tx) error {
			_, err := d.CreateProjectTargetsTx(tx, pid, items)
			return err
		})
	}
	assert.ErrorIs(t, create(ProjectTargetInput{Title: "x", ParentID: nullID(foreign)}), ErrNotInProject)
	assert.ErrorIs(t, create(ProjectTargetInput{Title: "x", ParentID: nullID(personal)}), ErrNotInProject)
	assert.ErrorContains(t, create(ProjectTargetInput{Title: "x", BatchParent: 1}), "not an earlier item")
	assert.ErrorContains(t, create(ProjectTargetInput{Title: "a"}, ProjectTargetInput{Title: "b", BatchParent: 1, ParentID: nullID(foreign)}),
		"mutually exclusive")

	_, err = d.CreateProjectTarget(pid+100, sql.NullInt64{}, "x", "")
	assert.ErrorIs(t, err, ErrProjectNotFound)
}

func TestTargets_ProjectIDRoundTripsThroughCreateAndUpdate(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	id, err := d.CreateTarget(Target{Text: "board item", Status: "todo", Priority: "medium", Ownership: "mine",
		SourceType: "chat", ProjectID: nullID(pid)})
	require.NoError(t, err)

	tg, err := d.GetTargetByID(int(id))
	require.NoError(t, err)
	assert.Equal(t, nullID(pid), tg.ProjectID)

	tg.Text = "renamed"
	require.NoError(t, d.UpdateTarget(*tg))
	tg, err = d.GetTargetByID(int(id))
	require.NoError(t, err)
	assert.Equal(t, nullID(pid), tg.ProjectID, "a full-row update keeps the board")
}

func TestGetTargets_ProjectScope(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	other := newTestProject(t, d)
	_, err := d.CreateTarget(Target{Text: "personal", Status: "todo", Priority: "medium", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)
	mine, err := d.CreateProjectTarget(pid, sql.NullInt64{}, "on my board", "")
	require.NoError(t, err)
	_, err = d.CreateProjectTarget(other, sql.NullInt64{}, "on another board", "")
	require.NoError(t, err)

	personal, err := d.GetTargets(TargetFilter{})
	require.NoError(t, err)
	require.Len(t, personal, 1)
	assert.Equal(t, "personal", personal[0].Text)

	board, err := d.GetTargets(TargetFilter{ProjectID: pid, IncludeDone: true})
	require.NoError(t, err)
	require.Len(t, board, 1)
	assert.Equal(t, int(mine), board[0].ID)
}

func TestPromoteSubItemToChild_CopiesProjectID(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	parent, err := d.CreateProjectTarget(pid, sql.NullInt64{}, "feature", "")
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE targets SET sub_items = '[{"text":"write the test","done":false}]' WHERE id = ?`, parent)
	require.NoError(t, err)

	child, err := d.PromoteSubItemToChild(parent, 0, PromoteOverrides{})
	require.NoError(t, err)
	tg, err := d.GetTargetByID(int(child))
	require.NoError(t, err)
	assert.Equal(t, nullID(pid), tg.ProjectID, "a promoted sub-item stays on the parent's board")
}
```

Create `internal/db/proj01_guard_test.go`:

```go
package db

import (
	"database/sql"
	"strconv"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestProj01_ProjectTargetsNeverReachNonBoardReaders guards PROJ-01
// (docs/inventory/projects.md): with one personal and one project target that
// otherwise look identical (active, overdue, digest-sourced, high priority),
// every non-board reader of spec §4.1 in internal/db returns only the personal
// one. Companions in their own packages: TestProj01_DayPlanGatherExcludesProjectTargets
// (internal/dayplan), TestProj01_ExtractSnapshotExcludesProjectTargets and
// TestProj01_NextStepSkipsProjectTarget (internal/targets).
func TestProj01_ProjectTargetsNeverReachNonBoardReaders(t *testing.T) {
	d := openTestDB(t)
	now := time.Now().UTC()
	due := now.Add(-2 * time.Hour).Format("2006-01-02T15:04")

	require.NoError(t, d.UpsertChannel(Channel{ID: "C1", Name: "general", Type: "public", IsMember: true}))
	res, err := d.Exec(`INSERT INTO digests (channel_id, period_from, period_to, type, summary, message_count)
		VALUES ('C1', ?, ?, 'channel', 'd', 1)`, float64(now.Unix()-3600), float64(now.Unix()))
	require.NoError(t, err)
	digestID, err := res.LastInsertId()
	require.NoError(t, err)
	source := strconv.FormatInt(digestID, 10)

	personal, err := d.CreateTarget(Target{Text: "personal", Status: "todo", Priority: "high", Ownership: "mine",
		SourceType: "digest", SourceID: source, DueDate: due})
	require.NoError(t, err)
	pid := newTestProject(t, d)
	onBoard, err := d.CreateProjectTarget(pid, sql.NullInt64{}, "board only", "")
	require.NoError(t, err)
	// Defense in depth: the predicate, not the project defaults, keeps it out.
	_, err = d.Exec(`UPDATE targets SET source_type = 'digest', source_id = ?, due_date = ?, priority = 'high' WHERE id = ?`,
		source, due, onBoard)
	require.NoError(t, err)

	want := []int{int(personal)}
	ids := func(ts []Target) []int {
		out := make([]int, 0, len(ts))
		for _, tg := range ts {
			out = append(out, tg.ID)
		}
		return out
	}

	t.Run("GetTargets", func(t *testing.T) {
		for _, f := range []TargetFilter{{}, {IncludeDone: true}, {Limit: 100}, {Status: "todo"}} {
			got, err := d.GetTargets(f)
			require.NoError(t, err)
			assert.Equal(t, want, ids(got), "%+v", f)
		}
	})
	t.Run("GetTargetsNeedingNextStep", func(t *testing.T) {
		got, err := d.GetTargetsNeedingNextStep(0)
		require.NoError(t, err)
		assert.Equal(t, want, ids(got))
	})
	t.Run("GetTargetsForBriefing", func(t *testing.T) {
		got, err := d.GetTargetsForBriefing()
		require.NoError(t, err)
		assert.Equal(t, want, ids(got))
	})
	t.Run("GetTargetCounts", func(t *testing.T) {
		active, overdue, err := d.GetTargetCounts()
		require.NoError(t, err)
		assert.Equal(t, 1, active)
		assert.Equal(t, 1, overdue)
	})
	t.Run("ListCatchupTargets", func(t *testing.T) {
		got, err := d.ListCatchupTargets(float64(now.Add(-24*time.Hour).Unix()), float64(now.Add(time.Hour).Unix()), 50)
		require.NoError(t, err)
		require.Len(t, got, 1)
		assert.Equal(t, int(personal), got[0].ID)
	})
	t.Run("ListTargetsForMirror", func(t *testing.T) {
		got, err := d.ListTargetsForMirror()
		require.NoError(t, err)
		require.Len(t, got, 1)
		assert.Equal(t, int(personal), got[0].ID)
	})
	t.Run("GetChannelValueSignals", func(t *testing.T) {
		got, err := d.GetChannelValueSignals()
		require.NoError(t, err)
		assert.Equal(t, 1, got["C1"].TaskCount)
	})
	// Last: it stamps notified_at/updated_at on what it surfaces.
	t.Run("NotifyDueTargets", func(t *testing.T) {
		n, err := d.NotifyDueTargets(now)
		require.NoError(t, err)
		assert.Equal(t, 1, n)
		var surfaced int64
		require.NoError(t, d.QueryRow(`SELECT target_id FROM inbox_items WHERE trigger_type = 'target_due'`).Scan(&surfaced))
		assert.Equal(t, personal, surfaced)
	})
}
```

- [ ] **Step 2: Write the failing package-local companions**

Append to `internal/dayplan/gather_test.go`:

```go
// TestProj01_DayPlanGatherExcludesProjectTargets: a project target never
// reaches the day-plan input (PROJ-01, docs/inventory/projects.md).
func TestProj01_DayPlanGatherExcludesProjectTargets(t *testing.T) {
	d := gatherTestDB(t)
	p := testPipeline(d)
	_, err := d.CreateTarget(db.Target{Text: "personal", Status: "todo", Priority: "medium", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)
	pid, err := d.CreateProject("acme", t.TempDir())
	require.NoError(t, err)
	_, err = d.CreateProjectTarget(pid, sql.NullInt64{}, "board only", "")
	require.NoError(t, err)

	got, err := p.gatherTargets()
	require.NoError(t, err)
	require.Len(t, got, 1)
	assert.Equal(t, "personal", got[0].Text)
}
```

Append to `internal/targets/pipeline_test.go` (add `"database/sql"` to its imports if absent):

```go
// TestProj01_ExtractSnapshotExcludesProjectTargets: the ACTIVE TARGETS
// snapshot the extract prompt carries (and the link/dedup one, same query)
// never lists a project target (PROJ-01).
func TestProj01_ExtractSnapshotExcludesProjectTargets(t *testing.T) {
	gen := &mockGenerator{responses: []string{`{"extracted": [], "omitted_count": 0, "notes": ""}`}}
	p, d := makeTestPipeline(t, gen)
	_, err := d.CreateTarget(db.Target{Text: "personal-target-visible", Status: "todo", Priority: "medium",
		Ownership: "mine", SourceType: "manual"})
	if err != nil {
		t.Fatalf("create personal target: %v", err)
	}
	pid, err := d.CreateProject("acme", t.TempDir())
	if err != nil {
		t.Fatalf("create project: %v", err)
	}
	if _, err := d.CreateProjectTarget(pid, sql.NullInt64{}, "project-target-hidden", ""); err != nil {
		t.Fatalf("create project target: %v", err)
	}

	if _, err := p.Extract(context.Background(), ExtractRequest{RawText: "ship the thing"}); err != nil {
		t.Fatalf("Extract: %v", err)
	}
	if !strings.Contains(gen.lastSystem, "personal-target-visible") {
		t.Fatalf("snapshot lost the personal target:\n%s", gen.lastSystem)
	}
	if strings.Contains(gen.lastSystem, "project-target-hidden") {
		t.Fatalf("snapshot leaked a project target:\n%s", gen.lastSystem)
	}
}
```

Append to `internal/targets/nextstep_test.go` (add `"errors"` to its imports):

```go
// TestProj01_NextStepSkipsProjectTarget: next-step never runs for a project
// target — no AI call, no attempt recorded (PROJ-01).
func TestProj01_NextStepSkipsProjectTarget(t *testing.T) {
	gen := &mockGenerator{responses: []string{`{"title":"x","rationale":"y","urgency":"normal","actions":[]}`}}
	p, d := makeTestPipeline(t, gen)
	pid, err := d.CreateProject("acme", t.TempDir())
	if err != nil {
		t.Fatalf("create project: %v", err)
	}
	id, err := d.CreateProjectTarget(pid, sql.NullInt64{}, "board only", "")
	if err != nil {
		t.Fatalf("create project target: %v", err)
	}

	_, err = p.GenerateNextStep(context.Background(), int(id))
	if !errors.Is(err, ErrProjectTarget) {
		t.Fatalf("GenerateNextStep err = %v, want ErrProjectTarget", err)
	}
	if gen.calls() != 0 {
		t.Fatalf("AI called %d times for a project target", gen.calls())
	}
	tg, err := d.GetTargetByID(int(id))
	if err != nil {
		t.Fatalf("reload: %v", err)
	}
	if tg.NextStepAttempts != 0 || tg.NextStepAttemptedAt != "" {
		t.Fatalf("attempt recorded for a project target: %+v", tg)
	}
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `go test ./internal/db/ -run 'TestCreateProjectTarget|TestTargets_ProjectID|TestGetTargets_ProjectScope|TestPromoteSubItemToChild_CopiesProjectID|TestProj01'`
Expected: FAIL to compile — `d.CreateProjectTarget undefined`, `unknown field ProjectID in struct literal of type Target`.

Run: `go test ./internal/dayplan/ ./internal/targets/ -run 'TestProj01'`
Expected: FAIL to compile — `d.CreateProjectTarget undefined`, `undefined: ErrProjectTarget`.

- [ ] **Step 4: Add the model fields**

In `internal/db/models.go`, replace

```go
	NextStepAttemptedAt string // UTC ISO8601 of the most recent attempt (success or failure), "" if never attempted
}
```

with

```go
	NextStepAttemptedAt string        // UTC ISO8601 of the most recent attempt (success or failure), "" if never attempted
	ProjectID           sql.NullInt64 // set = lives only on that project's board (migration 00081, PROJ-01)
}
```

and replace

```go
	Limit       int
	IncludeDone bool
}

// TargetLink represents a typed link between two targets or to an external reference.
```

with

```go
	Limit       int
	IncludeDone bool
	// ProjectID scopes the query to one project board: 0 (every existing
	// caller) excludes project targets, N returns only project N's (PROJ-01).
	ProjectID int64
}

// TargetLink represents a typed link between two targets or to an external reference.
```

- [ ] **Step 5: Carry `project_id` through `internal/db/targets.go`**

Replace

```go
	next_step, next_step_at, next_step_attempts, next_step_attempted_at`
```

with

```go
	next_step, next_step_at, next_step_attempts, next_step_attempted_at, project_id`
```

In `scanTarget` replace

```go
		&t.NextStep, &t.NextStepAt, &t.NextStepAttempts, &t.NextStepAttemptedAt,
	); err != nil {
```

with

```go
		&t.NextStep, &t.NextStepAt, &t.NextStepAttempts, &t.NextStepAttemptedAt, &t.ProjectID,
	); err != nil {
```

In `CreateTarget` replace

```go
		 tags, sub_items, notes, progress, source_type, source_id, ai_level_confidence)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		t.Text, t.Intent, t.Level, t.CustomLabel, t.PeriodStart, t.PeriodEnd, t.ParentID,
		t.Status, t.Priority, t.Ownership, t.BallOn, t.DueDate, t.SnoozeUntil, t.Blocking,
		t.Tags, t.SubItems, t.Notes, progress, t.SourceType, t.SourceID, t.AILevelConfidence,
	)
```

with

```go
		 tags, sub_items, notes, progress, source_type, source_id, ai_level_confidence, project_id)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		t.Text, t.Intent, t.Level, t.CustomLabel, t.PeriodStart, t.PeriodEnd, t.ParentID,
		t.Status, t.Priority, t.Ownership, t.BallOn, t.DueDate, t.SnoozeUntil, t.Blocking,
		t.Tags, t.SubItems, t.Notes, progress, t.SourceType, t.SourceID, t.AILevelConfidence, t.ProjectID,
	)
```

In `UpdateTarget` replace

```go
		tags = ?, sub_items = ?, notes = ?, source_type = ?, source_id = ?,
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE id = ?`,
		t.Text, t.Intent, t.Level, t.CustomLabel, t.PeriodStart, t.PeriodEnd,
		t.ParentID, t.Status, t.Priority, t.Ownership,
		t.BallOn, t.DueDate, t.SnoozeUntil, t.Blocking,
		t.Tags, t.SubItems, t.Notes, t.SourceType, t.SourceID,
		t.ID,
```

with

```go
		tags = ?, sub_items = ?, notes = ?, source_type = ?, source_id = ?, project_id = ?,
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE id = ?`,
		t.Text, t.Intent, t.Level, t.CustomLabel, t.PeriodStart, t.PeriodEnd,
		t.ParentID, t.Status, t.Priority, t.Ownership,
		t.BallOn, t.DueDate, t.SnoozeUntil, t.Blocking,
		t.Tags, t.SubItems, t.Notes, t.SourceType, t.SourceID, t.ProjectID,
		t.ID,
```

In `GetTargetsNeedingNextStep` replace

```go
		WHERE status IN ('todo','in_progress','blocked')
		  AND (next_step_at = '' OR next_step_at < updated_at)
```

with

```go
		WHERE status IN ('todo','in_progress','blocked')
		  AND project_id IS NULL
		  AND (next_step_at = '' OR next_step_at < updated_at)
```

In `GetTargets` replace

```go
	if !f.IncludeDone && f.Status == "" {
		conditions = append(conditions, "status NOT IN ('done','dismissed')")
	}
```

with

```go
	if !f.IncludeDone && f.Status == "" {
		conditions = append(conditions, "status NOT IN ('done','dismissed')")
	}
	scope, scopeArgs := projectScope(f.ProjectID)
	conditions = append(conditions, scope)
	args = append(args, scopeArgs...)
```

and add right above `// GetTargets returns targets matching the filter.`:

```go
// projectScope is the PROJ-01 clause of GetTargets: 0 keeps project targets
// out, N selects only project N's board (docs/inventory/projects.md).
func projectScope(projectID int64) (string, []any) {
	if projectID > 0 {
		return "project_id = ?", []any{projectID}
	}
	return "project_id IS NULL", nil
}

```

In `GetTargetCounts` replace

```go
		FROM targets WHERE status NOT IN ('done','dismissed')`, now).Scan(&active, &overdue)
```

with

```go
		FROM targets WHERE status NOT IN ('done','dismissed') AND project_id IS NULL`, now).Scan(&active, &overdue)
```

In `GetTargetsForBriefing` replace

```go
	rows, err := db.Query(`SELECT ` + targetSelectCols + ` FROM targets
		WHERE status IN ('todo','in_progress','blocked')
		ORDER BY
```

with

```go
	rows, err := db.Query(`SELECT ` + targetSelectCols + ` FROM targets
		WHERE status IN ('todo','in_progress','blocked') AND project_id IS NULL
		ORDER BY
```

- [ ] **Step 6: Exclude project targets in the other `internal/db` readers**

`internal/db/targets_remind.go` — replace

```go
			  AND notified_at = ''
			  AND status IN ('todo','in_progress','blocked')`, cutoff)
```

with

```go
			  AND notified_at = ''
			  AND status IN ('todo','in_progress','blocked')
			  AND project_id IS NULL`, cutoff)
```

`internal/db/catchup.go` (`ListCatchupTargets`) — replace

```go
		WHERE status NOT IN ('done','dismissed') AND due_date <> ''
```

with

```go
		WHERE status NOT IN ('done','dismissed') AND due_date <> '' AND project_id IS NULL
```

`internal/db/memory.go` (`ListTargetsForMirror`) — replace

```go
		       (status IN ('done', 'dismissed'))
		FROM targets
		ORDER BY id`)
```

with

```go
		       (status IN ('done', 'dismissed'))
		FROM targets
		WHERE project_id IS NULL
		ORDER BY id`)
```

and in its doc comment replace `(MEM-14): targets are only read here, never written.` with `(MEM-14): targets are only read here, never written. Project targets are never mirrored (PROJ-01).`

`internal/db/channel_stats.go` (`GetChannelValueSignals`) — replace

```go
			JOIN digests d ON t.source_type = 'digest' AND t.source_id = CAST(d.id AS TEXT)
			WHERE t.status IN ('todo','in_progress','blocked')
```

with

```go
			JOIN digests d ON t.source_type = 'digest' AND t.source_id = CAST(d.id AS TEXT)
			WHERE t.status IN ('todo','in_progress','blocked') AND t.project_id IS NULL
```

and replace

```go
			JOIN inbox_items i ON t.source_type = 'inbox' AND t.source_id = CAST(i.id AS TEXT)
			WHERE t.status IN ('todo','in_progress','blocked')
```

with

```go
			JOIN inbox_items i ON t.source_type = 'inbox' AND t.source_id = CAST(i.id AS TEXT)
			WHERE t.status IN ('todo','in_progress','blocked') AND t.project_id IS NULL
```

`internal/db/targets_promote.go` (`PromoteSubItemToChild`) — replace

```go
		parentTags        string
		parentSubItems    string
	)
	err = tx.QueryRow(`SELECT intent, level, custom_label, period_start, period_end,
		priority, ownership, ball_on, due_date, tags, sub_items
		FROM targets WHERE id = ?`, parentID).Scan(
		&parentIntent, &parentLevel, &parentCustomLabel,
		&parentPeriodStart, &parentPeriodEnd,
		&parentPriority, &parentOwnership, &parentBallOn, &parentDueDate,
		&parentTags, &parentSubItems,
	)
```

with

```go
		parentTags        string
		parentSubItems    string
		parentProjectID   sql.NullInt64
	)
	err = tx.QueryRow(`SELECT intent, level, custom_label, period_start, period_end,
		priority, ownership, ball_on, due_date, tags, sub_items, project_id
		FROM targets WHERE id = ?`, parentID).Scan(
		&parentIntent, &parentLevel, &parentCustomLabel,
		&parentPeriodStart, &parentPeriodEnd,
		&parentPriority, &parentOwnership, &parentBallOn, &parentDueDate,
		&parentTags, &parentSubItems, &parentProjectID,
	)
```

and replace

```go
		 tags, sub_items, notes, progress, source_type, source_id, ai_level_confidence)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '', '',
		        ?, '[]', '[]', ?, 'promoted_subitem', ?, NULL)`,
		childText, childIntent, childLevel, childCustomLabel,
		childPeriodStart, childPeriodEnd, parentID,
		childStatus, childPriority, childOwnership, parentBallOn, childDueDate,
		childTags, childProgress, sourceID,
	)
```

with

```go
		 tags, sub_items, notes, progress, source_type, source_id, ai_level_confidence, project_id)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '', '',
		        ?, '[]', '[]', ?, 'promoted_subitem', ?, NULL, ?)`,
		childText, childIntent, childLevel, childCustomLabel,
		childPeriodStart, childPeriodEnd, parentID,
		childStatus, childPriority, childOwnership, parentBallOn, childDueDate,
		childTags, childProgress, sourceID, parentProjectID,
	)
```

Also add to the inheritance list in the `PromoteOverrides` doc comment, right after the line `//     (keeps parent progress stable across the promote)`:

```go
//   - project_id — parent.project_id (a promoted sub-item stays on its board)
```

- [ ] **Step 7: Create `internal/db/project_targets.go`**

```go
package db

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

// ProjectTargetInput is one item of a CreateProjectTargetsTx batch. Its parent
// is an existing target of the same project (ParentID) or an earlier item of
// the same batch (BatchParent, 1-based; 0 = none) — never both — so a whole
// plan (feature → tasks → steps) lands in one call.
type ProjectTargetInput struct {
	Title       string
	Intent      string
	ParentID    sql.NullInt64
	BatchParent int
}

// CreateProjectTarget creates one target on project projectID's board.
func (db *DB) CreateProjectTarget(projectID int64, parentID sql.NullInt64, title, intent string) (int64, error) {
	var ids []int64
	err := db.WithTx(func(tx *sql.Tx) error {
		var err error
		ids, err = db.CreateProjectTargetsTx(tx, projectID,
			[]ProjectTargetInput{{Title: title, Intent: intent, ParentID: parentID}})
		return err
	})
	if err != nil {
		return 0, err
	}
	return ids[0], nil
}

// CreateProjectTargetsTx inserts items, in order, as targets of project
// projectID inside tx and returns their ids. Every item gets the board
// defaults: level custom, custom_label project, period = the UTC day of
// creation, source chat, ownership mine, status todo. The first invalid item
// fails the call; the caller's transaction then rolls the whole batch back.
func (db *DB) CreateProjectTargetsTx(tx *sql.Tx, projectID int64, items []ProjectTargetInput) ([]int64, error) {
	if err := requireProject(tx, projectID); err != nil {
		return nil, err
	}
	day := time.Now().UTC().Format("2006-01-02")
	ids := make([]int64, 0, len(items))
	for i, it := range items {
		id, err := insertProjectTarget(tx, projectID, day, it, ids)
		if err != nil {
			return nil, fmt.Errorf("target %d of %d: %w", i+1, len(items), err)
		}
		ids = append(ids, id)
	}
	return ids, nil
}

func insertProjectTarget(tx *sql.Tx, projectID int64, day string, it ProjectTargetInput, created []int64) (int64, error) {
	title := strings.TrimSpace(it.Title)
	if title == "" {
		return 0, errors.New("empty title")
	}
	parent, err := resolveProjectParent(tx, projectID, it, created)
	if err != nil {
		return 0, err
	}
	res, err := tx.Exec(`INSERT INTO targets
		(text, intent, level, custom_label, period_start, period_end, parent_id,
		 status, ownership, source_type, project_id)
		VALUES (?, ?, 'custom', 'project', ?, ?, ?, 'todo', 'mine', 'chat', ?)`,
		title, strings.TrimSpace(it.Intent), day, day, parent, projectID)
	if err != nil {
		return 0, fmt.Errorf("inserting project target: %w", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return 0, err
	}
	if parent.Valid {
		if err := recomputeParentProgressOn(tx, parent.Int64); err != nil {
			return 0, err
		}
	}
	return id, nil
}

func resolveProjectParent(q targetsQuerier, projectID int64, it ProjectTargetInput, created []int64) (sql.NullInt64, error) {
	switch {
	case it.ParentID.Valid && it.BatchParent != 0:
		return sql.NullInt64{}, errors.New("parent_id and a batch parent are mutually exclusive")
	case it.BatchParent < 0 || it.BatchParent > len(created):
		return sql.NullInt64{}, fmt.Errorf("batch parent %d is not an earlier item of this batch", it.BatchParent)
	case it.BatchParent > 0:
		return sql.NullInt64{Int64: created[it.BatchParent-1], Valid: true}, nil
	case it.ParentID.Valid:
		return it.ParentID, checkTargetInProject(q, projectID, it.ParentID.Int64)
	}
	return sql.NullInt64{}, nil
}
```

- [ ] **Step 8: Exclude project targets in the day plan and next-step**

`internal/dayplan/gather.go` (`gatherTargets`) — replace

```go
		WHERE status IN ('todo', 'in_progress', 'blocked')
```

with

```go
		WHERE status IN ('todo', 'in_progress', 'blocked') AND project_id IS NULL
```

and extend its doc comment: `// gatherTargets returns active targets (todo, in_progress, blocked), ordered by priority. Project targets never reach the day plan (PROJ-01).`

`internal/targets/nextstep.go` — add `"errors"` to the imports, add above `// GenerateNextStep computes and persists …`:

```go
// ErrProjectTarget is returned for a target on a project board: project
// targets are moved by the project's agent, never by next-step (PROJ-01).
var ErrProjectTarget = errors.New("project targets have no next step")

```

and in `GenerateNextStep` replace

```go
	target, err := p.db.GetTargetByID(targetID)
	if err != nil {
		return nil, fmt.Errorf("loading target %d: %w", targetID, err)
	}

	now := time.Now().UTC()
```

with

```go
	target, err := p.db.GetTargetByID(targetID)
	if err != nil {
		return nil, fmt.Errorf("loading target %d: %w", targetID, err)
	}
	if target.ProjectID.Valid {
		return nil, fmt.Errorf("target %d: %w", targetID, ErrProjectTarget)
	}

	now := time.Now().UTC()
```

- [ ] **Step 9: Run the tests**

Run: `go test ./internal/db/ -run 'TestCreateProjectTarget|TestTargets_ProjectID|TestGetTargets_ProjectScope|TestPromoteSubItemToChild|TestProj01'`
Expected: PASS.

Run: `go test ./internal/db/ ./internal/dayplan/ ./internal/targets/`
Expected: PASS (every existing target test keeps passing — none of them creates a project target).

Run: `go test ./internal/catchup/ ./internal/briefing/ ./internal/memory/ ./internal/tools/`
Expected: PASS — these packages consume the changed readers.

- [ ] **Step 10: Lint**

Run: `make lint-diff`
Expected: no new issues.

- [ ] **Step 11: Commit**

```bash
git add internal/db/models.go internal/db/targets.go internal/db/targets_promote.go internal/db/targets_remind.go \
  internal/db/catchup.go internal/db/memory.go internal/db/channel_stats.go \
  internal/db/project_targets.go internal/db/project_targets_test.go internal/db/proj01_guard_test.go \
  internal/dayplan/gather.go internal/dayplan/gather_test.go \
  internal/targets/nextstep.go internal/targets/nextstep_test.go internal/targets/pipeline_test.go
git commit -m "feat(db): project targets stay on their board (PROJ-01)" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Lo9jbbmXQcr3qHo5f3pLD8"
```

---

## Task 4: Board query + `watchtower project create|list|show|board|delete`

**Files:**
- Create: `internal/db/project_board.go`
- Create: `internal/db/project_board_test.go`
- Create: `cmd/project.go`
- Create: `cmd/project_test.go`

**Interfaces:**
- Consumes: Tasks 2–3 (`ResolveProjectFolder`, `CreateProject`, `GetProject`, `ListProjects`, `ListProjectSources`, `ListProjectDocuments`, `DeleteProject`, `CreateProjectTargetsTx`, `newForAgentPredicate`, `targetSelectCols`/`scanTarget`); `openJiraCmdDB`, `writeJSON` (cmd).
- Produces:
  ```go
  // package db
  type BoardNode struct{ Target Target; Children []BoardNode; NewForAgent, UnreadForOwner int; Documents []ProjectDocument }
  func (db *DB) GetProjectBoard(projectID int64) ([]BoardNode, error)
  // package cmd
  var projectRemoveInstall = func(context.Context, *config.Config, *db.Project) error { return nil } // Task 12 wires devpack.RemoveProject
  func countBoardStatuses(nodes []db.BoardNode) map[string]int // also used by Task 5
  // CLI: project create --folder DIR [--name NAME] [--json] → {"id":N,"folder":…,"name":…}
  //      project list [--json] | show N [--json] | board N [--json] | delete N
  ```

- [ ] **Step 1: Write the failing board test**

Create `internal/db/project_board_test.go`:

```go
package db

import (
	"database/sql"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestGetProjectBoard_TreeOrderCountsAndDocuments(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	var ids []int64
	require.NoError(t, d.WithTx(func(tx *sql.Tx) error {
		var err error
		ids, err = d.CreateProjectTargetsTx(tx, pid, []ProjectTargetInput{
			{Title: "todo root"},
			{Title: "done root"},
			{Title: "active root"},
			{Title: "child of active", BatchParent: 3},
		})
		return err
	}))
	require.NoError(t, d.UpdateTargetStatus(int(ids[1]), "done"))
	require.NoError(t, d.UpdateTargetStatus(int(ids[2]), "in_progress"))

	_, err := d.CreateProjectTarget(newTestProject(t, d), sql.NullInt64{}, "another board", "")
	require.NoError(t, err)
	_, err = d.CreateTarget(Target{Text: "personal", Status: "todo", Priority: "medium", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)

	active := nullID(ids[2])
	_, err = d.AddProjectComment(ProjectComment{ProjectID: pid, TargetID: active, Author: "owner", Body: "please split"})
	require.NoError(t, err)
	_, err = d.AddProjectComment(ProjectComment{ProjectID: pid, TargetID: active, Author: "agent", Body: "which part?"})
	require.NoError(t, err)
	docID, _, err := d.UpsertProjectDocument(ProjectDocument{ProjectID: pid, TargetID: active, RelPath: "docs/plan.md", Kind: "plan"})
	require.NoError(t, err)

	board, err := d.GetProjectBoard(pid)
	require.NoError(t, err)
	require.Len(t, board, 3, "only this project's roots")
	assert.Equal(t, "active root", board[0].Target.Text, "in_progress first")
	assert.Equal(t, "todo root", board[1].Target.Text)
	assert.Equal(t, "done root", board[2].Target.Text, "done after todo")

	require.Len(t, board[0].Children, 1)
	assert.Equal(t, "child of active", board[0].Children[0].Target.Text)
	assert.Equal(t, 1, board[0].NewForAgent, "the open owner root")
	assert.Equal(t, 1, board[0].UnreadForOwner, "the unread agent comment")
	require.Len(t, board[0].Documents, 1)
	assert.Equal(t, docID, board[0].Documents[0].ID)
	assert.Zero(t, board[1].NewForAgent)

	empty, err := d.GetProjectBoard(pid + 100)
	require.NoError(t, err)
	assert.Empty(t, empty)
}
```

- [ ] **Step 2: Write the failing CLI tests**

Create `cmd/project_test.go`:

```go
package cmd

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
)

// runProject executes the real "project" command tree via rootCmd (the
// runActions precedent) with stdout and stderr captured separately.
func runProject(t *testing.T, args ...string) (stdout, stderr string, err error) {
	t.Helper()
	var out, errOut bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&errOut)
	rootCmd.SetArgs(append([]string{"project"}, args...))
	err = rootCmd.Execute()
	rootCmd.SetArgs(nil)
	projectFlagJSON = false
	projectCreateFlagFolder = ""
	projectCreateFlagName = ""
	return out.String(), errOut.String(), err
}

func TestProject_CreateStoresTheResolvedFolderAndDefaultsTheName(t *testing.T) {
	writeActionsConfig(t)
	base := t.TempDir()
	realDir := filepath.Join(base, "my проект")
	require.NoError(t, os.Mkdir(realDir, 0o755))
	link := filepath.Join(base, "link with spaces")
	require.NoError(t, os.Symlink(realDir, link))
	want, err := filepath.EvalSymlinks(realDir)
	require.NoError(t, err)

	out, _, err := runProject(t, "create", "--folder", link, "--json")
	require.NoError(t, err)
	var got projectJSON
	require.NoError(t, json.Unmarshal([]byte(out), &got))
	assert.Positive(t, got.ID)
	assert.Equal(t, want, got.Folder, "the symlink-resolved absolute path is stored")
	assert.Equal(t, "my проект", got.Name, "the name defaults to the folder's base name")

	out, _, err = runProject(t, "create", "--folder", realDir, "--name", "Acme", "--json")
	assert.ErrorIs(t, err, db.ErrProjectFolderTaken, "the real path of an already-bound symlink is taken: %s", out)
}

func TestProject_CreateRefusesMissingAndAlreadyBoundFolders(t *testing.T) {
	writeActionsConfig(t)
	_, _, err := runProject(t, "create", "--folder", filepath.Join(t.TempDir(), "gone"))
	assert.Error(t, err, "a missing directory is refused")
	_, _, err = runProject(t, "create")
	assert.ErrorContains(t, err, "--folder is required")

	folder := t.TempDir()
	_, _, err = runProject(t, "create", "--folder", folder)
	require.NoError(t, err)
	_, _, err = runProject(t, "create", "--folder", folder)
	assert.ErrorIs(t, err, db.ErrProjectFolderTaken)
}

func TestProject_ListShowAndBoardJSON(t *testing.T) {
	database := writeActionsConfig(t)
	pid, err := database.CreateProject("acme", t.TempDir())
	require.NoError(t, err)
	_, err = database.CreateProject("other", t.TempDir())
	require.NoError(t, err)
	var ids []int64
	require.NoError(t, database.WithTx(func(tx *sql.Tx) error {
		var err error
		ids, err = database.CreateProjectTargetsTx(tx, pid, []db.ProjectTargetInput{
			{Title: "feature"}, {Title: "task 1", BatchParent: 1},
		})
		return err
	}))
	require.NoError(t, database.UpdateTargetStatus(int(ids[1]), "in_progress"))
	_, err = database.AddProjectSource(db.ProjectSource{ProjectID: pid, Kind: "link", Ref: "https://example.com", Label: "site"})
	require.NoError(t, err)
	_, err = database.AddProjectComment(db.ProjectComment{ProjectID: pid, TargetID: sql.NullInt64{Int64: ids[0], Valid: true},
		Author: "owner", Body: "go"})
	require.NoError(t, err)

	out, _, err := runProject(t, "list", "--json")
	require.NoError(t, err)
	var list []projectJSON
	require.NoError(t, json.Unmarshal([]byte(out), &list))
	assert.Len(t, list, 2)

	out, _, err = runProject(t, "show", strconv.FormatInt(pid, 10), "--json")
	require.NoError(t, err)
	var view projectViewJSON
	require.NoError(t, json.Unmarshal([]byte(out), &view))
	assert.Equal(t, "acme", view.Name)
	require.Len(t, view.Sources, 1)
	assert.Equal(t, "https://example.com", view.Sources[0].Ref)
	assert.Equal(t, 1, view.Counts["todo"])
	assert.Equal(t, 1, view.Counts["in_progress"])

	out, _, err = runProject(t, "board", strconv.FormatInt(pid, 10), "--json")
	require.NoError(t, err)
	var board []boardNodeJSON
	require.NoError(t, json.Unmarshal([]byte(out), &board))
	require.Len(t, board, 1)
	assert.Equal(t, "feature", board[0].Title)
	assert.Equal(t, 1, board[0].NewForAgent)
	require.Len(t, board[0].Children, 1)
	assert.Equal(t, "in_progress", board[0].Children[0].Status)

	_, _, err = runProject(t, "show", "999")
	assert.ErrorIs(t, err, db.ErrProjectNotFound)
	_, _, err = runProject(t, "board", "abc")
	assert.Error(t, err)
}

// TestProject_DeleteStillDeletesWhenInstallRemovalFails: the folder cleanup
// runs first; its failure is reported and the delete still happens (spec §4.4).
func TestProject_DeleteStillDeletesWhenInstallRemovalFails(t *testing.T) {
	database := writeActionsConfig(t)
	pid, err := database.CreateProject("acme", t.TempDir())
	require.NoError(t, err)
	_, err = database.CreateProjectTarget(pid, sql.NullInt64{}, "board item", "")
	require.NoError(t, err)

	var removed *db.Project
	orig := projectRemoveInstall
	projectRemoveInstall = func(_ context.Context, _ *config.Config, p *db.Project) error {
		removed = p
		return errors.New("folder is read-only")
	}
	t.Cleanup(func() { projectRemoveInstall = orig })

	out, errOut, err := runProject(t, "delete", strconv.FormatInt(pid, 10))
	require.NoError(t, err)
	require.NotNil(t, removed, "the folder cleanup ran")
	assert.Equal(t, pid, removed.ID)
	assert.Contains(t, errOut, "folder is read-only")
	assert.Contains(t, out, "Deleted project")

	_, err = database.GetProject(pid)
	assert.ErrorIs(t, err, db.ErrProjectNotFound)
	var n int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM targets WHERE project_id = ?`, pid).Scan(&n))
	assert.Zero(t, n)

	_, _, err = runProject(t, "delete", strconv.FormatInt(pid, 10))
	assert.ErrorIs(t, err, db.ErrProjectNotFound)
}
```

(`runProject` resets every `project` flag var after each run; Task 5 Step 1 adds the reset of the brief's `--project` flag once it exists.)

- [ ] **Step 3: Run the tests to verify they fail**

Run: `go test ./internal/db/ -run TestGetProjectBoard`
Expected: FAIL to compile — `d.GetProjectBoard undefined`.

Run: `go test ./cmd -run 'TestProject_'`
Expected: FAIL to compile — `undefined: projectFlagJSON`, `undefined: projectJSON`, `undefined: projectRemoveInstall`.

- [ ] **Step 4: Implement `internal/db/project_board.go`**

```go
package db

import "fmt"

// BoardNode is one target of a project board with its subtree, its comment
// counters and the documents attached to it.
type BoardNode struct {
	Target         Target
	Children       []BoardNode
	NewForAgent    int // comments the agent has not answered (newForAgentPredicate)
	UnreadForOwner int // agent comments with an empty read_at
	Documents      []ProjectDocument
}

// boardStatusOrder sorts siblings: in_progress, blocked, todo, done, then
// dismissed/snoozed; ties by id.
const boardStatusOrder = `CASE status WHEN 'in_progress' THEN 0 WHEN 'blocked' THEN 1
	WHEN 'todo' THEN 2 WHEN 'done' THEN 3 ELSE 4 END, id`

type boardCounts struct{ newForAgent, unreadForOwner int }

// GetProjectBoard returns project projectID's target forest. An unknown
// project yields an empty board; callers check GetProject first.
func (db *DB) GetProjectBoard(projectID int64) ([]BoardNode, error) {
	targets, err := db.listBoardTargets(projectID)
	if err != nil {
		return nil, err
	}
	counts, err := db.boardCommentCounts(projectID)
	if err != nil {
		return nil, err
	}
	docs, err := db.ListProjectDocuments(projectID)
	if err != nil {
		return nil, err
	}
	return assembleBoard(targets, counts, docs), nil
}

func (db *DB) listBoardTargets(projectID int64) ([]Target, error) {
	rows, err := db.Query(`SELECT `+targetSelectCols+` FROM targets WHERE project_id = ? ORDER BY `+boardStatusOrder, projectID)
	if err != nil {
		return nil, fmt.Errorf("listing board targets: %w", err)
	}
	defer rows.Close()
	var out []Target
	for rows.Next() {
		t, err := scanTarget(rows)
		if err != nil {
			return nil, fmt.Errorf("scanning board target: %w", err)
		}
		out = append(out, *t)
	}
	return out, rows.Err()
}

func (db *DB) boardCommentCounts(projectID int64) (map[int64]boardCounts, error) {
	rows, err := db.Query(`SELECT c.target_id,
		SUM(CASE WHEN `+newForAgentPredicate+` THEN 1 ELSE 0 END),
		SUM(CASE WHEN c.author = 'agent' AND c.read_at = '' THEN 1 ELSE 0 END)
		FROM project_comments c
		WHERE c.project_id = ? AND c.target_id IS NOT NULL
		GROUP BY c.target_id`, projectID)
	if err != nil {
		return nil, fmt.Errorf("counting board comments: %w", err)
	}
	defer rows.Close()
	out := map[int64]boardCounts{}
	for rows.Next() {
		var id int64
		var c boardCounts
		if err := rows.Scan(&id, &c.newForAgent, &c.unreadForOwner); err != nil {
			return nil, fmt.Errorf("scanning board comment counts: %w", err)
		}
		out[id] = c
	}
	return out, rows.Err()
}

// boardIndex builds the forest from the flat, already-ordered target list.
type boardIndex struct {
	children map[int64][]Target
	counts   map[int64]boardCounts
	docs     map[int64][]ProjectDocument
	seen     map[int64]bool
}

func assembleBoard(targets []Target, counts map[int64]boardCounts, docs []ProjectDocument) []BoardNode {
	onBoard := make(map[int64]bool, len(targets))
	for _, t := range targets {
		onBoard[int64(t.ID)] = true
	}
	ix := boardIndex{children: map[int64][]Target{}, counts: counts, docs: map[int64][]ProjectDocument{}, seen: map[int64]bool{}}
	for _, d := range docs {
		if d.TargetID.Valid {
			ix.docs[d.TargetID.Int64] = append(ix.docs[d.TargetID.Int64], d)
		}
	}
	var roots []Target
	for _, t := range targets {
		if t.ParentID.Valid && onBoard[t.ParentID.Int64] {
			ix.children[t.ParentID.Int64] = append(ix.children[t.ParentID.Int64], t)
			continue
		}
		roots = append(roots, t)
	}
	return ix.build(roots)
}

// build turns one sibling list into nodes. seen stops a parent cycle (which
// no project writer can create) from recursing forever.
func (ix boardIndex) build(level []Target) []BoardNode {
	nodes := make([]BoardNode, 0, len(level))
	for _, t := range level {
		id := int64(t.ID)
		if ix.seen[id] {
			continue
		}
		ix.seen[id] = true
		c := ix.counts[id]
		nodes = append(nodes, BoardNode{Target: t, NewForAgent: c.newForAgent, UnreadForOwner: c.unreadForOwner,
			Documents: ix.docs[id], Children: ix.build(ix.children[id])})
	}
	return nodes
}
```

- [ ] **Step 5: Implement `cmd/project.go`**

```go
package cmd

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/spf13/cobra"

	"watchtower/internal/config"
	"watchtower/internal/db"
)

var projectCmd = &cobra.Command{
	Use:   "project",
	Short: "Manage folder-bound projects (board, documents, comments)",
	Long: "A project binds a folder (e.g. a repository) to a board of targets, attached\n" +
		"documents and owner<->agent comments. Claude Code works on it through\n" +
		"`watchtower mcp --project N`, installed by `watchtower integrate claude-code --project N`.",
}

var projectCreateCmd = &cobra.Command{
	Use:   "create",
	Short: "Create a project bound to a folder",
	Long:  "Binds --folder (symlinks resolved) to a new project. Refuses a missing directory\nor a folder already bound to a project. The name defaults to the folder's base name.",
	RunE:  runProjectCreate,
}

var projectListCmd = &cobra.Command{
	Use:   "list",
	Short: "List projects",
	RunE:  runProjectList,
}

var projectShowCmd = &cobra.Command{
	Use:   "show <id>",
	Short: "Show a project: folder, description, sources, documents, target counts",
	Args:  cobra.ExactArgs(1),
	RunE:  runProjectShow,
}

var projectBoardCmd = &cobra.Command{
	Use:   "board <id>",
	Short: "Print a project's target tree with comment and document counters",
	Args:  cobra.ExactArgs(1),
	RunE:  runProjectBoard,
}

var projectDeleteCmd = &cobra.Command{
	Use:   "delete <id>",
	Short: "Delete a project, its board, documents and comments, and Watchtower's install in its folder",
	Long:  "Removes what `integrate claude-code --project N` installed in the folder first; a\nremoval failure is reported and the project is deleted anyway.",
	Args:  cobra.ExactArgs(1),
	RunE:  runProjectDelete,
}

var (
	projectFlagJSON         bool
	projectCreateFlagFolder string
	projectCreateFlagName   string
)

// projectRemoveInstall undoes what `integrate claude-code --project N` put
// into the project's folder. A no-op until the install lands (Task 12 wires
// devpack.RemoveProject); a package var so tests can observe and fail it.
var projectRemoveInstall = func(context.Context, *config.Config, *db.Project) error { return nil }

func init() {
	projectCreateCmd.Flags().StringVar(&projectCreateFlagFolder, "folder", "", "project folder (required; symlinks are resolved)")
	projectCreateCmd.Flags().StringVar(&projectCreateFlagName, "name", "", "project name (default: the folder's base name)")
	for _, c := range []*cobra.Command{projectCreateCmd, projectListCmd, projectShowCmd, projectBoardCmd} {
		c.Flags().BoolVar(&projectFlagJSON, "json", false, "output JSON")
	}
	projectCmd.AddCommand(projectCreateCmd, projectListCmd, projectShowCmd, projectBoardCmd, projectDeleteCmd)
	rootCmd.AddCommand(projectCmd)
}

type projectJSON struct {
	ID          int64  `json:"id"`
	Folder      string `json:"folder"`
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
	CreatedAt   string `json:"created_at,omitempty"`
	UpdatedAt   string `json:"updated_at,omitempty"`
}

type projectSourceJSON struct {
	ID    int64  `json:"id"`
	Kind  string `json:"kind"`
	Ref   string `json:"ref"`
	Label string `json:"label"`
}

type projectDocumentJSON struct {
	ID        int64  `json:"id"`
	TargetID  *int64 `json:"target_id,omitempty"`
	RelPath   string `json:"rel_path"`
	Kind      string `json:"kind"`
	Title     string `json:"title"`
	UpdatedAt string `json:"updated_at"`
}

type projectViewJSON struct {
	projectJSON
	Sources   []projectSourceJSON   `json:"sources"`
	Documents []projectDocumentJSON `json:"documents"`
	Counts    map[string]int        `json:"counts"` // targets per status
}

type boardNodeJSON struct {
	ID             int                   `json:"id"`
	Title          string                `json:"title"`
	Intent         string                `json:"intent"`
	Status         string                `json:"status"`
	Progress       float64               `json:"progress"`
	NewForAgent    int                   `json:"new_for_agent"`
	UnreadForOwner int                   `json:"unread_for_owner"`
	Documents      []projectDocumentJSON `json:"documents"`
	Children       []boardNodeJSON       `json:"children"`
}

func toProjectJSON(p db.Project) projectJSON {
	return projectJSON{ID: p.ID, Folder: p.FolderPath, Name: p.Name, Description: p.Description,
		CreatedAt: p.CreatedAt, UpdatedAt: p.UpdatedAt}
}

func nullableID(n sql.NullInt64) *int64 {
	if !n.Valid {
		return nil
	}
	v := n.Int64
	return &v
}

func toDocumentsJSON(docs []db.ProjectDocument) []projectDocumentJSON {
	out := make([]projectDocumentJSON, 0, len(docs))
	for _, d := range docs {
		out = append(out, projectDocumentJSON{ID: d.ID, TargetID: nullableID(d.TargetID), RelPath: d.RelPath,
			Kind: d.Kind, Title: d.Title, UpdatedAt: d.UpdatedAt})
	}
	return out
}

func toBoardJSON(nodes []db.BoardNode) []boardNodeJSON {
	out := make([]boardNodeJSON, 0, len(nodes))
	for _, n := range nodes {
		out = append(out, boardNodeJSON{ID: n.Target.ID, Title: n.Target.Text, Intent: n.Target.Intent,
			Status: n.Target.Status, Progress: n.Target.Progress, NewForAgent: n.NewForAgent,
			UnreadForOwner: n.UnreadForOwner, Documents: toDocumentsJSON(n.Documents), Children: toBoardJSON(n.Children)})
	}
	return out
}

// countBoardStatuses counts every target of the board by status.
func countBoardStatuses(nodes []db.BoardNode) map[string]int {
	counts := map[string]int{}
	var walk func([]db.BoardNode)
	walk = func(level []db.BoardNode) {
		for _, n := range level {
			counts[n.Target.Status]++
			walk(n.Children)
		}
	}
	walk(nodes)
	return counts
}

func parseProjectID(arg string) (int64, error) {
	id, err := strconv.ParseInt(arg, 10, 64)
	if err != nil || id <= 0 {
		return 0, fmt.Errorf("invalid project id %q", arg)
	}
	return id, nil
}

func runProjectCreate(cmd *cobra.Command, _ []string) error {
	if projectCreateFlagFolder == "" {
		return errors.New("--folder is required")
	}
	folder, err := db.ResolveProjectFolder(projectCreateFlagFolder)
	if err != nil {
		return err
	}
	name := projectCreateFlagName
	if strings.TrimSpace(name) == "" {
		name = filepath.Base(folder)
	}
	_, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	id, err := database.CreateProject(name, folder)
	if err != nil {
		return err
	}
	if projectFlagJSON {
		return writeJSON(cmd.OutOrStdout(), projectJSON{ID: id, Folder: folder, Name: name})
	}
	fmt.Fprintf(cmd.OutOrStdout(), "Created project %d %q at %s\n", id, name, folder)
	return nil
}

func runProjectList(cmd *cobra.Command, _ []string) error {
	_, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	projects, err := database.ListProjects()
	if err != nil {
		return err
	}
	if projectFlagJSON {
		out := make([]projectJSON, 0, len(projects))
		for _, p := range projects {
			out = append(out, toProjectJSON(p))
		}
		return writeJSON(cmd.OutOrStdout(), out)
	}
	if len(projects) == 0 {
		fmt.Fprintln(cmd.OutOrStdout(), "No projects.")
	}
	for _, p := range projects {
		fmt.Fprintf(cmd.OutOrStdout(), "#%d  %s  %s\n", p.ID, p.Name, p.FolderPath)
	}
	return nil
}

func runProjectShow(cmd *cobra.Command, args []string) error {
	id, err := parseProjectID(args[0])
	if err != nil {
		return err
	}
	_, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	view, err := loadProjectView(database, id)
	if err != nil {
		return err
	}
	if projectFlagJSON {
		return writeJSON(cmd.OutOrStdout(), view)
	}
	printProjectView(cmd.OutOrStdout(), view)
	return nil
}

func loadProjectView(database *db.DB, id int64) (projectViewJSON, error) {
	p, err := database.GetProject(id)
	if err != nil {
		return projectViewJSON{}, err
	}
	sources, err := database.ListProjectSources(id)
	if err != nil {
		return projectViewJSON{}, err
	}
	docs, err := database.ListProjectDocuments(id)
	if err != nil {
		return projectViewJSON{}, err
	}
	board, err := database.GetProjectBoard(id)
	if err != nil {
		return projectViewJSON{}, err
	}
	view := projectViewJSON{projectJSON: toProjectJSON(*p), Sources: make([]projectSourceJSON, 0, len(sources)),
		Documents: toDocumentsJSON(docs), Counts: countBoardStatuses(board)}
	for _, s := range sources {
		view.Sources = append(view.Sources, projectSourceJSON{ID: s.ID, Kind: s.Kind, Ref: s.Ref, Label: s.Label})
	}
	return view, nil
}

func printProjectView(w io.Writer, v projectViewJSON) {
	fmt.Fprintf(w, "Project #%d %q\nFolder: %s\n", v.ID, v.Name, v.Folder)
	if v.Description != "" {
		fmt.Fprintf(w, "Description: %s\n", v.Description)
	}
	fmt.Fprintf(w, "Targets: %d in progress, %d blocked, %d todo, %d done\n",
		v.Counts["in_progress"], v.Counts["blocked"], v.Counts["todo"], v.Counts["done"])
	for _, s := range v.Sources {
		fmt.Fprintf(w, "Source #%d %s %s %s\n", s.ID, s.Kind, s.Ref, s.Label)
	}
	for _, d := range v.Documents {
		fmt.Fprintf(w, "Document #%d [%s] %s %s\n", d.ID, d.Kind, d.RelPath, d.Title)
	}
}

func runProjectBoard(cmd *cobra.Command, args []string) error {
	id, err := parseProjectID(args[0])
	if err != nil {
		return err
	}
	_, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	if _, err := database.GetProject(id); err != nil {
		return err
	}
	board, err := database.GetProjectBoard(id)
	if err != nil {
		return err
	}
	if projectFlagJSON {
		return writeJSON(cmd.OutOrStdout(), toBoardJSON(board))
	}
	printBoard(cmd.OutOrStdout(), board, 0)
	return nil
}

func printBoard(w io.Writer, nodes []db.BoardNode, depth int) {
	for _, n := range nodes {
		fmt.Fprintf(w, "%s#%d [%s] %s\n", strings.Repeat("  ", depth), n.Target.ID, n.Target.Status, n.Target.Text)
		printBoard(w, n.Children, depth+1)
	}
}

func runProjectDelete(cmd *cobra.Command, args []string) error {
	id, err := parseProjectID(args[0])
	if err != nil {
		return err
	}
	cfg, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	p, err := database.GetProject(id)
	if err != nil {
		return err
	}
	if rerr := projectRemoveInstall(cmd.Context(), cfg, p); rerr != nil {
		fmt.Fprintf(cmd.ErrOrStderr(), "warning: removing Watchtower's install from %s failed: %v (the project is deleted anyway)\n",
			p.FolderPath, rerr)
	}
	if err := database.DeleteProject(id); err != nil {
		return err
	}
	fmt.Fprintf(cmd.OutOrStdout(), "Deleted project %d %q.\n", id, p.Name)
	return nil
}
```

- [ ] **Step 6: Run the tests**

Run: `go test ./internal/db/ -run TestGetProjectBoard`
Expected: PASS.

Run: `go test ./cmd -run 'TestProject_'`
Expected: PASS.

- [ ] **Step 7: Lint**

Run: `make lint-diff`
Expected: no new issues.

- [ ] **Step 8: Commit**

```bash
git add internal/db/project_board.go internal/db/project_board_test.go cmd/project.go cmd/project_test.go
git commit -m "feat(project): board query and project create/list/show/board/delete CLI" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Lo9jbbmXQcr3qHo5f3pLD8"
```

---

## Task 5: `watchtower project brief` (the SessionStart hook body)

**Files:**
- Create: `cmd/project_brief.go`
- Create: `cmd/project_brief_test.go`
- Modify: `cmd/project_test.go` (`runProject` resets the brief flag)

**Interfaces:**
- Consumes: Task 4 `projectCmd`, `countBoardStatuses`, `runProject` (test); Task 2 `ListProjectComments{NewForAgent}`, `ListProjectDocuments`, `ErrProjectNotFound`; Task 4 `GetProjectBoard`.
- Produces:
  ```go
  func renderProjectBrief(board []db.BoardNode, p *db.Project, comments []db.ProjectComment, docs map[int64]db.ProjectDocument) string // pure, ≤ 4000 runes
  const briefMaxChars = 4000
  // CLI: watchtower project brief --project N — always exit 0; failures are one line
  //      "Watchtower: project N no longer exists." / "… folder … is missing …" / "… is unavailable: …"
  ```

- [ ] **Step 1: Write the failing tests**

In `cmd/project_test.go`, in `runProject`, replace

```go
	projectCreateFlagName = ""
	return out.String(), errOut.String(), err
```

with

```go
	projectCreateFlagName = ""
	projectBriefFlagProject = 0
	return out.String(), errOut.String(), err
```

Create `cmd/project_brief_test.go`:

```go
package cmd

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func briefNode(id int, status, title string, children ...db.BoardNode) db.BoardNode {
	return db.BoardNode{Target: db.Target{ID: id, Status: status, Text: title}, Children: children}
}

func briefProject() *db.Project {
	return &db.Project{ID: 7, Name: "acme", FolderPath: "/tmp/acme", Description: "A demo project."}
}

// TestRenderProjectBrief_LargeBoardStaysWithinBudget: whatever the board
// holds, the hook body fits 4000 runes, keeps the rules and says what it cut.
func TestRenderProjectBrief_LargeBoardStaysWithinBudget(t *testing.T) {
	long := strings.Repeat("Implement the next part of the plan ", 8)
	var board []db.BoardNode
	id := 1
	for r := 0; r < 40; r++ {
		root := briefNode(id, "in_progress", long)
		id++
		for c := 0; c < 15; c++ {
			root.Children = append(root.Children, briefNode(id, "todo", "Ünïcödé "+long))
			id++
		}
		board = append(board, root)
	}
	docs := map[int64]db.ProjectDocument{1: {ID: 1, RelPath: "docs/plan.md"}}
	var comments []db.ProjectComment
	for i := 0; i < 150; i++ {
		c := db.ProjectComment{ID: int64(1000 + i), Author: "owner", Body: strings.Repeat("Please revise this. ", 25)}
		if i%2 == 0 {
			c.DocumentID = sql.NullInt64{Int64: 1, Valid: true}
			c.AnchorHeading = strings.Repeat("Heading ", 20)
			c.AnchorQuote = strings.Repeat("quoted text ", 20)
		} else {
			c.TargetID = sql.NullInt64{Int64: 1, Valid: true}
		}
		comments = append(comments, c)
	}
	p := briefProject()
	p.Name = strings.Repeat("very long name ", 500)
	p.FolderPath = "/tmp/" + strings.Repeat("deep/", 500)

	out := renderProjectBrief(board, p, comments, docs)

	assert.LessOrEqual(t, utf8.RuneCountInString(out), briefMaxChars)
	assert.True(t, utf8.ValidString(out))
	assert.Contains(t, out, "more targets (project_board)")
	assert.Contains(t, out, "more comments (list_comments)")
	for _, rule := range briefRules {
		assert.Contains(t, out, rule)
	}
}

func TestRenderProjectBrief_OpenTreeInProgressFirstDoneOmitted(t *testing.T) {
	board := []db.BoardNode{
		briefNode(3, "in_progress", "active feature", briefNode(4, "todo", "open task")),
		briefNode(1, "todo", "later feature"),
		briefNode(2, "done", "shipped feature", briefNode(5, "todo", "leftover task")),
	}
	out := renderProjectBrief(board, briefProject(), nil, nil)

	assert.Contains(t, out, "Targets: 1 in progress, 0 blocked, 3 todo, 1 done.")
	active := strings.Index(out, "#3 [in_progress")
	later := strings.Index(out, "#1 [todo")
	require.NotEqual(t, -1, active)
	require.NotEqual(t, -1, later)
	assert.Less(t, active, later, "in progress first")
	assert.Contains(t, out, "\n  - #4 [todo 0%] open task", "children are indented under their parent")
	assert.NotContains(t, out, "shipped feature", "done is omitted")
	assert.Contains(t, out, "\n- #5 [todo 0%] leftover task", "an open child of a done target stays listed")
	assert.Contains(t, out, "New comments for you: none.")
}

func TestRenderProjectBrief_CommentsTargetsFirstThenDocumentsWithHeadingAndQuote(t *testing.T) {
	board := []db.BoardNode{briefNode(3, "in_progress", "active feature")}
	docs := map[int64]db.ProjectDocument{9: {ID: 9, RelPath: "docs/plan.md"}}
	comments := []db.ProjectComment{
		{ID: 21, DocumentID: sql.NullInt64{Int64: 9, Valid: true}, Author: "owner", Body: "Split task 3",
			AnchorHeading: "Task 3", AnchorQuote: "one big step"},
		{ID: 22, TargetID: sql.NullInt64{Int64: 3, Valid: true}, Author: "owner", Body: "Use the new API"},
	}
	out := renderProjectBrief(board, briefProject(), comments, docs)

	onTarget := strings.Index(out, `comment #22 on target #3 "active feature": Use the new API`)
	onDoc := strings.Index(out, `comment #21 on document #9 docs/plan.md § Task 3 on "one big step": Split task 3`)
	require.NotEqual(t, -1, onTarget, out)
	require.NotEqual(t, -1, onDoc, out)
	assert.Less(t, onTarget, onDoc, "target comments come before document comments")
}

func TestRenderProjectBrief_EmptyProjectAsksForSetup(t *testing.T) {
	p := briefProject()
	p.Description = ""
	out := renderProjectBrief(nil, p, nil, nil)
	assert.Contains(t, out, "Setup pending")
	assert.Contains(t, out, "Open targets: none.")
}

func TestProjectBrief_DeletedProjectPrintsOneLineAndExitsZero(t *testing.T) {
	writeActionsConfig(t)
	out, _, err := runProject(t, "brief", "--project", "5")
	require.NoError(t, err, "a hook never fails the session start")
	assert.Equal(t, "Watchtower: project 5 no longer exists.\n", out)
}

func TestProjectBrief_MissingFolderPrintsOneLine(t *testing.T) {
	database := writeActionsConfig(t)
	folder := filepath.Join(t.TempDir(), "repo")
	require.NoError(t, os.Mkdir(folder, 0o755))
	pid, err := database.CreateProject("acme", folder)
	require.NoError(t, err)
	require.NoError(t, os.RemoveAll(folder))

	out, _, err := runProject(t, "brief", "--project", strconv.FormatInt(pid, 10))
	require.NoError(t, err)
	assert.Equal(t, 1, strings.Count(out, "\n"), out)
	assert.Contains(t, out, "is missing")
	assert.Contains(t, out, folder)
}

func TestProjectBrief_UnreadableConfigPrintsOneLine(t *testing.T) {
	cfgPath := filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, os.WriteFile(cfgPath, []byte("active_workspace: [unclosed\n"), 0o600))
	orig := flagConfig
	flagConfig = cfgPath
	t.Cleanup(func() { flagConfig = orig })

	out, _, err := runProject(t, "brief", "--project", "5")
	require.NoError(t, err)
	assert.Equal(t, 1, strings.Count(out, "\n"), out)
	assert.True(t, strings.HasPrefix(out, "Watchtower: project 5 "), out)
}

func TestProjectBrief_NoProjectFlagPrintsOneLine(t *testing.T) {
	out, _, err := runProject(t, "brief")
	require.NoError(t, err)
	assert.Equal(t, "Watchtower: project 0 is unavailable: no --project id given.\n", out)
}

func TestProjectBrief_RendersBoardFromDB(t *testing.T) {
	database := writeActionsConfig(t)
	pid, err := database.CreateProject("acme", t.TempDir())
	require.NoError(t, err)
	tid, err := database.CreateProjectTarget(pid, sql.NullInt64{}, "Ship the board", "")
	require.NoError(t, err)
	require.NoError(t, database.UpdateTargetStatus(int(tid), "in_progress"))
	cid, err := database.AddProjectComment(db.ProjectComment{ProjectID: pid, TargetID: sql.NullInt64{Int64: tid, Valid: true},
		Author: "owner", Body: "Keep it small"})
	require.NoError(t, err)

	out, _, err := runProject(t, "brief", "--project", strconv.FormatInt(pid, 10))
	require.NoError(t, err)
	assert.Contains(t, out, fmt.Sprintf("#%d [in_progress", tid))
	assert.Contains(t, out, fmt.Sprintf("comment #%d on target #%d", cid, tid))
	assert.Contains(t, out, "Setup pending", "no description yet")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `go test ./cmd -run 'TestRenderProjectBrief|TestProjectBrief'`
Expected: FAIL to compile — `undefined: renderProjectBrief`, `undefined: projectBriefFlagProject`, `undefined: briefRules`.

- [ ] **Step 3: Implement `cmd/project_brief.go`**

```go
package cmd

import (
	"errors"
	"fmt"
	"math"
	"os"
	"sort"
	"strings"
	"unicode/utf8"

	"github.com/spf13/cobra"

	"watchtower/internal/db"
)

const (
	// briefMaxChars caps the SessionStart hook body (runes): Claude Code adds
	// it to every session's context, whatever the board holds.
	briefMaxChars  = 4000
	briefLineChars = 240
)

var briefRules = []string{
	"Board rules: set a target in_progress (update_target) before you work on it and done after; ask the owner with add_comment instead of stopping.",
	"Before revising an attached document call list_comments(document_id); resolve each comment you addressed (resolve_comment), then attach_document again.",
}

var projectBriefCmd = &cobra.Command{
	Use:   "brief",
	Short: "Print a project's brief for Claude Code (the SessionStart hook body)",
	Long: "Prints at most 4000 characters: target counts, the open part of the board with\n" +
		"ids (in progress first, done omitted), comments waiting for the agent, and the\n" +
		"board rules. Always exits 0 — a hook must never break a session start, so any\n" +
		"failure (project gone, folder moved, database unreadable) is one line.",
	// No root schema/config pre-run: a broken config would otherwise fail the
	// hook before RunE could turn it into the one-line brief (the
	// extract-pdf-text precedent). loadProjectBrief loads config itself.
	PersistentPreRunE: func(*cobra.Command, []string) error { return nil },
	RunE:              runProjectBrief,
}

var projectBriefFlagProject int64

func init() {
	projectBriefCmd.Flags().Int64Var(&projectBriefFlagProject, "project", 0, "project id")
	projectCmd.AddCommand(projectBriefCmd)
}

func runProjectBrief(cmd *cobra.Command, _ []string) error {
	fmt.Fprintln(cmd.OutOrStdout(), loadProjectBrief(projectBriefFlagProject))
	return nil
}

func loadProjectBrief(id int64) string {
	if id <= 0 {
		return briefUnavailable(id, "is unavailable: no --project id given")
	}
	_, database, err := openJiraCmdDB()
	if err != nil {
		return briefUnavailable(id, "is unavailable: "+err.Error())
	}
	defer database.Close()
	p, err := database.GetProject(id)
	if errors.Is(err, db.ErrProjectNotFound) {
		return briefUnavailable(id, "no longer exists")
	}
	if err != nil {
		return briefUnavailable(id, "is unavailable: "+err.Error())
	}
	if _, err := os.Stat(p.FolderPath); err != nil {
		return briefUnavailable(id, fmt.Sprintf("folder %s is missing (moved or deleted?)", p.FolderPath))
	}
	return briefFromDB(database, p)
}

func briefFromDB(database *db.DB, p *db.Project) string {
	board, err := database.GetProjectBoard(p.ID)
	if err != nil {
		return briefUnavailable(p.ID, "is unavailable: "+err.Error())
	}
	comments, err := database.ListProjectComments(db.ProjectCommentFilter{ProjectID: p.ID, NewForAgent: true})
	if err != nil {
		return briefUnavailable(p.ID, "is unavailable: "+err.Error())
	}
	docs, err := database.ListProjectDocuments(p.ID)
	if err != nil {
		return briefUnavailable(p.ID, "is unavailable: "+err.Error())
	}
	byID := make(map[int64]db.ProjectDocument, len(docs))
	for _, d := range docs {
		byID[d.ID] = d
	}
	return renderProjectBrief(board, p, comments, byID)
}

// briefUnavailable is the one-line brief for every failure.
func briefUnavailable(id int64, reason string) string {
	return briefClip(fmt.Sprintf("Watchtower: project %d %s.", id, reason), briefLineChars)
}

// renderProjectBrief is the hook body: header, the open tree, the comments new
// for the agent, the rules — at most briefMaxChars runes. Pure.
func renderProjectBrief(board []db.BoardNode, p *db.Project, comments []db.ProjectComment, docs map[int64]db.ProjectDocument) string {
	head := briefHeader(p, board, len(comments))
	rules := strings.Join(briefRules, "\n")
	budget := briefMaxChars - utf8.RuneCountInString(head) - utf8.RuneCountInString(rules) - 3 // three joining newlines
	commentLines := briefCommentLines(comments, docs, boardTitles(board))
	treeBudget := budget
	if len(commentLines) > 0 {
		treeBudget = budget / 2
	}
	tree := fitBriefSection("Open targets:", briefTargetLines(board), treeBudget, "targets (project_board)")
	section := fitBriefSection("New comments for you:", commentLines, budget-utf8.RuneCountInString(tree), "comments (list_comments)")
	return strings.Join([]string{head, tree, section, rules}, "\n")
}

func briefHeader(p *db.Project, board []db.BoardNode, newComments int) string {
	c := countBoardStatuses(board)
	lines := []string{
		briefClip(fmt.Sprintf("Watchtower project #%d %q — %s", p.ID, p.Name, p.FolderPath), briefLineChars),
		fmt.Sprintf("Targets: %d in progress, %d blocked, %d todo, %d done. New comments for you: %d.",
			c["in_progress"], c["blocked"], c["todo"], c["done"], newComments),
	}
	if strings.TrimSpace(p.Description) == "" {
		lines = append(lines, "Setup pending: run the watchtower-project skill's setup (project_info, update_project, first board).")
	}
	return strings.Join(lines, "\n")
}

// fitBriefSection writes title and as many lines as fit in limit runes; the
// rest becomes one "… N more <what>" line. Each written line reserved room
// for a marker at least as long as any later one, so the marker always fits.
func fitBriefSection(title string, lines []string, limit int, what string) string {
	if len(lines) == 0 {
		return title + " none."
	}
	var b strings.Builder
	b.WriteString(title)
	used := utf8.RuneCountInString(title)
	for i, line := range lines {
		more := fmt.Sprintf("\n… %d more %s", len(lines)-i, what)
		reserve := 0
		if i < len(lines)-1 {
			reserve = utf8.RuneCountInString(more)
		}
		need := 1 + utf8.RuneCountInString(line)
		if used+need+reserve > limit {
			b.WriteString(more)
			return b.String()
		}
		b.WriteString("\n")
		b.WriteString(line)
		used += need
	}
	return b.String()
}

func briefClosed(status string) bool { return status == "done" || status == "dismissed" }

// briefTargetLines lists the open targets depth-first in board order. A
// closed target is omitted; its open children stay, at its depth.
func briefTargetLines(board []db.BoardNode) []string {
	var lines []string
	var walk func([]db.BoardNode, int)
	walk = func(level []db.BoardNode, depth int) {
		for _, n := range level {
			if briefClosed(n.Target.Status) {
				walk(n.Children, depth)
				continue
			}
			lines = append(lines, briefTargetLine(n, depth))
			walk(n.Children, depth+1)
		}
	}
	walk(board, 0)
	return lines
}

func briefTargetLine(n db.BoardNode, depth int) string {
	indent := strings.Repeat("  ", min(depth, 4))
	t := n.Target
	line := fmt.Sprintf("- #%d [%s %d%%] %s", t.ID, t.Status, int(math.Round(t.Progress*100)), t.Text)
	if n.NewForAgent > 0 {
		line += fmt.Sprintf(" (%d new comments)", n.NewForAgent)
	}
	if len(n.Documents) > 0 {
		line += fmt.Sprintf(" (%d docs)", len(n.Documents))
	}
	return indent + briefClip(line, briefLineChars-len(indent))
}

func boardTitles(board []db.BoardNode) map[int64]string {
	titles := map[int64]string{}
	var walk func([]db.BoardNode)
	walk = func(level []db.BoardNode) {
		for _, n := range level {
			titles[int64(n.Target.ID)] = n.Target.Text
			walk(n.Children)
		}
	}
	walk(board)
	return titles
}

// briefCommentLines renders target comments first, then document comments.
func briefCommentLines(comments []db.ProjectComment, docs map[int64]db.ProjectDocument, titles map[int64]string) []string {
	ordered := append([]db.ProjectComment(nil), comments...)
	sort.SliceStable(ordered, func(i, j int) bool {
		return !ordered[i].DocumentID.Valid && ordered[j].DocumentID.Valid
	})
	lines := make([]string, 0, len(ordered))
	for _, c := range ordered {
		lines = append(lines, briefClip(briefCommentLine(c, docs, titles), briefLineChars))
	}
	return lines
}

func briefCommentLine(c db.ProjectComment, docs map[int64]db.ProjectDocument, titles map[int64]string) string {
	who := fmt.Sprintf("- comment #%d", c.ID)
	if c.ParentID.Valid {
		who += fmt.Sprintf(" (reply in thread #%d)", c.ParentID.Int64)
	}
	body := briefClip(c.Body, 160)
	if !c.DocumentID.Valid {
		return fmt.Sprintf("%s on target #%d %q: %s", who, c.TargetID.Int64, briefClip(titles[c.TargetID.Int64], 60), body)
	}
	where := docs[c.DocumentID.Int64].RelPath
	if c.AnchorHeading != "" {
		where += " § " + briefClip(c.AnchorHeading, 60)
	}
	if c.AnchorQuote != "" {
		where += fmt.Sprintf(" on %q", briefClip(c.AnchorQuote, 80))
	}
	return fmt.Sprintf("%s on document #%d %s: %s", who, c.DocumentID.Int64, where, body)
}

// briefClip collapses whitespace to single spaces and cuts s to n runes.
func briefClip(s string, n int) string {
	s = strings.Join(strings.Fields(s), " ")
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	r := []rune(s)
	return string(r[:n-1]) + "…"
}
```

- [ ] **Step 4: Run the tests**

Run: `go test ./cmd -run 'TestRenderProjectBrief|TestProjectBrief|TestProject_'`
Expected: PASS.

- [ ] **Step 5: Lint**

Run: `make lint-diff`
Expected: no new issues.

- [ ] **Step 6: Commit**

```bash
git add cmd/project_brief.go cmd/project_brief_test.go cmd/project_test.go
git commit -m "feat(project): project brief — the bounded SessionStart hook body" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Lo9jbbmXQcr3qHo5f3pLD8"
```

---

## Phase gate (controller, once)

Run `bash scripts/dev-health.sh` first, then: `make test`, `make test-swift`, `make lint-all`. A failing `goose.DownTo` test anywhere means the 00081 Down is wrong — fix the SQL, never the test.

## Interface errata

1. **`CreateProjectTargetsTx`** — the index's `CreateProjectTargetsTx(tx *sql.Tx, …)` is concretized as
   `func (db *DB) CreateProjectTargetsTx(tx *sql.Tx, projectID int64, items []ProjectTargetInput) ([]int64, error)`
   with the new type `type ProjectTargetInput struct{ Title, Intent string; ParentID sql.NullInt64; BatchParent int }` (`BatchParent`: 1-based index of an earlier item of the same batch, 0 = none; mutually exclusive with `ParentID`). Task 7's `create_targets` maps each `parent_key` onto `BatchParent` and `parent_id` onto `ParentID`, and runs the call inside `db.WithTx`.
2. **`WithTx` is produced by Task 2**, not Task 3 (document upserts and comment placement need it); signature unchanged: `func (db *DB) WithTx(fn func(*sql.Tx) error) error`.
3. **New sentinel `db.ErrNotInProject`** (Task 2) — returned (wrapped) for any target, document, source or comment that belongs to another project or to none. Task 7's `targetInProject` should return it wrapped, so tools can match it with `errors.Is`.
4. **New sentinel `targets.ErrProjectTarget`** (Task 3) — `GenerateNextStep` returns it for a project target.
5. **`BoardNode.Target` is the existing `db.Target`, whose `ID` is `int`** (not `int64`); compare with `sql.NullInt64` values via `int64(t.ID)`. `GetProjectBoard` does not verify the project exists — an unknown id returns an empty board; callers call `GetProject` first.
6. **New file `internal/db/project_targets.go`** (not in the index's file map) holds `ProjectTargetInput`, `CreateProjectTarget`, `CreateProjectTargetsTx`. `internal/targets/pipeline.go` needs no edit (its snapshots use the excluding `GetTargets` default).
7. **`cmd.countBoardStatuses(nodes []db.BoardNode) map[string]int`** (Task 4) is shared with the brief; the `project brief` failure lines are `Watchtower: project N no longer exists.`, `Watchtower: project N folder <path> is missing (moved or deleted?).`, `Watchtower: project N is unavailable: <reason>.` — Task 9's tool error text (`project N no longer exists`) matches the first.
