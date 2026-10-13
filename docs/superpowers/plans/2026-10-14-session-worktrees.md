# Session Worktrees Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A second (and every further) concurrent agent session of a workbench starts in its own git worktree, prepared from `.worktreeinclude` and an optional setup command, and a clean worktree is removed when the session ends.

**Architecture:** Go owns every git and install write: `internal/workbenchgit/worktree*.go` (create, include, remove, ensure) behind `watchtower workbench worktree create|ensure|remove --json`, which also installs the workbench integration into the worktree through `devpack`. The Desktop decides placement with a pure `SessionPlacement.decide` (WatchtowerCore), calls the CLI before inserting the session row, stores the worktree on the row (migration 00110), runs cleanup when a finished worktree session's agent exits or its row is deleted, and shows a badge and menu items.

**Tech Stack:** Go 1.25 (cobra, `database/sql` + modernc SQLite, goose migrations, `golang.org/x/sys/unix` for `clonefile`), SwiftUI + GRDB (WatchtowerCore / WatchtowerDesktop).

**Spec:** `docs/superpowers/specs/2026-10-14-session-worktrees-design.md` (approved in ask #115). Board target #229.

## Global Constraints

- Worktree path: `<top_level>/.claude/worktrees/<slug>`; branch `wt/<slug>`; slug ASCII, ≤ 40 characters, suffix `-2`, `-3`, … when the branch or path exists.
- Base = the main folder's `HEAD` commit (`git worktree add -b wt/<slug> <path> HEAD`).
- Exclude line `/.claude/worktrees/` appended once to `<common_dir>/info/exclude`.
- `.worktreeinclude`: `.gitignore` syntax at the repository root; a path is copied only if it matches **and** is ignored; `clonefile(2)`; non-clone fallback copies at most 1 GiB in total.
- Never: `worktree remove --force`, `branch -D`, `reset`, `clean`, `checkout --`, `stash`. Branch deletion only `git branch -d` of a `wt/…` branch with zero commits beyond its base.
- A worktree with any `git status --porcelain` entry (ignored files excluded) or an operation in progress is kept.
- CLI: every git outcome is an exit-0 JSON envelope; non-zero only when the workbench/folder does not resolve. Write budget 60 s.
- Migration `00110_terminal_session_worktrees.sql`: `terminal_sessions.worktree_branch TEXT`, `terminal_sessions.worktree_base TEXT`, `terminal_sessions.worktree_state TEXT CHECK (worktree_state IN ('kept'))`, `terminal_sessions.worktree_removed_at TEXT`, `projects.worktree_setup TEXT NOT NULL DEFAULT ''`.
- Inner loop only per task (`go test ./internal/<pkg>`, `make test-swift FILTER=…`, `make lint-diff`); the full gate runs once at the end (CLAUDE.md).
- Tests that spawn processes reap them; git tests use `helpers_test.go`'s `gitBin`/`newRepo` (owner's git config isolated).
- Docs and code comments in English; no live-install data in the repo.

## Spec deviation found while planning

- **Spec §11 PROJ-14 needs no code change.** `internal/sessionreport` checks `branch:<name>` and `pr:` refs, which resolve repository-wide (`gh pr list --head <branch>`, `BranchMerge`), so the main folder sees `wt/…` branches. Task 9 pins this with a test instead of changing the folder.

## Review Focus

1. **The workbench folder is a subfolder of the repository** → the session must start in `<worktree>/<prefix>`, and `.worktreeinclude` is read from the repository root, not the workbench folder. (Task 2 test `TestWorktreeCreate_SubfolderWorkbench`.)
2. **The main folder has uncommitted changes** → the new worktree does not have them, and the envelope says `base_dirty: true` so the Desktop can say so. (Task 2 test `TestWorktreeCreate_BaseDirty`, Task 10 note.)
3. **The worktree directory was deleted by hand while the row remains** → resume recreates it from the branch through `ensure`; with the branch gone too, the row is unavailable with a clear message, never a crash or a silent start in the main folder. (Task 4 tests, Task 10 resume test.)
4. **Removing a worktree must not drop exclude lines the main folder still needs** → worktree removal only unregisters the MCP entry; it never calls `devpack.RemoveWorkbench` (which drops `info/exclude` lines whose paths are gone — and `info/exclude` is shared by every worktree). (Task 5 test `TestWorktreeRemove_KeepsSharedExcludeLines`.)
5. **Two sessions start at the same moment in an idle folder** → both see the folder free and both start in it. The Desktop serialises placement per workbench (one decision in flight), so the second sees the first's row as live. (Task 10 test `testConcurrentStartsSecondGetsWorktree`.)

---

### Task 1: Migration 00110 and the Go/Swift row fields

**Files:**
- Create: `internal/db/migrations/00110_terminal_session_worktrees.sql`
- Modify: `internal/db/schema.sql` (the `terminal_sessions` and `projects` tables)
- Modify: `internal/db/terminal_sessions.go` (struct `TerminalSession`, its scan; new `SessionWorktrees`)
- Test: `internal/db/terminal_sessions_worktree_test.go`
- Regenerate: schema golden + `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Models/TerminalSession.swift`, `.../Models/Workbench.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/TerminalSessionQueries.swift` (`NewSession`, `create`, new `setWorktreeState`), `.../Queries/WorkbenchQueries.swift` (new `setWorktreeSetup`)
- Test: `WatchtowerDesktop/Tests/Core/TerminalSessionWorktreeQueriesTests.swift`

**Interfaces:**
- Produces (Go): `TerminalSession.WorktreeBranch sql.NullString`; `func (db *DB) SessionWorktrees(workbenchID int64) ([]SessionWorktree, error)` with `type SessionWorktree struct{ ID int64; FolderPath, Branch, Base string }` — rows with `worktree_branch IS NOT NULL AND worktree_removed_at IS NULL`.
- Produces (Swift): `TerminalSession.worktreeBranch: String?`, `.worktreeBase: String?`, `.worktreeKept: Bool` (`worktree_state == "kept"`), `.worktreeRemovedAt: String?`; `NewSession.worktreeBranch: String?`, `NewSession.worktreeBase: String?`; `TerminalSessionQueries.setWorktreeState(_ db:, id:, kept: Bool, removedAt: String?)`; `Workbench.worktreeSetup: String`; `WorkbenchQueries.setWorktreeSetup(_ db:, projectID:, command:)`.

- [ ] **Step 1: Write the migration**

```sql
-- +goose Up
-- Session worktrees (spec 2026-10-14-session-worktrees-design.md §7).
-- worktree_branch non-NULL = the row owns the worktree its folder_path is in.
ALTER TABLE terminal_sessions ADD COLUMN worktree_branch TEXT;
-- The commit the branch was cut from (for the empty-branch check, §9).
ALTER TABLE terminal_sessions ADD COLUMN worktree_base TEXT;
-- 'kept' = the agent ended but the worktree had uncommitted changes.
ALTER TABLE terminal_sessions ADD COLUMN worktree_state TEXT CHECK (worktree_state IN ('kept'));
-- When Watchtower removed the worktree (the branch stays); NULL = on disk.
ALTER TABLE terminal_sessions ADD COLUMN worktree_removed_at TEXT;
-- The command run in a new worktree before the agent's first launch; '' = none.
ALTER TABLE projects ADD COLUMN worktree_setup TEXT NOT NULL DEFAULT '';

-- +goose Down
ALTER TABLE projects DROP COLUMN worktree_setup;
ALTER TABLE terminal_sessions DROP COLUMN worktree_removed_at;
ALTER TABLE terminal_sessions DROP COLUMN worktree_state;
ALTER TABLE terminal_sessions DROP COLUMN worktree_base;
ALTER TABLE terminal_sessions DROP COLUMN worktree_branch;
```

Mirror the five columns, with the same comments, into `internal/db/schema.sql` (end of each table's column list, before the `CHECK` lines of `terminal_sessions`).

- [ ] **Step 2: Write the failing Go test**

```go
package db

func TestSessionWorktrees_ListsLiveWorktreeRowsOnly(t *testing.T) {
	d := openTestDB(t)
	wb := createTestWorkbench(t, d, t.TempDir())
	plain := insertTerminalSession(t, d, wb.ID, "/repo")
	wt := insertTerminalSession(t, d, wb.ID, "/repo/.claude/worktrees/a")
	gone := insertTerminalSession(t, d, wb.ID, "/repo/.claude/worktrees/b")
	_, err := d.Exec(`UPDATE terminal_sessions SET worktree_branch = 'wt/a', worktree_base = 'abc' WHERE id = ?`, wt)
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE terminal_sessions SET worktree_branch = 'wt/b', worktree_removed_at = '2026-10-14T00:00:00Z' WHERE id = ?`, gone)
	require.NoError(t, err)

	got, err := d.SessionWorktrees(wb.ID)
	require.NoError(t, err)
	assert.Equal(t, []SessionWorktree{{ID: wt, FolderPath: "/repo/.claude/worktrees/a", Branch: "wt/a", Base: "abc"}}, got)
	_ = plain
}
```

Use the helpers `terminal_sessions_test.go` already has; if `insertTerminalSession` does not exist under that name, use the existing insert helper of that file (read it first) — do not add a second one.

- [ ] **Step 3: Run it to see it fail**

Run: `go test ./internal/db -run TestSessionWorktrees`
Expected: FAIL — `d.SessionWorktrees undefined`.

- [ ] **Step 4: Implement**

In `internal/db/terminal_sessions.go` add `WorktreeBranch sql.NullString` to `TerminalSession`, extend the `SELECT` column list and `Scan` in `GetTerminalSession` with `worktree_branch`, and add:

```go
// SessionWorktree is a session row that owns a worktree still on disk.
type SessionWorktree struct {
	ID         int64
	FolderPath string
	Branch     string
	Base       string // "" when not recorded
}

// SessionWorktrees lists the workbench's session rows whose worktree
// Watchtower has not removed (spec §9: workbench deletion cleans them).
func (db *DB) SessionWorktrees(workbenchID int64) ([]SessionWorktree, error) {
	rows, err := db.Query(`SELECT id, folder_path, worktree_branch, COALESCE(worktree_base, '') FROM terminal_sessions
		WHERE project_id = ? AND worktree_branch IS NOT NULL AND worktree_removed_at IS NULL
		ORDER BY id`, workbenchID)
	if err != nil {
		return nil, fmt.Errorf("listing session worktrees: %w", err)
	}
	defer rows.Close()
	var out []SessionWorktree
	for rows.Next() {
		var s SessionWorktree
		if err := rows.Scan(&s.ID, &s.FolderPath, &s.Branch, &s.Base); err != nil {
			return nil, fmt.Errorf("listing session worktrees: %w", err)
		}
		out = append(out, s)
	}
	return out, rows.Err()
}
```

- [ ] **Step 5: Regenerate and run**

Run: `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update && go test ./internal/db`
Expected: PASS.

- [ ] **Step 6: Swift model and queries (failing test first)**

`WatchtowerDesktop/Tests/Core/TerminalSessionWorktreeQueriesTests.swift`:

```swift
import GRDB
import XCTest
@testable import WatchtowerCore

final class TerminalSessionWorktreeQueriesTests: XCTestCase {
    func testCreateStoresWorktreeAndStateRoundTrips() throws {
        let db = try TestDatabase.make()
        let projectID = try TestDatabase.insertWorkbench(db, folder: "/repo")
        let row = try db.write { db in
            try TerminalSessionQueries.create(db, .init(
                projectID: projectID, kind: .claude, title: "t", folderPath: "/repo/.claude/worktrees/a",
                claudeSessionID: "s", worktreeBranch: "wt/a", worktreeBase: "abc1234"))
        }
        XCTAssertEqual(row.worktreeBranch, "wt/a")
        XCTAssertEqual(row.worktreeBase, "abc1234")
        XCTAssertFalse(row.worktreeKept)
        try db.write { try TerminalSessionQueries.setWorktreeState($0, id: row.id, kept: true, removedAt: nil) }
        XCTAssertTrue(try db.read { try TerminalSessionQueries.fetch($0, id: row.id) }!.worktreeKept)
        try db.write { try TerminalSessionQueries.setWorktreeState($0, id: row.id, kept: false, removedAt: "2026-10-14T00:00:00Z") }
        let removed = try db.read { try TerminalSessionQueries.fetch($0, id: row.id) }!
        XCTAssertFalse(removed.worktreeKept)
        XCTAssertEqual(removed.worktreeRemovedAt, "2026-10-14T00:00:00Z")
    }

