# Session Worktrees Implementation Plan (rev 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A second (and every further) concurrent agent session of a workbench starts in its own git worktree, prepared from `.worktreeinclude`, the workbench integration and an optional setup command; when the finished session's agent exits, #535's cleanup removes the worktree and branch if nothing can be lost.

**Architecture:** Go owns every git and install write: `internal/workbenchgit/worktree*.go` (create, include, ensure) behind `watchtower workbench worktree create|ensure|forget --json`, which also installs (or unregisters) the workbench integration through `devpack`. `internal/sessioncleanup` learns that a row's own placed worktree and `wt/` branch are the session's by record. The Desktop decides placement with a pure `SessionStartPlacement.decide` (WatchtowerCore) fed by #565's `SessionPlaceCenter`, calls the CLI before inserting the row (migration 00114 stores `worktree_branch`/`worktree_base`), runs the setup command on the first launch, re-adds a cleaned-up worktree on resume, and runs `SessionCleanupCenter.applyCleanup` for the two placed items when a finished placed session's agent exits.

**Tech Stack:** Go 1.25 (cobra, `database/sql` + modernc SQLite, goose migrations, `golang.org/x/sys/unix` for `clonefile`), SwiftUI + GRDB (WatchtowerCore / WatchtowerDesktop).

**Spec:** `docs/superpowers/specs/2026-10-14-session-worktrees-design.md` rev 2 (approved in ask #124; direction in ask #122). Board target #229. Builds on #565 (`docs/superpowers/specs/2026-10-12-session-worktree-design.md`) and #535 (`docs/superpowers/specs/2026-10-12-session-cleanup-design.md`), both on main.

## Global Constraints

- Worktree path: `<top_level>/.claude/worktrees/<slug>`; branch `wt/<slug>`; slug `^[a-z0-9][a-z0-9-]*$`, ≤ 40 characters, suffix `-2`, `-3`, … when the branch or path exists.
- Base = the main folder's `HEAD` commit (`git worktree add -b wt/<slug> <path> <base sha>`).
- Exclude line `/.claude/worktrees/` appended once to `<common_dir>/info/exclude`; the owner's lines are never rewritten.
- `.worktreeinclude`: `.gitignore` syntax at the repository root; a path is copied only if it matches **and** is ignored; `clonefile(2)`; the non-clone fallback copies at most 1 GiB in total.
- Placement code (create, ensure, forget) never runs `worktree remove`, `--force`, `branch -D`/`-d`, `reset`, `clean`, `checkout`, `stash`. Removal is only #535's `workbench cleanup` with every PROJ-18 catch.
- `devpack.RemoveWorkbench` is never called for a worktree path (it drops shared `info/exclude` lines).
- CLI: every git outcome is an exit-0 JSON envelope; non-zero only when the workbench/folder does not resolve. Write budget 60 s (`workbenchGitWriteBudget`).
- Migration `00114_terminal_session_placement.sql` (re-check the next free number before writing it): `terminal_sessions.worktree_branch TEXT`, `terminal_sessions.worktree_base TEXT`, `projects.worktree_setup TEXT NOT NULL DEFAULT ''`.
- A placed row stores the worktree cwd as its `folder_path` (spec D9); every other row keeps the workbench folder (#565's pinning tests stay green).
- Desktop never runs git itself for this feature; it calls the CLI (`WorkbenchCLI`, `SessionCleanupCenter`).
- Inner loop only per task (`go test ./internal/<pkg>`, `make test-swift FILTER=…`, `make lint-diff`); the full gate runs once at the end (CLAUDE.md). Never `run_in_background` for builds or tests.
- Tests that spawn processes reap them; git tests use `internal/workbenchgit/helpers_test.go`'s `newRepo`/`recorder`/`options` (owner's git config isolated).
- Docs and code comments in English; no live-install data in the repo.

## Review Focus

1. **The workbench folder is a subfolder of the repository** → the session starts in `<worktree>/<prefix>`, `.worktreeinclude` is read from the repository root, and cleanup's by-record ownership finds the worktree from that subfolder cwd. (Task 2 `TestWorktreeCreate_SubfolderWorkbench`, Task 6 `TestCleanupPlacedSubfolderRowOwnsItsWorktree`.)
2. **The main folder has uncommitted changes** → the new worktree does not have them, `base_dirty: true`, and the Desktop says so. (Task 2 `TestWorktreeCreate_BaseDirty`, Task 11 `testBaseDirtyShowsTheNote`.)
3. **The worktree was cleaned up or deleted by hand while the row remains** → resume re-adds it from the branch through `ensure`; with the branch gone too the row is unavailable with a clear message, never a silent start in the main folder. (Task 4 tests, Task 12 `testResumeOfACleanedUpWorktreeReAddsIt`, `testResumeWithTheBranchGoneIsUnavailable`.)
4. **Two sessions start at the same moment in an idle folder** → placement is serialised per workbench, so the second sees the first's row as live and gets a worktree. (Task 11 `testConcurrentStartsSecondGetsWorktree`.)
5. **The automatic cleanup touches only what Watchtower made** → it names exactly `worktree:<root>` and `branch:wt/<slug>`, and an unplaced worktree born before the session is still kept. (Task 6 `TestCleanupUnplacedOldWorktreeStillKept`, Task 13 `testFinishedPlacedSessionExitCleansExactlyItsTwoItems`.)

## Task order and lanes

Go lane: 1 → 2 → 3 → 4 → 5 → 6 → 7. Swift lane (after 1 and 5): 8 → 9 → 10 → 11 → 12 → 13 → 14. One implementer at a time (this plan runs sequentially). Task 15 is the gate.

---

### Task 1: Migration 00114 and the Go/Swift row fields

**Depends on:** none.

**Files:**
- Create: `internal/db/migrations/00114_terminal_session_placement.sql`
- Modify: `internal/db/schema.sql` (`terminal_sessions`, `projects`)
- Modify: `internal/db/terminal_sessions.go` (`TerminalSession.WorktreeBranch`, `GetTerminalSession`'s SELECT/Scan; new `PlacedSessions`)
- Test: `internal/db/terminal_sessions_placement_test.go`
- Regenerate: schema golden + `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Models/TerminalSession.swift`, `.../Models/Workbench.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/TerminalSessionQueries.swift` (`NewSession`, `create`), `.../Queries/WorkbenchQueries.swift` (new `setWorktreeSetup`)
- Test: `WatchtowerDesktop/Tests/Core/TerminalSessionPlacementQueriesTests.swift`

**Interfaces:**
- Produces (Go): `TerminalSession.WorktreeBranch sql.NullString` (read by `GetTerminalSession`); `type PlacedSession struct{ ID int64; FolderPath, Branch string }`; `func (db *DB) PlacedSessions(workbenchID int64) ([]PlacedSession, error)` — rows of the workbench with `worktree_branch IS NOT NULL`, by id. (`db.SessionWorktree` already exists — #535's ledger type; do not reuse the name.)
- Produces (Swift): `TerminalSession.worktreeBranch: String?`, `.worktreeBase: String?` (CodingKeys `worktree_branch`, `worktree_base`); `NewSession.worktreeBranch: String?`, `.worktreeBase: String?` (init params, default nil, after `claudeSessionID`); `Workbench.worktreeSetup: String`; `WorkbenchQueries.setWorktreeSetup(_ db: Database, projectID: Int64, command: String) throws`.

- [ ] **Step 1: Write the migration**

Check `ls internal/db/migrations | tail -1` first; if 00114 is taken, use the next free number everywhere in this plan.

```sql
-- +goose Up
-- Session placement (board #229, spec 2026-10-14-session-worktrees-design.md §7).
-- worktree_branch non-NULL = Watchtower created the worktree this row's
-- folder_path is in, on this wt/<slug> branch; #535's cleanup owns that
-- worktree and branch by record. NULL = every other row.
ALTER TABLE terminal_sessions ADD COLUMN worktree_branch TEXT;
-- The commit the branch was cut from; NULL with worktree_branch.
ALTER TABLE terminal_sessions ADD COLUMN worktree_base TEXT;
-- The command run in a new session worktree before the agent's first launch; '' = none.
ALTER TABLE projects ADD COLUMN worktree_setup TEXT NOT NULL DEFAULT '';

-- +goose Down
ALTER TABLE projects DROP COLUMN worktree_setup;
ALTER TABLE terminal_sessions DROP COLUMN worktree_base;
ALTER TABLE terminal_sessions DROP COLUMN worktree_branch;
```

Mirror the three columns, with the same comments, into `internal/db/schema.sql` (end of each table's column list, before any table-level `CHECK` lines).

- [ ] **Step 2: Write the failing Go test**

```go
package db

func TestPlacedSessions_ListsRowsWithAWorktreeBranch(t *testing.T) {
	d := openTestDB(t)
	wb := createTestWorkbench(t, d, t.TempDir())
	plain := insertTerminalSession(t, d, wb.ID, "/repo")
	placed := insertTerminalSession(t, d, wb.ID, "/repo/.claude/worktrees/a")
	_, err := d.Exec(`UPDATE terminal_sessions SET worktree_branch = 'wt/a', worktree_base = 'abc' WHERE id = ?`, placed)
	require.NoError(t, err)

	got, err := d.PlacedSessions(wb.ID)
	require.NoError(t, err)
	assert.Equal(t, []PlacedSession{{ID: placed, FolderPath: "/repo/.claude/worktrees/a", Branch: "wt/a"}}, got)

	row, err := d.GetTerminalSession(placed)
	require.NoError(t, err)
	assert.Equal(t, "wt/a", row.WorktreeBranch.String)
	other, err := d.GetTerminalSession(plain)
	require.NoError(t, err)
	assert.False(t, other.WorktreeBranch.Valid)
}
```

Read `internal/db/terminal_sessions_test.go` first and use its existing helpers for opening a DB, creating a workbench and inserting a session row; rename `openTestDB`/`createTestWorkbench`/`insertTerminalSession` above to those names. Add no second helper for something that exists.

- [ ] **Step 3: Run it to see it fail**

Run: `go test ./internal/db -run TestPlacedSessions`
Expected: FAIL — `d.PlacedSessions undefined`.

- [ ] **Step 4: Implement**

In `internal/db/terminal_sessions.go` add `WorktreeBranch sql.NullString` to `TerminalSession` (after `TranscriptPath`), extend `GetTerminalSession`'s column list and `Scan` with `worktree_branch`, and add:

```go
// PlacedSession is a session row Watchtower started in a worktree it
// created (board #229): folder_path is the agent's cwd inside it.
type PlacedSession struct {
	ID         int64
	FolderPath string
	Branch     string
}

// PlacedSessions lists the workbench's placed session rows, by id.
func (db *DB) PlacedSessions(workbenchID int64) ([]PlacedSession, error) {
	rows, err := db.Query(`SELECT id, folder_path, worktree_branch FROM terminal_sessions
		WHERE project_id = ? AND worktree_branch IS NOT NULL ORDER BY id`, workbenchID)
	if err != nil {
		return nil, fmt.Errorf("listing placed sessions: %w", err)
	}
	defer rows.Close()
	var out []PlacedSession
	for rows.Next() {
		var s PlacedSession
		if err := rows.Scan(&s.ID, &s.FolderPath, &s.Branch); err != nil {
			return nil, fmt.Errorf("listing placed sessions: %w", err)
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

`WatchtowerDesktop/Tests/Core/TerminalSessionPlacementQueriesTests.swift`:

```swift
import GRDB
import XCTest
@testable import WatchtowerCore

final class TerminalSessionPlacementQueriesTests: XCTestCase {
    func testCreateStoresTheWorktreeBranchAndBase() throws {
        let db = try TestDatabase.make()
        let projectID = try TestDatabase.insertWorkbench(db, folder: "/repo")
        let row = try db.write { db in
            try TerminalSessionQueries.create(db, .init(
                projectID: projectID, kind: .claude, title: "t", folderPath: "/repo/.claude/worktrees/a",
                claudeSessionID: UUID().uuidString, worktreeBranch: "wt/a", worktreeBase: "abc1234"))
        }
        XCTAssertEqual(row.worktreeBranch, "wt/a")
        XCTAssertEqual(row.worktreeBase, "abc1234")
        let plain = try db.write { db in
            try TerminalSessionQueries.create(db, .init(
                projectID: projectID, kind: .claude, title: "p", folderPath: "/repo", claudeSessionID: UUID().uuidString))
        }
        XCTAssertNil(plain.worktreeBranch)
    }

    func testWorktreeSetupRoundTripsTrimmed() throws {
        let db = try TestDatabase.make()
        let projectID = try TestDatabase.insertWorkbench(db, folder: "/repo")
        try db.write { try WorkbenchQueries.setWorktreeSetup($0, projectID: projectID, command: "  npm install \n") }
        XCTAssertEqual(try db.read { try WorkbenchQueries.fetch($0, id: projectID) }?.worktreeSetup, "npm install")
    }
}
```

Read `WatchtowerDesktop/Tests/Support/` and an existing `Tests/Core` queries test first; use the `TestDatabase` helper names that exist (rename `make`/`insertWorkbench`/`fetch` above accordingly).

Run: `make test-swift FILTER=TerminalSessionPlacementQueriesTests` → FAIL (no such members).

Implement: `TerminalSession` gains `package let worktreeBranch: String?` and `package let worktreeBase: String?` with CodingKeys `worktree_branch`/`worktree_base` (synthesised Codable decodes a missing optional as nil; keep any memberwise init callers compiling by giving the new parameters `= nil` defaults if the type has an explicit init). `NewSession` gains the two fields (init params default nil) and `create`'s `INSERT` lists `worktree_branch, worktree_base`. `Workbench.worktreeSetup = row["worktree_setup"] ?? ""`. `WorkbenchQueries.setWorktreeSetup` mirrors `setArchiveAfterDays` (same `updated_at` write and `workbenchNotFound` guard), storing `command.trimmingCharacters(in: .whitespacesAndNewlines)`.

Run: `make test-swift FILTER=TerminalSessionPlacementQueriesTests` → PASS.

- [ ] **Step 7: Commit**

```bash
git add internal/db WatchtowerDesktop/Sources/WatchtowerCore WatchtowerDesktop/Tests
git commit -m "feat(db): session placement columns (migration 00114)"
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

### Task 4: `EnsureWorktree` and the placement argv guard

**Depends on:** Task 3.

**Files:**
- Modify: `internal/workbenchgit/worktree.go`
- Test: `internal/workbenchgit/worktree_ensure_test.go`

**Interfaces:**
- Produces: `func EnsureWorktree(ctx context.Context, o Options, path, branch string) WorktreeResult` — `o.Folder` is the **main** workbench folder; `path` is the worktree's top level (`<top>/.claude/worktrees/<slug>`); an existing directory at `path` is left alone (`Created: false`, no error); a missing branch is `RefusedUnknownBranch` (the constant `switch.go` already has); a `path` outside `<top>/.claude/worktrees/` or a branch not under `wt/` is `RefusedInvalidName`.

- [ ] **Step 1: Write the failing tests**

```go
func made(t *testing.T, dir string) WorktreeResult {
	res := CreateWorktree(context.Background(), options(dir, &recorder{}), WorktreeRequest{Slug: "r"})
	require.True(t, res.Created, "%+v", res)
	return res
}

// dropWorktree removes a worktree the way a cleanup would, for the test only.
func dropWorktree(t *testing.T, dir string, wt WorktreeResult) {
	gitIn(t, dir, "worktree", "remove", wt.Path)
}

func TestWorktreeEnsure_RecreatesFromBranch(t *testing.T) {
	dir := newRepo(t)
	wt := made(t, dir)
	commit(t, wt.Path, "work.txt", "done\n", "work")
	dropWorktree(t, dir, wt)
	res := EnsureWorktree(context.Background(), options(dir, &recorder{}), wt.Path, wt.Branch)
	require.True(t, res.Created, "%+v", res)
	assert.Equal(t, "done\n", readFile(t, wt.Path, "work.txt"))
	again := EnsureWorktree(context.Background(), options(dir, &recorder{}), wt.Path, wt.Branch)
	assert.False(t, again.Created, "an existing worktree is left alone")
	assert.Empty(t, again.Error)
}

func TestWorktreeEnsure_DeletedByHandIsReAdded(t *testing.T) {
	dir := newRepo(t)
	wt := made(t, dir)
	require.NoError(t, os.RemoveAll(wt.Path))
	res := EnsureWorktree(context.Background(), options(dir, &recorder{}), wt.Path, wt.Branch)
	require.True(t, res.Created, "%+v", res)
	assert.Equal(t, wt.Branch, gitIn(t, wt.Path, "branch", "--show-current"))
}

func TestWorktreeEnsure_CopiesIncludePathsAgain(t *testing.T) {
	dir := includeRepo(t)
	wt := made(t, dir)
	dropWorktree(t, dir, wt)
	res := EnsureWorktree(context.Background(), options(dir, &recorder{}), wt.Path, wt.Branch)
	assert.ElementsMatch(t, []string{".env", "node_modules/"}, res.Included)
}

func TestWorktreeEnsure_BranchGone(t *testing.T) {
	dir := newRepo(t)
	res := EnsureWorktree(context.Background(), options(dir, &recorder{}), filepath.Join(dir, ".claude", "worktrees", "z"), "wt/z")
	assert.Equal(t, RefusedUnknownBranch, res.Refused)
	assert.NoDirExists(t, filepath.Join(dir, ".claude", "worktrees", "z"))
}

func TestWorktreeEnsure_RefusesPathsOutsideTheWorktreesDir(t *testing.T) {
	dir := newRepo(t)
	gitIn(t, dir, "branch", "wt/q")
	for _, p := range []string{dir, filepath.Join(dir, "elsewhere"), filepath.Join(dir, ".claude", "worktrees")} {
		res := EnsureWorktree(context.Background(), options(dir, &recorder{}), p, "wt/q")
		assert.Equal(t, RefusedInvalidName, res.Refused, p)
	}
	assert.Equal(t, RefusedInvalidName, EnsureWorktree(context.Background(), options(dir, &recorder{}),
		filepath.Join(dir, ".claude", "worktrees", "q"), "main").Refused)
}

func TestProj18_PlacementNeverForcesOrDiscards(t *testing.T) {
	dir := includeRepo(t)
	rec := &recorder{}
	o := options(dir, rec)
	ctx := context.Background()
	a := CreateWorktree(ctx, o, WorktreeRequest{Slug: "a"})
	b := CreateWorktree(ctx, o, WorktreeRequest{Slug: "b"})
	writeFile(t, b.Path, "README.md", "x\n")
	require.NoError(t, os.RemoveAll(a.Path))
	EnsureWorktree(ctx, o, a.Path, a.Branch)
	EnsureWorktree(ctx, o, b.Path, b.Branch)

	forbidden := []string{"remove", "--force", "-f", "-D", "-d", "--hard", "reset", "clean", "checkout", "stash", "--discard-changes"}
	require.NotEmpty(t, rec.argv())
	for _, c := range rec.argv() {
		for _, arg := range c {
			assert.NotContains(t, forbidden, arg, "git %s", strings.Join(c, " "))
		}
	}
	assert.Equal(t, "x\n", readFile(t, b.Path, "README.md"), "an existing worktree's changes are untouched")
}
```

`TestProj18_PlacementNeverForcesOrDiscards` is a PROJ-18 guard (Task 7 lists it in the inventory). `-d` is forbidden because `worktree add -b` is the only branch write; check the recorder's argv shape (`helpers_test.go`) — if it records `-b` and the branch name as separate elements, the list above is right as written.

- [ ] **Step 2: Run them to see them fail**

Run: `go test ./internal/workbenchgit -run 'TestWorktreeEnsure|TestProj18'`
Expected: FAIL — `undefined: EnsureWorktree`.

- [ ] **Step 3: Implement (append to `worktree.go`)**

```go
// EnsureWorktree puts a placed session's worktree back at path from its
// branch — a resume after #535's cleanup removed it, or after the owner
// deleted the directory (spec §7) — and copies the include paths again. An
// existing directory at path is left alone (Created false, no error); a
// missing branch is RefusedUnknownBranch. It writes nothing but the new
// worktree: no remove, prune of other entries, reset or checkout.
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
	root := filepath.Join(st.TopLevel, filepath.FromSlash(worktreesDir))
	if filepath.Dir(filepath.Clean(path)) != root || !strings.HasPrefix(branch, worktreeBranchRoot) {
		res.Refused, res.RefusedDetail = RefusedInvalidName, "not a session worktree: "+path
		return res
	}
	if _, err := os.Lstat(path); err == nil {
		return res
	}
	if _, code, err := r.run(ctx, "show-ref", "--verify", "--quiet", "refs/heads/"+branch); code == 1 {
		res.Refused, res.RefusedDetail = RefusedUnknownBranch, branch
		return res
	} else if err != nil {
		res.Refused, res.Error = RefusedGitFailed, gitError(err)
		return res
	}
	// A directory deleted by hand leaves its admin entry: `worktree add`
	// refuses a registered path, and --force is never used, so the stale
	// entry goes first — `worktree prune` drops only entries whose directory
	// is gone, never a worktree on disk.
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

`EnsureWorktree` leaves `Cwd` empty: the Desktop keeps the row's stored `folder_path`. (Note `worktree prune` is not on the forbidden list; #535 §4 avoids it because a prune drops *every* prunable entry — here that is acceptable only because every such entry's directory is already gone and nothing on disk is touched. Say so in the code comment as written.)

- [ ] **Step 4: Run the tests**

Run: `go test ./internal/workbenchgit`
Expected: PASS (all, including PROJ-10's).

- [ ] **Step 5: Commit**

```bash
git add internal/workbenchgit
git commit -m "feat(workbenchgit): ensure — re-add a placed session's worktree from its branch"
```

---

### Task 5: `watchtower workbench worktree create|ensure|forget` with the integration

**Depends on:** Task 4.

**Files:**
- Create: `cmd/workbench_worktree.go`
- Test: `cmd/workbench_worktree_test.go`
- Modify: `internal/devpack/workbench.go` (export `UnregisterWorkbenchMCP`)
- Test: `internal/devpack/workbench_test.go` (one test for the export)

**Interfaces:**
- Consumes: `workbenchgit.CreateWorktree/EnsureWorktree`, `workbenchgit.ReadStatus`; in `cmd/`: `workbenchGitTarget`, `workbenchGitContext`, `workbenchGitWriteBudget`, `workbenchGitFlagWorkbench`, `workbenchGitFlagJSON`, `writeJSON`, `addWorkbenchIDFlag`, `workbenchInstallOptions(p *db.Workbench)` (`cmd/integrate_workbench.go:52`, reads only `ID` and `FolderPath`), `devpack.InstallWorkbench` (already installs #535's cleanup permission), `devpack.InstallCodex`, `devpack.CodexFound`, `codexFindBinary`, `codexAppServerFor`.
- Produces: `func UnregisterWorkbenchMCP(ctx context.Context, o WorkbenchInstallOptions) error` (devpack). CLI (all `--json`):
  - `workbench worktree create --workbench N --name <slug>` → `WorktreeResult` + `"integration_error": string`
  - `workbench worktree ensure --workbench N --path P --branch B` → `WorktreeResult` + `"cwd"` (filled when re-added) + `"integration_error"`
  - `workbench worktree forget --workbench N --path P` → `{"workbench_id", "forgot": bool, "error": string}` — runs only `claude mcp remove --scope local` for P's session cwd, no git; P must be under the workbench repository's `.claude/worktrees/`, else `error` and nothing run.

- [ ] **Step 1: Write the failing tests**

```go
func TestWorkbenchWorktree_CreateInstallsTheIntegration(t *testing.T) {
	folder := newGitWorkbenchFolder(t)
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
	assert.Empty(t, created.IntegrationError)
	assert.FileExists(t, filepath.Join(created.Cwd, ".claude", "settings.local.json"), "hooks and the cleanup permission installed in the worktree")
	assert.DirExists(t, filepath.Join(created.Cwd, ".claude", "skills", "watchtower-workbench"))
	assert.Contains(t, strings.Join(calls, "\n"), created.Cwd+" :: claude mcp add --scope local watchtower-workbench")
}

func TestWorkbenchWorktree_EnsureReinstallsAndReportsTheCwd(t *testing.T) {
	folder := newGitWorkbenchFolder(t)
	id := createTestWorkbenchRow(t, folder)
	stubWorkbenchCommandRunner(t, nil)
	var c workbenchgit.WorktreeResult
	require.NoError(t, json.Unmarshal(runCmd(t, "workbench", "worktree", "create", "--workbench", fmt.Sprint(id), "--name", "s2", "--json"), &c))
	require.NoError(t, os.RemoveAll(c.Path))

	out := runCmd(t, "workbench", "worktree", "ensure", "--workbench", fmt.Sprint(id), "--path", c.Path, "--branch", c.Branch, "--json")
	var e workbenchgit.WorktreeResult
	require.NoError(t, json.Unmarshal(out, &e))
	require.True(t, e.Created, "%s", out)
	assert.Equal(t, c.Cwd, e.Cwd)
	assert.FileExists(t, filepath.Join(c.Cwd, ".claude", "settings.local.json"))
}

func TestWorkbenchWorktree_ForgetUnregistersOnlyAndKeepsSharedExcludeLines(t *testing.T) {
	folder := newGitWorkbenchFolder(t)
	id := createTestWorkbenchRow(t, folder)
	var calls []string
	stubWorkbenchCommandRunner(t, func(dir, name string, args ...string) {
		calls = append(calls, dir+" :: "+name+" "+strings.Join(args, " "))
	})
	runCmd(t, "integrate", "claude-code", "--workbench", fmt.Sprint(id)) // the main folder's own install
	before := readExclude(t, folder)
	var c workbenchgit.WorktreeResult
	require.NoError(t, json.Unmarshal(runCmd(t, "workbench", "worktree", "create", "--workbench", fmt.Sprint(id), "--name", "s3", "--json"), &c))
	calls = nil

	out := runCmd(t, "workbench", "worktree", "forget", "--workbench", fmt.Sprint(id), "--path", c.Path, "--json")
	assert.Contains(t, string(out), `"forgot": true`)
	joined := strings.Join(calls, "\n")
	assert.Contains(t, joined, c.Cwd+" :: claude mcp remove --scope local watchtower-workbench")
	assert.NotContains(t, joined, ":: git ", "forget runs no git")
	assert.DirExists(t, c.Path, "forget never removes the worktree")
	after := readExclude(t, folder)
	for _, line := range strings.Split(strings.TrimSpace(before), "\n") {
		assert.Contains(t, after, line, "a line the main folder needs survives")
	}
}

func TestWorkbenchWorktree_ForgetRefusesAPathOutsideTheWorktreesDir(t *testing.T) {
	folder := newGitWorkbenchFolder(t)
	id := createTestWorkbenchRow(t, folder)
	var calls []string
	stubWorkbenchCommandRunner(t, func(dir, name string, args ...string) { calls = append(calls, name) })
	out := runCmd(t, "workbench", "worktree", "forget", "--workbench", fmt.Sprint(id), "--path", folder, "--json")
	assert.Contains(t, string(out), `"forgot": false`)
	assert.Empty(t, calls)
}

func TestWorkbenchWorktree_UnknownWorkbenchExitsNonZero(t *testing.T) {
	_, err := runCmdErr(t, "workbench", "worktree", "create", "--workbench", "999", "--name", "x", "--json")
	require.Error(t, err)
}
```

Before writing these, read `cmd/workbench_git_test.go` and `cmd/integrate_workbench_test.go` and use **their** helper names for: a git workbench folder, inserting the workbench row, running a command and capturing stdout (and the error form), stubbing `workbenchCommandRunner` (the claude CLI) and `workbenchExecutable`. Rename `newGitWorkbenchFolder` / `createTestWorkbenchRow` / `runCmd` / `runCmdErr` / `stubWorkbenchCommandRunner` / `readExclude` above to those names; add only helpers that do not exist (`readExclude` reads `<folder>/.git/info/exclude`). Whether `workbenchCommandRunner` also sees git calls depends on the stub — if git does not go through it, drop the `NotContains(":: git ")` line and instead assert `forget` does not reach `workbenchgit` (it calls no `workbenchgit` function except `ReadStatus` for the top level; see Step 4).

- [ ] **Step 2: Run them to see them fail**

Run: `go test ./cmd -run TestWorkbenchWorktree`
Expected: FAIL — unknown command "worktree".

- [ ] **Step 3: Export the MCP unregistration (devpack)**

In `internal/devpack/workbench.go`, next to `unregisterWorkbenchMCP`:

```go
// UnregisterWorkbenchMCP removes the folder's local registration of the
// workbench MCP server. A removed session worktree uses it instead of
// RemoveWorkbench: the worktree's files went with the worktree, and
// RemoveWorkbench would also drop exclude lines that every worktree of the
// repository shares (info/exclude lives in the common git dir).
func UnregisterWorkbenchMCP(ctx context.Context, o WorkbenchInstallOptions) error {
	if err := o.validate(); err != nil {
		return err
	}
	return unregisterWorkbenchMCP(ctx, o)
}
```

If `o.validate` does not exist under that name, use what `RemoveWorkbench` checks first. Test in `internal/devpack/workbench_test.go` with that file's fake runner: after `InstallWorkbench`, `UnregisterWorkbenchMCP` issues `claude mcp remove --scope local watchtower-workbench` in `o.Folder` and leaves `settings.local.json` and the exclude block untouched. Run `go test ./internal/devpack -run UnregisterWorkbenchMCP` → PASS.

- [ ] **Step 4: Implement `cmd/workbench_worktree.go`**

```go
package cmd

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"strings"

	"github.com/spf13/cobra"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/devpack"
	"watchtower/internal/workbenchgit"
)

var workbenchWorktreeCmd = &cobra.Command{
	Use:   "worktree",
	Short: "Create and restore session worktrees (parallel agent sessions)",
	Long: "A session worktree is <repository>/.claude/worktrees/<name> on branch wt/<name>,\n" +
		"cut from the workbench folder's HEAD, with the .worktreeinclude paths cloned in and\n" +
		"the workbench integration installed. Removal is `workbench cleanup` (PROJ-18); forget\n" +
		"only unregisters a removed worktree's MCP entry. Every command exits 0 once the\n" +
		"workbench and its folder resolve.",
}

var (
	workbenchWorktreeFlagName   string
	workbenchWorktreeFlagPath   string
	workbenchWorktreeFlagBranch string
)

func init() {
	create := &cobra.Command{Use: "create", Short: "Create a session worktree", Args: cobra.NoArgs, RunE: runWorkbenchWorktreeCreate}
	ensure := &cobra.Command{Use: "ensure", Short: "Put a removed session worktree back from its branch", Args: cobra.NoArgs, RunE: runWorkbenchWorktreeEnsure}
	forget := &cobra.Command{Use: "forget", Short: "Unregister a removed session worktree's MCP entry (no git)", Args: cobra.NoArgs, RunE: runWorkbenchWorktreeForget}
	for _, c := range []*cobra.Command{create, ensure, forget} {
		addWorkbenchIDFlag(c, &workbenchGitFlagWorkbench, "workbench id")
		c.Flags().BoolVar(&workbenchGitFlagJSON, "json", false, "output JSON")
		workbenchWorktreeCmd.AddCommand(c)
	}
	create.Flags().StringVar(&workbenchWorktreeFlagName, "name", "", "the worktree's name (lowercase letters, digits, dashes)")
	for _, c := range []*cobra.Command{ensure, forget} {
		c.Flags().StringVar(&workbenchWorktreeFlagPath, "path", "", "the worktree's top level")
	}
	ensure.Flags().StringVar(&workbenchWorktreeFlagBranch, "branch", "", "its wt/… branch")
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
	return writeWorktreeEnvelope(ctx, cmd, id, res)
}

func runWorkbenchWorktreeEnsure(cmd *cobra.Command, _ []string) error {
	id, o, err := workbenchGitTarget(cmd)
	if err != nil {
		return err
	}
	ctx, cancel := workbenchGitContext(cmd, workbenchGitWriteBudget)
	defer cancel()
	res := workbenchgit.EnsureWorktree(ctx, o, workbenchWorktreeFlagPath, workbenchWorktreeFlagBranch)
	if res.Created {
		res.Cwd = sessionCwdIn(ctx, o, res.Path)
	}
	return writeWorktreeEnvelope(ctx, cmd, id, res)
}

type worktreeForgetResult struct {
	WorkbenchID int64  `json:"workbench_id"`
	Forgot      bool   `json:"forgot"`
	Error       string `json:"error"`
}

func runWorkbenchWorktreeForget(cmd *cobra.Command, _ []string) error {
	id, o, err := workbenchGitTarget(cmd)
	if err != nil {
		return err
	}
	ctx, cancel := workbenchGitContext(cmd, workbenchGitWriteBudget)
	defer cancel()
	res := worktreeForgetResult{WorkbenchID: id}
	top := workbenchgit.ReadStatus(ctx, o).TopLevel
	root := filepath.Join(top, ".claude", "worktrees")
	if top == "" || filepath.Dir(filepath.Clean(workbenchWorktreeFlagPath)) != root {
		res.Error = "not a session worktree: " + workbenchWorktreeFlagPath
		return writeJSON(cmd.OutOrStdout(), res)
	}
	opts, err := workbenchInstallOptions(&db.Workbench{ID: id, FolderPath: sessionCwdIn(ctx, o, workbenchWorktreeFlagPath)})
	if err == nil {
		err = devpack.UnregisterWorkbenchMCP(ctx, opts)
	}
	if err != nil {
		res.Error = err.Error()
	} else {
		res.Forgot = true
	}
	return writeJSON(cmd.OutOrStdout(), res)
}

// sessionCwdIn is the worktree top joined with the main folder's path below
// its own top level (a workbench bound to a repository subfolder).
func sessionCwdIn(ctx context.Context, main workbenchgit.Options, worktreeTop string) string {
	top := workbenchgit.ReadStatus(ctx, main).TopLevel
	rel, err := filepath.Rel(top, main.Folder)
	if top == "" || err != nil || rel == "." || strings.HasPrefix(rel, "..") {
		return worktreeTop
	}
	return filepath.Join(worktreeTop, rel)
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

func writeWorktreeEnvelope(ctx context.Context, cmd *cobra.Command, id int64, res workbenchgit.WorktreeResult) error {
	res.WorkbenchID = id
	env := worktreeEnvelope{WorktreeResult: res}
	if res.Created && res.Cwd != "" {
		if err := installWorktreeIntegration(ctx, id, res.Cwd); err != nil {
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

Check the real names of `config.Load`, `flagConfig`, `devpack.CodexFound`, `codexFindBinary`, `codexAppServerFor` against how `cmd/integrate_workbench.go` installs Codex today and copy that call shape exactly; the above is the intent. `forget` uses `ReadStatus` only to read the top level (no write); it must not touch `workbenchgit` beyond that.

- [ ] **Step 5: Trust prompt spike (spec §8 open item)**

Manually, once: `go build -o "$TMPDIR/wt" . && "$TMPDIR/wt" workbench worktree create --workbench <a scratch workbench on a scratch repo> --name trust --json`, then run `claude` in the printed `cwd` from a terminal. Record in the ledger (and later in `docs/features/workbench.md`, Task 14) whether Claude Code shows its folder-trust prompt. Do **not** write `~/.claude.json` to suppress it: if it appears it is a documented v1 limit. Clean up with `git worktree remove` in the scratch repo and `"$TMPDIR/wt" workbench worktree forget …`.

- [ ] **Step 6: Run the tests**

Run: `go test ./cmd -run TestWorkbenchWorktree && go test ./internal/devpack`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add cmd/workbench_worktree.go cmd/workbench_worktree_test.go internal/devpack
git commit -m "feat(cmd): workbench worktree create|ensure|forget with the workbench integration"
```

---

### Task 6: Cleanup owns a placed row's worktree and branch by record (PROJ-18)

**Depends on:** Task 1.

**Files:**
- Modify: `internal/sessioncleanup/deps.go` (`SessionInfo`), `internal/sessioncleanup/store.go` (`DBStore.CleanupSession`), `internal/sessioncleanup/ownership.go`, `internal/sessioncleanup/catches.go` (`catchOwnWorktree`, `catchOwnBranch`), `internal/sessioncleanup/plan.go` (`listsWorktree`, `branchCandidates` if they filter by `sawWorktree`/`branches`)
- Test: `internal/sessioncleanup/placed_test.go`
- Modify: `docs/inventory/workbench.md` (PROJ-18 amendment)

**Interfaces:**
- Consumes: `db.TerminalSession.WorktreeBranch`, `.FolderPath` (Task 1).
- Produces: `SessionInfo` gains `PlacedCwd string` (the row's `folder_path` when `worktree_branch` is set, else "") and `PlacedBranch string`; `observed` gains `placedCwd`, `placedBranch` (resolved like other roots); `func (o observed) placedWorktree(w worktree, all []worktree) bool` — `w` is the longest listed linked worktree root containing `placedCwd`.

Read `ownership.go`, `catches.go` (`catchOwnWorktree` ~l.102, `catchOwnBranch` ~l.293), `plan.go` (`loadSession` ~l.132, `loadObserved` ~l.226, `listsWorktree` ~l.272, `branchCandidates` ~l.367) and `plan_test.go` (`WorktreeOlderThanTheSessionIsKept` ~l.111 — its fixture builder is the model for the new tests) before starting.

- [ ] **Step 1: Write the failing tests**

```go
// A placed row: Watchtower created the worktree and its wt/ branch before
// inserting the row, so both are born before created_at; by record they are
// the session's anyway (spec §9). Every other catch still runs.
func TestCleanupPlacedRowOwnsItsWorktreeAndBranch(t *testing.T) {
	fx := newFixture(t)                                   // the plan_test.go fixture builder
	wt := fx.addWorktree("wt/p", ".claude/worktrees/p")   // born now
	fx.pushBranch("wt/p")                                 // so W7/B4 do not keep it
	s := fx.newSessionAfter(time.Minute, sessionPlaced(wt.Root, "wt/p")) // row created after the worktree
	plan := fx.plan(s)
	assert.Equal(t, "remove", plan.item("worktree:"+wt.Root).Action, plan.item("worktree:"+wt.Root).Reason)
	assert.Equal(t, "remove", plan.item("branch:wt/p").Action)
}

func TestCleanupPlacedSubfolderRowOwnsItsWorktree(t *testing.T) {
	fx := newFixture(t)
	wt := fx.addWorktree("wt/s", ".claude/worktrees/s")
	fx.pushBranch("wt/s")
	s := fx.newSessionAfter(time.Minute, sessionPlaced(filepath.Join(wt.Root, "app", "web"), "wt/s"))
	assert.Equal(t, "remove", fx.plan(s).item("worktree:"+wt.Root).Action)
}

func TestCleanupPlacedRowStillKeepsUncommittedWork(t *testing.T) {
	fx := newFixture(t)
	wt := fx.addWorktree("wt/d", ".claude/worktrees/d")
	fx.pushBranch("wt/d")
	fx.writeFile(wt.Root, "README.md", "edited\n")
	s := fx.newSessionAfter(time.Minute, sessionPlaced(wt.Root, "wt/d"))
	it := fx.plan(s).item("worktree:" + wt.Root)
	assert.Equal(t, "keep", it.Action)
	assert.Equal(t, ReasonUncommittedChanges, it.Reason)
}

func TestCleanupUnplacedOldWorktreeStillKept(t *testing.T) {
	fx := newFixture(t)
	wt := fx.addWorktree("wt/o", ".claude/worktrees/o")
	fx.pushBranch("wt/o")
	other := fx.addWorktree("wt/p2", ".claude/worktrees/p2")
	s := fx.newSessionAfter(time.Minute, sessionPlaced(other.Root, "wt/p2"), sessionObserved(wt.Root, "wt/o"))
	assert.Equal(t, ReasonExistedBeforeSession, fx.plan(s).item("worktree:"+wt.Root).Reason,
		"by-record ownership covers only the row's own placed worktree")
}
```

These names (`newFixture`, `addWorktree`, `pushBranch`, `newSessionAfter`, `sessionPlaced`, `sessionObserved`, `plan`, `item`, `writeFile`, `ReasonUncommittedChanges`) are the intent: map each onto what `plan_test.go`/`helpers_test.go` already provide (the fake `Store`, the clock, the repo builder, the reason constant names in `catches.go`), and add only the two option helpers (`sessionPlaced` sets `SessionInfo.PlacedCwd/PlacedBranch` on the fake store's session) that do not exist.

- [ ] **Step 2: Run them to see them fail**

Run: `go test ./internal/sessioncleanup -run 'TestCleanupPlaced|TestCleanupUnplaced'`
Expected: FAIL — the placed items are kept `existed_before_session` (or the fields are undefined).

- [ ] **Step 3: Implement**

- `SessionInfo` gains `PlacedCwd, PlacedBranch string`. `DBStore.CleanupSession` fills them from `GetTerminalSession`: when `row.WorktreeBranch.Valid`, `PlacedCwd = row.FolderPath`, `PlacedBranch = row.WorktreeBranch.String`.
- `observe` (or `loadObserved` right after it) records the placed pair: `placedCwd = resolvePath(PlacedCwd)` (empty stays empty), `placedBranch`. The placed root also counts as seen (`roots[...]`) once found, and the placed branch as seen (`branches[...]`), so `listsWorktree`/`branchCandidates` list them.
- `placedWorktree(w, all)`: `placedCwd != ""`, `w` is a linked worktree (never the main one — W1 runs first anyway), `within(placedCwd, w.Root)`, and no other listed worktree root containing `placedCwd` is longer than `w.Root` (reuse `longestContaining`/`within` from `internal/workbenchgit/folder.go` if exported, else a local helper with the same rule).
- `catchOwnWorktree`: if `b.seen.placedWorktree(w, b.worktrees)` → return no catch (skip both the seen check and `bornReason`). `catchOwnBranch`: if `br.Name == b.seen.placedBranch` → no catch. Every other catch is unchanged and still runs.
- Doc comment on `placedWorktree`: "Watchtower created this worktree and branch for this row (board #229); by record they are the session's, although born before the row (spec 2026-10-14-session-worktrees-design.md §9)."

- [ ] **Step 4: Run the package**

Run: `go test ./internal/sessioncleanup && go test ./cmd -run TestWorkbenchCleanup`
Expected: PASS (all existing PROJ-18 guards unchanged).

- [ ] **Step 5: Amend PROJ-18 in the inventory**

In `docs/inventory/workbench.md`, PROJ-18 (`## PROJ-18 — session cleanup never removes …`): add to **Observable**, after the ownership rule, one paragraph:

> *2026-10-14 amendment (board #229, owner approved in asks #122/#124, spec `docs/superpowers/specs/2026-10-14-session-worktrees-design.md` §9):* a session row Watchtower placed in a worktree it created (`terminal_sessions.worktree_branch` set) owns, by record, the linked worktree that is the longest listed root containing its `folder_path`, and its `worktree_branch` — although both were born before the row. Nothing else is owned by record, and every safety catch (W1, W3–W9, B1, B2, B4) still applies. Placement code (`workbench worktree create|ensure|forget`) never removes a worktree or deletes a branch and runs no `--force`, `reset`, `clean`, `checkout` or `stash`.

Add to **Test guards**: `internal/sessioncleanup/placed_test.go` — `TestCleanupPlacedRowOwnsItsWorktreeAndBranch`, `TestCleanupPlacedSubfolderRowOwnsItsWorktree`, `TestCleanupPlacedRowStillKeepsUncommittedWork`, `TestCleanupUnplacedOldWorktreeStillKept`; `internal/workbenchgit/worktree_ensure_test.go` — `TestProj18_PlacementNeverForcesOrDiscards`. Append `; amended 2026-10-14 (placed sessions, board #229, asks #122/#124)` to its Status line.

- [ ] **Step 6: Commit**

```bash
git add internal/sessioncleanup docs/inventory/workbench.md
git commit -m "feat(sessioncleanup): a placed row owns its worktree and wt/ branch by record (PROJ-18)"
```

---

### Task 7: Workbench deletion cleans placed worktrees (PROJ-02); PROJ-14 pin

**Depends on:** Tasks 1, 5, 6.

**Files:**
- Modify: `cmd/workbench.go` (`runWorkbenchDelete`, ~l.472)
- Test: `cmd/workbench_test.go` (or the file holding the `workbench delete` tests)
- Test: `internal/sessionreport/` (the package's existing test file for branch refs)
- Modify: `docs/inventory/workbench.md` (PROJ-02 amendment; PROJ-14 guard line)

**Interfaces:**
- Consumes: `db.PlacedSessions` (Task 1); the in-process cleanup entry `cmd/workbench_cleanup.go` uses (read it: the function that builds a `sessioncleanup.Request` and calls the plan/apply — reuse it, do not re-implement); `devpack.UnregisterWorkbenchMCP` (Task 5).
- Produces: `workbench delete --json` gains `"kept_worktrees": [path…]` (never null).

- [ ] **Step 1: Write the failing tests**

```go
func TestWorkbenchDelete_CleansPlacedWorktreesKeepsDirtyOnes(t *testing.T) {
	folder := newGitWorkbenchFolder(t)
	id := createTestWorkbenchRow(t, folder)
	stubWorkbenchCommandRunner(t, nil)
	clean := createPlacedSession(t, id, "c")   // worktree create + a row with worktree_branch, branch pushed to a bare remote
	dirty := createPlacedSession(t, id, "d")
	writeFileAt(t, dirty.Path, "README.md", "edited\n")

	out := runCmd(t, "workbench", "delete", fmt.Sprint(id), "--json")
	var res struct{ KeptWorktrees []string `json:"kept_worktrees"` }
	require.NoError(t, json.Unmarshal(out, &res))
	assert.NoDirExists(t, clean.Path)
	assert.DirExists(t, dirty.Path)
	assert.Equal(t, []string{dirty.Path}, res.KeptWorktrees)
}
```

`createPlacedSession` is a new test helper in this test file: run `workbench worktree create`, push its branch to a bare remote the fixture sets up (so PROJ-18's W7/B4 allow removal — read how `internal/sessioncleanup/apply_test.go::MergedAndPushedWorkIsRemoved` makes work "pushed"), and insert a `terminal_sessions` row with `folder_path = cwd`, `worktree_branch`, `worktree_base`. Use the existing helper names for the rest.

Session report pin (spec §11 PROJ-14): in `internal/sessionreport`'s test file for `branch:` refs, add `TestSessionReport_ReportsAWorktreeBranch`: a target linked with `branch: wt/x` where `wt/x` exists only as a branch checked out in a linked worktree resolves the same as any branch (read the nearest existing branch-ref test and copy its fixture; only the branch's location differs).

- [ ] **Step 2: Run them to see them fail**

Run: `go test ./cmd -run TestWorkbenchDelete_CleansPlaced && go test ./internal/sessionreport -run TestSessionReport_ReportsAWorktreeBranch`
Expected: the delete test FAILs (worktrees left, no `kept_worktrees`); the report test is expected to PASS already (it pins existing behaviour) — if it fails, stop and report it as a spec deviation instead of changing `internal/sessionreport`.

- [ ] **Step 3: Implement**

In `runWorkbenchDelete`, before the install removal and `DeleteWorkbench`: for each `PlacedSessions(id)` row, run the session cleanup **apply** in process for that session with exactly two items, `worktree:<root>` and `branch:<branch>` (root = the plan item whose key starts with `worktree:` and whose root contains the row's `folder_path`; take it from a plan of that session — plan first, then apply only those keys, as the CLI's `--item` path does). An item that is not removed → its path goes into `kept_worktrees`; a removed worktree → `devpack.UnregisterWorkbenchMCP` for the row's `folder_path` (best effort, a failure is one stderr warning). A cleanup error is a stderr warning and the path goes into `kept_worktrees`; deletion continues (PROJ-02: the workbench is deleted anyway, as the install-removal failure already is).

- [ ] **Step 4: Run the tests**

Run: `go test ./cmd -run 'TestWorkbenchDelete|TestProj02' && go test ./internal/sessionreport`
Expected: PASS.

- [ ] **Step 5: Inventory**

PROJ-02 (`docs/inventory/workbench.md` ~l.115): add to Observable: "*2026-10-14 (board #229, asks #122/#124):* deleting a workbench first runs the session cleanup (PROJ-18) for every placed session's worktree and `wt/` branch; a worktree the cleanup keeps stays on disk and is listed in `kept_worktrees`; a removed one's local MCP entry is unregistered." Add the test to its guards. PROJ-14: add `TestSessionReport_ReportsAWorktreeBranch` to its guards with "(a placed session's `wt/` branch, board #229)".

- [ ] **Step 6: Commit**

```bash
git add cmd internal/sessionreport docs/inventory/workbench.md
git commit -m "feat(workbench): deleting a workbench cleans its placed worktrees (PROJ-02)"
```

---

### Task 8: WatchtowerCore — envelopes and `SessionStartPlacement`

**Depends on:** Task 5 (envelope shape).

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Models/WorkbenchWorktree.swift`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/SessionStartPlacement.swift`
- Test: `WatchtowerDesktop/Tests/Core/SessionStartPlacementTests.swift`, `WatchtowerDesktop/Tests/Core/WorkbenchWorktreeDecodingTests.swift`

**Interfaces:**
- Consumes: `WorkbenchGitStatus` (`gitAvailable`, `git`, `unborn`, `statusOK`), `SessionPlace` (`.unknown`, `.main`, `.worktree(name:root:status:)`, `.removed(name:path:)`), `TerminalSession.folderPath`, `.worktreeBranch`, `.kind.isAgent`.
- Produces:

```swift
package struct WorktreeCreateResult: Decodable, Equatable, Sendable {
    package let workbenchID: Int64
    package let created: Bool
    package let path: String
    package let cwd: String
    package let branch: String
    package let base: String
    package let baseBranch: String
    package let baseDirty: Bool
    package let included: [String]
    package let includeWarnings: [String]
    package let refused: String
    package let refusedDetail: String
    package let error: String
    package let warning: String
    package let integrationError: String
}
package struct WorktreeForgetResult: Decodable, Equatable, Sendable {
    package let workbenchID: Int64
    package let forgot: Bool
    package let error: String
}

package enum WorktreeChoice: String, Sendable, CaseIterable { case auto, folder, worktree }

package enum SessionStartPlacement: Equatable, Sendable {
    case folder(note: String?)   // note: why a worktree was not used, when one was asked for or implied
    case worktree

    package static func decide(choice: WorktreeChoice, gitStatus: WorkbenchGitStatus?, occupied: Bool) -> Self
    package static func occupies(row: TerminalSession, place: SessionPlace, workbenchFolder: String) -> Bool
    package static func unavailableReason(_ gitStatus: WorkbenchGitStatus?) -> String?
    package static func slug(targetID: Int64?, targetText: String?, sessionNumber: Int) -> String
}
```

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import WatchtowerCore

final class SessionStartPlacementTests: XCTestCase {
    private func status(git: Bool = true, available: Bool = true, unborn: Bool = false, ok: Bool = true) -> WorkbenchGitStatus {
        // build through JSON so the test does not depend on a memberwise init
        let json = """
        {"workbench_id":1,"git_available":\(available),"git":\(git),"unborn":\(unborn),"status_ok":\(ok)}
        """
        return try! JSONDecoder().decode(WorkbenchGitStatus.self, from: Data(json.utf8))
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
        for s in [status(git: false), status(available: false), status(unborn: true), status(ok: false), nil] {
            guard case .folder(let note) = SessionStartPlacement.decide(choice: .auto, gitStatus: s, occupied: true) else {
                return XCTFail("\(String(describing: s))")
            }
            XCTAssertNotNil(note, "an implied worktree that cannot be made says why")
            XCTAssertNotNil(SessionStartPlacement.unavailableReason(s))
        }
        XCTAssertEqual(SessionStartPlacement.decide(choice: .auto, gitStatus: status(git: false), occupied: false), .folder(note: nil),
                       "a lone session in a plain folder needs no note")
    }

    func testOccupancyFollowsThePlace() {
        let folder = "/repo"
        let plain = TestRows.session(folderPath: folder)
        let placed = TestRows.session(folderPath: "/repo/.claude/worktrees/a", worktreeBranch: "wt/a")
        XCTAssertTrue(SessionStartPlacement.occupies(row: plain, place: .unknown, workbenchFolder: folder), "fresh, before its first hook")
        XCTAssertTrue(SessionStartPlacement.occupies(row: plain, place: .main, workbenchFolder: folder))
        XCTAssertFalse(SessionStartPlacement.occupies(row: placed, place: .unknown, workbenchFolder: folder), "placed, before its first hook")
        XCTAssertTrue(SessionStartPlacement.occupies(row: placed, place: .main, workbenchFolder: folder), "an agent that cd'd back")
        XCTAssertFalse(SessionStartPlacement.occupies(row: plain, place: .removed(name: "x", path: "/repo/.claude/worktrees/x"), workbenchFolder: folder))
    }

    func testSlug() {
        XCTAssertEqual(SessionStartPlacement.slug(targetID: 229, targetText: "Параллельные Sessions & worktrees!", sessionNumber: 3), "229-sessions-worktrees")
        XCTAssertEqual(SessionStartPlacement.slug(targetID: nil, targetText: nil, sessionNumber: 3), "session-3")
        XCTAssertLessThanOrEqual(SessionStartPlacement.slug(targetID: 1, targetText: String(repeating: "word ", count: 30), sessionNumber: 1).count, 40)
        XCTAssertFalse(SessionStartPlacement.slug(targetID: 1, targetText: String(repeating: "ab ", count: 30), sessionNumber: 1).hasSuffix("-"))
    }
}
```

`TestRows.session(...)` stands for however `Tests/Core` builds a `TerminalSession` today (read an existing Core test that needs one — JSON decoding or a test factory); use that, adding the `worktreeBranch` argument to the factory if one exists. `WorkbenchWorktreeDecodingTests`: decode a full `create` envelope (every key, snake_case) and one with `refused: "unborn"` and empty arrays; decode `WorktreeForgetResult`.

Run: `make test-swift FILTER='SessionStartPlacementTests|WorkbenchWorktreeDecodingTests'` → FAIL (undefined).

- [ ] **Step 2: Implement**

`WorkbenchWorktree.swift`: the two structs with `CodingKeys` in snake_case (`workbench_id`, `base_branch`, `base_dirty`, `include_warnings`, `refused_detail`, `integration_error`); a custom `init(from:)` that defaults every missing key (`""`, `false`, `[]`) the way `WorkbenchGitStatus.init(from:)` does, so an older CLI decodes.

`SessionStartPlacement.swift`:

```swift
/// Where a new workbench agent session starts (board #229, spec
/// 2026-10-14-session-worktrees-design.md §4). Pure; the view model feeds it
/// the folder's git status and whether a live agent already works in it.
package enum SessionStartPlacement: Equatable, Sendable {
    case folder(note: String?)
    case worktree

    package static func decide(choice: WorktreeChoice, gitStatus: WorkbenchGitStatus?, occupied: Bool) -> Self {
        let wants = choice == .worktree || (choice == .auto && occupied)
        if choice == .folder || !wants { return .folder(note: nil) }
        if let reason = unavailableReason(gitStatus) { return .folder(note: "Started in the folder: \(reason)") }
        return .worktree
    }

    /// nil when a worktree can be made; else the reason in words.
    package static func unavailableReason(_ s: WorkbenchGitStatus?) -> String? {
        guard let s else { return "the folder's git status could not be read." }
        if !s.gitAvailable { return "git is not available." }
        if !s.git { return "the folder is not in a git repository." }
        if !s.statusOK { return "the folder's git status could not be read." }
        if s.unborn { return "the repository has no commit yet." }
        return nil
    }

    /// A live agent row works in the main folder: its place is the main
    /// folder, or unknown and it was not placed in a worktree.
    package static func occupies(row: TerminalSession, place: SessionPlace, workbenchFolder: String) -> Bool {
        switch place {
        case .main: return true
        case .unknown: return row.worktreeBranch == nil && SessionPlace.isWorkbenchFolder(row.folderPath, workbenchFolder: workbenchFolder)
        case .worktree, .removed: return false
        }
    }

    /// `<target id>-<words>` or `session-<n>`: lowercase ASCII letters,
    /// digits and single dashes, at most 40 characters, no trailing dash.
    package static func slug(targetID: Int64?, targetText: String?, sessionNumber: Int) -> String {
        guard let targetID else { return "session-\(sessionNumber)" }
        let folded = (targetText ?? "").folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en_US_POSIX")).lowercased()
        let words = folded.split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) }).map(String.init)
        var out = "\(targetID)"
        for w in words where out.count + 1 + w.count <= 40 { out += "-" + w }
        return out
    }
}
```

(Non-ASCII words drop out — the test's Cyrillic word does.) Check the test's expectation against this code once by hand and adjust the test, not the rule, if they disagree on a detail the spec does not fix.

Run: `make test-swift FILTER='SessionStartPlacementTests|WorkbenchWorktreeDecodingTests'` → PASS.

- [ ] **Step 3: Commit**

```bash
git add WatchtowerDesktop/Sources/WatchtowerCore WatchtowerDesktop/Tests/Core
git commit -m "feat(core): session start placement and worktree envelopes"
```

---

### Task 9: `WorkbenchCLI` worktree calls

**Depends on:** Tasks 5, 8.

**Files:**
- Modify: `WatchtowerDesktop/Sources/Services/WorkbenchCLI.swift` (next to `gitStatus`, ~l.715)
- Test: the existing `WorkbenchCLI` tests file (find it: `grep -rl "gitStatus(projectID" WatchtowerDesktop/Tests`)

**Interfaces:**
- Produces:

```swift
func worktreeCreate(projectID: Int64, name: String) async throws -> WorktreeCreateResult
func worktreeEnsure(projectID: Int64, path: String, branch: String) async throws -> WorktreeCreateResult
func worktreeForget(projectID: Int64, path: String) async throws -> WorktreeForgetResult
```

Args: `["workbench","worktree","create","--workbench",id,"--name",name,"--json"]`, `[…,"ensure","--workbench",id,"--path",p,"--branch",b,"--json"]`, `[…,"forget","--workbench",id,"--path",p,"--json"]`; run through the same `runner.run(args:)` and `JSONDecoder` as `gitStatus`.

- [ ] **Step 1: Failing test** — with the file's fake runner, assert each call's exact argv and that a canned envelope decodes. Run `make test-swift FILTER=<that test class>` → FAIL.
- [ ] **Step 2: Implement** the three methods mirroring `gitStatus`. Run → PASS.
- [ ] **Step 3: Commit** `git commit -m "feat(desktop): WorkbenchCLI worktree create/ensure/forget"`.

---

### Task 10: Launch — the setup command before the agent's first start

**Depends on:** Task 1.

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/TerminalLaunch.swift` (`make`, ~l.71)
- Modify: `WatchtowerDesktop/Sources/Services/TerminalCenter.swift` (`launch`/`run`, ~l.751–866: pass the prelude through)
- Test: the existing `TerminalLaunch` tests (`grep -rl "TerminalLaunch.make" WatchtowerDesktop/Tests`)

**Interfaces:**
- Produces: `TerminalLaunch.make(shell:folder:mode:rowID:codex:setup: String? = nil)`; `TerminalCenter.launch(…, setup: String? = nil)` (new trailing parameter, default nil, forwarded to `run` → `make`).

Rule: `setup` non-nil and non-blank, and the mode is a **new** agent start (`.newClaude` or a new Codex run — never `.resumeClaude`, a Codex resume or `.shell`) → the `-c` string becomes `<setup-block>; <the existing exec …>`, where

```
{ printf '\033[2mwatchtower: running the worktree setup command…\033[0m\n'; <setup>; } || printf 'watchtower: the worktree setup command failed (exit %s); starting the agent anyway.\n' "$?"
```

The setup text goes in verbatim (it is the owner's shell command, like a Makefile recipe); the agent's `exec …` is unchanged after it. Codex: prefix the same block inside `codexLoginCommand`'s shell before its `eval`/`exec` (read `codexScript`/`codexLoginCommand` and put the block where the existing `PATH=…` prefix goes, before the `exec`).

- [ ] **Step 1: Failing tests**

```swift
func testSetupRunsBeforeANewClaudeStart() {
    let l = TerminalLaunch.make(shell: "/bin/zsh", folder: "/w", mode: .newClaude(uuid: "u", prompt: nil), setup: "npm install")
    let script = l.args.last!
    XCTAssertTrue(script.contains("npm install; }"), script)
    XCTAssertTrue(script.range(of: "npm install")!.lowerBound < script.range(of: "exec claude")!.lowerBound)
}
func testSetupNeverRunsOnResumeOrShell() {
    XCTAssertFalse(TerminalLaunch.make(shell: "/bin/zsh", folder: "/w", mode: .resumeClaude(uuid: "u"), setup: "npm install").args.joined().contains("npm install"))
    XCTAssertFalse(TerminalLaunch.make(shell: "/bin/zsh", folder: "/w", mode: .shell, setup: "npm install").args.joined().contains("npm install"))
}
func testBlankSetupChangesNothing() {
    let a = TerminalLaunch.make(shell: "/bin/zsh", folder: "/w", mode: .newClaude(uuid: "u", prompt: nil))
    let b = TerminalLaunch.make(shell: "/bin/zsh", folder: "/w", mode: .newClaude(uuid: "u", prompt: nil), setup: "  ")
    XCTAssertEqual(a.args, b.args)
}
```

Plus one Codex case (new run contains the block; read the Codex mode's case name). Use the real `Mode` case names (read `TerminalLaunch.Mode`). Also one test that actually runs the composed script with `/bin/sh -c` replacing `exec claude …` by `exec echo started` is **not** needed — keep it string-level.

Run: `make test-swift FILTER=<TerminalLaunch test class>` → FAIL.

- [ ] **Step 2: Implement**, then → PASS. `make test-swift FILTER=TerminalCenter` must stay green (the new parameter defaults to nil).
- [ ] **Step 3: Commit** `git commit -m "feat(desktop): run a workbench's worktree setup command before a new agent start"`.

---

### Task 11: Desktop — placement at start

**Depends on:** Tasks 1, 8, 9, 10.

**Files:**
- Modify: `WatchtowerDesktop/Sources/ViewModels/WorkbenchesViewModel+Sessions.swift` (`startNewSession` ~l.224, `startTarget` ~l.342, `createAndActivate` ~l.630, `newSession` ~l.194, `workOn` ~l.257, `startForTarget` ~l.321)
- Create: `WatchtowerDesktop/Sources/ViewModels/WorkbenchesViewModel+Placement.swift`
- Test: `WatchtowerDesktop/Tests/WorkbenchesViewModelPlacementTests.swift`; update `WatchtowerDesktop/Tests/WorkbenchesViewModelSessionsTests.swift` only by adding cases (its #565 pins `testPlusStartsInTheMainFolderWhileAWorktreeSessionIsShown` and `testWorkOnItStartsInTheMainFolder` must stay green unchanged: no live agent occupies the main folder in them — if one does, give that test `worktree: .folder` explicitly and say so in the report)

**Interfaces:**
- Consumes: `SessionStartPlacement`, `WorktreeChoice`, `WorktreeCreateResult` (Task 8); `cli.worktreeCreate` (Task 9); `cli.gitStatus(projectID:)`; `sessionPlaces.currentPlace(sessionID:)` (#565, `WorkbenchesViewModel.sessionPlaces`); `terminalCenter.liveAgentIDs`, its `rows` (or `TerminalSessionQueries.fetchForWorkbench`); `NewSession.worktreeBranch/worktreeBase`; `TerminalCenter.launch(…, setup:)` (Task 10); `Workbench.worktreeSetup`.
- Produces: `worktree: WorktreeChoice = .auto` parameter on `newSession`, `startNewSession`, `workOn`, `startForTarget`, `startTarget`; `private(set) var startNotice: [Int64: String]` (per workbench, one line shown above the sessions panel; Task 14 renders it); `func placementForNewSession(project: Workbench, choice: WorktreeChoice, targetID: Int64?, targetText: String?) async -> (folderPath: String, worktreeBranch: String?, worktreeBase: String?, notice: String?)`; serialisation: one placement decision in flight per workbench (an `actor`-free `[Int64: Task<…>]` chain on the main actor: a second start awaits the first's insert before deciding).

Behaviour:
1. `occupied` = any live agent row of the workbench (`liveAgentIDs`, `row.projectID == project.id`) with `SessionStartPlacement.occupies(row:place:workbenchFolder:)` true.
2. `.worktree` → `cli.worktreeCreate(projectID:name: slug)`; `created` → folder = `cwd`, branch, base; notice: `base_dirty` → "The new worktree does not have the folder's uncommitted changes."; non-empty `include_warnings`/`warning`/`integration_error` → the first of them, prefixed "Worktree: ". Not created (refused, error, or the call threw) → main folder + notice "Started in the folder: <refused_detail | error | refused>".
3. `.folder(note)` → main folder, notice = note.
4. The row is inserted with that folder/branch/base; the first launch passes `setup: project.worktreeSetup` **only** when `worktreeBranch != nil` (fresh start).
5. Reopening an existing row (`.openExisting`, `openMostRecentSession`) never re-decides.
6. Shell sessions and standalone terminals are never placed.
7. The setup session (`WorkbenchesViewModel.swift:735`) and `CodeHandoffCenter` (`.newSession(agent)`) go through `startNewSession` and so get `.auto`.

- [ ] **Step 1: Failing tests** (`WorkbenchesViewModelPlacementTests`, using the fakes `WorkbenchesViewModelSessionsTests` uses — `SessionPlaceViewModelTests.RoutingRunner`, the fake CLI runner, a live-row helper; read them first):

- `testALoneSessionStartsInTheFolder` — no live agent → `folderPath == folder`, no CLI `worktree` call, `worktreeBranch == nil`.
- `testASecondSessionGetsAWorktree` — one live claude row in the folder (place `.main`) → the CLI got `worktree create --name session-2` (or the target slug), the row's `folderPath` is the envelope's `cwd`, `worktreeBranch == "wt/…"`, `worktreeBase` set, and the launch's `currentDirectory` is the `cwd`.
- `testAPlacedLiveSessionDoesNotOccupyTheFolder` — the only live row is placed (place `.unknown`, `worktreeBranch` set) → the next start goes to the folder.
- `testOverrideFolderAndWorktree` — `worktree: .folder` with an occupied folder → folder; `worktree: .worktree` with a free folder → worktree.
- `testRefusedCreateFallsBackWithANote` — envelope `refused: "unborn"` → folder + `startNotice[projectID]` starts "Started in the folder:".
- `testBaseDirtyShowsTheNote` — `base_dirty: true` → notice "The new worktree does not have the folder's uncommitted changes."
- `testConcurrentStartsSecondGetsWorktree` — two `newSession` calls started together on a free folder: the first goes to the folder, the second to a worktree (the second's decision runs after the first row is live).
- `testSetupRunsOnlyOnAPlacedFirstLaunch` — `worktreeSetup = "make deps"`: the placed launch's args contain it; a folder start's args do not.
- `testWorkOnItPassesTheTargetSlug` — `workOn(targetID: 229, targetText: "Fix the thing")` in an occupied folder → `--name 229-fix-the-thing`.

Run: `make test-swift FILTER='WorkbenchesViewModelPlacementTests|WorkbenchesViewModelSessionsTests'` → the new tests FAIL.

- [ ] **Step 2: Implement** in `+Placement.swift` (the decision, the CLI call, the notice, the per-workbench chain) and thread `worktree:` through the start paths; `createAndActivate` gains the `setup:` pass-through to `activate`/`launch`. Run → PASS.
- [ ] **Step 3: Commit** `git commit -m "feat(desktop): start a second agent session in its own worktree"`.

---

### Task 12: Desktop — resume re-adds a cleaned-up worktree

**Depends on:** Task 11.

**Files:**
- Modify: `WatchtowerDesktop/Sources/ViewModels/WorkbenchesViewModel+Sessions.swift` (`activate`, ~l.690, before the launch of an existing row)
- Test: `WatchtowerDesktop/Tests/WorkbenchesViewModelPlacementTests.swift`

**Interfaces:**
- Consumes: `cli.worktreeEnsure` (Task 9); the row's `worktreeBranch`, `folderPath`.
- Produces: an existing placed row whose `folderPath` does not exist is re-added before its launch; `TerminalCenter.launch`'s existing "The folder … no longer exists." stays the last resort.

Rule: before launching an existing (non-fresh) row with `worktreeBranch != nil` whose `folderPath` is not a directory: the worktree top = the ancestor of `folderPath` whose parent's last two components are `.claude/worktrees` (pure helper in `SessionStartPlacement`: `worktreeTop(ofCwd:) -> String?`, tested in Core); call `worktreeEnsure(path: top, branch:)`. `created` → launch as usual (the transcript resolves at the same path). `refused == "unknown_branch"` → the row shows `.unavailable("The worktree and its branch \(branch) were cleaned up — start a new session.")` and nothing launches. Any other failure → `.unavailable("The worktree \(top) could not be restored: \(error)")`. Never a fallback to the main folder. A setup command never runs here.

- [ ] **Step 1: Failing tests** — `testResumeOfACleanedUpWorktreeReAddsIt` (folder missing → ensure called with the top and branch → launch in `folderPath`), `testResumeWithTheBranchGoneIsUnavailable` (exact text, no launch), `testResumeOfAnExistingWorktreeCallsNothing`, `testResumeNeverRunsTheSetupCommand`; Core: `worktreeTop(ofCwd:)` for `/r/.claude/worktrees/a`, `/r/.claude/worktrees/a/app/web`, `/r/elsewhere` (nil). Run → FAIL.
- [ ] **Step 2: Implement.** Run `make test-swift FILTER='WorkbenchesViewModelPlacementTests|SessionStartPlacementTests'` → PASS.
- [ ] **Step 3: Commit** `git commit -m "feat(desktop): resume re-adds a placed session's worktree from its branch"`.

---

### Task 13: Desktop — automatic cleanup when a finished placed session's agent exits

**Depends on:** Tasks 6, 11.

**Files:**
- Create: `WatchtowerDesktop/Sources/ViewModels/WorkbenchesViewModel+PlacedCleanup.swift`
- Modify: `WatchtowerDesktop/Sources/ViewModels/WorkbenchesViewModel+Sessions.swift` (`sessionExited(_:code:)` ~l.604 calls the new hook)
- Test: `WatchtowerDesktop/Tests/WorkbenchesViewModelPlacedCleanupTests.swift`

**Interfaces:**
- Consumes: `TerminalCenter.onSessionExit` → `sessionExited` (already wired, `WorkbenchesViewModel.swift:435`); the row's finished state (the same source the session panel uses for Finished — read `SessionStatePresentation`/`SessionAgentStateCenter` for "finished_at set"/`finished`); `SessionCleanupCenter.planCleanup(sessionID:workbenchID:closingSession:)` and `applyCleanup(sessionID:workbenchID:items:) async -> Bool`, its phase for the result; `cli.worktreeForget` (Task 9).
- Produces: `func cleanUpPlacedWorktree(_ row: TerminalSession) async` — plans with `closingSession: true` (the session's own id leaves the live set; its process has exited), picks from the plan exactly the item with key `worktree:<root>` whose root contains `row.folderPath` and the item `branch:<row.worktreeBranch>`, applies only those that are `remove` in the plan, then: the worktree was removed → `cli.worktreeForget(path: root)` (best effort; a failure is logged, not shown); kept → nothing more (the cleanup's `cleanup_result` and #535's report line say why). Never runs for a row without `worktreeBranch`, for a row that is not finished, or while the row is live again (a resume between exit and the call).

- [ ] **Step 1: Failing tests** (fake cleanup runner returning canned plan/apply JSON; read `SessionCleanupCenter`'s tests for the fake):
- `testFinishedPlacedSessionExitCleansExactlyItsTwoItems` — the apply argv carries exactly `--item=worktree:<root>` and `--item=branch:wt/x`, even when the plan lists other `remove` items (another worktree the session visited).
- `testUnfinishedExitDoesNothing` — a crash or a quit without `finish_session` → no cleanup call.
- `testUnplacedRowExitDoesNothing`.
- `testKeptItemsAreNotForgotten` — plan says `keep / uncommitted_changes` for the worktree → no apply of it, no `forget`.
- `testRemovedWorktreeIsForgotten` — apply result `done: true` for the worktree → `worktree forget --path <root>`.
- `testAResumeBeforeTheCleanupRunsCancelsIt` — the row is live again when the hook runs → nothing.
Run `make test-swift FILTER=WorkbenchesViewModelPlacedCleanupTests` → FAIL.
- [ ] **Step 2: Implement.** Run → PASS. Also `make test-swift FILTER='SessionCleanup|WorkbenchesViewModelSessionsTests'` stays green.
- [ ] **Step 3: Commit** `git commit -m "feat(desktop): clean up a finished placed session's worktree when its agent exits"`.

The Delete Session dialog needs no change: Task 6 puts the placed worktree and branch on #535's plan. Add one test in this task's file, `testDeleteDialogPlanListsThePlacedItems`, only if the dialog's plan is built in Swift from data this feature controls; otherwise note in the report that Task 6's Go tests cover it.

---

### Task 14: Desktop UI, setup field, docs

**Depends on:** Tasks 11, 12, 13.

**Files:**
- Modify: the new-session menu and **Work on It** split button views (find them: `grep -rn "newSessionOnPage\|Work on It" WatchtowerDesktop/Sources/Views/Workbench`)
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/WorkbenchHeaderControls.swift` (next to `archiveMenu`, ~l.190: a "Worktree Setup Command…" item opening a small sheet)
- Create: `WatchtowerDesktop/Sources/Views/Workbench/WorktreeSetupSheet.swift`
- Modify: the sessions panel (where the header notices render) for `startNotice`; the session row's context menu for **Show Worktree in Finder**
- Modify: `WatchtowerDesktop/Sources/ViewModels/WorkbenchesViewModel.swift` (`setWorktreeSetup(_:projectID:) async`, mirroring `setArchiveAfterDays` at ~l.898, with `worktreeSetupErrors[projectID]`)
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/SessionStartPlacementPresentation.swift` + test
- Modify: `docs/features/workbench.md` (a **Session placement** bullet), `docs/app-guide.md` (the user-facing paragraph), `CLAUDE.md`'s workbench feature-note line (append "session placement (2026-10-14, board #229: …)")

**Interfaces:**
- Produces: `SessionStartPlacementPresentation.menuTitle(_ choice: WorktreeChoice) -> String` ("Automatic", "In This Folder", "In Its Own Worktree"), `.disabledHelp(_ reason: String) -> String`, `.setupHint` ("Runs in a new session worktree before the agent starts, after the .worktreeinclude paths are copied. Leave empty for none.").

- [ ] **Step 1: Failing presentation test** (titles, hint). Run → FAIL. Implement → PASS.
- [ ] **Step 2: Views.** The menus offer **In This Folder** / **In Its Own Worktree** (the plain button stays `.auto`); "In Its Own Worktree" is disabled with `unavailableReason` as help when the last known git status says so (read it from the header's git status the VM already holds — no new git call to build the menu). The setup sheet: one `TextField` (monospaced), the hint, Save/Cancel; Save calls `vm.setWorktreeSetup`. `startNotice` shows as one secondary line with a dismiss button above the sessions list. **Show Worktree in Finder** (`NSWorkspace.shared.activateFileViewerSelecting`) only for rows with `worktreeBranch` whose folder exists. The workbench delete flow (`WorkbenchesViewModel.deleteWorkbench`, which runs `workbench delete --json` through `WorkbenchCLI.swift:~811`) decodes Task 7's `kept_worktrees` (default `[]`) and, when non-empty, shows one notice: "Kept \(n) worktree(s) with work in them: <paths>" — add the key to the decoded result type and a test in the file that tests that decode.
- [ ] **Step 3: Build and the touched tests.** `make test-swift FILTER='SessionStartPlacement|WorkbenchesViewModelPlacement'`; `make lint-diff`.
- [ ] **Step 4: Docs.** `docs/features/workbench.md`: a **Session placement (2026-10-14, board #229)** bullet — the rule, the CLI (`workbench worktree create|ensure|forget` and their keys), `.worktreeinclude`, the setup command, D9 (`folder_path` = the worktree for placed rows), the automatic cleanup through #535 with by-record ownership, resume via `ensure`, the trust-prompt finding from Task 5's spike, v1 limits (spec §13). `docs/app-guide.md`: what the user sees and how to override. Note in the #565 section that its "new sessions keep the workbench folder" rule has the placed exception (D9).
- [ ] **Step 5: Commit** `git commit -m "feat(desktop): worktree start choice, setup command field, placement docs"`.

---

### Task 15: Gate and manual check

**Depends on:** all.

- [ ] **Step 1:** `bash scripts/dev-health.sh` — stop if `HEALTH: overloaded`.
- [ ] **Step 2:** Full gate, foreground, each to a log with its exit code: `make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...`. Fix failures through the normal fix loop.
- [ ] **Step 3:** File the owner's manual check (`ask_owner`, `kind: check`): (1) start an agent session, then a second one in the same workbench → the second shows the worktree place label and works in `.claude/worktrees/…`; (2) add a `.worktreeinclude` with a gitignored file and a setup command → both reach a new worktree, the setup output shows in the terminal; (3) let the second session finish (`finish_session`) and quit its agent → the worktree is removed if pushed/merged, or kept with the reason in the session report; (4) resume a session whose worktree was cleaned up → it is re-added; (5) a Codex session in a worktree; (6) "In This Folder" / "In Its Own Worktree" overrides; (7) whether Claude Code asked to trust the new worktree folder.
- [ ] **Step 4:** Open the PR into main (`superpowers:finishing-a-development-branch`), with the deviation list and the ledger's rulings.