    func testWorktreeSetupRoundTrips() throws {
        let db = try TestDatabase.make()
        let projectID = try TestDatabase.insertWorkbench(db, folder: "/repo")
        try db.write { try WorkbenchQueries.setWorktreeSetup($0, projectID: projectID, command: "npm install") }
        XCTAssertEqual(try db.read { try WorkbenchQueries.fetch($0, id: projectID) }?.worktreeSetup, "npm install")
    }
}
```

Use the existing `TestDatabase` helpers (read `WatchtowerDesktop/Tests/Support/` first; use the names that exist).

Run: `make test-swift FILTER=TerminalSessionWorktreeQueriesTests` → FAIL (no such members).

Implement: decode the four columns in `TerminalSession` (`row["worktree_branch"]`, …; `worktreeKept = (row["worktree_state"] as String?) == "kept"`); add `worktreeBranch`/`worktreeBase` (default nil) to `NewSession.init` and to the `INSERT` column list; add

```swift
package static func setWorktreeState(_ db: Database, id: Int64, kept: Bool, removedAt: String?) throws {
    try db.execute(
        sql: "UPDATE terminal_sessions SET worktree_state = ?, worktree_removed_at = COALESCE(?, worktree_removed_at) WHERE id = ?",
        arguments: [kept ? "kept" : nil, removedAt, id]
    )
}
```

`Workbench.worktreeSetup = row["worktree_setup"] ?? ""`; `WorkbenchQueries.setWorktreeSetup` mirrors `setArchiveAfterDays` (`UPDATE projects SET worktree_setup = ? WHERE id = ?`, trimmed).

Run: `make test-swift FILTER=TerminalSessionWorktreeQueriesTests` → PASS.

- [ ] **Step 7: Commit**

```bash
git add internal/db WatchtowerDesktop/Sources/WatchtowerCore WatchtowerDesktop/Tests
git commit -m "feat(db): session worktree columns (migration 00110)"
```

---

### Task 2: `workbenchgit.CreateWorktree`

**Depends on:** none.

**Files:**
- Create: `internal/workbenchgit/worktree.go`
- Test: `internal/workbenchgit/worktree_test.go`

**Interfaces:**
- Consumes: `open`, `repo.git`, `repo.locatePaths`, `gitError`, `clip`, `readStatus`, the `Refused*` constants (`run.go`, `status.go`, `switch.go`).
- Produces:

```go
const RefusedUnborn = "unborn"

type WorktreeRequest struct {
	Slug string // already ASCII-folded by the caller; validated here
}

type WorktreeResult struct {
	WorkbenchID     int64    `json:"workbench_id"`
	Created         bool     `json:"created"`
	Path            string   `json:"path"`   // the worktree's top level
	Cwd             string   `json:"cwd"`    // Path + the workbench folder's prefix
	Branch          string   `json:"branch"` // wt/<slug>
	Base            string   `json:"base"`   // full commit id
	BaseBranch      string   `json:"base_branch"` // "" when detached
	BaseDirty       bool     `json:"base_dirty"`
	Included        []string `json:"included"`
	IncludeWarnings []string `json:"include_warnings"`
	Refused         string   `json:"refused"`
	RefusedDetail   string   `json:"refused_detail"`
	Error           string   `json:"error"`
	Warning         string   `json:"warning"`
}

func CreateWorktree(ctx context.Context, o Options, req WorktreeRequest) WorktreeResult
```

`Included`/`IncludeWarnings` are filled by Task 3 (`includeInto`); in this task `CreateWorktree` calls a stub `includeInto(ctx, r, p, path) ([]string, []string)` that returns nil, nil, defined in `worktree_include.go` so Task 3 replaces only that file.

- [ ] **Step 1: Write the failing tests**

```go
func TestWorktreeCreate_CutsBranchFromHEAD(t *testing.T) {
	dir := newRepo(t)
	res := CreateWorktree(context.Background(), options(dir, &recorder{}), WorktreeRequest{Slug: "229-worktrees"})
	require.True(t, res.Created, "%+v", res)
	assert.Equal(t, "wt/229-worktrees", res.Branch)
	assert.Equal(t, filepath.Join(dir, ".claude", "worktrees", "229-worktrees"), res.Path)
	assert.Equal(t, res.Path, res.Cwd)
	assert.Equal(t, gitIn(t, dir, "rev-parse", "HEAD"), res.Base)
	assert.Equal(t, "main", res.BaseBranch)
	assert.Equal(t, "wt/229-worktrees", gitIn(t, res.Path, "branch", "--show-current"))
	assert.Empty(t, gitIn(t, dir, "status", "--porcelain"), "the worktree never shows in the main folder")
}

func TestWorktreeCreate_SuffixesTakenNames(t *testing.T) {
	dir := newRepo(t)
	gitIn(t, dir, "branch", "wt/x")
	o := options(dir, &recorder{})
	first := CreateWorktree(context.Background(), o, WorktreeRequest{Slug: "x"})
	second := CreateWorktree(context.Background(), o, WorktreeRequest{Slug: "x"})
	assert.Equal(t, "wt/x-2", first.Branch)
	assert.Equal(t, "wt/x-3", second.Branch)
}

func TestWorktreeCreate_ExcludeLineAddedOnce(t *testing.T) {
	dir := newRepo(t)
	o := options(dir, &recorder{})
	CreateWorktree(context.Background(), o, WorktreeRequest{Slug: "a"})
	CreateWorktree(context.Background(), o, WorktreeRequest{Slug: "b"})
	ex := readFile(t, filepath.Join(dir, ".git", "info"), "exclude")
	assert.Equal(t, 1, strings.Count(ex, "/.claude/worktrees/\n"))
}

func TestWorktreeCreate_SubfolderWorkbench(t *testing.T) {
	dir := newRepo(t)
	require.NoError(t, os.MkdirAll(filepath.Join(dir, "app", "web"), 0o755))
	commit(t, filepath.Join(dir, "app", "web"), "index.js", "x\n", "web")
	res := CreateWorktree(context.Background(), options(filepath.Join(dir, "app", "web"), &recorder{}), WorktreeRequest{Slug: "s"})
	require.True(t, res.Created, "%+v", res)
	assert.Equal(t, filepath.Join(dir, ".claude", "worktrees", "s"), res.Path, "the worktree is the whole repository")
	assert.Equal(t, filepath.Join(res.Path, "app", "web"), res.Cwd)
}

func TestWorktreeCreate_BaseDirty(t *testing.T) {
	dir := newRepo(t)
	writeFile(t, dir, "README.md", "edited\n")
	res := CreateWorktree(context.Background(), options(dir, &recorder{}), WorktreeRequest{Slug: "d"})
	require.True(t, res.Created)
	assert.True(t, res.BaseDirty)
	assert.Equal(t, "hello\n", readFile(t, res.Path, "README.md"), "uncommitted changes stay in the main folder")
}

func TestWorktreeCreate_DetachedHEAD(t *testing.T) {
	dir := newRepo(t)
	gitIn(t, dir, "switch", "-q", "--detach", "feature")
	res := CreateWorktree(context.Background(), options(dir, &recorder{}), WorktreeRequest{Slug: "det"})
	require.True(t, res.Created, "%+v", res)
	assert.Empty(t, res.BaseBranch)
	assert.Equal(t, gitIn(t, dir, "rev-parse", "feature"), res.Base)
}

func TestWorktreeCreate_Refusals(t *testing.T) {
	plain := t.TempDir()
	assert.Equal(t, RefusedNotGit, CreateWorktree(context.Background(), Options{Folder: plain}, WorktreeRequest{Slug: "a"}).Refused)
	noGit := Options{Folder: newRepo(t), Locate: func() (string, bool) { return "", false }}
	assert.Equal(t, RefusedGitUnavailable, CreateWorktree(context.Background(), noGit, WorktreeRequest{Slug: "a"}).Refused)
	unborn, _ := filepath.EvalSymlinks(t.TempDir())
	gitIn(t, unborn, "init", "-q", "-b", "main")
	assert.Equal(t, RefusedUnborn, CreateWorktree(context.Background(), Options{Folder: unborn}, WorktreeRequest{Slug: "a"}).Refused)
	assert.Equal(t, RefusedInvalidName, CreateWorktree(context.Background(), Options{Folder: newRepo(t)}, WorktreeRequest{Slug: "../x"}).Refused)
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `go test ./internal/workbenchgit -run TestWorktreeCreate`
Expected: FAIL — `undefined: CreateWorktree`.

- [ ] **Step 3: Implement `worktree.go`**

```go
package workbenchgit

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// RefusedUnborn: the repository has no commit to cut a worktree branch from.
const RefusedUnborn = "unborn"

// worktreesDir is where session worktrees live, relative to the top level;
// worktreeExcludeLine keeps them out of the main folder's git status.
const (
	worktreesDir        = ".claude/worktrees"
	worktreeExcludeLine = "/.claude/worktrees/"
	worktreeBranchRoot  = "wt/"
	maxSlug             = 40
)

var slugPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9-]*$`)

// WorktreeRequest is one `workbench worktree create`.
type WorktreeRequest struct {
	Slug string
}

// WorktreeResult is the `workbench worktree create` and `ensure` envelope.
type WorktreeResult struct {
	WorkbenchID     int64    `json:"workbench_id"`
	Created         bool     `json:"created"`
	Path            string   `json:"path"`
	Cwd             string   `json:"cwd"`
	Branch          string   `json:"branch"`
	Base            string   `json:"base"`
	BaseBranch      string   `json:"base_branch"`
	BaseDirty       bool     `json:"base_dirty"`
	Included        []string `json:"included"`
	IncludeWarnings []string `json:"include_warnings"`
	Refused         string   `json:"refused"`
	RefusedDetail   string   `json:"refused_detail"`
	Error           string   `json:"error"`
	Warning         string   `json:"warning"`
}

// CreateWorktree checks out a new branch wt/<slug> from the folder's HEAD
// in <top level>/.claude/worktrees/<slug> (a taken name gets -2, -3, …),
// keeps that directory out of the main folder's status, and copies the
// .worktreeinclude paths into it. A failure after the worktree exists is a
// Warning: the worktree is returned and usable (spec §5).
func CreateWorktree(ctx context.Context, o Options, req WorktreeRequest) (res WorktreeResult) {
	res = WorktreeResult{Included: []string{}, IncludeWarnings: []string{}}
	if !slugPattern.MatchString(req.Slug) || len(req.Slug) > maxSlug {
		res.Refused, res.RefusedDetail = RefusedInvalidName, "a slug is lowercase letters, digits and dashes, at most 40"
		return res
	}
	st, r := readStatus(ctx, o)
	switch {
	case !st.GitAvailable:
		res.Refused = RefusedGitUnavailable
		return res
	case r == nil:
		res.Refused = RefusedNotGit
		return res
	case !st.StatusOK:
		res.Refused, res.Error = RefusedGitFailed, st.StatusError
		return res
	case st.Unborn:
		res.Refused = RefusedUnborn
		return res
	}
	p := paths{topLevel: st.TopLevel, gitDir: st.GitDir, commonDir: st.CommonDir}
	base, err := r.git(ctx, "rev-parse", "--verify", "HEAD^{commit}")
	if err != nil {
		res.Refused, res.Error = RefusedGitFailed, gitError(err)
		return res
	}
	prefix, err := r.git(ctx, "rev-parse", "--show-prefix")
	if err != nil {
		res.Refused, res.Error = RefusedGitFailed, gitError(err)
		return res
	}
	res.Base, res.BaseBranch, res.BaseDirty = strings.TrimSpace(string(base)), st.Branch, st.Dirty
	slug, err := r.freeSlug(ctx, p.topLevel, req.Slug)
	if err != nil {
		res.Refused, res.Error = RefusedGitFailed, gitError(err)
		return res
	}
	res.Branch = worktreeBranchRoot + slug
	res.Path = filepath.Join(p.topLevel, filepath.FromSlash(worktreesDir), slug)
	if err := ensureExcludeLine(p.commonDir, worktreeExcludeLine); err != nil {
		res.Warning = clip("adding the exclude line: " + err.Error())
	}
	if _, err := r.git(ctx, "worktree", "add", "-b", res.Branch, res.Path, res.Base); err != nil {
		res.Error = gitError(err)
		return res
	}
	res.Created = true
	res.Cwd = filepath.Join(res.Path, filepath.FromSlash(strings.TrimSuffix(strings.TrimSpace(string(prefix)), "/")))
	res.Included, res.IncludeWarnings = includeInto(ctx, r, p, res.Path)
	return res
}

// freeSlug is slug, or slug-2, slug-3, … — the first whose branch and
// directory are both free.
func (r *repo) freeSlug(ctx context.Context, top, slug string) (string, error) {
	for n := 1; n < 1000; n++ {
		cand := slug
		if n > 1 {
			cand = fmt.Sprintf("%s-%d", slug, n)
		}
		_, code, err := r.run(ctx, "show-ref", "--verify", "--quiet", "refs/heads/"+worktreeBranchRoot+cand)
		if err != nil && code != 1 {
			return "", err
		}
		if code == 0 {
			continue
		}
		if _, statErr := os.Lstat(filepath.Join(top, filepath.FromSlash(worktreesDir), cand)); statErr == nil {
			continue
		}
		return cand, nil
	}
	return "", fmt.Errorf("no free name for %s", slug)
}

// ensureExcludeLine appends line to <commonDir>/info/exclude unless a line
// equal to it is already there; the owner's lines are never rewritten.
func ensureExcludeLine(commonDir, line string) error {
	file := filepath.Join(commonDir, "info", "exclude")
	raw, err := os.ReadFile(file)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	for _, l := range strings.Split(string(raw), "\n") {
		if strings.TrimSpace(l) == line {
			return nil
		}
	}
	if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
		return err
	}
	f, err := os.OpenFile(file, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	prefix := ""
	if len(raw) > 0 && !strings.HasSuffix(string(raw), "\n") {
		prefix = "\n"
	}
	_, err = f.WriteString(prefix + "# watchtower: session worktrees\n" + line + "\n")
	return err
}
```

Note on `show-ref` exit codes: the `recorder`/`execRunner` returns `code 1` with a `runError` for "not found" — treat `code == 1` as free (as written).

Create `internal/workbenchgit/worktree_include.go` with the stub:

```go
package workbenchgit

import "context"

// includeInto copies the .worktreeinclude paths into the new worktree
// (spec §6); filled in by the include task.
func includeInto(ctx context.Context, r *repo, p paths, dest string) (included, warnings []string) {
	return []string{}, []string{}
}
```

- [ ] **Step 4: Run the tests**

Run: `go test ./internal/workbenchgit -run TestWorktreeCreate`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/workbenchgit/worktree.go internal/workbenchgit/worktree_include.go internal/workbenchgit/worktree_test.go
git commit -m "feat(workbenchgit): create a session worktree on wt/<slug>"
```

---

### Task 3: `.worktreeinclude` — list and clone

**Depends on:** Task 2.

**Files:**
- Modify: `internal/workbenchgit/worktree_include.go`
- Create: `internal/workbenchgit/clone_darwin.go`, `internal/workbenchgit/clone_other.go`
- Test: `internal/workbenchgit/worktree_include_test.go`

**Interfaces:**
- Consumes: `repo`, `paths` (Task 2).
- Produces: `includeInto(ctx, r, p, dest) (included, warnings []string)`; package var `cloneFile func(src, dst string) error` (tests swap it); const `copyFallbackLimit int64 = 1 << 30`.

- [ ] **Step 1: Write the failing tests**

```go
func includeRepo(t *testing.T) string {
	dir := newRepo(t)
	commit(t, dir, ".gitignore", ".env\nnode_modules/\nbuild/\nsecret.txt\n", "ignore")
	commit(t, dir, ".worktreeinclude", ".env\nnode_modules/\nREADME.md\n", "include")
	writeFile(t, dir, ".env", "KEY=1\n")
	writeFile(t, dir, "secret.txt", "not listed\n")
	require.NoError(t, os.MkdirAll(filepath.Join(dir, "node_modules", "pkg"), 0o755))
	writeFile(t, filepath.Join(dir, "node_modules", "pkg"), "index.js", "module\n")
	return dir
}

func TestWorktreeInclude_CopiesListedIgnoredPathsOnly(t *testing.T) {
	dir := includeRepo(t)
	res := CreateWorktree(context.Background(), options(dir, &recorder{}), WorktreeRequest{Slug: "inc"})
	require.True(t, res.Created, "%+v", res)
	assert.ElementsMatch(t, []string{".env", "node_modules/"}, res.Included)
	assert.Equal(t, "KEY=1\n", readFile(t, res.Path, ".env"))
	assert.Equal(t, "module\n", readFile(t, filepath.Join(res.Path, "node_modules", "pkg"), "index.js"))
	assert.NoFileExists(t, filepath.Join(res.Path, "secret.txt"), "ignored but not listed")
	assert.Empty(t, gitIn(t, res.Path, "status", "--porcelain"), "copied paths are ignored in the worktree too")
}

func TestWorktreeInclude_NoFileCopiesNothing(t *testing.T) {
	dir := newRepo(t)
	res := CreateWorktree(context.Background(), options(dir, &recorder{}), WorktreeRequest{Slug: "none"})
	assert.Empty(t, res.Included)
	assert.Empty(t, res.IncludeWarnings)
}

func TestWorktreeInclude_SymlinkCopiedAsLink(t *testing.T) {
	dir := includeRepo(t)
	require.NoError(t, os.Remove(filepath.Join(dir, ".env")))
	require.NoError(t, os.Symlink("/etc/hosts", filepath.Join(dir, ".env")))
	res := CreateWorktree(context.Background(), options(dir, &recorder{}), WorktreeRequest{Slug: "ln"})
	target, err := os.Readlink(filepath.Join(res.Path, ".env"))
	require.NoError(t, err)
	assert.Equal(t, "/etc/hosts", target)
}

func TestWorktreeInclude_FallbackCopyIsCapped(t *testing.T) {
	dir := includeRepo(t)
	saved, savedLimit := cloneFile, copyFallbackLimit
	t.Cleanup(func() { cloneFile, copyFallbackLimit = saved, savedLimit })
	cloneFile = func(string, string) error { return errCloneUnsupported }
	copyFallbackLimit = 8 // bytes: .env (6) fits, node_modules (7) does not
	res := CreateWorktree(context.Background(), options(dir, &recorder{}), WorktreeRequest{Slug: "cap"})
	assert.Equal(t, []string{".env"}, res.Included)
	require.Len(t, res.IncludeWarnings, 1)
	assert.Contains(t, res.IncludeWarnings[0], "node_modules/")
	assert.NoDirExists(t, filepath.Join(res.Path, "node_modules"))
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `go test ./internal/workbenchgit -run TestWorktreeInclude`
Expected: FAIL (`Included` empty; `cloneFile`, `errCloneUnsupported`, `copyFallbackLimit` undefined).

- [ ] **Step 3: Implement**

`clone_darwin.go`:

```go
//go:build darwin

package workbenchgit

import (
	"errors"

	"golang.org/x/sys/unix"
)

// clonefileNative is clonefile(2): a copy-on-write copy, recursive for a
// directory, never following a symlink at src.
func clonefileNative(src, dst string) error {
	err := unix.Clonefile(src, dst, unix.CLONE_NOFOLLOW)
	if errors.Is(err, unix.ENOTSUP) || errors.Is(err, unix.EXDEV) {
		return errCloneUnsupported
	}
	return err
}
```

`clone_other.go`:

```go
//go:build !darwin

package workbenchgit

func clonefileNative(string, string) error { return errCloneUnsupported }
```

`worktree_include.go`:

```go
package workbenchgit

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

const includeFile = ".worktreeinclude"

var errCloneUnsupported = errors.New("the volume does not support clones")

// cloneFile and copyFallbackLimit are package vars so tests can force the
// fallback and shrink its budget.
var (
	cloneFile               = clonefileNative
	copyFallbackLimit int64 = 1 << 30
)

// includeInto copies into dest every path of the main work tree that
// .worktreeinclude matches and git ignores (spec §6). It never fails the
// create: what could not be copied is a warning.
func includeInto(ctx context.Context, r *repo, p paths, dest string) (included, warnings []string) {
	included, warnings = []string{}, []string{}
	list := filepath.Join(p.topLevel, includeFile)
	if _, err := os.Stat(list); err != nil {
		return included, warnings
	}
	top := Options{Folder: p.topLevel, Run: r.o.Run, Locate: r.o.Locate}
	tr := &repo{o: top, bin: r.bin}
	matched, err := tr.lsIgnored(ctx, "--exclude-from="+list)
	if err != nil {
		return included, []string{clip("reading " + includeFile + ": " + gitError(err))}
	}
	ignored, err := tr.lsIgnored(ctx, "--exclude-standard")
	if err != nil {
		return included, []string{clip("reading the ignored files: " + gitError(err))}
	}
	var budget int64
	for _, rel := range intersectCovered(matched, ignored) {
		src := filepath.Join(p.topLevel, filepath.FromSlash(strings.TrimSuffix(rel, "/")))
		dst := filepath.Join(dest, filepath.FromSlash(strings.TrimSuffix(rel, "/")))
		if _, err := os.Lstat(dst); err == nil {
			continue
		}
		if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
			warnings = append(warnings, clip("not copied: "+rel+": "+err.Error()))
			continue
		}
		err := cloneFile(src, dst)
		if errors.Is(err, errCloneUnsupported) {
			size, sizeErr := treeSize(src)
			if sizeErr != nil || budget+size > copyFallbackLimit {
				warnings = append(warnings, fmt.Sprintf("not copied: %s (%s, the volume does not support clones)", rel, humanSize(size)))
				continue
			}
			budget += size
			err = copyTree(src, dst)
		}
		if err != nil {
			_ = os.RemoveAll(dst) // only what this call made; dst did not exist before
			warnings = append(warnings, clip("not copied: "+rel+": "+err.Error()))
			continue
		}
		included = append(included, rel)
	}
	return included, warnings
}

// lsIgnored lists untracked ignored paths under the given exclude rule,
// directories collapsed ("node_modules/").
func (r *repo) lsIgnored(ctx context.Context, rule string) ([]string, error) {
	out, err := r.git(ctx, "ls-files", "-z", "--others", "--ignored", "--directory", rule)
	if err != nil {
		return nil, err
	}
	var paths []string
	for _, b := range bytes.Split(out, []byte{0}) {
		if len(b) > 0 {
			paths = append(paths, string(b))
		}
	}
	return paths, nil
}

// intersectCovered keeps the matched paths that are ignored: equal to an
// ignored entry or inside an ignored directory. Sorted, deduplicated, and a
// path inside another kept path dropped (the parent's copy covers it).
func intersectCovered(matched, ignored []string) []string {
	covered := func(path string) bool {
		for _, ig := range ignored {
			if path == ig || (strings.HasSuffix(ig, "/") && strings.HasPrefix(path, ig)) {
				return true
			}
		}
		return false
	}
	var keep []string
	for _, m := range matched {
		if covered(m) {
			keep = append(keep, m)
		}
	}
	sort.Strings(keep)
	var out []string
	for _, k := range keep {
		if n := len(out); n > 0 && strings.HasSuffix(out[n-1], "/") && strings.HasPrefix(k, out[n-1]) {
			continue
		}
		if n := len(out); n > 0 && out[n-1] == k {
			continue
		}
		out = append(out, k)
	}
	return out
}

func treeSize(root string) (int64, error) {
	var total int64
	err := filepath.WalkDir(root, func(_ string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.Type().IsRegular() {
			info, err := d.Info()
			if err != nil {
				return err
			}
			total += info.Size()
		}
		return nil
	})
	return total, err
}

// copyTree copies files, directories and symlinks (as links), keeping
// permission bits; nothing outside root is followed.
func copyTree(src, dst string) error {
	return filepath.WalkDir(src, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, path)
		to := filepath.Join(dst, rel)
		info, err := d.Info()
		if err != nil {
			return err
		}
		switch {
		case d.Type()&fs.ModeSymlink != 0:
			target, err := os.Readlink(path)
			if err != nil {
				return err
			}
			return os.Symlink(target, to)
		case d.IsDir():
			return os.MkdirAll(to, info.Mode().Perm())
		case d.Type().IsRegular():
			return copyRegular(path, to, info.Mode().Perm())
		}
		return nil // sockets, devices: skipped
	})
}

func copyRegular(from, to string, perm fs.FileMode) error {
	in, err := os.Open(from)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(to, os.O_CREATE|os.O_EXCL|os.O_WRONLY, perm)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

func humanSize(n int64) string {
	switch {
	case n >= 1<<30:
		return fmt.Sprintf("%.1f GB", float64(n)/(1<<30))
	case n >= 1<<20:
		return fmt.Sprintf("%.1f MB", float64(n)/(1<<20))
	}
	return fmt.Sprintf("%d bytes", n)
}
```

Note: `copyTree` on a single file root works because `WalkDir` visits the root itself. For a symlink root `WalkDir` reports it with `ModeSymlink` and does not descend.

- [ ] **Step 4: Run the tests**

Run: `go test ./internal/workbenchgit -run 'TestWorktreeInclude|TestWorktreeCreate'`
Expected: PASS. Then `go mod tidy` if `golang.org/x/sys` moved from indirect to direct, and `go build ./...`.

- [ ] **Step 5: Commit**

```bash
git add internal/workbenchgit go.mod go.sum
git commit -m "feat(workbenchgit): clone .worktreeinclude paths into a new worktree"
```

---

### Task 4: `RemoveWorktree`, `EnsureWorktree` and the PROJ-17 guard

**Depends on:** Task 3.

**Files:**
- Modify: `internal/workbenchgit/worktree.go`
- Test: `internal/workbenchgit/worktree_remove_test.go`
- Modify: `docs/inventory/workbench.md` (new PROJ-17 after PROJ-16)

**Interfaces:**
- Produces:

```go
type RemoveRequest struct {
	Path   string // the worktree's top level, as stored (CreateWorktree's Path)
	Branch string // wt/<slug>
	Base   string // the commit the branch was cut from ("" = never delete the branch)
}

type RemoveResult struct {
	WorkbenchID   int64  `json:"workbench_id"`
	Removed       bool   `json:"removed"`
	Kept          bool   `json:"kept"`
	Changes       int    `json:"changes"`
	Operation     string `json:"operation"`
	Gone          bool   `json:"gone"` // the directory was already gone; only pruned
	BranchDeleted bool   `json:"branch_deleted"`
	Refused       string `json:"refused"`
	RefusedDetail string `json:"refused_detail"`
	Error         string `json:"error"`
	Warning       string `json:"warning"`
}

func RemoveWorktree(ctx context.Context, o Options, req RemoveRequest) RemoveResult
func EnsureWorktree(ctx context.Context, o Options, path, branch string) WorktreeResult
```

`o.Folder` is the **main** workbench folder for both.

- [ ] **Step 1: Write the failing tests**

```go
func made(t *testing.T, dir string) WorktreeResult {
	res := CreateWorktree(context.Background(), options(dir, &recorder{}), WorktreeRequest{Slug: "r"})
	require.True(t, res.Created, "%+v", res)
	return res
}

func TestWorktreeRemove_CleanRemovedEmptyBranchDeleted(t *testing.T) {
	dir := newRepo(t)
	wt := made(t, dir)
	res := RemoveWorktree(context.Background(), options(dir, &recorder{}), RemoveRequest{Path: wt.Path, Branch: wt.Branch, Base: wt.Base})
	assert.True(t, res.Removed, "%+v", res)
	assert.True(t, res.BranchDeleted)
	assert.NoDirExists(t, wt.Path)
	assert.Empty(t, gitIn(t, dir, "branch", "--list", wt.Branch))
}

func TestWorktreeRemove_BranchWithCommitsKept(t *testing.T) {
	dir := newRepo(t)
	wt := made(t, dir)
	commit(t, wt.Path, "work.txt", "done\n", "work")
	res := RemoveWorktree(context.Background(), options(dir, &recorder{}), RemoveRequest{Path: wt.Path, Branch: wt.Branch, Base: wt.Base})
	assert.True(t, res.Removed)
	assert.False(t, res.BranchDeleted)
	assert.NotEmpty(t, gitIn(t, dir, "branch", "--list", wt.Branch))
}

func TestWorktreeRemove_UncommittedKept(t *testing.T) {
	for name, edit := range map[string]func(t *testing.T, p string){
		"modified":  func(t *testing.T, p string) { writeFile(t, p, "README.md", "x\n") },
		"untracked": func(t *testing.T, p string) { writeFile(t, p, "new.txt", "x\n") },
		"staged":    func(t *testing.T, p string) { writeFile(t, p, "s.txt", "x\n"); gitIn(t, p, "add", "s.txt") },
	} {
		t.Run(name, func(t *testing.T) {
			dir := newRepo(t)
			wt := made(t, dir)
			edit(t, wt.Path)
			res := RemoveWorktree(context.Background(), options(dir, &recorder{}), RemoveRequest{Path: wt.Path, Branch: wt.Branch, Base: wt.Base})
			assert.True(t, res.Kept, "%+v", res)
			assert.False(t, res.Removed)
			assert.DirExists(t, wt.Path)
			assert.NotEmpty(t, gitIn(t, dir, "branch", "--list", wt.Branch))
		})
	}
}

func TestWorktreeRemove_IgnoredFilesDoNotKeep(t *testing.T) {
	dir := includeRepo(t)
	wt := made(t, dir)
	writeFile(t, wt.Path, ".env", "changed\n")
	res := RemoveWorktree(context.Background(), options(dir, &recorder{}), RemoveRequest{Path: wt.Path, Branch: wt.Branch, Base: wt.Base})
	assert.True(t, res.Removed, "%+v", res)
}

func TestWorktreeRemove_GoneDirectoryPruned(t *testing.T) {
	dir := newRepo(t)
	wt := made(t, dir)
	require.NoError(t, os.RemoveAll(wt.Path))
	res := RemoveWorktree(context.Background(), options(dir, &recorder{}), RemoveRequest{Path: wt.Path, Branch: wt.Branch, Base: wt.Base})
	assert.True(t, res.Gone && res.Removed, "%+v", res)
	assert.NotContains(t, gitIn(t, dir, "worktree", "list"), wt.Path)
}

func TestWorktreeRemove_RefusesPathOutsideWorktreesDir(t *testing.T) {
	dir := newRepo(t)
	res := RemoveWorktree(context.Background(), options(dir, &recorder{}), RemoveRequest{Path: dir, Branch: "main"})
	assert.Equal(t, RefusedInvalidName, res.Refused)
	assert.DirExists(t, dir)
}

func TestWorktreeEnsure_RecreatesFromBranch(t *testing.T) {
	dir := newRepo(t)
	wt := made(t, dir)
	commit(t, wt.Path, "work.txt", "done\n", "work")
	RemoveWorktree(context.Background(), options(dir, &recorder{}), RemoveRequest{Path: wt.Path, Branch: wt.Branch, Base: wt.Base})
	res := EnsureWorktree(context.Background(), options(dir, &recorder{}), wt.Path, wt.Branch)
	require.True(t, res.Created, "%+v", res)
	assert.Equal(t, "done\n", readFile(t, wt.Path, "work.txt"))
	again := EnsureWorktree(context.Background(), options(dir, &recorder{}), wt.Path, wt.Branch)
	assert.False(t, again.Created, "an existing worktree is left alone")
	assert.Empty(t, again.Error)
}

func TestWorktreeEnsure_BranchGone(t *testing.T) {
	dir := newRepo(t)
	res := EnsureWorktree(context.Background(), options(dir, &recorder{}), filepath.Join(dir, ".claude", "worktrees", "z"), "wt/z")
	assert.Equal(t, RefusedUnknownBranch, res.Refused)
}

func TestProj17_NeverForcesOrDiscards(t *testing.T) {
	dir := includeRepo(t)
	rec := &recorder{}
	o := options(dir, rec)
	ctx := context.Background()
	clean := CreateWorktree(ctx, o, WorktreeRequest{Slug: "a"})
	dirtyWT := CreateWorktree(ctx, o, WorktreeRequest{Slug: "b"})
	writeFile(t, dirtyWT.Path, "README.md", "x\n")
	RemoveWorktree(ctx, o, RemoveRequest{Path: clean.Path, Branch: clean.Branch, Base: clean.Base})
	RemoveWorktree(ctx, o, RemoveRequest{Path: dirtyWT.Path, Branch: dirtyWT.Branch, Base: dirtyWT.Base})
	EnsureWorktree(ctx, o, clean.Path, clean.Branch)

	forbidden := []string{"--force", "-f", "-D", "--hard", "reset", "clean", "checkout", "stash", "--discard-changes"}
	require.NotEmpty(t, rec.argv())
	for _, c := range rec.argv() {
		for _, a := range c {
			assert.NotContains(t, forbidden, a, "git %s", strings.Join(c, " "))
		}
	}
	assert.DirExists(t, dirtyWT.Path, "a dirty worktree survives")
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `go test ./internal/workbenchgit -run 'TestWorktreeRemove|TestWorktreeEnsure|TestProj17'`
Expected: FAIL — undefined `RemoveWorktree`, `EnsureWorktree`.

- [ ] **Step 3: Implement (append to `worktree.go`)**

```go
// RemoveWorktree removes a session worktree that has no uncommitted work
// (spec §9, PROJ-17): git status in it lists nothing (ignored files do not
// count) and no operation is in progress, else nothing is written and Kept
// is set. The branch stays unless Watchtower made it and it carries no
// commit beyond Base (`branch -d`, never -D). Never --force.
func RemoveWorktree(ctx context.Context, o Options, req RemoveRequest) (res RemoveResult) {
	main, r := readStatus(ctx, o)
	switch {
	case !main.GitAvailable:
		res.Refused = RefusedGitUnavailable
		return res
	case r == nil:
		res.Refused = RefusedNotGit
		return res
	case !main.StatusOK:
		res.Refused, res.Error = RefusedGitFailed, main.StatusError
		return res
	}
	root := filepath.Join(main.TopLevel, filepath.FromSlash(worktreesDir)) + string(filepath.Separator)
	if !strings.HasPrefix(filepath.Clean(req.Path)+string(filepath.Separator), root) || filepath.Clean(req.Path)+string(filepath.Separator) == root ||
		!strings.HasPrefix(req.Branch, worktreeBranchRoot) {
		res.Refused, res.RefusedDetail = RefusedInvalidName, "not a session worktree: "+req.Path
		return res
	}
	if _, err := os.Stat(req.Path); os.IsNotExist(err) {
		res.Gone = true
		if _, err := r.git(ctx, "worktree", "prune"); err != nil {
			res.Error = gitError(err)
			return res
		}
	} else {
		wt := readStatusIn(ctx, o, req.Path)
		switch {
		case !wt.StatusOK:
			res.Kept, res.Error = true, wt.StatusError
			return res
		case wt.Changes > 0 || wt.Operation != "":
			res.Kept, res.Changes, res.Operation = true, wt.Changes, wt.Operation
			return res
		}
		if _, err := r.git(ctx, "worktree", "remove", req.Path); err != nil {
			res.Kept, res.Error = true, gitError(err)
			return res
		}
	}
	res.Removed = true
	if req.Base != "" && r.branchIsEmpty(ctx, req.Branch, req.Base) {
		if _, err := r.git(ctx, "branch", "-d", req.Branch); err != nil {
			res.Warning = gitError(err)
		} else {
			res.BranchDeleted = true
		}
	}
	return res
}

// readStatusIn is the status of another worktree of the same repository.
func readStatusIn(ctx context.Context, o Options, folder string) Status {
	o.Folder = folder
	return ReadStatus(ctx, o)
}

// branchIsEmpty: the branch's tip is base (no commit of its own). Any
// failure reads as not empty, so the branch is kept.
func (r *repo) branchIsEmpty(ctx context.Context, branch, base string) bool {
	out, err := r.git(ctx, "rev-list", "--count", base+".."+"refs/heads/"+branch)
	return err == nil && strings.TrimSpace(string(out)) == "0"
}

// EnsureWorktree puts a removed session worktree back at path from its
// branch (a resume after cleanup, spec §7) and copies the include paths
// again. An existing worktree at path is left alone (Created false, no
// error); a missing branch is RefusedUnknownBranch.
func EnsureWorktree(ctx context.Context, o Options, path, branch string) (res WorktreeResult) {
	res = WorktreeResult{Path: path, Branch: branch, Included: []string{}, IncludeWarnings: []string{}}
	st, r := readStatus(ctx, o)
	switch {
	case !st.GitAvailable:
		res.Refused = RefusedGitUnavailable
		return res
	case r == nil:
		res.Refused = RefusedNotGit
		return res
	case !st.StatusOK:
		res.Refused, res.Error = RefusedGitFailed, st.StatusError
		return res
	}
	if _, err := os.Stat(path); err == nil {
		return res
	}
	if _, code, err := r.run(ctx, "show-ref", "--verify", "--quiet", "refs/heads/"+branch); code == 1 {
		res.Refused, res.RefusedDetail = RefusedUnknownBranch, branch
		return res
	} else if err != nil {
		res.Refused, res.Error = RefusedGitFailed, gitError(err)
		return res
	}
	if _, err := r.git(ctx, "worktree", "prune"); err != nil {
		res.Error = gitError(err)
		return res
	}
	if _, err := r.git(ctx, "worktree", "add", path, branch); err != nil {
		res.Error = gitError(err)
		return res
	}
	res.Created = true
	p := paths{topLevel: st.TopLevel, gitDir: st.GitDir, commonDir: st.CommonDir}
	res.Included, res.IncludeWarnings = includeInto(ctx, r, p, path)
	return res
}
```

`EnsureWorktree` leaves `Cwd` empty: the Desktop keeps the row's stored `folder_path`.

- [ ] **Step 4: Run the tests**

Run: `go test ./internal/workbenchgit`
Expected: PASS (all, including PROJ-10's).

- [ ] **Step 5: Write PROJ-17 into the inventory**

Append to `docs/inventory/workbench.md` after PROJ-16, in the file's entry format (read PROJ-10's entry first and match its headings: Status, Observable, Guard tests, Why):

```markdown
## PROJ-17 — a session worktree never loses work

**Status:** Enforced (Go; owner approved 2026-10-14 in ask #115 with the spec `docs/superpowers/specs/2026-10-14-session-worktrees-design.md` §9, §11)

**Observable:** `workbench worktree remove` removes a session worktree only
when `git status` in it lists nothing (ignored files do not count) and no
merge, rebase, cherry-pick, revert or bisect is in progress; otherwise it
writes nothing and answers `kept`. It only touches paths under
`<top level>/.claude/worktrees/` on `wt/…` branches. It never runs
`worktree remove --force`, `branch -D`, `reset`, `clean`, `checkout` or
`stash`, and deletes a branch (`branch -d`) only when that `wt/…` branch has
no commit beyond the base it was cut from. `ensure` re-adds a removed
worktree from its branch and never touches an existing one.

**Guard tests:** `internal/workbenchgit/worktree_remove_test.go` —
`TestProj17_NeverForcesOrDiscards`, `TestWorktreeRemove_UncommittedKept`,
`TestWorktreeRemove_BranchWithCommitsKept`,
`TestWorktreeRemove_RefusesPathOutsideWorktreesDir`.

**Why:** the worktree is where an agent's unfinished work lives; Watchtower
cleans up after it automatically, so the cleanup must never be the thing
that loses that work.
```

- [ ] **Step 6: Commit**

```bash
git add internal/workbenchgit docs/inventory/workbench.md
git commit -m "feat(workbenchgit): remove and ensure session worktrees (PROJ-17)"
```

---

### Task 5: `watchtower workbench worktree create|ensure|remove` with the integration

**Depends on:** Task 4.

**Files:**
- Create: `cmd/workbench_worktree.go`
- Test: `cmd/workbench_worktree_test.go`
- Modify: `internal/devpack/workbench.go` (export `UnregisterWorkbenchMCP`)
- Test: `internal/devpack/workbench_test.go` (one test for the export)

**Interfaces:**
- Consumes: `workbenchgit.CreateWorktree/EnsureWorktree/RemoveWorktree`; `workbenchInstallOptions(p)`, `devpack.InstallWorkbench`, `devpack.InstallCodex`, `codexAppServerFor`, `codexFindBinary`, `devpack.CodexFound`, `workbenchGitContext`, `workbenchGitWriteBudget`, `writeJSON`, `addWorkbenchIDFlag`, `checkWorkbenchIDFlags`, `workbenchWithFolder`, `openJiraCmdDB` (all in `cmd/`).
- Produces: `func UnregisterWorkbenchMCP(ctx context.Context, o WorkbenchInstallOptions) error` (devpack). CLI:
  - `workbench worktree create --workbench N --name <slug> --json` → `WorktreeResult` + `"integration_error": string`
  - `workbench worktree ensure --workbench N --path P --branch B --json` → `WorktreeResult` + `"integration_error"`
  - `workbench worktree remove --workbench N --path P --branch B [--base SHA] --json` → `RemoveResult`

- [ ] **Step 1: Write the failing tests**

```go
func TestWorkbenchWorktree_CreateInstallsIntegrationThenRemoveUnregisters(t *testing.T) {
	folder := newGitWorkbenchFolder(t) // existing cmd test helper for a git folder; if none, init one like workbench_git_test.go does
	id := createTestWorkbenchRow(t, folder)
	var calls []string
	stubWorkbenchCommandRunner(t, func(dir, name string, args ...string) {
		calls = append(calls, dir+" :: "+name+" "+strings.Join(args, " "))
	})

	out := runCmd(t, "workbench", "worktree", "create", "--workbench", fmt.Sprint(id), "--name", "s1", "--json")
	var created struct {
		workbenchgit.WorktreeResult
		IntegrationError string `json:"integration_error"`
	}
	require.NoError(t, json.Unmarshal(out, &created))
	require.True(t, created.Created, "%s", out)
	assert.FileExists(t, filepath.Join(created.Cwd, ".claude", "settings.local.json"), "hooks installed in the worktree")
	assert.DirExists(t, filepath.Join(created.Cwd, ".claude", "skills", "watchtower-workbench"))
	assert.Contains(t, strings.Join(calls, "\n"), created.Cwd+" :: claude mcp add --scope local watchtower-workbench")

	calls = nil
	out = runCmd(t, "workbench", "worktree", "remove", "--workbench", fmt.Sprint(id),
		"--path", created.Path, "--branch", created.Branch, "--base", created.Base, "--json")
	var removed workbenchgit.RemoveResult
	require.NoError(t, json.Unmarshal(out, &removed))
	assert.True(t, removed.Removed, "%s", out)
	assert.Contains(t, strings.Join(calls, "\n"), created.Cwd+" :: claude mcp remove --scope local watchtower-workbench")
}

func TestWorktreeRemove_KeepsSharedExcludeLines(t *testing.T) {
	folder := newGitWorkbenchFolder(t)
	id := createTestWorkbenchRow(t, folder)
	stubWorkbenchCommandRunner(t, nil)
	runCmd(t, "integrate", "claude-code", "--workbench", fmt.Sprint(id)) // the main folder's own install
	before := readExclude(t, folder)
	out := runCmd(t, "workbench", "worktree", "create", "--workbench", fmt.Sprint(id), "--name", "s2", "--json")
	var c workbenchgit.WorktreeResult
	require.NoError(t, json.Unmarshal(out, &c))
	runCmd(t, "workbench", "worktree", "remove", "--workbench", fmt.Sprint(id), "--path", c.Path, "--branch", c.Branch, "--base", c.Base, "--json")
	after := readExclude(t, folder)
	for _, line := range strings.Split(strings.TrimSpace(before), "\n") {
		assert.Contains(t, after, line, "a line the main folder needs survives")
	}
}

func TestWorkbenchWorktree_UnknownWorkbenchExitsNonZero(t *testing.T) {
	_, err := runCmdErr(t, "workbench", "worktree", "create", "--workbench", "999", "--name", "x", "--json")
	require.Error(t, err)
}
```

Before writing these, read `cmd/workbench_git_test.go` and `cmd/integrate_workbench_test.go` and use **their** helper names for: making a git workbench folder, inserting the workbench row, running a command and capturing stdout, stubbing `workbenchCommandRunner` (the claude CLI) and `workbenchExecutable`. Rename `newGitWorkbenchFolder` / `createTestWorkbenchRow` / `runCmd` / `runCmdErr` / `stubWorkbenchCommandRunner` / `readExclude` in the tests above to those names; add only the helpers that do not exist (`readExclude` reads `<folder>/.git/info/exclude`).

- [ ] **Step 2: Run them to see them fail**

Run: `go test ./cmd -run 'TestWorkbenchWorktree|TestWorktreeRemove_KeepsShared'`
Expected: FAIL — unknown command "worktree".

- [ ] **Step 3: Export the MCP unregistration (devpack)**

In `internal/devpack/workbench.go` add, next to `unregisterWorkbenchMCP`:

```go
// UnregisterWorkbenchMCP removes the folder's local registration of the
// workbench MCP server (both names). A session worktree's cleanup uses it
// instead of RemoveWorkbench: the worktree's files go with the worktree, and
// RemoveWorkbench would also drop exclude lines that every worktree of the
// repository shares (info/exclude lives in the common git dir).
func UnregisterWorkbenchMCP(ctx context.Context, o WorkbenchInstallOptions) error {
	if err := o.validate(); err != nil {
		return err
	}
	return unregisterWorkbenchMCP(ctx, o)
}
```

Test in `internal/devpack/workbench_test.go`, using that file's fake runner: after `InstallWorkbench`, `UnregisterWorkbenchMCP` issues `claude mcp remove --scope local watchtower-workbench` in `o.Folder` and leaves `settings.local.json` and the exclude block untouched. Run `go test ./internal/devpack -run UnregisterWorkbenchMCP` → PASS.

- [ ] **Step 4: Implement `cmd/workbench_worktree.go`**

```go
package cmd

import (
	"context"
	"errors"
	"fmt"

	"github.com/spf13/cobra"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/devpack"
	"watchtower/internal/workbenchgit"
)

var workbenchWorktreeCmd = &cobra.Command{
	Use:   "worktree",
	Short: "Create, restore and remove session worktrees (parallel agent sessions)",
	Long: "A session worktree is <repository>/.claude/worktrees/<name> on branch wt/<name>,\n" +
		"cut from the workbench folder's HEAD, with the .worktreeinclude paths cloned in and\n" +
		"the workbench integration installed. remove never discards work (PROJ-17). Every\n" +
		"command exits 0 once the workbench and its folder resolve.",
}

var (
	workbenchWorktreeFlagName   string
	workbenchWorktreeFlagPath   string
	workbenchWorktreeFlagBranch string
	workbenchWorktreeFlagBase   string
)

func init() {
	create := &cobra.Command{Use: "create", Short: "Create a session worktree", Args: cobra.NoArgs, RunE: runWorkbenchWorktreeCreate}
	ensure := &cobra.Command{Use: "ensure", Short: "Put a removed session worktree back from its branch", Args: cobra.NoArgs, RunE: runWorkbenchWorktreeEnsure}
	remove := &cobra.Command{Use: "remove", Short: "Remove a session worktree that has no uncommitted work", Args: cobra.NoArgs, RunE: runWorkbenchWorktreeRemove}
	for _, c := range []*cobra.Command{create, ensure, remove} {
		addWorkbenchIDFlag(c, &workbenchGitFlagWorkbench, "workbench id")
		c.Flags().BoolVar(&workbenchGitFlagJSON, "json", false, "output JSON")
		workbenchWorktreeCmd.AddCommand(c)
	}
	create.Flags().StringVar(&workbenchWorktreeFlagName, "name", "", "the worktree's name (lowercase letters, digits, dashes)")
	for _, c := range []*cobra.Command{ensure, remove} {
		c.Flags().StringVar(&workbenchWorktreeFlagPath, "path", "", "the worktree's top level")
		c.Flags().StringVar(&workbenchWorktreeFlagBranch, "branch", "", "its wt/… branch")
	}
	remove.Flags().StringVar(&workbenchWorktreeFlagBase, "base", "", "the commit the branch was cut from (an empty branch is deleted)")
	workbenchCmd.AddCommand(workbenchWorktreeCmd)
}

// worktreeEnvelope is a create/ensure result plus the integration install's
// failure: the worktree is usable without it, but its session would lack
// the hooks and board tools, so the Desktop shows it.
type worktreeEnvelope struct {
	workbenchgit.WorktreeResult
	IntegrationError string `json:"integration_error"`
}

func runWorkbenchWorktreeCreate(cmd *cobra.Command, _ []string) error {
	id, o, err := workbenchGitTarget(cmd)
	if err != nil {
		return err
	}
	ctx, cancel := workbenchGitContext(cmd, workbenchGitWriteBudget)
	defer cancel()
	res := workbenchgit.CreateWorktree(ctx, o, workbenchgit.WorktreeRequest{Slug: workbenchWorktreeFlagName})
	return writeWorktreeEnvelope(ctx, cmd, id, res, res.Cwd)
}

func runWorkbenchWorktreeEnsure(cmd *cobra.Command, _ []string) error {
	id, o, err := workbenchGitTarget(cmd)
	if err != nil {
		return err
	}
	ctx, cancel := workbenchGitContext(cmd, workbenchGitWriteBudget)
	defer cancel()
	res := workbenchgit.EnsureWorktree(ctx, o, workbenchWorktreeFlagPath, workbenchWorktreeFlagBranch)
	cwd := ""
	if res.Created {
		cwd = sessionCwdIn(o.Folder, res.Path)
	}
	return writeWorktreeEnvelope(ctx, cmd, id, res, cwd)
}

func runWorkbenchWorktreeRemove(cmd *cobra.Command, _ []string) error {
	id, o, err := workbenchGitTarget(cmd)
	if err != nil {
		return err
	}
	ctx, cancel := workbenchGitContext(cmd, workbenchGitWriteBudget)
	defer cancel()
	req := workbenchgit.RemoveRequest{Path: workbenchWorktreeFlagPath, Branch: workbenchWorktreeFlagBranch, Base: workbenchWorktreeFlagBase}
	// Unregister first, while the folder exists: claude keys the local
	// registration by the directory it runs in.
	var unregErr error
	cwd := sessionCwdIn(o.Folder, req.Path)
	if isExistingDir(cwd) {
		unregErr = unregisterWorktreeMCP(ctx, id, cwd)
	}
	res := workbenchgit.RemoveWorktree(ctx, o, req)
	res.WorkbenchID = id
	if unregErr != nil && res.Warning == "" {
		res.Warning = "the MCP registration of " + cwd + " was not removed: " + unregErr.Error()
	}
	return writeJSON(cmd.OutOrStdout(), res)
}

// installWorktreeIntegration is `integrate claude-code` (and codex's skill,
// when codex is found) for the worktree folder, same workbench id.
func installWorktreeIntegration(ctx context.Context, id int64, folder string) error {
	o, err := workbenchInstallOptions(&db.Workbench{ID: id, FolderPath: folder})
	if err != nil {
		return err
	}
	_, err = devpack.InstallWorkbench(ctx, o)
	cfg, cfgErr := config.Load(flagConfig)
	if cfgErr != nil {
		cfg = &config.Config{}
	}
	if devpack.CodexFound(cfg, codexFindBinary) {
		_, codexErr := devpack.InstallCodex(ctx, o, codexAppServerFor(ctx, cfg, o))
		err = errors.Join(err, codexErr)
	}
	return err
}

func unregisterWorktreeMCP(ctx context.Context, id int64, folder string) error {
	o, err := workbenchInstallOptions(&db.Workbench{ID: id, FolderPath: folder})
	if err != nil {
		return err
	}
	return devpack.UnregisterWorkbenchMCP(ctx, o)
}

func writeWorktreeEnvelope(ctx context.Context, cmd *cobra.Command, id int64, res workbenchgit.WorktreeResult, cwd string) error {
	res.WorkbenchID = id
	env := worktreeEnvelope{WorktreeResult: res}
	if cwd != "" {
		if err := installWorktreeIntegration(ctx, id, cwd); err != nil {
			env.IntegrationError = err.Error()
		}
	}
	if workbenchGitFlagJSON {
		return writeJSON(cmd.OutOrStdout(), env)
	}
	fmt.Fprintf(cmd.OutOrStdout(), "path: %s\nbranch: %s\ncreated: %t\n", res.Path, res.Branch, res.Created)
	return nil
}
```

`workbenchInstallOptions` reads only `ID` and `FolderPath` of the `*db.Workbench`. `sessionCwdIn(mainFolder, worktreeTop)` = `worktreeTop` joined with the main folder's path relative to its repository top level — compute it with `workbenchgit.ReadStatus(ctx, Options{Folder: mainFolder}).TopLevel` and `filepath.Rel`; put it in this file with a one-line comment.

`workbenchInstallOptions` in `cmd/integrate_workbench.go` reads `workbenchCommandRunner` and `workbenchExecutable` — the tests' stubs therefore cover the worktree install too.

- [ ] **Step 5: Trust prompt spike (spec §8 open item)**

Manually, once: `go build -o /tmp/wt ./ && /tmp/wt workbench worktree create --workbench <a test workbench> --name trust --json`, then run `claude` in the printed `cwd` from a terminal. Record in the plan's execution notes (and in `docs/features/workbench.md`, Task 12) whether Claude Code shows its folder-trust prompt. Do **not** write to `~/.claude.json` to suppress it: if it appears, it is a documented v1 limit (the owner accepts it once per worktree in the embedded terminal). Remove the test worktree with `remove`.

- [ ] **Step 6: Run the tests**

Run: `go test ./cmd -run 'TestWorkbenchWorktree|TestWorktreeRemove_KeepsShared' && go test ./internal/devpack`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add cmd/workbench_worktree.go cmd/workbench_worktree_test.go internal/devpack
git commit -m "feat(cmd): workbench worktree create|ensure|remove with the workbench integration"
```

---

### Task 6: Workbench deletion cleans session worktrees (PROJ-02)

**Depends on:** Tasks 1, 5.

**Files:**
- Modify: `cmd/workbench.go` (`runWorkbenchDelete`, ~l.471)
- Test: `cmd/workbench_test.go`
- Modify: `docs/inventory/workbench.md` (PROJ-02 amendment)

**Interfaces:**
- Consumes: `db.SessionWorktrees` (Task 1), `workbenchgit.RemoveWorktree` (Task 4), `unregisterWorktreeMCP` (Task 5).
- Produces: `workbench delete` JSON gains `"kept_worktrees": [path…]`.

- [ ] **Step 1: Write the failing test**

```go
func TestWorkbenchDelete_RemovesCleanSessionWorktreesKeepsDirty(t *testing.T) {
	folder := newGitWorkbenchFolder(t)
	id := createTestWorkbenchRow(t, folder)
	stubWorkbenchCommandRunner(t, nil)
	clean := createWorktreeRow(t, id, folder, "c") // runs `workbench worktree create`, inserts a terminal_sessions row with worktree_branch/base
	dirty := createWorktreeRow(t, id, folder, "d")
	writeTestFile(t, dirty.Path, "README.md", "edited\n")

	out := runCmd(t, "workbench", "delete", fmt.Sprint(id), "--json")
	assert.NoDirExists(t, clean.Path)
	assert.DirExists(t, dirty.Path, "PROJ-17: uncommitted work survives the delete")
	assert.Contains(t, string(out), dirty.Path, "the kept worktree is named")
}
```

Use the delete command's real flag shape (read `runWorkbenchDelete` first; it may confirm differently).

- [ ] **Step 2: Run it to see it fail**

Run: `go test ./cmd -run TestWorkbenchDelete_RemovesCleanSessionWorktrees`
Expected: FAIL — clean worktree still on disk.

- [ ] **Step 3: Implement**

In `runWorkbenchDelete`, before the row deletion and before `workbenchRemoveInstall`, read `database.SessionWorktrees(p.ID)`; for each: `unregisterWorktreeMCP(ctx, p.ID, s.FolderPath)` when the folder exists, then `workbenchgit.RemoveWorktree(ctx, Options{Folder: p.FolderPath}, RemoveRequest{Path: <top of s.FolderPath>, Branch: s.Branch, Base: s.Base})` — the stored `folder_path` is the session cwd; its worktree top is `<main top>/.claude/worktrees/<the path component right after it>` (write a small `worktreeTopOf(cwd, mainTop string) (string, bool)` helper in `cmd/workbench_worktree.go` and use it in Task 5's remove too). Collect `res.Kept` paths into `kept_worktrees` in the output (JSON and text). Failures are joined into the command's error like `workbenchRemoveInstall`'s.

PROJ-02 amendment in `docs/inventory/workbench.md` (append to PROJ-02's Observable): "Since 2026-10-14 (spec session worktrees §9): deleting a workbench also removes each of its session worktrees that has no uncommitted work and unregisters their MCP entries; a worktree with uncommitted work stays on disk (PROJ-17) and is listed in `kept_worktrees`." Add the test name to its guard tests.

- [ ] **Step 4: Run the tests**

Run: `go test ./cmd -run 'TestWorkbenchDelete'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add cmd/workbench.go cmd/workbench_test.go internal/db docs/inventory/workbench.md
git commit -m "feat(cmd): workbench delete removes clean session worktrees (PROJ-02)"
```

---

### Task 7: WatchtowerCore — envelopes and `SessionPlacement`

**Depends on:** none (pure Swift).

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Models/WorkbenchWorktree.swift`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/SessionPlacement.swift`
- Test: `WatchtowerDesktop/Tests/Core/SessionPlacementTests.swift`, `WatchtowerDesktop/Tests/Core/WorkbenchWorktreeDecodingTests.swift`

**Interfaces:**
- Consumes: `WorkbenchGitStatus` (`WatchtowerCore/Models/WorkbenchGit.swift`: `gitAvailable`, `git`, `unborn` — read the file for the exact property names).
- Produces:

```swift
package struct WorktreeCreateResult: Decodable, Equatable, Sendable {
    package var created: Bool
    package var path: String
    package var cwd: String
    package var branch: String
    package var base: String
    package var baseDirty: Bool
    package var included: [String]
    package var includeWarnings: [String]
    package var refused: String
    package var refusedDetail: String
    package var error: String
    package var warning: String
    package var integrationError: String
}

package struct WorktreeRemoveResult: Decodable, Equatable, Sendable {
    package var removed: Bool
    package var kept: Bool
    package var changes: Int
    package var gone: Bool
    package var branchDeleted: Bool
    package var refused: String
    package var error: String
    package var warning: String
}

package enum WorktreeChoice: String, Sendable { case auto, folder, worktree }

package enum SessionPlacement: Equatable, Sendable {
    case folder
    case worktree
    /// The folder cannot have worktrees; `reason` is shown when the owner asked for one.
    case folderOnly(reason: String)

    package static func decide(choice: WorktreeChoice, git: WorkbenchGitStatus?, occupied: Bool) -> SessionPlacement

    /// Lowercase ASCII slug, ≤ 40: "<targetID>-<first words>" or "session-<n>".
    package static func slug(targetID: Int64?, targetText: String?, sessionNumber: Int) -> String
}
```

- [ ] **Step 1: Write the failing tests**

```swift
final class SessionPlacementTests: XCTestCase {
    private func status(git: Bool = true, available: Bool = true, unborn: Bool = false) -> WorkbenchGitStatus {
        // build through JSON so the test does not depend on the memberwise init
        let json = #"{"workbench_id":1,"git_available":\#(available),"git":\#(git),"unborn":\#(unborn)}"#
        return try! JSONDecoder().decode(WorkbenchGitStatus.self, from: Data(json.utf8))
    }

    func testLoneSessionStaysInFolder() {
        XCTAssertEqual(SessionPlacement.decide(choice: .auto, git: status(), occupied: false), .folder)
    }
    func testOccupiedFolderGetsWorktree() {
        XCTAssertEqual(SessionPlacement.decide(choice: .auto, git: status(), occupied: true), .worktree)
    }
    func testOverridesWin() {
        XCTAssertEqual(SessionPlacement.decide(choice: .folder, git: status(), occupied: true), .folder)
        XCTAssertEqual(SessionPlacement.decide(choice: .worktree, git: status(), occupied: false), .worktree)
    }
    func testNoGitNeverWorktree() {
        for st in [status(git: false), status(available: false), status(unborn: true), nil] {
            guard case .folderOnly = SessionPlacement.decide(choice: .worktree, git: st, occupied: true) else {
                return XCTFail("expected folderOnly for \(String(describing: st))")
            }
        }
    }
    func testSlug() {
        XCTAssertEqual(SessionPlacement.slug(targetID: 229, targetText: "Параллельные сессии: worktree!", sessionNumber: 3), "229-worktree")
        XCTAssertEqual(SessionPlacement.slug(targetID: 12, targetText: "Fix the Login Bug in Settings view", sessionNumber: 1), "12-fix-the-login-bug")
        XCTAssertEqual(SessionPlacement.slug(targetID: nil, targetText: nil, sessionNumber: 4), "session-4")
        XCTAssertLessThanOrEqual(SessionPlacement.slug(targetID: 1, targetText: String(repeating: "abcdefghij ", count: 10), sessionNumber: 1).count, 40)
    }
}
```

`WorkbenchWorktreeDecodingTests`: decode a create envelope with every key (snake_case, via `keyDecodingStrategy = .convertFromSnakeCase` or explicit `CodingKeys` — match what `WorkbenchGit.swift` does) and one with keys missing → defaults (`false`, `""`, `[]`), as `WorkbenchGit.swift`'s envelopes tolerate older Go.

- [ ] **Step 2: Run them to see them fail**

Run: `make test-swift FILTER='SessionPlacementTests|WorkbenchWorktreeDecodingTests'`
Expected: FAIL — types not found.

- [ ] **Step 3: Implement**

`decide`: `guard let git, git.gitAvailable else { return .folderOnly(reason: "git is not available") }`; `guard git.git else { .folderOnly(reason: "the folder is not a git repository") }`; `guard !git.unborn else { .folderOnly(reason: "the repository has no commit yet") }`; then `switch choice { case .folder: .folder; case .worktree: .worktree; case .auto: occupied ? .worktree : .folder }`. Note `.folderOnly` is returned for `.auto` too; callers treat it as `.folder` and show the reason only when `choice == .worktree`.

`slug`: fold `targetText` with `.applyingTransform(.toLatin, reverse: false)` then `.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)`, lowercase, map any non `[a-z0-9]` run to one `-`, keep the first four words, trim dashes; prefix `"\(targetID)-"`; if the word part is empty use `"\(targetID)"`; cap to 40 by dropping whole trailing words, then hard-cut and trim a trailing dash. No target → `"session-\(sessionNumber)"`.

Note on the first `testSlug` assertion: Cyrillic transliterates to Latin words ("parallelnye sessii worktree") — adjust the expected value to the transliteration your implementation produces with the first four words, e.g. `"229-parallelnye-sessii-worktree"`. Write the expectation after running once, then keep it fixed.

Envelopes: mirror `WorkbenchGit.swift`'s decoding style exactly (its `init(from:)` with `decodeIfPresent ?? default`).

- [ ] **Step 4: Run the tests**

Run: `make test-swift FILTER='SessionPlacementTests|WorkbenchWorktreeDecodingTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/WatchtowerCore WatchtowerDesktop/Tests/Core
git commit -m "feat(core): session placement rule and worktree envelopes"
```

---

### Task 8: `WorkbenchCLI` worktree calls

**Depends on:** Tasks 5, 7.

**Files:**
- Modify: `WatchtowerDesktop/Sources/Services/WorkbenchCLI.swift` (next to `gitCreateBranch`, ~l.710)
- Test: the existing `WorkbenchCLI` test file (find it: `grep -l "gitCreateBranch" WatchtowerDesktop/Tests`)

**Interfaces:**
- Produces:

```swift
func worktreeCreate(projectID: Int64, name: String) async throws -> WorktreeCreateResult
func worktreeEnsure(projectID: Int64, path: String, branch: String) async throws -> WorktreeCreateResult
func worktreeRemove(projectID: Int64, path: String, branch: String, base: String?) async throws -> WorktreeRemoveResult
```

- [ ] **Step 1: Failing test** — with the test file's fake `CLIRunnerProtocol`, assert each call's argv:
  `["workbench","worktree","create","--workbench","7","--name","s1","--json"]`,
  `["workbench","worktree","ensure","--workbench","7","--path","/r/.claude/worktrees/s1","--branch","wt/s1","--json"]`,
  `["workbench","worktree","remove","--workbench","7","--path","/r/.claude/worktrees/s1","--branch","wt/s1","--base","abc","--json"]` (no `--base` when nil), and that the stub's JSON decodes.
- [ ] **Step 2:** `make test-swift FILTER=<that test class>` → FAIL.
- [ ] **Step 3: Implement** — same shape as `gitCreateBranch`:

```swift
/// Creates a session worktree (`workbench worktree create`); a refusal is in the envelope.
func worktreeCreate(projectID: Int64, name: String) async throws -> WorktreeCreateResult {
    let data = try await runner.run(args: ["workbench", "worktree", "create", "--workbench", String(projectID), "--name", name, "--json"])
    return try JSONDecoder().decode(WorktreeCreateResult.self, from: data)
}

/// Puts a removed session worktree back from its branch before a resume.
func worktreeEnsure(projectID: Int64, path: String, branch: String) async throws -> WorktreeCreateResult {
    let data = try await runner.run(args: ["workbench", "worktree", "ensure", "--workbench", String(projectID),
                                           "--path", path, "--branch", branch, "--json"])
    return try JSONDecoder().decode(WorktreeCreateResult.self, from: data)
}

/// Removes a session worktree with no uncommitted work (PROJ-17); `kept` otherwise.
func worktreeRemove(projectID: Int64, path: String, branch: String, base: String?) async throws -> WorktreeRemoveResult {
    var args = ["workbench", "worktree", "remove", "--workbench", String(projectID), "--path", path, "--branch", branch]
    if let base, !base.isEmpty { args += ["--base", base] }
    args.append("--json")
    let data = try await runner.run(args: args)
    return try JSONDecoder().decode(WorktreeRemoveResult.self, from: data)
}
```

- [ ] **Step 4:** run the filter → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(desktop): WorkbenchCLI worktree calls"`.

---

### Task 9: Session report sees worktree branches (spec §11 PROJ-14 check)

**Depends on:** Task 2.

**Files:**
- Test: `internal/sessionreport/refresh_test.go`

- [ ] **Step 1: Write the test** — in `refresh_test.go`'s style (read it first; it fakes `gh`), create a repo, a workbench row on it, a worktree via `workbenchgit.CreateWorktree`, a commit on `wt/<slug>` merged into main, and call `Refresh` with ref `branch:wt/<slug>`: the cached state reads `merged` without any change to `refresh.go`. Name: `TestRefresh_WorktreeBranchResolvesFromTheMainFolder`.
- [ ] **Step 2:** `go test ./internal/sessionreport -run TestRefresh_WorktreeBranch` → PASS on first run is the expected outcome (it pins existing behaviour). If it fails, stop and report to the controller: the spec's PROJ-14 change is needed after all.
- [ ] **Step 3: Commit** — `git commit -m "test(sessionreport): worktree branches resolve from the main folder"`.

---

### Task 10: Desktop — placement at start, setup command, resume, PROJ-10 guard

**Depends on:** Tasks 1, 7, 8.

**Files:**
- Modify: `WatchtowerDesktop/Sources/ViewModels/WorkbenchesViewModel+Sessions.swift` (`newSession`, `startNewSession`, `startTarget`, `createAndActivate`, `reopen`/`open` resume path)
- Create: `WatchtowerDesktop/Sources/ViewModels/WorkbenchesViewModel+Worktrees.swift` (placement + cleanup helpers; keeps `+Sessions.swift` from growing)
- Modify: `WatchtowerDesktop/Sources/Services/TerminalCenter.swift` (`hasLiveAgentSession` ~l.239; first-launch setup command in `run` ~l.852)
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/TerminalLaunch.swift` (`make` gains `setupCommand: String?`)
- Modify: `docs/inventory/workbench.md` (PROJ-10 amendment)
- Test: `WatchtowerDesktop/Tests/WorkbenchesViewModelWorktreeTests.swift`, `WatchtowerDesktop/Tests/Core/TerminalLaunchTests.swift` (existing; add cases)

**Interfaces:**
- Consumes: `SessionPlacement`, `WorktreeChoice`, `WorktreeCreateResult` (Task 7); `cli.worktreeCreate/worktreeEnsure` (Task 8); `NewSession.worktreeBranch/worktreeBase`, `Workbench.worktreeSetup` (Task 1); `cli.gitStatus(projectID:)`.
- Produces: `newSession(projectID:placement:agent:worktree: WorktreeChoice = .auto)`, `workOn(…, worktree: WorktreeChoice = .auto)`; `startNotice[projectID]: String?` (a one-line note shown above the sessions panel, e.g. "Started in the folder: …" / "New worktree wt/x does not have the folder's uncommitted changes."); `TerminalCenter.isOccupying(folder:)`.

- [ ] **Step 1: Write the failing tests** (`WorkbenchesViewModelWorktreeTests`, using the fakes `WorkbenchesViewModelSessionsTests` and `WorkbenchesViewModelGitTests` already use — read both first):
  - `testLoneSessionStartsInFolder` — no live rows → row's `folderPath == project.folderPath`, `worktreeBranch == nil`, no `worktree create` call.
  - `testSecondSessionGetsWorktree` — a live claude row in the folder → `worktree create --name session-2`, the row's `folderPath == cwd`, `worktreeBranch == "wt/session-2"`, `worktreeBase` stored.
  - `testWorkOnUsesTargetSlug` — occupied folder, Work on It for target 229 → `--name 229-…`.
  - `testRefusedCreateFallsBackWithNotice` — fake returns `refused: "not_git"` with `.auto` → folder row, no notice; with `.worktree` → folder row and `startNotice` names the reason.
  - `testBaseDirtyNotice` — `base_dirty: true` → notice mentions uncommitted changes.
  - `testConcurrentStartsSecondGetsWorktree` — two `newSession` calls started together on an idle folder: exactly one row in the folder, one in a worktree (placement is serialised per workbench).
  - `testResumeEnsuresRemovedWorktree` — a row with `worktreeBranch` whose folder is missing → `worktree ensure` is called before launch; `refused: "unknown_branch"` → the row is `.unavailable` with "The worktree and its branch wt/… no longer exist."
  - `testBranchSwitchGuardIgnoresWorktreeSessions` — a live agent row whose folder is a worktree → `gitSwitch(agentRunning: false)`; a live row in the main folder → `true`.
  - `TerminalLaunchTests.testSetupCommandRunsBeforeAgentOnFirstLaunch` — `make(…, setupCommand: "npm install")` builds `-l -c "npm install || echo '…setup command failed…'; exec claude --session-id …"`; nil/empty → today's argv unchanged.
- [ ] **Step 2:** `make test-swift FILTER='WorkbenchesViewModelWorktreeTests|TerminalLaunchTests'` → FAIL.
- [ ] **Step 3: Implement**

  - `TerminalCenter.isOccupying(folder:)`: true when a live agent row's resolved `folderPath` equals the resolved `folder` (exact match, not "under": a worktree under `.claude/worktrees` does not occupy).
  - `TerminalCenter.hasLiveAgentSession(workbenchID:workTree:)`: drop the `row.projectID == workbenchID` clause; keep only "resolved folder equals or is under `workTree`" **and** not under `<workTree>/.claude/worktrees/`. (Its only caller is the branch switch guard.)
  - In `+Worktrees.swift`:

```swift
extension WorkbenchesViewModel {
    /// Where a new agent session of `project` runs (spec §4): the folder, or
    /// a fresh worktree whose row fields come back filled in. One decision
    /// per workbench at a time, so two starts never both take the folder.
    func placeNewSession(_ new: TerminalSessionQueries.NewSession, project: Workbench,
                         choice: WorktreeChoice, slugTarget: (id: Int64, text: String)?) async -> TerminalSessionQueries.NewSession
}
```

    It awaits a per-workbench `placementLock` (an `[Int64: Task<Void, Never>]` chain on the VM), reads `cli.gitStatus` (failure → `nil` → `.folderOnly`), computes `occupied` from `terminalCenter.isOccupying(folder: project.folderPath)` **plus** rows this VM created in the folder whose launch is still pending (`pendingFolderStarts[projectID]` counter, incremented before `createAndActivate` and decremented after `activate` returns), decides, and for `.worktree` calls `cli.worktreeCreate(projectID:name:)`. Success → returns `new` with `folderPath = res.cwd`, `worktreeBranch = res.branch`, `worktreeBase = res.base`, and sets `startNotice` when `baseDirty`, `includeWarnings`, `integrationError` or `warning` is non-empty (one line, the first of them). Refusal/error/throw → returns `new` unchanged and, when `choice == .worktree`, sets `startNotice = "Started in the folder: \(reason)"`.
  - Call it from `createAndActivate` only for rows with `projectID != nil` and `kind` `.claude`/`.codex` (standalone and shell rows untouched). Thread `choice` and the target (id, text) from `newSession` / `startNewSession` / `startTarget` as new defaulted parameters; `CodeHandoffCenter` and the setup session keep `.auto`.
  - Setup command: `TerminalLaunch.make` gets `setupCommand: String?`; `TerminalCenter.run` passes `project.worktreeSetup` only when the row has `worktreeBranch != nil` **and** this is the row's fresh start (`fresh: true` from `createAndActivate`), never on resume.
  - Resume: in the open/reopen path, before `activate(row, fresh: false…)`, if `row.worktreeBranch != nil` and the folder does not exist, call `cli.worktreeEnsure(projectID:path:branch:)` with `path` = the worktree top (strip the session's prefix: the top is `<main top>/.claude/worktrees/<slug>`, derivable from `folderPath` by taking the path up to the component after `.claude/worktrees`). `refused == "unknown_branch"` → set the row unavailable with the message above; after a successful ensure clear `worktreeRemovedAt` (`setWorktreeState(kept: false, removedAt: nil)` leaves it; add a `clearWorktreeRemoved` query in `TerminalSessionQueries` setting `worktree_removed_at = NULL`).
  - PROJ-10 amendment in `docs/inventory/workbench.md` (append to PROJ-10 Observable): "Since 2026-10-14: an agent session working in its own session worktree (under `<top level>/.claude/worktrees/`) does not count as running in the folder; only an agent whose folder is the work tree or below it outside that directory does."
- [ ] **Step 4:** run the filter → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** — `git commit -m "feat(desktop): start concurrent sessions in their own worktree"`.

---

### Task 11: Desktop — cleanup on finish, on delete, Remove Worktree

**Depends on:** Task 10.

**Files:**
- Modify: `WatchtowerDesktop/Sources/ViewModels/WorkbenchesViewModel+Worktrees.swift`
- Modify: `WatchtowerDesktop/Sources/ViewModels/WorkbenchesViewModel+Sessions.swift` (`sessionExited` ~l.592, `delete` ~l.492)
- Test: `WatchtowerDesktop/Tests/WorkbenchesViewModelWorktreeTests.swift` (add)

**Interfaces:**
- Produces: `func cleanUpWorktree(_ row: TerminalSession) async` (VM); `func removeWorktree(_ row: TerminalSession) async` (menu action, same call, but refuses while live).

- [ ] **Step 1: Failing tests**
  - `testExitWhileFinishedRemovesCleanWorktree` — row with `worktreeBranch`, `finishedAt` set; `sessionExited(id, 0)` → `worktree remove --path <top> --branch wt/… --base <sha>`; envelope `removed` → row `worktreeRemovedAt` set.
  - `testExitWhileNotFinishedDoesNothing` — `finishedAt == nil` → no remove call.
  - `testKeptMarksRow` — envelope `kept: true` → `worktreeKept == true`; a later successful remove clears it.
  - `testDeleteRowRemovesWorktreeFirst` — `delete(row)` calls remove before the row deletion; a `kept` worktree does not block the row deletion, and `startNotice` says "The worktree at … has uncommitted changes and was left on disk."
  - `testRemoveWorktreeRefusedWhileLive` — live row → no CLI call, notice "Stop the agent first".
- [ ] **Step 2:** filter → FAIL.
- [ ] **Step 3: Implement** — `sessionExited`: after its existing body, `if let row = rowsByID[id], row.worktreeBranch != nil, row.worktreeRemovedAt == nil, row.finishedAt != nil { Task { await cleanUpWorktree(row) } }` (re-read the row from the DB first: `finished_at` is written by Go hooks, the in-memory copy may be stale). `cleanUpWorktree` calls `cli.worktreeRemove(projectID:path:branch:base:)` and writes `setWorktreeState(kept: res.kept, removedAt: res.removed ? now ISO : nil)`; a thrown error is logged with `NSLog` and leaves the row alone. `delete` runs `cleanUpWorktree` after closing the process and before the row deletion. Reload the panel's rows after each write.
- [ ] **Step 4:** filter → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(desktop): remove a finished session's clean worktree"`.

---

### Task 12: Desktop UI, settings field and docs

**Depends on:** Tasks 10, 11.

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/WorkbenchSessionsPanel.swift` (row badge ~row view; `.contextMenu` ~l.125)
- Modify: the new-session and Work on It menus (find with `grep -rn "Work on It" WatchtowerDesktop/Sources/Views`), the workbench settings view (where `archive_after_days` is edited: `grep -rn "setArchiveAfterDays" WatchtowerDesktop/Sources/Views`)
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/WorktreeBadgePresentation.swift` (pure text)
- Test: `WatchtowerDesktop/Tests/Core/WorktreeBadgePresentationTests.swift`
- Modify: `docs/features/workbench.md` (new bullet), `CLAUDE.md` (append "session worktrees (2026-10-14 …)" to the Workbench feature line)

**Interfaces:**
- Consumes: Tasks 1, 7, 10, 11.
- Produces: `WorktreeBadgePresentation.badge(branch:) -> String` (`"⎇ " + middle-truncated to 24`), `.keptHelp` ("Uncommitted changes left in the worktree"), `.menuTitles` for the choices ("In This Folder", "In Its Own Worktree").

- [ ] **Step 1: Failing test** — `WorktreeBadgePresentationTests`: `badge(branch: "wt/229-parallel-sessions-in-worktrees")` is ≤ 26 characters, starts with `"⎇ wt/"`, contains `"…"`; short names unchanged.
- [ ] **Step 2:** `make test-swift FILTER=WorktreeBadgePresentationTests` → FAIL; implement; → PASS.
- [ ] **Step 3: Views**
  - Session row: when `worktreeBranch != nil && worktreeRemovedAt == nil`, a secondary-colour badge text; when `worktreeKept`, an orange dot with `.help(keptHelp)`.
  - Row context menu, before "Delete…": **Show Worktree in Finder** (`NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.folderPath)])`), **Open Terminal in Worktree** (`newStandalone(kind: .shell, folder: URL(fileURLWithPath: row.folderPath))`), **Remove Worktree** (`removeWorktree(row)`, disabled while the row is live). Shown only for worktree rows.
  - New session menu and Work on It: add a submenu or two items **In This Folder** / **In Its Own Worktree** passing `.folder` / `.worktree`; the plain button stays `.auto`.
  - Settings: a `TextField("Worktree setup command", …)` saved through `WorkbenchQueries.setWorktreeSetup` on commit, with the caption "Runs in a new session worktree before the agent starts. Ignored files to copy go in .worktreeinclude at the repository root."
  - The `startNotice` line above the sessions panel (same style as the existing session error line, dismissible).
- [ ] **Step 4: Docs** — `docs/features/workbench.md`: a "Session worktrees (2026-10-14, board #229, PROJ-17; spec/plan paths)" bullet covering §2–§10 of the spec in the file's dense style, the trust-prompt finding from Task 5 Step 5, and the v1 limits of spec §13. `CLAUDE.md`: append to the Workbench line "; session worktrees (2026-10-14, board #229: migration 00110, `workbench worktree create|ensure|remove`, `.worktreeinclude` clones, `SessionPlacement`, PROJ-17, PROJ-02/10 amended)".
- [ ] **Step 5:** `make test-swift FILTER='WorktreeBadgePresentationTests|WorkbenchesViewModelWorktreeTests'`, `make lint-diff` → clean.
- [ ] **Step 6: Commit** — `git commit -m "feat(desktop): worktree badge, menus and setup command field; docs"`.

---

### Task 13: Gate and manual check

**Depends on:** all.

- [ ] **Step 1:** `bash scripts/dev-health.sh`; if `HEALTH: overloaded`, stop and tell the owner.
- [ ] **Step 2:** `make test`, `make test-swift`, `make lint-all`, `go test -race ./internal/workbenchgit` — all to log files with explicit exit codes.
- [ ] **Step 3:** File a `kind: check` ask (target #229) with this checklist:
  1. Start one session on a workbench: it runs in the folder (no badge).
  2. Start a second while the first works: it shows `⎇ wt/…`, its terminal is in `.claude/worktrees/…`, `git status` in the main folder is clean.
  3. Add `.worktreeinclude` with a large ignored folder (e.g. `WatchtowerDesktop/.build/`) and a setup command; start a third: the folder appears instantly, the setup command runs once before the agent.
  4. In the worktree session, the board tools and the ask guard work (ask the agent to call `workbench_info`).
  5. Finish the worktree session without changes: its worktree and empty branch are gone.
  6. Finish one with a commit: worktree gone, branch stays; resume it: the worktree comes back with the commit.
  7. Leave an uncommitted edit and finish: the row shows the kept dot; the worktree stays.
  8. Switch the header branch while only worktree agents run: no agent-running confirmation.
  9. Repeat 2 with Codex as the agent.
- [ ] **Step 4:** Open the PR into main (local-review skill first, per the repo's flow).
