# Diff Reviewer — Plan 1: engine, rounds, Changes pane (Quick), delivery

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A working reviewer of a workbench session's changes: the owner opens **Review Changes**, sees the session's diff against the base (or since the last round) in a Monaco diff editor, writes line comments, marks files Viewed, and **Send** delivers one fixed line to the session; the agent reads the round with `get_review`.

**Architecture:** Git lives in Go: a new package `internal/reviewdiff` snapshots the work tree into a tree object through a temporary index (no ref, no owner index touched) and diffs trees; `watchtower workbench review …` exposes it as JSON. Rounds and comments live in three new tables (migration 00117); Swift writes drafts and Viewed marks, Go writes rounds and reads comments for the MCP tool. The Desktop adds a `changes` workspace pane hosting a second Monaco page (`diff.html`) and delivers the round line through `SessionLineDelivery` (PROJ-12 gates).

**Tech Stack:** Go 1.26 (cobra, `database/sql` + modernc sqlite, goose), SwiftUI + GRDB (WatchtowerCore), Monaco (bundled `CodeEditorWeb`, AMD), WKWebView.

**Spec:** `docs/superpowers/specs/2026-10-16-workbench-diff-reviewer-design.md` (approved, ask #179). This plan covers spec §15 phases 1–2. Plan 2 = phase 3 (Deep mode), Plan 3 = phases 4–5 (agent tools, AI overview, Undo, learning loop).

## Global Constraints

- Every git call goes through `internal/gitbin` with `gitbin.ReadArgsIn` argv (no fsmonitor, hooks path `/dev/null`, no `log.showSignature`, folder filter drivers blanked for content reads); git located by `gitbin.Locate`, never PATH.
- No git ref is created or moved; the owner's index (`.git/index`) is never written; no work-tree file is written by anything in this plan (REVIEW-01).
- Snapshot = `GIT_INDEX_FILE=<private temp file>` → `read-tree HEAD` (empty tree when no commit) → `add -A` → `write-tree`.
- Empty tree sha: `4b825dc642cb6eb9a060e54bf8d69288fbee4904`.
- Caps: a file side over **1 MB** or over **5,000** changed lines is `too_large`; a whole diff over **50,000** changed lines sets `truncated` (later files carry no hunks). Tunables live in `internal/reviewdiff/limits.go` only.
- Delivery line (Go and Swift, byte-identical, pinned by `internal/reviewdiff/testdata/lines/*.json`): `Review round #<id> sent (<n> comments) — read it with get_review <id> using the watchtower-workbench skill.` — `<n>` is the count of the round's comments with status `sent`; `1 comment` singular.
- Statuses: round `open|sent|delivered`; comment `draft|sent|carried|resolved|outdated`; round `source` `session|pr` (only `session` written in v1); round `mode` `quick|deep` (only `quick` used in this plan).
- One open round per session (DB partial unique index).
- Board language for anything the agent writes on the board: the session language. Repo docs: English.
- Public repo hygiene: no real ids, names, paths in tests or docs; temp repos and `example.com` only.
- Task scope checks only (`go test ./internal/<pkg>`, `make test-swift FILTER=…`, `make lint-diff`, `make lint-swift` for Swift); full gate once per phase by the controller.

## Review Focus

1. **A file with spaces, unicode or a quote in its path** — the diff lists it with its real path and its hunks attached to the right file (tested in Task 2 with a `"dir name/файл \"q\".go"` path).
2. **A repository with no commits yet (fresh `git init`)** — Review Changes works: base is the empty tree, every file shows as added (Task 2, Task 4).
3. **The agent edits files while the round is open** — `refresh` moves the round to a new tree and the open drafts re-anchor or turn `outdated`, none disappear (Task 4 Go refresh test, Task 6 Swift re-anchor test).
4. **Send pressed twice / in two windows** — only one transition `open → sent`, one line typed (Task 3 guarded update test, Task 8 view-model test).
5. **A folder whose `.git/config` names a filter driver or fsmonitor that writes a marker file** — no snapshot or diff runs it (Task 1 + Task 2 guard tests `TestReview05_*`).

---

## Dependencies and parallel lanes

The owner asked for parallel agents wherever tasks are independent (2026-10-16). Each lane runs in its own worktree/branch off `feature/328-diff-reviewer`; the controller merges lanes back in the order below. Heavy Swift work stays one lane at a time (CLAUDE.md).

| Task | Depends on |
|---|---|
| 1 gitbin | none |
| 2 reviewdiff (+ DeliveryLine and its fixtures) | Task 1 |
| 3 migration + DB | none |
| 4 CLI | Tasks 2, 3 |
| 5 get_review, brief, skill | Tasks 2, 3 |
| 6 Swift core | Tasks 2 (line fixtures), 3 (schema) |
| 7 Swift CLI + line key | Task 6 |
| 8 ReviewChangesModel | Task 7 |
| 9 diff page + pane | Task 8 |
| 10 docs + guard names | Tasks 1–9 |

- **Wave 1 (parallel):** Lane G1 = Task 1 → Task 2; Lane D = Task 3.
- **Wave 2 (parallel, after merging G1 and D):** Lane G2 = Task 4; Lane G3 = Task 5; Lane S = Task 6 → 7 → 8 → 9 (one Swift lane).
- **Wave 3:** Task 10 on the merged branch, then the phase gate.

Task 6 also edits `internal/db/review_rounds.go` (carried comments in `SendReviewRound`); Lane S rebases on G2/G3 before merge — they do not touch that file.

---

## File Structure

**Go**
- Modify `internal/gitbin/run.go` — `ExecEnv` (extra env after the repository-env strip), `add` and `diff-tree -p` become content reads.
- Create `internal/reviewdiff/` — `reviewdiff.go` (Repo, Open, runner), `snapshot.go`, `base.go`, `diff.go` (parse), `file.go`, `limits.go`, `collapse.go`, `line.go` (DeliveryLine), tests + `testdata/lines/`.
- Create `internal/db/migrations/00117_review_rounds.sql`; modify `internal/db/schema.sql`, `internal/db/db_test.go`; create `internal/db/review_rounds.go` (+ test).
- Create `cmd/workbench_review.go`, `cmd/workbench_review_context.go` (+ tests).
- Create `internal/tools/workbench_review.go` (`get_review`); modify `internal/tools/workbenches.go`, `cmd/actions_registry_test.go`.
- Modify `cmd/workbench_brief.go` (waiting rounds line).
- Modify `internal/devpack/workbenchskill/watchtower-workbench/SKILL.md` (v9, Review section), `internal/devpack/workbench_test.go`.

**Swift (WatchtowerDesktop/Sources)**
- Create `WatchtowerCore/Models/ReviewModels.swift` (envelopes + DB records).
- Create `WatchtowerCore/Database/Queries/ReviewQueries.swift`.
- Create `WatchtowerCore/Services/Review/ReviewDeliveryLine.swift`, `ReviewCommentAnchor.swift`.
- Modify `Services/WorkbenchCLI.swift` (review calls), `Services/SessionLineDelivery.swift` (`LineKey.review`).
- Create `ViewModels/ReviewChangesModel.swift`.
- Create `CodeEditorWeb/diff.html`, `CodeEditorWeb/diff.js`; create `Views/Workbench/Review/MonacoDiffView.swift`, `ReviewChangesPaneView.swift`, `ReviewFileListView.swift`.
- Modify `WatchtowerCore/Services/WorkspaceLayout.swift` (`.changes`), `Views/Workbench/WorkspacePaneView.swift`, `Views/Workbench/TerminalSessionRow.swift` + `SessionRowActions`.

**Docs**
- Create `docs/inventory/review.md`, `docs/features/diff-reviewer.md`; modify `docs/inventory/README.md`, `docs/inventory/workbench.md` (PROJ-12 amendment), `CLAUDE.md` (feature link).

---

### Task 1: gitbin — extra env and content reads for the snapshot

**Files:**
- Modify: `internal/gitbin/run.go:75-86` (contentReads/readsContent), `:143` (Exec)
- Test: `internal/gitbin/run_test.go` (append)

**Interfaces:**
- Produces: `func ExecEnv(ctx context.Context, dir string, extraEnv []string, stdin []byte, name string, args ...string) (stdout, stderr []byte, err error)` — `Exec` becomes `ExecEnv(ctx, dir, nil, stdin, name, args...)`. `extraEnv` entries are appended **after** the strip, so a caller's `GIT_INDEX_FILE` survives while an inherited one never does. `readsContent([]string{"add",…})` and `readsContent([]string{"diff-tree","-p",…})` are true.

- [ ] **Step 1: Write the failing tests**

```go
func TestReadsContent_AddAndPatchDiffTree(t *testing.T) {
	for _, tc := range []struct {
		args []string
		want bool
	}{
		{[]string{"add", "-A"}, true},
		{[]string{"diff-tree", "-r", "-p", "a", "b"}, true},
		{[]string{"diff-tree", "-r", "--name-status", "a", "b"}, false},
		{[]string{"write-tree"}, false},
		{[]string{"read-tree", "HEAD"}, false},
	} {
		if got := readsContent(tc.args); got != tc.want {
			t.Errorf("readsContent(%v) = %v, want %v", tc.args, got, tc.want)
		}
	}
}

func TestExecEnv_KeepsCallerIndexDropsInherited(t *testing.T) {
	t.Setenv("GIT_INDEX_FILE", "/inherited/index")
	out, _, err := ExecEnv(context.Background(), t.TempDir(), []string{"GIT_INDEX_FILE=/caller/index"}, nil,
		"/bin/sh", "-c", `printf %s "$GIT_INDEX_FILE"`)
	if err != nil {
		t.Fatal(err)
	}
	if string(out) != "/caller/index" {
		t.Fatalf("GIT_INDEX_FILE = %q, want the caller's", out)
	}
	out, _, err = Exec(context.Background(), t.TempDir(), nil, "/bin/sh", "-c", `printf %s "${GIT_INDEX_FILE-unset}"`)
	if err != nil {
		t.Fatal(err)
	}
	if string(out) != "unset" {
		t.Fatalf("Exec leaked the inherited GIT_INDEX_FILE: %q", out)
	}
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `go test ./internal/gitbin -run 'TestReadsContent_AddAndPatchDiffTree|TestExecEnv_' -v`
Expected: FAIL — `ExecEnv` undefined; `add` reported false.

- [ ] **Step 3: Implement**

In `run.go` replace `contentReads`/`readsContent`:

```go
// contentReads are the subcommands that can run a filter driver on the
// folder's files (add runs clean filters while it stages); log, show and
// diff-tree only with a patch.
var contentReads = []string{"status", "ls-files", "check-ignore", "diff", "diff-files", "diff-index", "add"}

// readsContent: args (subcommand first) may run a filter driver.
func readsContent(args []string) bool {
	if len(args) == 0 {
		return false
	}
	switch args[0] {
	case "log", "show", "diff-tree":
		return slices.ContainsFunc(args[1:], func(a string) bool { return a == "-p" || a == "--patch" || a == "-u" })
	}
	return slices.Contains(contentReads, args[0])
}
```

Replace `Exec` with:

```go
// Exec runs name … (doc unchanged).
func Exec(ctx context.Context, dir string, stdin []byte, name string, args ...string) (stdout, stderr []byte, err error) {
	return ExecEnv(ctx, dir, nil, stdin, name, args...)
}

// ExecEnv is Exec with extraEnv appended after the inherited repository
// variables are dropped: a caller's own GIT_INDEX_FILE (the reviewer's
// temporary index) reaches git, an inherited one never does.
func ExecEnv(ctx context.Context, dir string, extraEnv []string, stdin []byte, name string, args ...string) (stdout, stderr []byte, err error) {
	c := exec.CommandContext(ctx, name, args...)
	c.Dir = dir
	env := slices.DeleteFunc(os.Environ(), func(kv string) bool {
		key, _, _ := strings.Cut(kv, "=")
		return slices.Contains(repositoryEnv, key)
	})
	env = append(env, "GIT_OPTIONAL_LOCKS=0", "GIT_TERMINAL_PROMPT=0", "GIT_EDITOR=true", "GH_PROMPT_DISABLED=1", "LC_ALL=C")
	c.Env = append(env, extraEnv...)
	c.WaitDelay = time.Second
	if stdin != nil {
		c.Stdin = bytes.NewReader(stdin)
	}
	var out, errOut bytes.Buffer
	c.Stdout, c.Stderr = &out, &errOut
	err = c.Run()
	return out.Bytes(), bytes.TrimSpace(errOut.Bytes()), err
}
```

- [ ] **Step 4: Run tests**

Run: `go test ./internal/gitbin ./internal/workbenchgit ./internal/workbenchcheck`
Expected: PASS (existing callers unchanged).

- [ ] **Step 5: Commit**

```bash
git add internal/gitbin/run.go internal/gitbin/run_test.go
git commit -m "feat(gitbin): ExecEnv and add/diff-tree -p as content reads (board #328)"
```

---

### Task 2: reviewdiff — snapshot, base, diff, file, delivery line

**Depends on:** Task 1

**Files:**
- Create: `internal/reviewdiff/reviewdiff.go`, `snapshot.go`, `base.go`, `diff.go`, `file.go`, `limits.go`, `collapse.go`, `line.go`
- Create: `internal/reviewdiff/testdata/lines/{one,many,zero}.json`, `internal/reviewdiff/testdata/README.md`
- Test: `internal/reviewdiff/helpers_test.go`, `snapshot_test.go`, `diff_test.go`, `guard_test.go`, `line_test.go`

**Interfaces:**
- Consumes: `gitbin.ExecEnv`, `gitbin.ReadArgsIn`, `gitbin.Locate`, `gitbin.ErrUnavailable` (Task 1).
- Produces:

```go
package reviewdiff

const EmptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

type Runner func(ctx context.Context, dir string, env []string, name string, args ...string) (stdout []byte, err error)

type Repo struct { /* dir, bin, run */ }
func Open(folder string, run Runner) (*Repo, error) // run nil = real git; ErrNotRepository, gitbin.ErrUnavailable
var ErrNotRepository error

func (r *Repo) Snapshot(ctx context.Context) (tree string, err error)
func (r *Repo) Base(ctx context.Context) (Base, error)
type Base struct { SHA, Label string } // SHA = commit or EmptyTree; Label e.g. "origin/main", "" when none
func (r *Repo) TreeExists(ctx context.Context, sha string) bool
func (r *Repo) Diff(ctx context.Context, from, to string) (Diff, error)
func (r *Repo) File(ctx context.Context, tree, path string) (Side, error)

type Diff struct {
	Files     []File `json:"files"`
	Truncated bool   `json:"truncated"`
}
type File struct {
	Path            string `json:"path"`
	OldPath         string `json:"old_path,omitempty"`
	Status          string `json:"status"` // added|modified|deleted|renamed
	Additions       int    `json:"additions"`
	Deletions       int    `json:"deletions"`
	Binary          bool   `json:"binary"`
	CollapsedReason string `json:"collapsed_reason,omitempty"` // lockfile|generated|too_large
	Hunks           []Hunk `json:"hunks"`
}
type Hunk struct {
	ID       string   `json:"hunk_id"`
	Header   string   `json:"header"`
	OldStart int      `json:"old_start"`
	OldLines int      `json:"old_lines"`
	NewStart int      `json:"new_start"`
	NewLines int      `json:"new_lines"`
	Lines    []string `json:"lines"` // each with its ' ', '+' or '-' prefix
}
type Side struct {
	Exists   bool   `json:"exists"`
	Text     string `json:"text"`
	Binary   bool   `json:"binary"`
	TooLarge bool   `json:"too_large"`
}
```

- [ ] **Step 1: Test helpers**

`helpers_test.go`:

```go
package reviewdiff

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"watchtower/internal/gitbin"
)

func gitBin(t *testing.T) string {
	t.Helper()
	bin, ok := gitbin.Locate()
	if !ok {
		t.Skip("git not installed")
	}
	t.Setenv("GIT_CONFIG_GLOBAL", os.DevNull)
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	t.Setenv("GIT_AUTHOR_NAME", "t")
	t.Setenv("GIT_AUTHOR_EMAIL", "t@example.com")
	t.Setenv("GIT_COMMITTER_NAME", "t")
	t.Setenv("GIT_COMMITTER_EMAIL", "t@example.com")
	return bin
}

func gitIn(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command(gitBin(t), args...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return string(out)
}

func writeFile(t *testing.T, dir, name, content string) {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// newRepo: main with one commit (a.go), the work tree clean.
func newRepo(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	gitIn(t, dir, "init", "-q", "-b", "main")
	writeFile(t, dir, "a.go", "package a\n\nfunc A() int { return 1 }\n")
	gitIn(t, dir, "add", "-A")
	gitIn(t, dir, "commit", "-q", "-m", "init")
	return dir
}

func openRepo(t *testing.T, dir string) *Repo {
	t.Helper()
	gitBin(t)
	r, err := Open(dir, nil)
	if err != nil {
		t.Fatal(err)
	}
	return r
}
```

- [ ] **Step 2: Write the failing tests**

`snapshot_test.go`:

```go
func TestSnapshot_IncludesUntrackedAndLeavesIndexAndRefsAlone(t *testing.T) {
	dir := newRepo(t)
	writeFile(t, dir, "a.go", "package a\n\nfunc A() int { return 2 }\n")
	writeFile(t, dir, "new/b.go", "package new\n")
	indexBefore, _ := os.ReadFile(filepath.Join(dir, ".git", "index"))
	refsBefore := gitIn(t, dir, "for-each-ref")

	r := openRepo(t, dir)
	tree, err := r.Snapshot(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	ls := gitIn(t, dir, "ls-tree", "-r", "--name-only", tree)
	if !strings.Contains(ls, "new/b.go") || !strings.Contains(ls, "a.go") {
		t.Fatalf("snapshot tree misses files:\n%s", ls)
	}
	indexAfter, _ := os.ReadFile(filepath.Join(dir, ".git", "index"))
	if !bytes.Equal(indexBefore, indexAfter) {
		t.Fatal("snapshot wrote the owner's index")
	}
	if refsAfter := gitIn(t, dir, "for-each-ref"); refsAfter != refsBefore {
		t.Fatalf("snapshot moved refs:\n%s\nvs\n%s", refsBefore, refsAfter)
	}
	if st := gitIn(t, dir, "status", "--porcelain"); !strings.Contains(st, "?? new/") {
		t.Fatalf("untracked file got staged in the owner's index:\n%s", st)
	}
}

func TestSnapshot_NoCommitYet(t *testing.T) {
	dir := t.TempDir()
	gitIn(t, dir, "init", "-q", "-b", "main")
	writeFile(t, dir, "x.txt", "x\n")
	r := openRepo(t, dir)
	tree, err := r.Snapshot(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	base, err := r.Base(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if base.SHA != EmptyTree || base.Label != "" {
		t.Fatalf("base = %+v, want the empty tree", base)
	}
	d, err := r.Diff(context.Background(), base.SHA, tree)
	if err != nil {
		t.Fatal(err)
	}
	if len(d.Files) != 1 || d.Files[0].Status != "added" || d.Files[0].Path != "x.txt" {
		t.Fatalf("diff = %+v", d.Files)
	}
}

func TestBase_MergeBaseWithDefaultBranch(t *testing.T) {
	dir := newRepo(t)
	mainSHA := strings.TrimSpace(gitIn(t, dir, "rev-parse", "HEAD"))
	gitIn(t, dir, "switch", "-q", "-c", "feature")
	writeFile(t, dir, "f.go", "package a\n")
	gitIn(t, dir, "add", "-A")
	gitIn(t, dir, "commit", "-q", "-m", "f")
	b, err := openRepo(t, dir).Base(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if b.SHA != mainSHA || b.Label != "main" {
		t.Fatalf("base = %+v, want %s main", b, mainSHA)
	}
}

func TestTreeExists(t *testing.T) {
	dir := newRepo(t)
	r := openRepo(t, dir)
	tree, _ := r.Snapshot(context.Background())
	if !r.TreeExists(context.Background(), tree) {
		t.Fatal("fresh snapshot reported missing")
	}
	if r.TreeExists(context.Background(), strings.Repeat("1", 40)) {
		t.Fatal("unknown sha reported present")
	}
}
```

`diff_test.go`:

```go
func TestDiff_StatusesHunksAndOddPaths(t *testing.T) {
	dir := newRepo(t)
	writeFile(t, dir, "gone.txt", "bye\n")
	writeFile(t, dir, "old name.txt", "same content here\nline2\nline3\n")
	gitIn(t, dir, "add", "-A")
	gitIn(t, dir, "commit", "-q", "-m", "more")
	r := openRepo(t, dir)
	base := strings.TrimSpace(gitIn(t, dir, "rev-parse", "HEAD"))

	writeFile(t, dir, "a.go", "package a\n\nfunc A() int { return 2 }\n")
	os.Remove(filepath.Join(dir, "gone.txt"))
	os.Rename(filepath.Join(dir, "old name.txt"), filepath.Join(dir, "new name.txt"))
	odd := "dir name/файл \"q\".go"
	writeFile(t, dir, odd, "package x\n")
	writeFile(t, dir, "img.bin", "\x00\x01\x02")

	tree, err := r.Snapshot(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	d, err := r.Diff(context.Background(), base, tree)
	if err != nil {
		t.Fatal(err)
	}
	byPath := map[string]File{}
	for _, f := range d.Files {
		byPath[f.Path] = f
	}
	if f := byPath["a.go"]; f.Status != "modified" || f.Additions != 1 || f.Deletions != 1 || len(f.Hunks) != 1 {
		t.Fatalf("a.go = %+v", f)
	}
	if f := byPath["gone.txt"]; f.Status != "deleted" {
		t.Fatalf("gone.txt = %+v", f)
	}
	if f := byPath["new name.txt"]; f.Status != "renamed" || f.OldPath != "old name.txt" {
		t.Fatalf("rename = %+v", f)
	}
	if f := byPath[odd]; f.Status != "added" || len(f.Hunks) != 1 || f.Hunks[0].Lines[0] != "+package x" {
		t.Fatalf("odd path = %+v (all: %v)", f, d.Files)
	}
	if f := byPath["img.bin"]; !f.Binary || len(f.Hunks) != 0 {
		t.Fatalf("binary = %+v", f)
	}
	h := byPath["a.go"].Hunks[0]
	if h.ID == "" || h.NewStart == 0 {
		t.Fatalf("hunk = %+v", h)
	}
	again, _ := r.Diff(context.Background(), base, tree)
	for _, f := range again.Files {
		if f.Path == "a.go" && f.Hunks[0].ID != h.ID {
			t.Fatal("hunk id not stable")
		}
	}
}

func TestDiff_CollapsedAndCaps(t *testing.T) {
	dir := newRepo(t)
	r := openRepo(t, dir)
	base := strings.TrimSpace(gitIn(t, dir, "rev-parse", "HEAD"))
	writeFile(t, dir, "go.sum", "x v1 h1:abc\n")
	writeFile(t, dir, "big.txt", strings.Repeat("line\n", MaxFileChangedLines+1))
	tree, _ := r.Snapshot(context.Background())
	d, err := r.Diff(context.Background(), base, tree)
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range d.Files {
		switch f.Path {
		case "go.sum":
			if f.CollapsedReason != "lockfile" {
				t.Fatalf("go.sum = %+v", f)
			}
		case "big.txt":
			if f.CollapsedReason != "too_large" || len(f.Hunks) != 0 || f.Additions != MaxFileChangedLines+1 {
				t.Fatalf("big.txt = %+v", f)
			}
		}
	}
}

func TestFile_BothSides(t *testing.T) {
	dir := newRepo(t)
	r := openRepo(t, dir)
	base := strings.TrimSpace(gitIn(t, dir, "rev-parse", "HEAD"))
	writeFile(t, dir, "a.go", "package a\n// changed\n")
	tree, _ := r.Snapshot(context.Background())
	old, err := r.File(context.Background(), base, "a.go")
	if err != nil || !old.Exists || !strings.Contains(old.Text, "return 1") {
		t.Fatalf("old = %+v, %v", old, err)
	}
	cur, _ := r.File(context.Background(), tree, "a.go")
	if !strings.Contains(cur.Text, "// changed") {
		t.Fatalf("new = %+v", cur)
	}
	missing, err := r.File(context.Background(), base, "nope.go")
	if err != nil || missing.Exists {
		t.Fatalf("missing = %+v, %v", missing, err)
	}
}
```

`guard_test.go` (REVIEW-05):

```go
// TestReview05_SnapshotAndDiffRunNothingFromTheFolder: a filter driver and an
// fsmonitor the folder's own config names never run.
func TestReview05_SnapshotAndDiffRunNothingFromTheFolder(t *testing.T) {
	dir := newRepo(t)
	marker := filepath.Join(t.TempDir(), "ran")
	script := filepath.Join(t.TempDir(), "evil.sh")
	if err := os.WriteFile(script, []byte("#!/bin/sh\ntouch "+marker+"\ncat\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	gitIn(t, dir, "config", "filter.evil.clean", script)
	gitIn(t, dir, "config", "filter.evil.smudge", script)
	gitIn(t, dir, "config", "core.fsmonitor", script)
	writeFile(t, dir, ".gitattributes", "*.go filter=evil\n")
	writeFile(t, dir, "a.go", "package a // edited\n")

	r := openRepo(t, dir)
	tree, err := r.Snapshot(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := r.Diff(context.Background(), EmptyTree, tree); err != nil {
		t.Fatal(err)
	}
	if _, err := r.File(context.Background(), tree, "a.go"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(marker); err == nil {
		t.Fatal("a command from the folder's git config ran")
	}
}
```

- [ ] **Step 3: Run to verify they fail**

Run: `go test ./internal/reviewdiff`
Expected: FAIL — package does not compile (types undefined).

- [ ] **Step 4: Implement**

`limits.go`:

```go
package reviewdiff

// Caps of one review diff (spec §4.4); the only place these numbers live.
const (
	MaxFileBytes        = 1 << 20
	MaxFileChangedLines = 5000
	MaxTotalLines       = 50000
)
```

`reviewdiff.go`:

```go
// Package reviewdiff snapshots a workbench folder's work tree into a git
// tree object and diffs trees for the Desktop's diff reviewer (spec
// docs/superpowers/specs/2026-10-16-workbench-diff-reviewer-design.md §4).
// It never writes a ref, the owner's index or a work-tree file (REVIEW-01),
// and every git call runs with gitbin's background-read hardening
// (REVIEW-05).
package reviewdiff

import (
	"context"
	"errors"
	"fmt"
	"os/exec"

	"watchtower/internal/gitbin"
)

const EmptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

var ErrNotRepository = errors.New("the folder is not a git work tree")

// Runner runs the located git binary (name) in dir with extra environment.
type Runner func(ctx context.Context, dir string, env []string, name string, args ...string) ([]byte, error)

type Repo struct {
	dir, bin string
	run      Runner
}

// Open checks that folder is inside a work tree. run nil = real git.
func Open(folder string, run Runner) (*Repo, error) {
	bin, ok := gitbin.Locate()
	if !ok {
		return nil, gitbin.ErrUnavailable
	}
	if !gitbin.InsideRepository(folder) {
		return nil, ErrNotRepository
	}
	if run == nil {
		run = execRunner
	}
	return &Repo{dir: folder, bin: bin, run: run}, nil
}

func execRunner(ctx context.Context, dir string, env []string, name string, args ...string) ([]byte, error) {
	argv, err := gitbin.ReadArgsIn(ctx, name, dir, args...)
	if err != nil {
		return nil, err
	}
	out, stderr, err := gitbin.ExecEnv(ctx, dir, env, nil, name, argv...)
	if err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			return out, fmt.Errorf("git %s: exit %d: %s", args[0], exitErr.ExitCode(), clip(stderr))
		}
		return out, fmt.Errorf("git %s: %w", args[0], err)
	}
	return out, nil
}

func (r *Repo) git(ctx context.Context, env []string, args ...string) ([]byte, error) {
	return r.run(ctx, r.dir, env, r.bin, args...)
}

func clip(b []byte) string {
	if len(b) > 300 {
		return string(b[:300])
	}
	return string(b)
}
```

`snapshot.go`:

```go
package reviewdiff

import (
	"context"
	"os"
	"path/filepath"
	"strings"
)

// Snapshot writes the work tree (tracked and untracked, not ignored) as a
// tree object through a private temporary index and returns its sha. Only
// objects are written; no ref and not the owner's index.
func (r *Repo) Snapshot(ctx context.Context) (string, error) {
	tmp, err := os.MkdirTemp("", "wt-review-")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(tmp)
	env := []string{"GIT_INDEX_FILE=" + filepath.Join(tmp, "index")}
	if r.hasHead(ctx) {
		if _, err := r.git(ctx, env, "read-tree", "HEAD"); err != nil {
			return "", err
		}
	}
	if _, err := r.git(ctx, env, "add", "-A", "--", "."); err != nil {
		return "", err
	}
	out, err := r.git(ctx, env, "write-tree")
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

func (r *Repo) hasHead(ctx context.Context) bool {
	_, err := r.git(ctx, nil, "rev-parse", "--verify", "--quiet", "HEAD^{commit}")
	return err == nil
}

// TreeExists: sha names an object in the repository (a pruned snapshot does not).
func (r *Repo) TreeExists(ctx context.Context, sha string) bool {
	_, err := r.git(ctx, nil, "cat-file", "-e", sha+"^{tree}")
	return err == nil
}
```

Note: `add -A -- .` from the folder root stages the whole work tree; the Desktop always passes the worktree root (`ResolveFolder.Root`), so `.` is the repository.

`base.go`:

```go
package reviewdiff

import (
	"context"
	"strings"
)

type Base struct {
	SHA   string `json:"base_sha"`
	Label string `json:"base_label"`
}

// Base is the merge-base of HEAD with the default branch, found as
// workbenchcheck finds it: origin/HEAD's target, else main, else master,
// each tried as refs/remotes/origin/<n> then refs/heads/<n>. No commit, no
// default branch or no merge-base → the empty tree, Label "".
func (r *Repo) Base(ctx context.Context) (Base, error) {
	if !r.hasHead(ctx) {
		return Base{SHA: EmptyTree}, nil
	}
	for _, ref := range r.defaultRefs(ctx) {
		out, err := r.git(ctx, nil, "merge-base", "HEAD", ref)
		if err == nil {
			label := strings.TrimPrefix(strings.TrimPrefix(ref, "refs/remotes/"), "refs/heads/")
			return Base{SHA: strings.TrimSpace(string(out)), Label: label}, nil
		}
	}
	return Base{SHA: EmptyTree}, nil
}

func (r *Repo) defaultRefs(ctx context.Context) []string {
	var names []string
	if out, err := r.git(ctx, nil, "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"); err == nil {
		names = append(names, strings.TrimPrefix(strings.TrimSpace(string(out)), "refs/remotes/origin/"))
	}
	names = append(names, "main", "master")
	var refs []string
	for _, n := range names {
		for _, ref := range []string{"refs/remotes/origin/" + n, "refs/heads/" + n} {
			if _, err := r.git(ctx, nil, "rev-parse", "--verify", "--quiet", ref+"^{commit}"); err == nil {
				refs = append(refs, ref)
			}
		}
	}
	return refs
}
```

`collapse.go`:

```go
package reviewdiff

import (
	"path"
	"slices"
	"strings"
)

var lockfiles = []string{"go.sum", "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "Package.resolved",
	"Cargo.lock", "Gemfile.lock", "poetry.lock", "composer.lock"}

// collapsedReason: lockfiles and generated files are folded by default.
func collapsedReason(p string) string {
	base := path.Base(p)
	switch {
	case slices.Contains(lockfiles, base):
		return "lockfile"
	case strings.HasSuffix(base, ".pb.go"), strings.HasSuffix(base, "_generated.go"),
		strings.HasSuffix(base, ".generated.swift"), strings.Contains(p, "/generated/"),
		strings.HasSuffix(base, ".golden"):
		return "generated"
	}
	return ""
}
```

(The spec's `linguist-generated` attribute is left out of v1: reading attributes from a tree needs `check-attr --source`, which older git lacks; name patterns cover the repo's cases. Recorded in the feature note.)

`diff.go`:

```go
package reviewdiff

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strconv"
	"strings"
)

// Diff lists from → to: paths and statuses from `diff-tree -z --name-status`
// (NUL-separated, so any path is exact), hunks from `diff-tree -p` matched
// to the files in the same order git emits both.
func (r *Repo) Diff(ctx context.Context, from, to string) (Diff, error) {
	names, err := r.git(ctx, nil, "diff-tree", "-r", "-M", "-z", "--name-status", "--no-commit-id", from, to)
	if err != nil {
		return Diff{}, err
	}
	files := parseNameStatus(names)
	patch, err := r.git(ctx, nil, "-c", "core.quotePath=false", "diff-tree", "-r", "-M", "-p",
		"--no-commit-id", "--no-color", "--no-ext-diff", "--no-textconv", "--full-index", from, to)
	if err != nil {
		return Diff{}, err
	}
	sections := splitSections(patch)
	if len(sections) != len(files) {
		return Diff{}, fmt.Errorf("diff-tree: %d files but %d patch sections", len(files), len(sections))
	}
	d := Diff{Files: files}
	total := 0
	for i := range d.Files {
		f := &d.Files[i]
		f.CollapsedReason = collapsedReason(f.Path)
		parseSection(f, sections[i])
		changed := f.Additions + f.Deletions
		switch {
		case changed > MaxFileChangedLines:
			f.CollapsedReason, f.Hunks = "too_large", nil
		case total+changed > MaxTotalLines:
			d.Truncated, f.Hunks = true, nil
		}
		total += changed
	}
	return d, nil
}

func parseNameStatus(b []byte) []File {
	fields := strings.Split(strings.TrimSuffix(string(b), "\x00"), "\x00")
	var files []File
	for i := 0; i < len(fields); {
		st := fields[i]
		if st == "" {
			break
		}
		switch st[0] {
		case 'R', 'C':
			files = append(files, File{Status: "renamed", OldPath: fields[i+1], Path: fields[i+2]})
			i += 3
		case 'A':
			files = append(files, File{Status: "added", Path: fields[i+1]})
			i += 2
		case 'D':
			files = append(files, File{Status: "deleted", Path: fields[i+1]})
			i += 2
		default: // M, T
			files = append(files, File{Status: "modified", Path: fields[i+1]})
			i += 2
		}
	}
	return files
}

// splitSections cuts the patch at each "diff --git " line.
func splitSections(patch []byte) [][]string {
	var out [][]string
	sc := bufio.NewScanner(bytes.NewReader(patch))
	sc.Buffer(make([]byte, 1<<20), 64<<20)
	for sc.Scan() {
		line := sc.Text()
		if strings.HasPrefix(line, "diff --git ") {
			out = append(out, nil)
		}
		if len(out) > 0 {
			out[len(out)-1] = append(out[len(out)-1], line)
		}
	}
	return out
}

func parseSection(f *File, lines []string) {
	var cur *Hunk
	flush := func() {
		if cur != nil {
			cur.ID = hunkID(f.Path, *cur)
			f.Hunks = append(f.Hunks, *cur)
			cur = nil
		}
	}
	for _, l := range lines {
		switch {
		case strings.HasPrefix(l, "Binary files ") || strings.HasPrefix(l, "GIT binary patch"):
			f.Binary = true
		case strings.HasPrefix(l, "@@ "):
			flush()
			h := Hunk{Header: l}
			h.OldStart, h.OldLines, h.NewStart, h.NewLines = parseRange(l)
			cur = &h
		case cur != nil && (strings.HasPrefix(l, "+") || strings.HasPrefix(l, "-") || strings.HasPrefix(l, " ")):
			cur.Lines = append(cur.Lines, l)
			if l[0] == '+' {
				f.Additions++
			} else if l[0] == '-' {
				f.Deletions++
			}
		case cur != nil && strings.HasPrefix(l, `\ `):
			cur.Lines = append(cur.Lines, l) // "\ No newline at end of file"
		}
	}
	flush()
}

// parseRange reads "@@ -a,b +c,d @@" (",b"/",d" default to 1).
func parseRange(h string) (os, ol, ns, nl int) {
	parts := strings.Fields(h)
	if len(parts) < 3 {
		return
	}
	os, ol = span(strings.TrimPrefix(parts[1], "-"))
	ns, nl = span(strings.TrimPrefix(parts[2], "+"))
	return
}

func span(s string) (start, n int) {
	a, b, ok := strings.Cut(s, ",")
	start, _ = strconv.Atoi(a)
	n = 1
	if ok {
		n, _ = strconv.Atoi(b)
	}
	return
}

func hunkID(path string, h Hunk) string {
	sum := sha256.New()
	fmt.Fprintf(sum, "%s\n%s\n%s", path, h.Header, strings.Join(h.Lines, "\n"))
	return hex.EncodeToString(sum.Sum(nil))[:16]
}
```

`file.go`:

```go
package reviewdiff

import (
	"bytes"
	"context"
	"strconv"
	"strings"
)

// File returns path's content in tree (Exists false when the path is not
// there). Over MaxFileBytes → TooLarge, no text; a NUL in the first 8 KB →
// Binary, no text.
func (r *Repo) File(ctx context.Context, tree, path string) (Side, error) {
	spec := tree + ":" + path
	if _, err := r.git(ctx, nil, "cat-file", "-e", spec); err != nil {
		return Side{}, nil
	}
	sizeOut, err := r.git(ctx, nil, "cat-file", "-s", spec)
	if err != nil {
		return Side{}, err
	}
	size, _ := strconv.Atoi(strings.TrimSpace(string(sizeOut)))
	if size > MaxFileBytes {
		return Side{Exists: true, TooLarge: true}, nil
	}
	blob, err := r.git(ctx, nil, "cat-file", "blob", spec)
	if err != nil {
		return Side{}, err
	}
	head := blob
	if len(head) > 8192 {
		head = head[:8192]
	}
	if bytes.IndexByte(head, 0) >= 0 {
		return Side{Exists: true, Binary: true}, nil
	}
	return Side{Exists: true, Text: string(blob)}, nil
}
```

- [ ] **Step 5: Run tests**

Run: `go test ./internal/reviewdiff -v`
Expected: PASS. If `TestDiff_StatusesHunksAndOddPaths` reports a section/file count mismatch, check that the rename detection flags (`-M`) are identical in both `diff-tree` calls.

- [ ] **Step 6: Delivery line (Go side, fixtures shared with Swift)**

Produces: `func DeliveryLine(roundID int64, comments int) string`.

`testdata/lines/one.json`: `{"round_id":7,"comments":1,"line":"Review round #7 sent (1 comment) — read it with get_review 7 using the watchtower-workbench skill."}`
`testdata/lines/many.json`: `{"round_id":12,"comments":5,"line":"Review round #12 sent (5 comments) — read it with get_review 12 using the watchtower-workbench skill."}`
`testdata/lines/zero.json`: `{"round_id":3,"comments":0,"line":"Review round #3 sent (0 comments) — read it with get_review 3 using the watchtower-workbench skill."}`
`testdata/README.md`: "These fixtures are read by Go `TestDeliveryLine_Fixtures` and Swift `ReviewDeliveryLineTests`; change both sides together."

`line_test.go`:

```go
func TestDeliveryLine_Fixtures(t *testing.T) {
	paths, _ := filepath.Glob("testdata/lines/*.json")
	if len(paths) < 3 {
		t.Fatal("fixtures missing")
	}
	for _, p := range paths {
		var fx struct {
			RoundID  int64  `json:"round_id"`
			Comments int    `json:"comments"`
			Line     string `json:"line"`
		}
		b, _ := os.ReadFile(p)
		if err := json.Unmarshal(b, &fx); err != nil {
			t.Fatal(err)
		}
		if got := DeliveryLine(fx.RoundID, fx.Comments); got != fx.Line {
			t.Errorf("%s: %q, want %q", p, got, fx.Line)
		}
	}
}
```

`line.go`:

```go
package reviewdiff

import "fmt"

// DeliveryLine is the one line the Desktop types into the round's session
// after Send, through PROJ-12's gates (spec §9) — the Go side of the Swift
// ReviewDeliveryLine, pinned by testdata/lines. No owner or agent text is in it.
func DeliveryLine(roundID int64, comments int) string {
	return fmt.Sprintf("Review round #%d sent (%s) — read it with get_review %d using the watchtower-workbench skill.",
		roundID, CommentCount(comments), roundID)
}

// CommentCount: "1 comment", "N comments" (the delivery line and the brief).
func CommentCount(n int) string {
	if n == 1 {
		return "1 comment"
	}
	return fmt.Sprintf("%d comments", n)
}
```

Run: `go test ./internal/reviewdiff -run TestDeliveryLine_ -v` → PASS.

- [ ] **Step 7: Lint and commit**

```bash
make lint-diff
git add internal/reviewdiff
git commit -m "feat(reviewdiff): snapshot via temp index, base, tree diff, file sides, delivery line (board #328)"
```

---

### Task 3: Migration 00117 and Go DB layer for rounds

**Depends on:** none

**Files:**
- Create: `internal/db/migrations/00117_review_rounds.sql`, `internal/db/review_rounds.go`
- Modify: `internal/db/schema.sql` (append section), `internal/db/db_test.go:166` (`expectedTables`)
- Regenerate: `internal/db/testdata/*.golden`, `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift`
- Test: `internal/db/review_rounds_test.go`

**Interfaces:**
- Produces:

```go
type ReviewRound struct {
	ID, ProjectID int64
	SessionID     sql.NullInt64
	Source        string // "session"
	FolderRoot    string
	BaseSHA       string
	BaseLabel     string
	TreeSHA       string
	PrevRoundID   sql.NullInt64
	Status        string // open|sent|delivered
	Mode          string
	CreatedAt     string
	SentAt        sql.NullString
	DeliveredAt   sql.NullString
}
type ReviewComment struct {
	ID, RoundID          int64
	Path                 sql.NullString // NULL = design comment (Plan 2)
	Side                 string         // old|new
	StartLine, EndLine   int
	Quote, TreeSHA, Lens string
	Body, Status         string
	CarriedFrom          sql.NullInt64
	AgentReply           string
}
var ErrReviewRoundNotOpen = errors.New("review round is not open")
func (db *DB) OpenReviewRound(projectID, sessionID int64) (*ReviewRound, error)            // nil, nil when none
func (db *DB) CreateReviewRound(r ReviewRound) (int64, error)                               // status 'open'
func (db *DB) UpdateReviewRoundTree(id int64, tree string) error                            // ErrReviewRoundNotOpen
func (db *DB) SendReviewRound(projectID, id int64) (sent int, ok bool, err error)          // ok=false: not open
func (db *DB) GetReviewRound(projectID, id int64) (*ReviewRound, error)                    // sql.ErrNoRows wrapped
func (db *DB) LastSentReviewRound(projectID, sessionID int64) (*ReviewRound, error)        // nil, nil when none
func (db *DB) ReviewRoundComments(roundID int64) ([]ReviewComment, error)
func (db *DB) MarkReviewRoundDelivered(projectID, id int64) (bool, error)
func (db *DB) ReviewRoundsWaiting(projectID, sessionID int64) ([]ReviewRound, error)       // sent, not delivered
```

- [ ] **Step 1: Migration**

`00117_review_rounds.sql`:

```sql
-- +goose Up
CREATE TABLE review_rounds (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  project_id     INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  session_id     INTEGER REFERENCES terminal_sessions(id) ON DELETE SET NULL,
  source         TEXT NOT NULL DEFAULT 'session' CHECK (source IN ('session','pr')),
  folder_root    TEXT NOT NULL,
  base_sha       TEXT NOT NULL,
  base_label     TEXT NOT NULL DEFAULT '',
  tree_sha       TEXT NOT NULL,
  prev_round_id  INTEGER REFERENCES review_rounds(id) ON DELETE SET NULL,
  status         TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','sent','delivered')),
  mode           TEXT NOT NULL DEFAULT 'quick' CHECK (mode IN ('quick','deep')),
  phase          TEXT NOT NULL DEFAULT '',
  chapter_key    TEXT NOT NULL DEFAULT '',
  active_seconds INTEGER NOT NULL DEFAULT 0 CHECK (active_seconds >= 0),
  created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  sent_at        TEXT,
  delivered_at   TEXT
);
CREATE UNIQUE INDEX review_rounds_one_open ON review_rounds(session_id) WHERE status = 'open' AND session_id IS NOT NULL;
CREATE INDEX review_rounds_project ON review_rounds(project_id, id);

CREATE TABLE review_comments (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  round_id       INTEGER NOT NULL REFERENCES review_rounds(id) ON DELETE CASCADE,
  path           TEXT,
  side           TEXT NOT NULL DEFAULT 'new' CHECK (side IN ('old','new')),
  start_line     INTEGER NOT NULL DEFAULT 0,
  end_line       INTEGER NOT NULL DEFAULT 0,
  quote          TEXT NOT NULL DEFAULT '',
  quote_prefix   TEXT NOT NULL DEFAULT '',
  quote_suffix   TEXT NOT NULL DEFAULT '',
  tree_sha       TEXT NOT NULL DEFAULT '',
  lens           TEXT NOT NULL DEFAULT '',
  body           TEXT NOT NULL,
  status         TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','sent','carried','resolved','outdated')),
  carried_from   INTEGER REFERENCES review_comments(id) ON DELETE SET NULL,
  agent_reply    TEXT NOT NULL DEFAULT '',
  agent_reply_at TEXT,
  created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  updated_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
CREATE INDEX review_comments_round ON review_comments(round_id, id);

CREATE TABLE review_viewed (
  round_id    INTEGER NOT NULL REFERENCES review_rounds(id) ON DELETE CASCADE,
  path        TEXT NOT NULL,
  content_sha TEXT NOT NULL,
  PRIMARY KEY (round_id, path)
);

-- +goose Down
DROP TABLE review_viewed;
DROP TABLE review_comments;
DROP TABLE review_rounds;
```

Deviation from spec §10 recorded: the spec's single migration is split per plan — Plan 1 creates the three tables it uses; Plans 2–3 add `review_checks`, `review_reverts`, `review_notes`, `review_overviews`, `review_lessons` in their own migrations (new tables only, no recreation).

Mirror the three `CREATE TABLE IF NOT EXISTS` blocks (and the two indexes) into `internal/db/schema.sql` at the end under `-- Diff reviewer rounds (00117, spec 2026-10-16-workbench-diff-reviewer-design.md)`, with one trailing `--` comment per non-obvious column (status values, `carried_from`, `path` NULL = design comment). Add `"review_rounds", "review_comments", "review_viewed",` to `expectedTables`.

- [ ] **Step 2: Regenerate schema snapshots**

Run: `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`
Then: `go test ./internal/db/ -run 'TestMigrationIdempotent|TestAllTablesExist|TestSchemaGolden|TestDesktopTestSchema'`
Expected: PASS.

- [ ] **Step 3: Write the failing DB tests**

`review_rounds_test.go`:

```go
package db

import (
	"errors"
	"testing"
)

func seedReviewSession(t *testing.T, d *DB) (projectID, sessionID int64) {
	t.Helper()
	projectID, err := d.CreateWorkbench("acme", t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	var res sql.Result
	res, err = d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id)
		VALUES (?, 'claude', 's', '/tmp/wb-review', 'uuid')`, projectID)
	if err != nil {
		t.Fatal(err)
	}
	sessionID, _ = res.LastInsertId()
	return
}

func TestReviewRounds_OneOpenPerSessionAndGuardedSend(t *testing.T) {
	d := openTestDB(t)
	pid, sid := seedReviewSession(t, d)
	r := ReviewRound{ProjectID: pid, SessionID: nullInt(sid), FolderRoot: "/tmp/wb-review", BaseSHA: "b", TreeSHA: "t1"}
	id, err := d.CreateReviewRound(r)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := d.CreateReviewRound(r); err == nil {
		t.Fatal("second open round for the same session was accepted")
	}
	if _, err := d.Exec(`INSERT INTO review_comments (round_id, path, start_line, end_line, quote, body) VALUES (?, 'a.go', 3, 3, 'x', 'fix')`, id); err != nil {
		t.Fatal(err)
	}
	n, ok, err := d.SendReviewRound(pid, id)
	if err != nil || !ok || n != 1 {
		t.Fatalf("send = %d %v %v", n, ok, err)
	}
	if _, ok, _ := d.SendReviewRound(pid, id); ok {
		t.Fatal("a sent round was sent again")
	}
	cs, _ := d.ReviewRoundComments(id)
	if len(cs) != 1 || cs[0].Status != "sent" {
		t.Fatalf("comments = %+v", cs)
	}
	if err := d.UpdateReviewRoundTree(id, "t2"); !errors.Is(err, ErrReviewRoundNotOpen) {
		t.Fatalf("tree update on a sent round: %v", err)
	}
	waiting, _ := d.ReviewRoundsWaiting(pid, sid)
	if len(waiting) != 1 {
		t.Fatalf("waiting = %+v", waiting)
	}
	if ok, _ := d.MarkReviewRoundDelivered(pid, id); !ok {
		t.Fatal("deliver failed")
	}
	if ok, _ := d.MarkReviewRoundDelivered(pid+1, id); ok {
		t.Fatal("another workbench delivered the round")
	}
	last, _ := d.LastSentReviewRound(pid, sid)
	if last == nil || last.ID != id {
		t.Fatalf("last sent = %+v", last)
	}
	if _, err := d.CreateReviewRound(r); err != nil {
		t.Fatalf("a new round after send: %v", err)
	}
}

func TestReviewRounds_RefusedSendFromAnotherWorkbenchWritesNothing(t *testing.T) {
	d := openTestDB(t)
	pid, sid := seedReviewSession(t, d)
	a, _ := d.CreateReviewRound(ReviewRound{ProjectID: pid, SessionID: nullInt(sid), FolderRoot: "/r", BaseSHA: "b", TreeSHA: "t"})
	d.Exec(`INSERT INTO review_comments (round_id, body) VALUES (?, 'mine')`, a)
	if _, ok, err := d.SendReviewRound(pid+100, a); ok || err != nil {
		t.Fatalf("send from another workbench: %v %v", ok, err)
	}
	cs, _ := d.ReviewRoundComments(a)
	if cs[0].Status != "draft" {
		t.Fatal("a refused send changed a draft")
	}
}
```

Add to the test file (imports `database/sql`): `func nullInt(v int64) sql.NullInt64 { return sql.NullInt64{Int64: v, Valid: true} }` — unless `grep -n "func nullInt" internal/db/*_test.go` finds one already, then use it.

- [ ] **Step 4: Run to verify they fail**

Run: `go test ./internal/db -run TestReviewRounds_ -v`
Expected: FAIL — methods undefined.

- [ ] **Step 5: Implement `review_rounds.go`**

```go
package db

import (
	"database/sql"
	"errors"
	"fmt"
)

// Diff reviewer rounds (migration 00117, spec
// 2026-10-16-workbench-diff-reviewer-design.md §5, §10). Go writes rounds and
// the send transition; drafts and Viewed marks are the Desktop's.

var ErrReviewRoundNotOpen = errors.New("review round is not open")

type ReviewRound struct {
	ID, ProjectID int64
	SessionID     sql.NullInt64
	Source        string
	FolderRoot    string
	BaseSHA       string
	BaseLabel     string
	TreeSHA       string
	PrevRoundID   sql.NullInt64
	Status        string
	Mode          string
	CreatedAt     string
	SentAt        sql.NullString
	DeliveredAt   sql.NullString
}

type ReviewComment struct {
	ID, RoundID        int64
	Path               sql.NullString
	Side               string
	StartLine, EndLine int
	Quote, TreeSHA     string
	Lens, Body, Status string
	CarriedFrom        sql.NullInt64
	AgentReply         string
}

const reviewRoundCols = `id, project_id, session_id, source, folder_root, base_sha, base_label, tree_sha,
	prev_round_id, status, mode, created_at, sent_at, delivered_at`

func scanReviewRound(s interface{ Scan(...any) error }) (*ReviewRound, error) {
	var r ReviewRound
	err := s.Scan(&r.ID, &r.ProjectID, &r.SessionID, &r.Source, &r.FolderRoot, &r.BaseSHA, &r.BaseLabel,
		&r.TreeSHA, &r.PrevRoundID, &r.Status, &r.Mode, &r.CreatedAt, &r.SentAt, &r.DeliveredAt)
	if err != nil {
		return nil, err
	}
	return &r, nil
}

func (db *DB) oneReviewRound(query string, args ...any) (*ReviewRound, error) {
	r, err := scanReviewRound(db.QueryRow(query, args...))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return r, err
}

// OpenReviewRound is session sessionID's open round, nil when none.
func (db *DB) OpenReviewRound(projectID, sessionID int64) (*ReviewRound, error) {
	return db.oneReviewRound(`SELECT `+reviewRoundCols+` FROM review_rounds
		WHERE project_id = ? AND session_id = ? AND status = 'open'`, projectID, sessionID)
}

// LastSentReviewRound is the session's newest sent or delivered round.
func (db *DB) LastSentReviewRound(projectID, sessionID int64) (*ReviewRound, error) {
	return db.oneReviewRound(`SELECT `+reviewRoundCols+` FROM review_rounds
		WHERE project_id = ? AND session_id = ? AND status IN ('sent','delivered')
		ORDER BY id DESC LIMIT 1`, projectID, sessionID)
}

// GetReviewRound reads round id of workbench projectID.
func (db *DB) GetReviewRound(projectID, id int64) (*ReviewRound, error) {
	r, err := scanReviewRound(db.QueryRow(`SELECT `+reviewRoundCols+` FROM review_rounds
		WHERE id = ? AND project_id = ?`, id, projectID))
	if err != nil {
		return nil, fmt.Errorf("review round %d: %w", id, err)
	}
	return r, nil
}

// CreateReviewRound inserts an open round; a second open round of the same
// session fails on review_rounds_one_open.
func (db *DB) CreateReviewRound(r ReviewRound) (int64, error) {
	if r.Source == "" {
		r.Source = "session"
	}
	if r.Mode == "" {
		r.Mode = "quick"
	}
	res, err := db.Exec(`INSERT INTO review_rounds (project_id, session_id, source, folder_root, base_sha,
		base_label, tree_sha, prev_round_id, mode) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		r.ProjectID, r.SessionID, r.Source, r.FolderRoot, r.BaseSHA, r.BaseLabel, r.TreeSHA, r.PrevRoundID, r.Mode)
	if err != nil {
		return 0, fmt.Errorf("creating review round: %w", err)
	}
	return res.LastInsertId()
}

// UpdateReviewRoundTree moves an open round to a fresh snapshot (Refresh).
func (db *DB) UpdateReviewRoundTree(id int64, tree string) error {
	res, err := db.Exec(`UPDATE review_rounds SET tree_sha = ? WHERE id = ? AND status = 'open'`, tree, id)
	if err != nil {
		return fmt.Errorf("refreshing review round %d: %w", id, err)
	}
	if n, _ := res.RowsAffected(); n != 1 {
		return fmt.Errorf("review round %d: %w", id, ErrReviewRoundNotOpen)
	}
	return nil
}

// SendReviewRound moves an open round to sent and its drafts to sent in one
// transaction; ok false (nothing written) when the round is not open or not
// this workbench's. sent counts the round's comments now sent.
func (db *DB) SendReviewRound(projectID, id int64) (sent int, ok bool, err error) {
	tx, err := db.Begin()
	if err != nil {
		return 0, false, err
	}
	defer tx.Rollback() //nolint:errcheck // a committed tx makes this a no-op
	res, err := tx.Exec(`UPDATE review_rounds SET status = 'sent', sent_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE id = ? AND project_id = ? AND status = 'open'`, id, projectID)
	if err != nil {
		return 0, false, fmt.Errorf("sending review round %d: %w", id, err)
	}
	if n, _ := res.RowsAffected(); n != 1 {
		return 0, false, nil
	}
	if _, err := tx.Exec(`UPDATE review_comments SET status = 'sent', updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE round_id = ? AND status = 'draft'`, id); err != nil {
		return 0, false, err
	}
	if err := tx.QueryRow(`SELECT COUNT(*) FROM review_comments WHERE round_id = ? AND status = 'sent'`, id).Scan(&sent); err != nil {
		return 0, false, err
	}
	return sent, true, tx.Commit()
}

// ReviewRoundComments lists a round's comments in id order.
func (db *DB) ReviewRoundComments(roundID int64) ([]ReviewComment, error) {
	rows, err := db.Query(`SELECT id, round_id, path, side, start_line, end_line, quote, tree_sha, lens, body,
		status, carried_from, agent_reply FROM review_comments WHERE round_id = ? ORDER BY id`, roundID)
	if err != nil {
		return nil, fmt.Errorf("reading review round %d comments: %w", roundID, err)
	}
	defer rows.Close()
	var out []ReviewComment
	for rows.Next() {
		var c ReviewComment
		if err := rows.Scan(&c.ID, &c.RoundID, &c.Path, &c.Side, &c.StartLine, &c.EndLine, &c.Quote, &c.TreeSHA,
			&c.Lens, &c.Body, &c.Status, &c.CarriedFrom, &c.AgentReply); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// MarkReviewRoundDelivered: get_review read a sent round (false otherwise).
func (db *DB) MarkReviewRoundDelivered(projectID, id int64) (bool, error) {
	res, err := db.Exec(`UPDATE review_rounds SET status = 'delivered',
		delivered_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE id = ? AND project_id = ? AND status = 'sent'`, id, projectID)
	if err != nil {
		return false, fmt.Errorf("delivering review round %d: %w", id, err)
	}
	n, err := res.RowsAffected()
	return n == 1, err
}

// ReviewRoundsWaiting: the session's sent, unread rounds, oldest first (the brief).
func (db *DB) ReviewRoundsWaiting(projectID, sessionID int64) ([]ReviewRound, error) {
	rows, err := db.Query(`SELECT `+reviewRoundCols+` FROM review_rounds
		WHERE project_id = ? AND session_id = ? AND status = 'sent' ORDER BY id`, projectID, sessionID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []ReviewRound
	for rows.Next() {
		r, err := scanReviewRound(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *r)
	}
	return out, rows.Err()
}
```

- [ ] **Step 6: Run tests, commit**

Run: `go test ./internal/db -run 'TestReviewRounds_|TestAllTablesExist|TestSchemaGolden|TestDesktopTestSchema'`
Expected: PASS.

```bash
git add internal/db WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift
git commit -m "feat(db): review rounds, comments and viewed tables (00117, board #328)"
```

---

### Task 4: CLI `watchtower workbench review …`

**Depends on:** Tasks 2, 3

**Files:**
- Create: `cmd/workbench_review.go`, `cmd/workbench_review_context.go`
- Test: `cmd/workbench_review_test.go`

**Interfaces:**
- Consumes: `reviewdiff.Open/Snapshot/Base/Diff/File/TreeExists` (Task 2); `db.OpenReviewRound/CreateReviewRound/UpdateReviewRoundTree/SendReviewRound/GetReviewRound/LastSentReviewRound` (Task 3); `workbenchWithFolder`, `openJiraCmdDB`, `addWorkbenchIDFlag`, `checkWorkbenchIDFlags`, `workbenchGitContext`, `writeJSON` (existing cmd helpers); `workbenchgit.ResolveFolder`; `db.TerminalAgentCwd`, `db.GetTerminalSession`, `db.SessionLinkedTargets`, `db.GetTargetByID`.
- Produces (all `--workbench N --json`, exit 0 with `ok:false` + `error` once the workbench resolves; exit ≠ 0 only for a bad id/missing workbench):

```
workbench review start   --session S [--refresh]   → {"ok","round":{id,status,mode,folder_root,base_sha,base_label,tree_sha,prev_round_id,prev_tree_sha,prev_tree_lost}}
workbench review diff    --round R [--since]       → {"ok","diff":Diff,"from","to","previous_tree_lost"}
workbench review file    --round R --path P [--since] → {"ok","old":Side,"new":Side}
workbench review send    --round R                 → {"ok","sent":bool,"comments":n,"line":"Review round #R sent (…)"}
workbench review context --session S               → {"ok","items":[{target_id,text,intent,plan_path,plan_task,plan_text,spec_path,missing}]}
```

Swift decodes these keys exactly (Task 7).

- `start`: resolves the session's folder (`TerminalAgentCwd(S).Path` if set, else the workbench folder) through `workbenchgit.ResolveFolder(ctx, Options{Folder: workbench.FolderPath}, agentCwd)` and uses `Root`; if an open round exists it is returned as is, unless `--refresh`, which re-snapshots and `UpdateReviewRoundTree`; otherwise snapshot, base, `prev_round_id` = `LastSentReviewRound`, create. `prev_tree_lost` = prev round's tree no longer exists.
- `diff --since`: from = prev round's `tree_sha` if it exists, else the base with `previous_tree_lost: true`.
- `send`: `SendReviewRound`; `line` = `reviewdiff.DeliveryLine(id, n)` (Task 5) — only when `sent` is true.
- `context`: for each linked target: text/intent; when intent matches `^(\S+\.md) — Task (\d+)`, read that file (relative to the workbench folder, `os.Lstat` must be a regular file ≤ 1 MB, no symlink) and cut the section from the `### Task N:` heading to the next `### ` heading; `spec_path` = the first `**Spec:** \`(…)\`` in the plan. A missing file or task → `missing: "plan"` / `"task"`.

- [ ] **Step 1: Write the failing tests**

```go
package cmd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"watchtower/internal/db"
)

// reviewFixture: a workbench bound to a git repo (main + README.md, branch
// feature, from gitBranchRepo) and a session row on it.
func reviewFixture(t *testing.T) (database *db.DB, wbID, sessionID int64, repo string) {
	t.Helper()
	database = writeActionsConfig(t)
	repo = gitBranchRepo(t)
	wbID, err := database.CreateWorkbench("acme", repo)
	require.NoError(t, err)
	sessionID = reviewSession(t, database, wbID, repo)
	return database, wbID, sessionID, repo
}

func reviewSession(t *testing.T, database *db.DB, wbID int64, folder string) int64 {
	t.Helper()
	res, err := database.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id)
		VALUES (?, 'claude', 's', ?, 'uuid')`, wbID, folder)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

func reviewJSON(t *testing.T, wb int64, sub string, args ...string) map[string]any {
	t.Helper()
	out, err := runWorkbenchAs(t, "workbench", append([]string{"review", sub, "--workbench", itoa(wb), "--json"}, args...)...)
	resetSetFlags(workbenchReviewCmd.Commands()...)
	require.NoError(t, err)
	var m map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &m), out)
	return m
}

func itoa(v int64) string { return strconv.FormatInt(v, 10) }

func TestWorkbenchReview_StartDiffSendRound(t *testing.T) {
	_, wb, s, repo := reviewFixture(t)
	if err := os.WriteFile(filepath.Join(repo, "README.md"), []byte("changed\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	start := reviewJSON(t, wb, "start", "--session", itoa(s))
	round := start["round"].(map[string]any)
	rid := int64(round["id"].(float64))
	again := reviewJSON(t, wb, "start", "--session", itoa(s))
	if int64(again["round"].(map[string]any)["id"].(float64)) != rid {
		t.Fatal("start opened a second round instead of resuming")
	}
	diff := reviewJSON(t, wb, "diff", "--round", itoa(rid))
	files := diff["diff"].(map[string]any)["files"].([]any)
	if len(files) != 1 || files[0].(map[string]any)["path"] != "README.md" {
		t.Fatalf("files = %v", files)
	}
	file := reviewJSON(t, wb, "file", "--round", itoa(rid), "--path", "README.md")
	if !strings.Contains(file["new"].(map[string]any)["text"].(string), "changed") {
		t.Fatalf("file = %v", file)
	}
	sent := reviewJSON(t, wb, "send", "--round", itoa(rid))
	if sent["sent"] != true || !strings.HasPrefix(sent["line"].(string), "Review round #") {
		t.Fatalf("send = %v", sent)
	}
	twice := reviewJSON(t, wb, "send", "--round", itoa(rid))
	if twice["sent"] != false || twice["line"] != nil && twice["line"] != "" {
		t.Fatalf("second send = %v", twice)
	}
}

func TestWorkbenchReview_SinceLastRoundAndRefresh(t *testing.T) {
	_, wb, s, repo := reviewFixture(t)
	os.WriteFile(filepath.Join(repo, "README.md"), []byte("one\n"), 0o644)
	r1 := int64(reviewJSON(t, wb, "start", "--session", itoa(s))["round"].(map[string]any)["id"].(float64))
	reviewJSON(t, wb, "send", "--round", itoa(r1))
	os.WriteFile(filepath.Join(repo, "x.txt"), []byte("new\n"), 0o644)
	r2 := reviewJSON(t, wb, "start", "--session", itoa(s))["round"].(map[string]any)
	if int64(r2["prev_round_id"].(float64)) != r1 {
		t.Fatalf("prev = %v", r2)
	}
	id2 := itoa(int64(r2["id"].(float64)))
	since := reviewJSON(t, wb, "diff", "--round", id2, "--since")["diff"].(map[string]any)["files"].([]any)
	if len(since) != 1 || since[0].(map[string]any)["path"] != "x.txt" {
		t.Fatalf("since = %v", since)
	}
	os.WriteFile(filepath.Join(repo, "y.txt"), []byte("later\n"), 0o644)
	ref := reviewJSON(t, wb, "start", "--session", itoa(s), "--refresh")["round"].(map[string]any)
	if ref["tree_sha"] == r2["tree_sha"] {
		t.Fatal("refresh kept the old tree")
	}
}

func TestWorkbenchReview_NotARepositoryIsAnEnvelope(t *testing.T) {
	database := writeActionsConfig(t)
	dir := t.TempDir()
	wb, err := database.CreateWorkbench("acme", dir)
	require.NoError(t, err)
	s := reviewSession(t, database, wb, dir)
	out := reviewJSON(t, wb, "start", "--session", itoa(s))
	assert.Equal(t, false, out["ok"])
	assert.NotEmpty(t, out["error"])
}

func TestWorkbenchReview_ContextReadsPlanTask(t *testing.T) {
	database, wb, s, repo := reviewFixture(t)
	plan := "# P\n\n**Spec:** `docs/spec.md`\n\n### Task 1: One\nstep one\n\n### Task 2: Two\nstep two\n"
	require.NoError(t, os.MkdirAll(filepath.Join(repo, "docs"), 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(repo, "docs", "plan.md"), []byte(plan), 0o644))
	tid := db.SeedTestWorkbenchTarget(t, database, wb, sql.NullInt64{}, "Task two")
	_, err := database.Exec(`UPDATE targets SET intent = 'docs/plan.md — Task 2' WHERE id = ?`, tid)
	require.NoError(t, err)
	_, err = database.Exec(`INSERT INTO terminal_session_targets (session_id, target_id, first_at, last_at) VALUES (?, ?, 'x', 'x')`, s, tid)
	require.NoError(t, err)
	items := reviewJSON(t, wb, "context", "--session", itoa(s))["items"].([]any)
	require.Len(t, items, 1)
	it := items[0].(map[string]any)
	assert.Contains(t, it["plan_text"], "step two")
	assert.NotContains(t, it["plan_text"], "step one")
	assert.Equal(t, "docs/spec.md", it["spec_path"])
}

func TestWorkbenchReview_ContextPlanEscapeStaysInFolder(t *testing.T) {
	database, wb, s, _ := reviewFixture(t)
	tid := db.SeedTestWorkbenchTarget(t, database, wb, sql.NullInt64{}, "Escape")
	_, err := database.Exec(`UPDATE targets SET intent = '../../etc/passwd.md — Task 1' WHERE id = ?`, tid)
	require.NoError(t, err)
	_, err = database.Exec(`INSERT INTO terminal_session_targets (session_id, target_id, first_at, last_at) VALUES (?, ?, 'x', 'x')`, s, tid)
	require.NoError(t, err)
	it := reviewJSON(t, wb, "context", "--session", itoa(s))["items"].([]any)[0].(map[string]any)
	assert.Equal(t, "plan", it["missing"])
}
```

`db.SeedTestWorkbenchTarget(t, d, workbenchID, parent sql.NullInt64, text) int64` is the exported test seed `internal/tools/workbenches_test.go:33` already uses; check its return type with `grep -n "func SeedTestWorkbenchTarget" internal/db/*.go` and convert if it returns `int`. Imports: `database/sql`, `encoding/json`, `os`, `path/filepath`, `strconv`, `strings`, `testing`, testify `assert`/`require`, `watchtower/internal/db`. Rewrite the first two tests' `t.Fatal` checks with `require`/`assert` in the same style when implementing (behaviour unchanged).

- [ ] **Step 2: Run to verify they fail**

Run: `go test ./cmd -run TestWorkbenchReview_ -v`
Expected: FAIL — `review` subcommand unknown.

- [ ] **Step 3: Implement `cmd/workbench_review.go`**

```go
package cmd

import (
	"context"
	"database/sql"
	"fmt"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/db"
	"watchtower/internal/reviewdiff"
	"watchtower/internal/workbenchgit"
)

const workbenchReviewBudget = 30 * time.Second

var (
	workbenchReviewCmd = &cobra.Command{Use: "review", Short: "Diff reviewer rounds of a workbench session (JSON for the Desktop)"}

	workbenchReviewStartCmd   = &cobra.Command{Use: "start", Short: "Open or resume the session's review round", RunE: runWorkbenchReviewStart}
	workbenchReviewDiffCmd    = &cobra.Command{Use: "diff", Short: "The round's diff", RunE: runWorkbenchReviewDiff}
	workbenchReviewFileCmd    = &cobra.Command{Use: "file", Short: "Both sides of one file of the round", RunE: runWorkbenchReviewFile}
	workbenchReviewSendCmd    = &cobra.Command{Use: "send", Short: "Close the round and print its delivery line", RunE: runWorkbenchReviewSend}
	workbenchReviewContextCmd = &cobra.Command{Use: "context", Short: "The session's intent card", RunE: runWorkbenchReviewContext}

	reviewFlagWorkbench int64
	reviewFlagJSON      bool
	reviewFlagSession   int64
	reviewFlagRound     int64
	reviewFlagPath      string
	reviewFlagSince     bool
	reviewFlagRefresh   bool
)

func init() {
	for _, c := range []*cobra.Command{workbenchReviewStartCmd, workbenchReviewDiffCmd, workbenchReviewFileCmd,
		workbenchReviewSendCmd, workbenchReviewContextCmd} {
		addWorkbenchIDFlag(c, &reviewFlagWorkbench, "workbench id")
		c.Flags().BoolVar(&reviewFlagJSON, "json", false, "output JSON")
		workbenchReviewCmd.AddCommand(c)
	}
	for _, c := range []*cobra.Command{workbenchReviewStartCmd, workbenchReviewContextCmd} {
		c.Flags().Int64Var(&reviewFlagSession, "session", 0, "terminal session id")
	}
	for _, c := range []*cobra.Command{workbenchReviewDiffCmd, workbenchReviewFileCmd, workbenchReviewSendCmd} {
		c.Flags().Int64Var(&reviewFlagRound, "round", 0, "review round id")
	}
	workbenchReviewDiffCmd.Flags().BoolVar(&reviewFlagSince, "since", false, "diff since the previous round")
	workbenchReviewFileCmd.Flags().BoolVar(&reviewFlagSince, "since", false, "old side = the previous round")
	workbenchReviewFileCmd.Flags().StringVar(&reviewFlagPath, "path", "", "file path in the round")
	workbenchReviewStartCmd.Flags().BoolVar(&reviewFlagRefresh, "refresh", false, "re-snapshot an open round")
	workbenchCmd.AddCommand(workbenchReviewCmd)
}

type reviewRoundJSON struct {
	ID           int64  `json:"id"`
	Status       string `json:"status"`
	Mode         string `json:"mode"`
	FolderRoot   string `json:"folder_root"`
	BaseSHA      string `json:"base_sha"`
	BaseLabel    string `json:"base_label"`
	TreeSHA      string `json:"tree_sha"`
	PrevRoundID  int64  `json:"prev_round_id"`
	PrevTreeSHA  string `json:"prev_tree_sha"`
	PrevTreeLost bool   `json:"prev_tree_lost"`
}

type reviewEnvelope struct {
	OK               bool                `json:"ok"`
	Error            string              `json:"error,omitempty"`
	Round            *reviewRoundJSON    `json:"round,omitempty"`
	Diff             *reviewdiff.Diff    `json:"diff,omitempty"`
	From             string              `json:"from,omitempty"`
	To               string              `json:"to,omitempty"`
	PreviousTreeLost bool                `json:"previous_tree_lost,omitempty"`
	Old              *reviewdiff.Side    `json:"old,omitempty"`
	New              *reviewdiff.Side    `json:"new,omitempty"`
	Sent             *bool               `json:"sent,omitempty"`
	Comments         int                 `json:"comments,omitempty"`
	Line             string              `json:"line,omitempty"`
	Items            []reviewContextItem `json:"items,omitempty"`
}

// reviewTarget resolves --workbench to its row and an open DB; a bad id or a
// missing workbench is a command error (non-zero exit).
func reviewTarget(cmd *cobra.Command) (*db.DB, *db.Workbench, error) {
	if err := checkWorkbenchIDFlags(cmd); err != nil {
		return nil, nil, err
	}
	if reviewFlagWorkbench <= 0 {
		return nil, nil, fmt.Errorf("--workbench is required")
	}
	_, database, err := openJiraCmdDB()
	if err != nil {
		return nil, nil, err
	}
	p, err := workbenchWithFolder(database, reviewFlagWorkbench)
	if err != nil {
		return nil, nil, err
	}
	return database, p, nil
}

func writeReview(cmd *cobra.Command, env reviewEnvelope) error {
	if reviewFlagJSON {
		return writeJSON(cmd.OutOrStdout(), env)
	}
	if !env.OK {
		fmt.Fprintln(cmd.OutOrStdout(), "error:", env.Error)
		return nil
	}
	fmt.Fprintf(cmd.OutOrStdout(), "ok\n")
	return nil
}

func failReview(cmd *cobra.Command, err error) error {
	return writeReview(cmd, reviewEnvelope{Error: err.Error()})
}

func roundJSON(ctx context.Context, repo *reviewdiff.Repo, database *db.DB, r *db.ReviewRound) *reviewRoundJSON {
	out := &reviewRoundJSON{ID: r.ID, Status: r.Status, Mode: r.Mode, FolderRoot: r.FolderRoot, BaseSHA: r.BaseSHA,
		BaseLabel: r.BaseLabel, TreeSHA: r.TreeSHA}
	if r.PrevRoundID.Valid {
		out.PrevRoundID = r.PrevRoundID.Int64
		if prev, err := database.GetReviewRound(r.ProjectID, r.PrevRoundID.Int64); err == nil {
			out.PrevTreeSHA = prev.TreeSHA
			out.PrevTreeLost = !repo.TreeExists(ctx, prev.TreeSHA)
		}
	}
	return out
}

// sessionFolder: the root of the folder the session's agent works in.
func sessionFolder(ctx context.Context, database *db.DB, p *db.Workbench, sessionID int64) (string, error) {
	row, err := database.GetTerminalSession(sessionID)
	if err != nil {
		return "", err
	}
	if !row.WorkbenchID.Valid || row.WorkbenchID.Int64 != p.ID {
		return "", fmt.Errorf("session %d is not on workbench %d", sessionID, p.ID)
	}
	cwd, err := database.TerminalAgentCwd(sessionID)
	if err != nil {
		return "", err
	}
	folder, err := workbenchgit.ResolveFolder(ctx, workbenchgit.Options{Folder: p.FolderPath}, cwd.Path)
	if err != nil {
		return "", err
	}
	if folder.Root == "" {
		return p.FolderPath, nil
	}
	return folder.Root, nil
}

func runWorkbenchReviewStart(cmd *cobra.Command, _ []string) error {
	database, p, err := reviewTarget(cmd)
	if err != nil {
		return err
	}
	ctx, cancel := workbenchGitContext(cmd, workbenchReviewBudget)
	defer cancel()
	open, err := database.OpenReviewRound(p.ID, reviewFlagSession)
	if err != nil {
		return failReview(cmd, err)
	}
	folder := ""
	if open != nil {
		folder = open.FolderRoot
	} else if folder, err = sessionFolder(ctx, database, p, reviewFlagSession); err != nil {
		return failReview(cmd, err)
	}
	repo, err := reviewdiff.Open(folder, nil)
	if err != nil {
		return failReview(cmd, err)
	}
	if open != nil && !reviewFlagRefresh {
		return writeReview(cmd, reviewEnvelope{OK: true, Round: roundJSON(ctx, repo, database, open)})
	}
	tree, err := repo.Snapshot(ctx)
	if err != nil {
		return failReview(cmd, err)
	}
	if open != nil {
		if err := database.UpdateReviewRoundTree(open.ID, tree); err != nil {
			return failReview(cmd, err)
		}
		open.TreeSHA = tree
		return writeReview(cmd, reviewEnvelope{OK: true, Round: roundJSON(ctx, repo, database, open)})
	}
	base, err := repo.Base(ctx)
	if err != nil {
		return failReview(cmd, err)
	}
	r := db.ReviewRound{ProjectID: p.ID, SessionID: sql.NullInt64{Int64: reviewFlagSession, Valid: true},
		FolderRoot: folder, BaseSHA: base.SHA, BaseLabel: base.Label, TreeSHA: tree}
	if last, err := database.LastSentReviewRound(p.ID, reviewFlagSession); err == nil && last != nil {
		r.PrevRoundID = sql.NullInt64{Int64: last.ID, Valid: true}
	}
	id, err := database.CreateReviewRound(r)
	if err != nil {
		return failReview(cmd, err)
	}
	created, err := database.GetReviewRound(p.ID, id)
	if err != nil {
		return failReview(cmd, err)
	}
	return writeReview(cmd, reviewEnvelope{OK: true, Round: roundJSON(ctx, repo, database, created)})
}

// roundRange: from/to of the round's diff; since → the previous round's tree
// when it still exists, else the base with lost=true.
func roundRange(ctx context.Context, repo *reviewdiff.Repo, database *db.DB, r *db.ReviewRound) (from string, lost bool) {
	if !reviewFlagSince || !r.PrevRoundID.Valid {
		return r.BaseSHA, false
	}
	prev, err := database.GetReviewRound(r.ProjectID, r.PrevRoundID.Int64)
	if err != nil || !repo.TreeExists(ctx, prev.TreeSHA) {
		return r.BaseSHA, true
	}
	return prev.TreeSHA, false
}

func loadRound(cmd *cobra.Command) (*db.DB, *db.ReviewRound, *reviewdiff.Repo, context.Context, context.CancelFunc, error) {
	database, p, err := reviewTarget(cmd)
	if err != nil {
		return nil, nil, nil, nil, nil, err
	}
	ctx, cancel := workbenchGitContext(cmd, workbenchReviewBudget)
	r, err := database.GetReviewRound(p.ID, reviewFlagRound)
	if err != nil {
		cancel()
		return nil, nil, nil, nil, nil, failReview(cmd, err)
	}
	repo, err := reviewdiff.Open(r.FolderRoot, nil)
	if err != nil {
		cancel()
		return nil, nil, nil, nil, nil, failReview(cmd, err)
	}
	return database, r, repo, ctx, cancel, nil
}

func runWorkbenchReviewDiff(cmd *cobra.Command, _ []string) error {
	database, r, repo, ctx, cancel, err := loadRound(cmd)
	if err != nil || r == nil {
		return err
	}
	defer cancel()
	from, lost := roundRange(ctx, repo, database, r)
	d, err := repo.Diff(ctx, from, r.TreeSHA)
	if err != nil {
		return failReview(cmd, err)
	}
	return writeReview(cmd, reviewEnvelope{OK: true, Diff: &d, From: from, To: r.TreeSHA, PreviousTreeLost: lost})
}

func runWorkbenchReviewFile(cmd *cobra.Command, _ []string) error {
	database, r, repo, ctx, cancel, err := loadRound(cmd)
	if err != nil || r == nil {
		return err
	}
	defer cancel()
	from, _ := roundRange(ctx, repo, database, r)
	oldSide, err := repo.File(ctx, from, reviewFlagPath)
	if err != nil {
		return failReview(cmd, err)
	}
	newSide, err := repo.File(ctx, r.TreeSHA, reviewFlagPath)
	if err != nil {
		return failReview(cmd, err)
	}
	return writeReview(cmd, reviewEnvelope{OK: true, Old: &oldSide, New: &newSide})
}

func runWorkbenchReviewSend(cmd *cobra.Command, _ []string) error {
	database, p, err := reviewTarget(cmd)
	if err != nil {
		return err
	}
	n, ok, err := database.SendReviewRound(p.ID, reviewFlagRound)
	if err != nil {
		return failReview(cmd, err)
	}
	env := reviewEnvelope{OK: true, Sent: &ok, Comments: n}
	if ok {
		env.Line = reviewdiff.DeliveryLine(reviewFlagRound, n)
	}
	return writeReview(cmd, env)
}
```

Note on `loadRound`'s error path: when `failReview` wrote an envelope it returns nil, so the caller sees `err == nil && r == nil` and returns; keep that `|| r == nil` check in every caller.

- [ ] **Step 4: Implement `cmd/workbench_review_context.go`**

```go
package cmd

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/spf13/cobra"

	"watchtower/internal/db"
)

type reviewContextItem struct {
	TargetID int    `json:"target_id"`
	Text     string `json:"text"`
	Intent   string `json:"intent"`
	PlanPath string `json:"plan_path,omitempty"`
	PlanTask int    `json:"plan_task,omitempty"`
	PlanText string `json:"plan_text,omitempty"`
	SpecPath string `json:"spec_path,omitempty"`
	Missing  string `json:"missing,omitempty"` // "plan" | "task"
}

var (
	planTaskIntent = regexp.MustCompile(`^(\S+\.md) — Task (\d+)`)
	planSpecLine   = regexp.MustCompile("\\*\\*Spec:\\*\\* `([^`]+)`")
)

const maxPlanBytes = 1 << 20

func runWorkbenchReviewContext(cmd *cobra.Command, _ []string) error {
	database, p, err := reviewTarget(cmd)
	if err != nil {
		return err
	}
	ids, err := database.SessionLinkedTargets(reviewFlagSession)
	if err != nil {
		return failReview(cmd, err)
	}
	items := []reviewContextItem{}
	for _, id := range ids {
		t, err := database.GetTargetByID(int(id))
		if err != nil || t == nil {
			continue
		}
		items = append(items, contextItem(p.FolderPath, t))
	}
	return writeReview(cmd, reviewEnvelope{OK: true, Items: items})
}

func contextItem(folder string, t *db.Target) reviewContextItem {
	it := reviewContextItem{TargetID: t.ID, Text: t.Text, Intent: t.Intent}
	m := planTaskIntent.FindStringSubmatch(t.Intent)
	if m == nil {
		return it
	}
	it.PlanPath = m[1]
	it.PlanTask = atoiOr(m[2], 0)
	body, ok := readPlainFile(filepath.Join(folder, filepath.Clean("/"+m[1])))
	if !ok {
		it.Missing = "plan"
		return it
	}
	if s := planSpecLine.FindStringSubmatch(body); s != nil {
		it.SpecPath = s[1]
	}
	it.PlanText = taskSection(body, it.PlanTask)
	if it.PlanText == "" {
		it.Missing = "task"
	}
	return it
}

// readPlainFile: a regular, non-symlink file of at most maxPlanBytes.
func readPlainFile(path string) (string, bool) {
	fi, err := os.Lstat(path)
	if err != nil || !fi.Mode().IsRegular() || fi.Size() > maxPlanBytes {
		return "", false
	}
	b, err := os.ReadFile(path)
	return string(b), err == nil
}

// taskSection: from "### Task N:" to the next "### " heading.
func taskSection(body string, n int) string {
	head := "### Task " + itoaInt(n) + ":"
	start := strings.Index(body, head)
	if start < 0 {
		return ""
	}
	rest := body[start+len(head):]
	if end := strings.Index(rest, "\n### "); end >= 0 {
		rest = rest[:end]
	}
	return strings.TrimSpace(head + rest)
}
```

(`filepath.Clean("/"+rel)` keeps a `../` intent inside the folder. `atoiOr`/`itoaInt`: use `strconv.Atoi`/`strconv.Itoa` inline if no such helpers exist in `cmd`.)

- [ ] **Step 5: Run tests, lint, commit**

Run: `go test ./cmd -run 'TestWorkbenchReview_|TestWorkbenchGit_' && make lint-diff`
Expected: PASS.

```bash
git add cmd/workbench_review.go cmd/workbench_review_context.go cmd/workbench_review_test.go
git commit -m "feat(cmd): workbench review start/diff/file/send/context (board #328)"
```

---

### Task 5: `get_review` MCP tool, brief line, skill pack v9

**Depends on:** Tasks 2, 3

**Files:**
- Create: `internal/tools/workbench_review.go`, `internal/tools/workbench_review_test.go`
- Modify: `internal/tools/workbenches.go` (`workbenchTools` list), `cmd/actions_registry_test.go` (`pinProjectSurface` list), `cmd/workbench_brief.go` (+ test in `cmd/workbench_brief_session_test.go`)
- Modify: `internal/devpack/workbenchskill/watchtower-workbench/SKILL.md`, `internal/devpack/workbench_test.go:124-132`; add fixture `internal/devpack/testdata/watchtower-workbench-v8.md` if the v1–v7 fixtures pattern holds (copy the current SKILL.md before editing)

**Interfaces:**
- Consumes: `reviewdiff.CommentCount` (Task 2), `db.GetReviewRound/ReviewRoundComments/MarkReviewRoundDelivered/ReviewRoundsWaiting` (Task 3).
- Produces: MCP tool `get_review {round_id}` (AccessRead, Surfaces `workbenchSurfaces`) returning:

```json
{"round_id":7,"status":"delivered","folder":"/…","tree_sha":"…","base_label":"main",
 "comments":[{"id":3,"path":"a.go","side":"new","start_line":10,"end_line":12,"quote":"…","lens":"","body":"…","carried_from":0}],
 "text":"Review round #7 — 1 comment\n#3 a.go:10-12\n> …\n…"}
```

Reading a `sent` round marks it `delivered` (same AGENT-06 scope exception as `get_ask`'s delivered write — note it in the inventory, Task 10).

- [ ] **Step 1: Write the failing `get_review` tests**

`internal/tools/workbench_review_test.go` — on the fixtures the `get_ask` tests use (`newWorkbenchFixture`, `askRegistry`, `callReadIn`, `seedTerminalSession`, `directBinding`):

```go
package tools

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// seedSentReviewRound: a session on workbench wb, a round with one comment
// (path, lines, quote, body), sent.
func seedSentReviewRound(t *testing.T, d *db.DB, wb int64, path string, start, end int, quote, body string) int64 {
	t.Helper()
	sid := seedTerminalSession(t, d, wb)
	rid, err := d.CreateReviewRound(db.ReviewRound{ProjectID: wb, SessionID: sql.NullInt64{Int64: sid, Valid: true},
		FolderRoot: "/tmp/acme", BaseSHA: "b", BaseLabel: "main", TreeSHA: "t"})
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO review_comments (round_id, path, start_line, end_line, quote, body) VALUES (?, ?, ?, ?, ?, ?)`,
		rid, path, start, end, quote, body)
	require.NoError(t, err)
	_, ok, err := d.SendReviewRound(wb, rid)
	require.NoError(t, err)
	require.True(t, ok)
	return rid
}

func TestGetReview_ReadsCommentsAndMarksDelivered(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := askRegistry(t, fx.d, "")
	rid := seedSentReviewRound(t, fx.d, fx.a, "a.go", 10, 12, "x := 1", "rename x")
	got := callReadIn(t, reg, fx.a, "get_review", fmt.Sprintf(`{"round_id":%d}`, rid))
	var v reviewView
	require.NoError(t, json.Unmarshal([]byte(got), &v))
	assert.Equal(t, "delivered", v.Status)
	require.Len(t, v.Comments, 1)
	assert.Equal(t, "rename x", v.Comments[0].Body)
	assert.Contains(t, v.Text, "a.go:10-12")
	assert.Contains(t, v.Text, "> x := 1")
	r, err := fx.d.GetReviewRound(fx.a, rid)
	require.NoError(t, err)
	assert.Equal(t, "delivered", r.Status)
}

func TestGetReview_OtherWorkbenchRefused(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := askRegistry(t, fx.d, "")
	rid := seedSentReviewRound(t, fx.d, fx.a, "a.go", 1, 1, "q", "c")
	_, err := reg.CallRead(context.Background(), "get_review", json.RawMessage(fmt.Sprintf(`{"round_id":%d}`, rid)), directBinding(fx.b))
	require.Error(t, err)
	r, _ := fx.d.GetReviewRound(fx.a, rid)
	assert.Equal(t, "sent", r.Status, "a refused read delivers nothing")
}

func TestGetReview_OpenRoundAndDraftsStayHidden(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := askRegistry(t, fx.d, "")
	sid := seedTerminalSession(t, fx.d, fx.a)
	open, err := fx.d.CreateReviewRound(db.ReviewRound{ProjectID: fx.a, SessionID: sql.NullInt64{Int64: sid, Valid: true},
		FolderRoot: "/tmp/acme", BaseSHA: "b", TreeSHA: "t"})
	require.NoError(t, err)
	_, err = reg.CallRead(context.Background(), "get_review", json.RawMessage(fmt.Sprintf(`{"round_id":%d}`, open)), directBinding(fx.a))
	require.Error(t, err, "an open round is not readable")

	rid := seedSentReviewRound(t, fx.d, fx.a, "a.go", 1, 1, "q", "sent one")
	_, err = fx.d.Exec(`INSERT INTO review_comments (round_id, body, status) VALUES (?, 'still a draft', 'draft')`, rid)
	require.NoError(t, err)
	got := callReadIn(t, reg, fx.a, "get_review", fmt.Sprintf(`{"round_id":%d}`, rid))
	assert.NotContains(t, got, "still a draft")
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `go test ./internal/tools -run TestGetReview_ -v`
Expected: FAIL — `get_review` not registered.

- [ ] **Step 3: Implement `internal/tools/workbench_review.go`**

```go
package tools

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"watchtower/internal/db"
)

type getReviewArgs struct {
	RoundID int64 `json:"round_id" jsonschema:"required,description=the review round id from the 'Review round #N sent' line or the brief"`
}

type reviewCommentView struct {
	ID          int64  `json:"id"`
	Path        string `json:"path,omitempty"`
	Side        string `json:"side"`
	StartLine   int    `json:"start_line"`
	EndLine     int    `json:"end_line"`
	Quote       string `json:"quote"`
	Lens        string `json:"lens,omitempty"`
	Body        string `json:"body"`
	CarriedFrom int64  `json:"carried_from,omitempty"`
}

type reviewView struct {
	RoundID   int64               `json:"round_id"`
	Status    string              `json:"status"`
	Folder    string              `json:"folder"`
	TreeSHA   string              `json:"tree_sha"`
	BaseLabel string              `json:"base_label"`
	Comments  []reviewCommentView `json:"comments"`
	Text      string              `json:"text"`
}

// NewGetReview: the agent reads a sent review round (spec §8.2); reading a
// sent round marks it delivered.
func NewGetReview() *Tool {
	return &Tool{
		Name: "get_review",
		Description: "Read a review round the owner sent from Watchtower's diff reviewer: every comment with its file, " +
			"lines, the quoted code and the owner's text. Answer each comment in your reply and fix the code; the " +
			"line 'Review round #N sent' or the session brief names the round.",
		InputSchema: mustSchema[getReviewArgs]("get_review"),
		Access:      AccessRead,
		Surfaces:    workbenchSurfaces,
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a getReviewArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, err
			}
			p, err := workbenchOf(ctx, d, call.Binding)
			if err != nil {
				return nil, err
			}
			r, err := d.GetReviewRound(p.ID, a.RoundID)
			if err != nil {
				return nil, fmt.Errorf("review round %d is not on this workbench", a.RoundID)
			}
			if r.Status == "open" {
				return nil, fmt.Errorf("review round %d is still open: the owner has not sent it", a.RoundID)
			}
			if r.Status == "sent" {
				if _, err := d.MarkReviewRoundDelivered(p.ID, r.ID); err != nil {
					return nil, err
				}
				r.Status = "delivered"
			}
			cs, err := d.ReviewRoundComments(r.ID)
			if err != nil {
				return nil, err
			}
			v := reviewView{RoundID: r.ID, Status: r.Status, Folder: r.FolderRoot, TreeSHA: r.TreeSHA, BaseLabel: r.BaseLabel,
				Comments: []reviewCommentView{}}
			for _, c := range cs {
				if c.Status != "sent" {
					continue
				}
				v.Comments = append(v.Comments, reviewCommentView{ID: c.ID, Path: c.Path.String, Side: c.Side,
					StartLine: c.StartLine, EndLine: c.EndLine, Quote: c.Quote, Lens: c.Lens, Body: c.Body,
					CarriedFrom: c.CarriedFrom.Int64})
			}
			v.Text = reviewText(v)
			return v, nil
		},
	}
}

func reviewText(v reviewView) string {
	var b strings.Builder
	fmt.Fprintf(&b, "Review round #%d — %d comment(s), folder %s\n", v.RoundID, len(v.Comments), v.Folder)
	for _, c := range v.Comments {
		where := "design"
		if c.Path != "" {
			where = fmt.Sprintf("%s:%d-%d", c.Path, c.StartLine, c.EndLine)
		}
		fmt.Fprintf(&b, "\n#%d %s\n", c.ID, where)
		for _, l := range strings.Split(strings.TrimRight(c.Quote, "\n"), "\n") {
			if l != "" {
				fmt.Fprintf(&b, "> %s\n", l)
			}
		}
		fmt.Fprintf(&b, "%s\n", c.Body)
	}
	return b.String()
}
```

Add `NewGetReview(),` to `workbenchTools` after `NewGetAsk()`, and `"get_review"` to the `workbenchTools` list in `cmd/actions_registry_test.go` `pinProjectSurface`. If `internal/mcp/workbench_test.go` asserts the full served tool list, add the name there too (`go test ./internal/mcp` will say).

Run: `go test ./internal/tools -run TestGetReview_ ./cmd -run TestActionsRegistry ./internal/mcp` → PASS.

- [ ] **Step 4: Brief line**

In `cmd/workbench_brief.go`, next to `loadBriefAsks`, load `database.ReviewRoundsWaiting(workbenchID, sessionID)` (only when `sessionID > 0`) and render, after the asks section and before the cleanup line, one line per round:
`Review round #<id> waiting (<count>) → get_review <id>`
where `<count>` = `reviewdiff.CommentCount(n)` and `n` = the round's comments with status `sent` (`ReviewRoundComments`, filtered). A read error renders `Review rounds: could not be read (<err>)` instead — never a silent skip. Follow `briefAsksSection`'s cut order: these lines are cut before the asks, never before the board. Helper: `func reviewWaitingLine(id int64, n int) string`.

Test (append to `cmd/workbench_brief_session_test.go`; imports already there plus `database/sql`):

```go
func TestProjectBrief_ListsWaitingReviewRounds(t *testing.T) {
	database, pid, row := briefSessionFixture(t)
	other, err := database.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id)
		VALUES (?, 'claude', 'other', '/tmp/acme', ?)`, pid, briefClearedID)
	require.NoError(t, err)
	otherRow, _ := other.LastInsertId()

	rid, err := database.CreateReviewRound(db.ReviewRound{ProjectID: pid, SessionID: sql.NullInt64{Int64: row, Valid: true},
		FolderRoot: "/tmp/acme", BaseSHA: "b", TreeSHA: "t"})
	require.NoError(t, err)
	_, err = database.Exec(`INSERT INTO review_comments (round_id, path, body) VALUES (?, 'a.go', 'fix')`, rid)
	require.NoError(t, err)
	_, ok, err := database.SendReviewRound(pid, rid)
	require.NoError(t, err)
	require.True(t, ok)

	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	out, _ := runBriefHook(t, pid, hookPayload("startup", briefLaunchID))
	assert.Contains(t, out, fmt.Sprintf("Review round #%d waiting (1 comment) → get_review %d", rid, rid))

	t.Setenv(terminalSessionEnv, strconv.FormatInt(otherRow, 10))
	out, _ = runBriefHook(t, pid, hookPayload("startup", briefClearedID))
	assert.NotContains(t, out, "Review round #", "another session's brief does not list it")

	_, err = database.MarkReviewRoundDelivered(pid, rid)
	require.NoError(t, err)
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	out, _ = runBriefHook(t, pid, hookPayload("resume", briefLaunchID))
	assert.NotContains(t, out, "Review round #", "a delivered round is no longer waiting")
}
```

- [ ] **Step 5: Skill pack v9**

Before editing, copy the current `SKILL.md` to `internal/devpack/testdata/watchtower-workbench-v8.md` if `ls internal/devpack/testdata/` shows a v7 fixture (follow the pattern; skip if v7 is absent). In `SKILL.md`: marker `x-watchtower-pack: v9`; add to **Tools** a bullet `- \`get_review\` — read a review round the owner sent from the diff reviewer (\`round_id\`): each comment with file, lines, quoted code and text.` and a new section after "Asking the owner":

```markdown
## Review rounds

The owner reviews your changes in Watchtower's diff reviewer and sends a round as one line: `Review round #N sent (K comments) — read it with get_review N …`. A waiting round is also listed in the session brief.

- Call `get_review N` first. Each comment names a file and lines of the snapshot the owner reviewed, with the quoted code; the code may have moved since — find it by the quote.
- Address every comment: fix it, or say why not. In your reply, name each comment as `#<id>` with what you did, one line each.
- A design comment (no file) is about the approach as a whole; answer it before the line comments.
- Do not ask the owner to re-review: they open the next round themselves.
```

Update `internal/devpack/workbench_test.go`: the marker assertion to `v9` and the version-history comment (`v9 — review rounds, get_review`); add `get_review` to the mentioned-tools assertion at line ~112.

Run: `go test ./internal/devpack ./cmd -run 'TestProjectBrief_|TestDevpack'` → PASS.

- [ ] **Step 6: Commit**

```bash
make lint-diff
git add internal/reviewdiff internal/tools cmd internal/devpack
git commit -m "feat(workbench): get_review, review delivery line, brief line, skill pack v9 (board #328)"
```

---

### Task 6: Swift core — models, queries, delivery line, comment anchor

**Depends on:** Tasks 2 (line fixtures), 3 (schema)

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Models/ReviewModels.swift`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ReviewQueries.swift`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Review/ReviewDeliveryLine.swift`, `ReviewCommentAnchor.swift`
- Test: `WatchtowerDesktop/Tests/Core/ReviewQueriesTests.swift`, `ReviewDeliveryLineTests.swift`, `ReviewCommentAnchorTests.swift`

**Interfaces:**
- Consumes: Task 4 JSON keys; Task 5 fixtures; `CommentAnchor` (`WatchtowerCore/Services/CommentAnchor.swift`), `WorkbenchCommentPrompt.oneLine`.
- Produces:

```swift
package struct ReviewRoundInfo: Decodable, Equatable, Sendable {
    package let id: Int64; package let status: String; package let mode: String
    package let folderRoot: String; package let baseSha: String; package let baseLabel: String
    package let treeSha: String; package let prevRoundId: Int64; package let prevTreeSha: String; package let prevTreeLost: Bool
}
package struct ReviewDiffFile: Decodable, Equatable, Sendable, Identifiable {
    package var id: String { path }
    package let path: String; package let oldPath: String?; package let status: String
    package let additions: Int; package let deletions: Int; package let binary: Bool
    package let collapsedReason: String?; package let hunks: [ReviewHunk]
}
package struct ReviewHunk: Decodable, Equatable, Sendable { hunkId, header, oldStart, oldLines, newStart, newLines, lines }
package struct ReviewDiff: Decodable, Equatable, Sendable { files: [ReviewDiffFile]; truncated: Bool }
package struct ReviewFileSide: Decodable, Equatable, Sendable { exists, text, binary, tooLarge }
package struct ReviewContextItem: Decodable, Equatable, Sendable { targetId, text, intent, planPath?, planTask?, planText?, specPath?, missing? }
package struct ReviewEnvelope: Decodable, Sendable { ok, error?, round?, diff?, from?, to?, previousTreeLost?, old?, new?, sent?, comments?, line?, items? }

package struct ReviewComment: FetchableRecord, Decodable, Equatable, Identifiable, Sendable {
    package enum Status: String, Decodable, Sendable { case draft, sent, carried, resolved, outdated }
    package let id: Int64; package let roundID: Int64; package let path: String?; package let side: String
    package let startLine: Int; package let endLine: Int; package let quote: String
    package let quotePrefix: String; package let quoteSuffix: String; package let treeSHA: String
    package let lens: String; package let body: String; package let status: Status
    package let carriedFrom: Int64?; package let agentReply: String
}

package enum ReviewQueries {
    package static func comments(_ db: Database, roundID: Int64) throws -> [ReviewComment]
    package static func addDraft(_ db: Database, roundID: Int64, path: String?, side: String, startLine: Int, endLine: Int,
                                 anchor: CommentAnchor, treeSHA: String, body: String) throws -> Int64
    package static func updateDraft(_ db: Database, id: Int64, body: String) throws          // drafts only
    package static func deleteDraft(_ db: Database, id: Int64) throws                       // drafts only
    package static func carry(_ db: Database, from previous: [ReviewComment], into roundID: Int64,
                              plan: ReviewCommentAnchor.Plan, treeSHA: String) throws
    package static func viewed(_ db: Database, roundID: Int64) throws -> [String: String]   // path → content sha
    package static func setViewed(_ db: Database, roundID: Int64, path: String, contentSHA: String?) throws // nil = unmark
}

package enum ReviewDeliveryLine { package static func line(roundID: Int64, comments: Int) -> String }

package enum ReviewCommentAnchor {
    package struct Placement: Equatable, Sendable { package let startLine: Int; package let endLine: Int }
    package struct Plan: Equatable, Sendable {
        package var moved: [Int64: Placement]   // comment id → new lines
        package var lost: Set<Int64>            // → outdated
    }
    package static func anchor(text: String, startLine: Int, endLine: Int) -> CommentAnchor
    package static func plan(_ comments: [ReviewComment], textFor path: (String) -> String?) -> Plan
}
```

- [ ] **Step 1: Write the failing tests**

`ReviewDeliveryLineTests.swift` — reads the Go fixtures (path relative to the test file, the way `OwnerAskPromptTests` locates `internal/asks/testdata/lines`; copy its locating code):

```swift
import XCTest
@testable import WatchtowerCore

final class ReviewDeliveryLineTests: XCTestCase {
    func testMatchesGoFixtures() throws {
        let dir = repoRoot().appendingPathComponent("internal/reviewdiff/testdata/lines")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertGreaterThanOrEqual(files.count, 3)
        for url in files {
            struct Fixture: Decodable { let round_id: Int64; let comments: Int; let line: String }
            let fx = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
            XCTAssertEqual(ReviewDeliveryLine.line(roundID: fx.round_id, comments: fx.comments), fx.line, url.lastPathComponent)
        }
    }
}
```

(`repoRoot()` — use the helper `OwnerAskPromptTests` uses; if it is private there, move it to `Tests/Core/Support` and use it from both.)

`ReviewCommentAnchorTests.swift`:

```swift
final class ReviewCommentAnchorTests: XCTestCase {
    private let original = "line1\nfunc a() {\n  return 1\n}\nline5\n"

    func testAnchorQuotesTheLines() {
        let a = ReviewCommentAnchor.anchor(text: original, startLine: 2, endLine: 3)
        XCTAssertEqual(a.quote, "func a() {\n  return 1")
    }

    func testMovedWhenLinesShift() {
        let c = comment(id: 1, start: 2, end: 3)
        let shifted = "new0\nnew1\n" + original
        let plan = ReviewCommentAnchor.plan([c]) { _ in shifted }
        XCTAssertEqual(plan.moved[1], .init(startLine: 4, endLine: 5))
        XCTAssertTrue(plan.lost.isEmpty)
    }

    func testLostWhenQuoteGone() {
        let plan = ReviewCommentAnchor.plan([comment(id: 2, start: 2, end: 3)]) { _ in "totally\ndifferent\n" }
        XCTAssertEqual(plan.lost, [2])
    }

    func testLostWhenFileGone() {
        let plan = ReviewCommentAnchor.plan([comment(id: 3, start: 1, end: 1)]) { _ in nil }
        XCTAssertEqual(plan.lost, [3])
    }

    func testDesignCommentNeverMoves() {
        var c = comment(id: 4, start: 0, end: 0)
        c = ReviewComment.fixture(id: 4, path: nil, start: 0, end: 0, anchor: .init(quote: "", prefix: "", suffix: "", heading: ""))
        let plan = ReviewCommentAnchor.plan([c]) { _ in nil }
        XCTAssertTrue(plan.lost.isEmpty && plan.moved.isEmpty)
    }

    private func comment(id: Int64, start: Int, end: Int) -> ReviewComment {
        ReviewComment.fixture(id: id, path: "a.go", start: start, end: end,
                              anchor: ReviewCommentAnchor.anchor(text: original, startLine: start, endLine: end))
    }
}
```

Add `ReviewComment.fixture(id:path:start:end:anchor:)` as a `package static func` in a test-support extension (`Tests/Core/Support/ReviewComment+Fixture.swift`), building the struct with `roundID: 1, side: "new", treeSHA: "t", lens: "", body: "b", status: .sent, carriedFrom: nil, agentReply: ""`. Since `ReviewComment` decodes from rows, give it a memberwise `package init` in `ReviewModels.swift`.

`ReviewQueriesTests.swift` (uses `TestDatabase` with the regenerated schema):

```swift
final class ReviewQueriesTests: XCTestCase {
    func testDraftLifecycleAndSentRowsAreImmutable() throws {
        let db = try TestDatabase.make()   // the Core tests' in-memory DB helper; grep Tests/Core for its exact name
        let roundID = try db.write { try seedRound($0) }
        let anchor = CommentAnchor(quote: "x", prefix: "", suffix: "", heading: "")
        let id = try db.write { try ReviewQueries.addDraft($0, roundID: roundID, path: "a.go", side: "new",
                                                           startLine: 1, endLine: 1, anchor: anchor, treeSHA: "t", body: "b") }
        try db.write { try ReviewQueries.updateDraft($0, id: id, body: "b2") }
        XCTAssertEqual(try db.read { try ReviewQueries.comments($0, roundID: roundID) }.first?.body, "b2")
        try db.write { try $0.execute(sql: "UPDATE review_comments SET status='sent' WHERE id=?", arguments: [id]) }
        XCTAssertThrowsError(try db.write { try ReviewQueries.updateDraft($0, id: id, body: "late") })
        XCTAssertThrowsError(try db.write { try ReviewQueries.deleteDraft($0, id: id) })
    }

    func testViewedKeepsContentSHA() throws {
        let db = try TestDatabase.make()
        let roundID = try db.write { try seedRound($0) }
        try db.write { try ReviewQueries.setViewed($0, roundID: roundID, path: "a.go", contentSHA: "s1") }
        XCTAssertEqual(try db.read { try ReviewQueries.viewed($0, roundID: roundID) }, ["a.go": "s1"])
        try db.write { try ReviewQueries.setViewed($0, roundID: roundID, path: "a.go", contentSHA: nil) }
        XCTAssertEqual(try db.read { try ReviewQueries.viewed($0, roundID: roundID) }, [:])
    }

    func testCarryCopiesMovedAndOutdatesLost() throws {
        let db = try TestDatabase.make()
        let r1 = try db.write { try seedRound($0) }
        let anchor = CommentAnchor(quote: "q", prefix: "", suffix: "", heading: "")
        let a = try db.write { try ReviewQueries.addDraft($0, roundID: r1, path: "a.go", side: "new", startLine: 1, endLine: 1, anchor: anchor, treeSHA: "t1", body: "keep") }
        let b = try db.write { try ReviewQueries.addDraft($0, roundID: r1, path: "b.go", side: "new", startLine: 1, endLine: 1, anchor: anchor, treeSHA: "t1", body: "gone") }
        try db.write { try $0.execute(sql: "UPDATE review_rounds SET status='sent' WHERE id=?; UPDATE review_comments SET status='sent'", arguments: [r1]) }
        let r2 = try db.write { try seedRound($0) }
        let prev = try db.read { try ReviewQueries.comments($0, roundID: r1) }
        let plan = ReviewCommentAnchor.Plan(moved: [a: .init(startLine: 5, endLine: 5)], lost: [b])
        try db.write { try ReviewQueries.carry($0, from: prev, into: r2, plan: plan, treeSHA: "t2") }
        let now = try db.read { try ReviewQueries.comments($0, roundID: r2) }
        XCTAssertEqual(now.count, 2)
        XCTAssertEqual(now.first { $0.carriedFrom == a }?.status, .carried)
        XCTAssertEqual(now.first { $0.carriedFrom == a }?.startLine, 5)
        XCTAssertEqual(now.first { $0.carriedFrom == b }?.status, .outdated)
    }
}
```

`seedRound` inserts a `projects` row (once), a `terminal_sessions` row, and a `review_rounds` row with `status` `open` — but the partial unique index allows one open round per session, so give each call its own session row.

- [ ] **Step 2: Run to verify they fail**

Run: `make test-swift FILTER='ReviewQueriesTests|ReviewDeliveryLineTests|ReviewCommentAnchorTests'`
Expected: FAIL — types undefined.

- [ ] **Step 3: Implement**

`ReviewDeliveryLine.swift`:

```swift
import Foundation

/// The line typed into a session after Send (spec §9) — the Swift twin of Go
/// `reviewdiff.DeliveryLine`, pinned by internal/reviewdiff/testdata/lines.
package enum ReviewDeliveryLine {
    package static func line(roundID: Int64, comments: Int) -> String {
        let noun = comments == 1 ? "comment" : "comments"
        return WorkbenchCommentPrompt.oneLine(
            "Review round #\(roundID) sent (\(comments) \(noun)) — read it with get_review \(roundID) using the watchtower-workbench skill."
        )
    }
}
```

`ReviewCommentAnchor.swift`:

```swift
import Foundation

/// Line comments of the diff reviewer anchored by their quoted lines and
/// re-placed on a later version of the file (REVIEW-03), on top of the
/// artifact comments' `CommentAnchor` (exact match, then whitespace-collapsed).
package enum ReviewCommentAnchor {
    package struct Placement: Equatable, Sendable {
        package let startLine: Int
        package let endLine: Int
        package init(startLine: Int, endLine: Int) { self.startLine = startLine; self.endLine = endLine }
    }

    package struct Plan: Equatable, Sendable {
        package var moved: [Int64: Placement]
        package var lost: Set<Int64>
        package init(moved: [Int64: Placement] = [:], lost: Set<Int64> = []) { self.moved = moved; self.lost = lost }
    }

    /// The anchor of lines startLine...endLine (1-based) of text.
    package static func anchor(text: String, startLine: Int, endLine: Int) -> CommentAnchor {
        guard let range = range(ofLines: startLine...max(startLine, endLine), in: text) else {
            return CommentAnchor(quote: "", prefix: "", suffix: "", heading: "")
        }
        return CommentAnchor.make(text: text, range: range, headings: [])
    }

    /// Where each line comment lands in its file's new text; a design comment
    /// (no path) is left alone.
    package static func plan(_ comments: [ReviewComment], textFor: (String) -> String?) -> Plan {
        var plan = Plan()
        for c in comments {
            guard let path = c.path else { continue }
            let anchor = CommentAnchor(quote: c.quote, prefix: c.quotePrefix, suffix: c.quoteSuffix, heading: "")
            guard let text = textFor(path), let found = anchor.locate(in: text) else {
                plan.lost.insert(c.id)
                continue
            }
            let start = line(at: found.lowerBound, in: text)
            let lastChar = found.isEmpty ? found.lowerBound : text.index(before: found.upperBound)
            plan.moved[c.id] = Placement(startLine: start, endLine: line(at: lastChar, in: text))
        }
        return plan
    }

    static func range(ofLines lines: ClosedRange<Int>, in text: String) -> Range<String.Index>? {
        var starts = [text.startIndex]
        var i = text.startIndex
        while let nl = text[i...].firstIndex(of: "\n") {
            i = text.index(after: nl)
            starts.append(i)
        }
        guard lines.lowerBound >= 1, lines.lowerBound <= starts.count else { return nil }
        let lo = starts[lines.lowerBound - 1]
        let hiLine = min(lines.upperBound, starts.count)
        var hi = hiLine < starts.count ? text.index(before: starts[hiLine]) : text.endIndex
        if hi < lo { hi = lo }
        return lo..<hi
    }

    static func line(at index: String.Index, in text: String) -> Int {
        text[text.startIndex..<index].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }
}
```

`ReviewModels.swift`: the envelope structs from **Interfaces**, decoded with `JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase` (Task 7), so property names are the snake_case keys camel-cased exactly: `baseSha`, `treeSha`, `prevRoundId`, `prevTreeSha`, `prevTreeLost`, `oldPath`, `collapsedReason`, `hunkId`, `oldStart`, `tooLarge`, `targetId`, `planPath`, `planTask`, `planText`, `specPath`, `previousTreeLost` — no `CodingKeys` on the envelope types. `ReviewComment` maps DB columns via `CodingKeys` (`round_id`, `start_line`, `end_line`, `quote_prefix`, `quote_suffix`, `tree_sha`, `carried_from`, `agent_reply`), and has a memberwise `package init`.

`ReviewQueries.swift`:

```swift
import GRDB

/// The Desktop's writes of the diff reviewer (spec §10): drafts and Viewed
/// marks. Go owns rounds and the send transition.
package enum ReviewQueries {
    package enum ReviewQueryError: Error, Equatable { case notADraft }

    package static func comments(_ db: Database, roundID: Int64) throws -> [ReviewComment] {
        try ReviewComment.fetchAll(db, sql: "SELECT * FROM review_comments WHERE round_id = ? ORDER BY id", arguments: [roundID])
    }

    package static func addDraft(_ db: Database, roundID: Int64, path: String?, side: String, startLine: Int, endLine: Int,
                                 anchor: CommentAnchor, treeSHA: String, body: String) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO review_comments (round_id, path, side, start_line, end_line, quote, quote_prefix, quote_suffix, tree_sha, body)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [roundID, path, side, startLine, endLine, anchor.quote, anchor.prefix, anchor.suffix, treeSHA, body])
        return db.lastInsertedRowID
    }

    package static func updateDraft(_ db: Database, id: Int64, body: String) throws {
        try db.execute(sql: """
            UPDATE review_comments SET body = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
            WHERE id = ? AND status IN ('draft','carried')
            """, arguments: [body, id])
        guard db.changesCount == 1 else { throw ReviewQueryError.notADraft }
    }

    package static func deleteDraft(_ db: Database, id: Int64) throws {
        try db.execute(sql: "DELETE FROM review_comments WHERE id = ? AND status IN ('draft','carried')", arguments: [id])
        guard db.changesCount == 1 else { throw ReviewQueryError.notADraft }
    }

    /// Carries the previous round's unresolved comments into roundID: moved →
    /// `carried` at the new lines, lost → `outdated` (REVIEW-03: none dropped).
    package static func carry(_ db: Database, from previous: [ReviewComment], into roundID: Int64,
                              plan: ReviewCommentAnchor.Plan, treeSHA: String) throws {
        for c in previous where c.status == .sent || c.status == .carried {
            let place = plan.moved[c.id]
            let status = plan.lost.contains(c.id) ? "outdated" : "carried"
            try db.execute(sql: """
                INSERT INTO review_comments (round_id, path, side, start_line, end_line, quote, quote_prefix, quote_suffix,
                    tree_sha, lens, body, status, carried_from, agent_reply)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [roundID, c.path, c.side, place?.startLine ?? c.startLine, place?.endLine ?? c.endLine,
                                 c.quote, c.quotePrefix, c.quoteSuffix, treeSHA, c.lens, c.body, status, c.id, c.agentReply])
        }
    }

    package static func viewed(_ db: Database, roundID: Int64) throws -> [String: String] {
        let rows = try Row.fetchAll(db, sql: "SELECT path, content_sha FROM review_viewed WHERE round_id = ?", arguments: [roundID])
        return Dictionary(uniqueKeysWithValues: rows.map { ($0["path"] as String, $0["content_sha"] as String) })
    }

    package static func setViewed(_ db: Database, roundID: Int64, path: String, contentSHA: String?) throws {
        if let contentSHA {
            try db.execute(sql: "INSERT OR REPLACE INTO review_viewed (round_id, path, content_sha) VALUES (?, ?, ?)",
                           arguments: [roundID, path, contentSHA])
        } else {
            try db.execute(sql: "DELETE FROM review_viewed WHERE round_id = ? AND path = ?", arguments: [roundID, path])
        }
    }
}
```

Note: a `carried` comment is shown with its agent reply; the owner either **Resolve**s it (Task 8 writes `status='resolved'` through a `resolve(_:id:)` query — add it here: `UPDATE review_comments SET status='resolved' WHERE id = ? AND status IN ('carried','outdated')`) or edits it, which makes it part of this round's send. `SendReviewRound` (Go, Task 3) sends `draft` rows only — **extend it in this task** to also send `carried` rows: change its comment UPDATE to `WHERE round_id = ? AND status IN ('draft','carried')` and add a Go test case (`TestReviewRounds_SendIncludesCarried`) in `internal/db/review_rounds_test.go`. Outdated rows are never sent.

- [ ] **Step 4: Run tests**

Run: `make test-swift FILTER='ReviewQueriesTests|ReviewDeliveryLineTests|ReviewCommentAnchorTests'` and `go test ./internal/db -run TestReviewRounds_`
Expected: PASS.

- [ ] **Step 5: Lint and commit**

```bash
make lint-swift
git add WatchtowerDesktop/Sources/WatchtowerCore WatchtowerDesktop/Tests/Core internal/db
git commit -m "feat(desktop): review models, queries, delivery line and comment anchor (board #328)"
```

---

### Task 7: Swift — CLI calls and `LineKey.review`

**Depends on:** Task 6

**Files:**
- Modify: `WatchtowerDesktop/Sources/Services/WorkbenchCLI.swift` (after `gitStatus`, ~line 731)
- Modify: `WatchtowerDesktop/Sources/Services/SessionLineDelivery.swift` (`LineKey`, `askID`, `logSource`)
- Test: `WatchtowerDesktop/Tests/WorkbenchCLIReviewTests.swift`, `WatchtowerDesktop/Tests/SessionLineDeliveryReviewTests.swift`

**Interfaces:**
- Consumes: `CLIRunnerProtocol`, `ReviewEnvelope` (Task 6).
- Produces:

```swift
extension WorkbenchCLI {
    func reviewStart(projectID: Int64, sessionID: Int64, refresh: Bool) async throws -> ReviewEnvelope
    func reviewDiff(projectID: Int64, roundID: Int64, since: Bool) async throws -> ReviewEnvelope
    func reviewFile(projectID: Int64, roundID: Int64, path: String, since: Bool) async throws -> ReviewEnvelope
    func reviewSend(projectID: Int64, roundID: Int64) async throws -> ReviewEnvelope
    func reviewContext(projectID: Int64, sessionID: Int64) async throws -> ReviewEnvelope
}
// SessionLineDelivery.LineKey gains: case review(Int64)
```

- [ ] **Step 1: Failing tests**

```swift
final class WorkbenchCLIReviewTests: XCTestCase {
    func testStartBuildsArgsAndDecodes() async throws {
        let runner = RecordingCLIRunner(output: """
        {"ok":true,"round":{"id":7,"status":"open","mode":"quick","folder_root":"/r","base_sha":"b","base_label":"main",
         "tree_sha":"t","prev_round_id":0,"prev_tree_sha":"","prev_tree_lost":false}}
        """)
        let env = try await WorkbenchCLI(runner: runner).reviewStart(projectID: 1, sessionID: 4, refresh: true)
        XCTAssertEqual(runner.lastArgs, ["workbench", "review", "start", "--workbench", "1", "--session", "4", "--refresh", "--json"])
        XCTAssertEqual(env.round?.id, 7)
        XCTAssertEqual(env.round?.baseLabel, "main")
    }

    func testDiffDecodesHunks() async throws {
        let runner = RecordingCLIRunner(output: """
        {"ok":true,"diff":{"files":[{"path":"a.go","status":"modified","additions":1,"deletions":1,"binary":false,
         "hunks":[{"hunk_id":"h","header":"@@ -1 +1 @@","old_start":1,"old_lines":1,"new_start":1,"new_lines":1,"lines":["-a","+b"]}]}],
         "truncated":false},"from":"b","to":"t"}
        """)
        let env = try await WorkbenchCLI(runner: runner).reviewDiff(projectID: 1, roundID: 7, since: true)
        XCTAssertEqual(runner.lastArgs.suffix(3), ["7", "--since", "--json"])
        XCTAssertEqual(env.diff?.files.first?.hunks.first?.hunkId, "h")
    }

    func testRefusalEnvelopeIsNotAThrow() async throws {
        let runner = RecordingCLIRunner(output: #"{"ok":false,"error":"the folder is not a git work tree"}"#)
        let env = try await WorkbenchCLI(runner: runner).reviewStart(projectID: 1, sessionID: 4, refresh: false)
        XCTAssertFalse(env.ok)
        XCTAssertEqual(env.error, "the folder is not a git work tree")
    }
}
```

(`RecordingCLIRunner`: reuse the fake runner the existing `WorkbenchCLI` tests use — `grep -rn "CLIRunnerProtocol" WatchtowerDesktop/Tests | head` — rather than adding one.)

`SessionLineDeliveryReviewTests.swift`: copy the structure of the ask-delivery test in `Tests/TerminalCenterTests.swift:592-613` and assert that `deliverLine(line, key: .review(7), sessionID:)` follows the same gates: with `hasHookState` false the result is `.typed` (paste, no Return); with hooks reported and not needing approval it is `.submitted`.

- [ ] **Step 2: Implement**

```swift
extension WorkbenchCLI {
    private func review(_ args: [String]) async throws -> ReviewEnvelope {
        let data = try await runner.run(args: ["workbench", "review"] + args + ["--json"])
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ReviewEnvelope.self, from: data)
    }

    func reviewStart(projectID: Int64, sessionID: Int64, refresh: Bool) async throws -> ReviewEnvelope {
        try await review(["start", "--workbench", String(projectID), "--session", String(sessionID)] + (refresh ? ["--refresh"] : []))
    }

    func reviewDiff(projectID: Int64, roundID: Int64, since: Bool) async throws -> ReviewEnvelope {
        try await review(["diff", "--workbench", String(projectID), "--round", String(roundID)] + (since ? ["--since"] : []))
    }

    func reviewFile(projectID: Int64, roundID: Int64, path: String, since: Bool) async throws -> ReviewEnvelope {
        try await review(["file", "--workbench", String(projectID), "--round", String(roundID), "--path", path] + (since ? ["--since"] : []))
    }

    func reviewSend(projectID: Int64, roundID: Int64) async throws -> ReviewEnvelope {
        try await review(["send", "--workbench", String(projectID), "--round", String(roundID)])
    }

    func reviewContext(projectID: Int64, sessionID: Int64) async throws -> ReviewEnvelope {
        try await review(["context", "--workbench", String(projectID), "--session", String(sessionID)])
    }
}
```

In `SessionLineDelivery.swift`: add `case review(Int64)` to `LineKey`; `askID` returns `nil` for it; `logSource` returns `"review"`; in `deliver(...)` `keepingFormatCharacters: key.askID == nil` would be `true` for a review line — the line is ours, so pass `false` explicitly for `.review` (change the argument to `keepingFormatCharacters: { if case .input = key { return true }; return false }()`). Held review lines retry like ask lines (order after asks: `askID ?? .max` already puts them last).

- [ ] **Step 3: Run, lint, commit**

Run: `make test-swift FILTER='WorkbenchCLIReviewTests|SessionLineDeliveryReviewTests|TerminalCenterTests'` then `make lint-swift`
Expected: PASS.

```bash
git add WatchtowerDesktop/Sources/Services WatchtowerDesktop/Tests
git commit -m "feat(desktop): review CLI calls and the review line key (board #328)"
```

---

### Task 8: `ReviewChangesModel` — the pane's view model

**Depends on:** Task 7

**Files:**
- Create: `WatchtowerDesktop/Sources/ViewModels/ReviewChangesModel.swift`
- Test: `WatchtowerDesktop/Tests/ReviewChangesModelTests.swift`

**Interfaces:**
- Consumes: `WorkbenchCLI.review*` (Task 7), `ReviewQueries`, `ReviewCommentAnchor`, `ReviewDeliveryLine` (Task 6), `SessionLineDelivery.deliverLine` (Task 7), a `DatabasePool` (`AppState`'s), a closure `isAgentWorking: () -> Bool`.
- Produces:

```swift
@MainActor @Observable
final class ReviewChangesModel {
    enum Load: Equatable { case idle, loading, failed(String), ready }
    enum View: Equatable { case all, sinceLastRound }
    private(set) var load: Load
    private(set) var round: ReviewRoundInfo?
    private(set) var files: [ReviewDiffFile]
    private(set) var truncated: Bool
    private(set) var previousTreeLost: Bool
    private(set) var context: [ReviewContextItem]
    private(set) var comments: [ReviewComment]
    private(set) var viewed: [String: String]           // path → content sha
    var selectedPath: String?
    var view: View
    private(set) var sides: (old: ReviewFileSide, new: ReviewFileSide)?
    private(set) var sending: Bool
    private(set) var lastSend: SessionLineDelivery.Delivery?

    init(projectID: Int64, sessionID: Int64, cli: WorkbenchCLI, db: DatabasePool, lineDelivery: SessionLineDelivery)
    func open() async                    // start (resume) → context → diff → comments → carry-over (new round only)
    func refresh() async                 // start --refresh → re-anchor this round's drafts → diff
    func select(_ path: String) async    // file sides
    func setView(_ v: View) async
    func addComment(path: String, side: String, startLine: Int, endLine: Int, body: String) throws
    func editComment(id: Int64, body: String) throws
    func deleteComment(id: Int64) throws
    func resolve(id: Int64) throws
    func toggleViewed(_ path: String) throws      // content sha = hunk ids joined, hashed (stable per content)
    func send() async                    // guarded: one at a time; CLI send → deliverLine(key: .review(id))
    var draftCount: Int { get }
}
```

Behaviour rules:
- **open():** `reviewStart(refresh: false)`; `ok == false` → `.failed(error)`. Then `reviewContext`, `reviewDiff(since: view == .sinceLastRound)`. If the round is new (no comments yet) and `prevRoundId > 0`: read the previous round's comments, for each path load the new side via `reviewFile`, build `ReviewCommentAnchor.plan`, write `ReviewQueries.carry`. Default `view` = `.sinceLastRound` when `prevRoundId > 0`, else `.all`.
- **refresh():** `reviewStart(refresh: true)`; drafts and carried comments of this round whose `treeSha` differs are re-planned against the new sides; moved → `UPDATE start_line/end_line/tree_sha`, lost → `outdated` (add `ReviewQueries.replace(_:id:placement:treeSHA:)` and `markOutdated(_:id:)` in Task 6's file as part of this task).
- **Viewed:** a file's content key = sha256 of its hunk ids joined by `\n`; `viewed[path] == key` → checked; a new round with the same hunks keeps it checked because `open()` copies the previous round's `review_viewed` rows whose key still matches.
- **send():** if `sending` return; set `sending = true`; `reviewSend`; if `sent == true` and `line` non-empty → `lineDelivery.deliverLine(line, key: .review(round.id), sessionID: sessionID)`; store `lastSend`; reload comments; `sending = false`. A `sent == false` envelope (already sent elsewhere) types nothing and reloads.

- [ ] **Step 1: Failing tests** (fake CLI runner scripted per call; a temp `DatabasePool` with the test schema; a fake `SessionLineDelivery` seam — if `SessionLineDelivery` is a final class without a protocol, add `protocol ReviewLineSink { func deliverLine(_:key:sessionID:) async -> SessionLineDelivery.Delivery }`, conform `SessionLineDelivery` to it in an extension, and have the model take `any ReviewLineSink`):

```swift
@MainActor
final class ReviewChangesModelTests: XCTestCase {
    func testOpenLoadsRoundDiffAndContext() async throws {
        let h = try Harness()
        h.cli.script(["start": startJSON(id: 7, prev: 0), "context": #"{"ok":true,"items":[]}"#, "diff": diffJSON(path: "a.go")])
        await h.model.open()
        XCTAssertEqual(h.model.load, .ready)
        XCTAssertEqual(h.model.round?.id, 7)
        XCTAssertEqual(h.model.files.map(\.path), ["a.go"])
        XCTAssertEqual(h.model.view, .all)
    }

    func testFailedStartShowsTheError() async throws {
        let h = try Harness()
        h.cli.script(["start": #"{"ok":false,"error":"the folder is not a git work tree"}"#])
        await h.model.open()
        XCTAssertEqual(h.model.load, .failed("the folder is not a git work tree"))
    }

    func testSendTwiceTypesOnce() async throws {
        let h = try Harness()
        h.cli.script(["start": startJSON(id: 7, prev: 0), "context": #"{"ok":true,"items":[]}"#, "diff": diffJSON(path: "a.go"),
                      "send": #"{"ok":true,"sent":true,"comments":1,"line":"Review round #7 sent (1 comment) — read it with get_review 7 using the watchtower-workbench skill."}"#])
        await h.model.open()
        try h.model.addComment(path: "a.go", side: "new", startLine: 1, endLine: 1, body: "x")
        async let a: Void = h.model.send()
        async let b: Void = h.model.send()
        _ = await (a, b)
        XCTAssertEqual(h.sink.lines.count, 1)
        XCTAssertEqual(h.sink.lines.first?.key, .review(7))
    }

    func testAlreadySentTypesNothing() async throws {
        let h = try Harness()
        h.cli.script(["start": startJSON(id: 7, prev: 0), "context": #"{"ok":true,"items":[]}"#, "diff": diffJSON(path: "a.go"),
                      "send": #"{"ok":true,"sent":false}"#])
        await h.model.open()
        await h.model.send()
        XCTAssertTrue(h.sink.lines.isEmpty)
    }

    func testNewRoundCarriesPreviousComments() async throws {
        let h = try Harness()
        let r6 = try h.db.write { db -> Int64 in
            try db.execute(sql: "INSERT INTO review_rounds (project_id, session_id, folder_root, base_sha, tree_sha, status) VALUES (?, ?, '/r', 'b', 't6', 'sent')",
                           arguments: [h.projectID, h.sessionID])
            return db.lastInsertedRowID
        }
        let anchor = ReviewCommentAnchor.anchor(text: "old line\n", startLine: 1, endLine: 1)
        let c6 = try h.db.write { db -> Int64 in
            let id = try ReviewQueries.addDraft(db, roundID: r6, path: "a.go", side: "new", startLine: 1, endLine: 1,
                                                anchor: anchor, treeSHA: "t6", body: "fix this")
            try db.execute(sql: "UPDATE review_comments SET status='sent' WHERE id=?", arguments: [id])
            return id
        }
        h.cli.script(["start": startJSON(id: 7, prev: r6), "context": #"{"ok":true,"items":[]}"#, "diff": diffJSON(path: "a.go"),
                      "file": #"{"ok":true,"old":{"exists":true,"text":"old line\n","binary":false,"too_large":false},"new":{"exists":true,"text":"inserted\nold line\n","binary":false,"too_large":false}}"#])
        await h.model.open()
        let carried = try h.db.read { try ReviewQueries.comments($0, roundID: 7) }
        XCTAssertEqual(carried.count, 1)
        XCTAssertEqual(carried.first?.status, .carried)
        XCTAssertEqual(carried.first?.startLine, 2)
        XCTAssertEqual(carried.first?.carriedFrom, c6)
        XCTAssertEqual(h.model.view, .sinceLastRound)
    }
}
```

`startJSON(id:prev:)` and `diffJSON(path:)` return the envelopes of Task 7's tests with those values; the scripted `start` makes the round row exist in the DB (the harness inserts `review_rounds` id `id` for the session when it serves a `start` whose id is not yet there, mirroring Go). `Harness` builds the temp DB, the scripted CLI (keyed by the subcommand at `args[2]`), the sink and the model with `projectID: 1, sessionID: <seeded>`.

- [ ] **Step 2: Run to verify failure, implement, run to pass**

Run: `make test-swift FILTER=ReviewChangesModelTests` → FAIL, then implement per the rules above, → PASS.

- [ ] **Step 3: Lint and commit**

```bash
make lint-swift
git add WatchtowerDesktop/Sources WatchtowerDesktop/Tests
git commit -m "feat(desktop): ReviewChangesModel — rounds, comments, viewed, send (board #328)"
```

---

### Task 9: Monaco diff page and the Changes pane

**Depends on:** Task 8

**Files:**
- Create: `WatchtowerDesktop/Sources/CodeEditorWeb/diff.html`, `WatchtowerDesktop/Sources/CodeEditorWeb/diff.js`
- Create: `WatchtowerDesktop/Sources/Views/Workbench/Review/MonacoDiffView.swift`, `ReviewChangesPaneView.swift`, `ReviewFileListView.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/WorkspaceLayout.swift` (`WorkspacePane.changes(Int64)`, `WorkspaceView.changes`), `Views/Workbench/WorkspacePaneView.swift:93-144` (picker + content), `Views/Workbench/TerminalSessionRow.swift:62` + `SessionRowActions` (Review Changes), `ViewModels/WorkbenchesViewModel+Panel.swift` (`showChanges(sessionID:projectID:)`, one `ReviewChangesModel` per session cached in the view model)
- Modify: `scripts/editor-bridge-check.swift` (diff page smoke: load `diff.html`, call `wt.showDiff`, expect `ready` and no `error`)
- Test: `WatchtowerDesktop/Tests/Core/WorkspaceLayoutChangesTests.swift`

**Interfaces:**
- Consumes: `ReviewChangesModel` (Task 8); `CodeEditorSchemeHandler` (serves any file of `CodeEditorWeb`), `WeakMessageHandler`.
- Produces: page API `window.wt = { showDiff({path, language, original, modified, inline, comments:[{id,startLine,endLine,body,status,reply}]}), setComments([...]), focus() }`; page → app messages on handler `wt`: `{type:"ready"}`, `{type:"comment", startLine, endLine, side}` (the owner chose **Comment** on a selection), `{type:"error", message}`.

- [ ] **Step 1: Failing layout test**

```swift
final class WorkspaceLayoutChangesTests: XCTestCase {
    func testChangesPaneRoundTripsAndMapsToItsView() throws {
        let pane = WorkspacePane.changes(42)
        let data = try JSONEncoder().encode(pane)
        XCTAssertEqual(try JSONDecoder().decode(WorkspacePane.self, from: data), pane)
        XCTAssertEqual(WorkspaceView(pane), .changes)
    }

    func testUnknownSavedPaneStillDecodesToDefault() throws {
        let legacy = Data(#"{"primary":{"somethingNew":{}}}"#.utf8)
        XCTAssertNoThrow(try JSONDecoder().decode(WorkspaceLayout.self, from: legacy))
    }
}
```

Run: `make test-swift FILTER=WorkspaceLayoutChangesTests` → FAIL.

- [ ] **Step 2: Layout enums**

Add `case changes(Int64)` (session id) to `WorkspacePane` and `case changes` to `WorkspaceView` with `title` "Changes", `icon` `"plus.forwardslash.minus"`, `help` "Review the session's changes". Fix every exhaustive `switch` the compiler reports (`WorkspaceView.init(_:)`, `matches`, `WorkspacePaneView.content`, `title`/`icon` helpers). `WorkspaceView.changes` acts on the selected session the way `.terminal` and `.report` do (`showWorkbenchView` uses the layout's current session; if none is selected the header button is disabled — follow `.report`'s rule).

Run the test → PASS.

- [ ] **Step 3: `diff.html` and `diff.js`**

`diff.html` — same CSP meta and script order as `index.html` (copy its `<head>` verbatim), body `<div id="diff"></div>`, scripts `boot.js`, `languages.js`, `diff.js`.

`diff.js`:

```js
(function () {
  "use strict";
  require.config({ paths: { vs: "vs" } });
  require(["vs/editor/editor.main"], function () {
    var dark = window.matchMedia("(prefers-color-scheme: dark)").matches;
    var editor = monaco.editor.createDiffEditor(document.getElementById("diff"), {
      automaticLayout: true, readOnly: true, originalEditable: false, renderSideBySide: true,
      renderOverviewRuler: true, minimap: { enabled: false }, scrollBeyondLastLine: false,
      theme: dark ? "vs-dark" : "vs",
    });
    var zones = [];
    var models = { original: null, modified: null };

    function dispose() {
      if (models.original) models.original.dispose();
      if (models.modified) models.modified.dispose();
    }

    function renderComments(list) {
      var mod = editor.getModifiedEditor();
      mod.changeViewZones(function (acc) {
        zones.forEach(function (z) { acc.removeZone(z); });
        zones = [];
        (list || []).forEach(function (c) {
          var node = document.createElement("div");
          node.className = "wt-comment wt-" + c.status;
          var body = document.createElement("div");
          body.textContent = c.body;           // textContent only: never HTML from the DB
          node.appendChild(body);
          if (c.reply) {
            var reply = document.createElement("div");
            reply.className = "wt-reply";
            reply.textContent = "Agent: " + c.reply;
            node.appendChild(reply);
          }
          zones.push(acc.addZone({ afterLineNumber: c.endLine, heightInLines: c.reply ? 3 : 2, domNode: node }));
        });
      });
    }

    var mod = editor.getModifiedEditor();
    mod.addAction({
      id: "wt.comment", label: "Comment", contextMenuGroupId: "navigation",
      keybindings: [monaco.KeyMod.CtrlCmd | monaco.KeyMod.Alt | monaco.KeyCode.KeyM],
      run: function (ed) {
        var s = ed.getSelection();
        post({ type: "comment", side: "new", startLine: s.startLineNumber, endLine: s.endLineNumber });
      },
    });

    window.wt = {
      showDiff: function (a) {
        dispose();
        models.original = monaco.editor.createModel(a.original || "", a.language || undefined);
        models.modified = monaco.editor.createModel(a.modified || "", a.language || undefined);
        editor.setModel({ original: models.original, modified: models.modified });
        editor.updateOptions({ renderSideBySide: !a.inline });
        renderComments(a.comments);
      },
      setComments: renderComments,
      focus: function () { editor.getModifiedEditor().focus(); },
    };
    post({ type: "ready" });
  });
})();
```

Add `.wt-comment`, `.wt-reply`, `.wt-carried`, `.wt-outdated` styles in a `<style>` block in `diff.html` (inline styles are allowed by the CSP). `language`: reuse `languages.js`'s path → language mapping function (read its exported name and call it from Swift's side or from `showDiff`; pass the path and resolve in JS).

- [ ] **Step 4: `MonacoDiffView`**

An `NSViewRepresentable` modelled on `MonacoEditorView` (`CodeFilesPaneView.swift:378`): same `WKWebViewConfiguration` (scheme handler `wtcode`, `WeakMessageHandler` named `wt`), loads `wtcode://editor/diff.html`, navigation policy identical (cancel everything but the page). Coordinator keeps `ready` and a pending `ShowDiff` payload; `updateNSView` sends `wt.showDiff(<JSON>)` when the payload changed and the page is ready (JSON-encode with `JSONSerialization`, as `call(_:_:)` does). Messages: `comment` → `onComment(startLine, endLine, side)`; `error` → log through the same logger the code viewer uses.

```swift
struct MonacoDiffView: NSViewRepresentable {
    struct Payload: Equatable {
        var path: String; var original: String; var modified: String; var inline: Bool
        var comments: [Comment]
        struct Comment: Equatable, Encodable { var id: Int64; var startLine: Int; var endLine: Int; var body: String; var status: String; var reply: String }
    }
    var payload: Payload?
    var onComment: (_ startLine: Int, _ endLine: Int, _ side: String) -> Void
    // makeNSView / updateNSView / Coordinator as described
}
```

- [ ] **Step 5: The pane**

`ReviewChangesPaneView(model: ReviewChangesModel)`:
- **Header:** `Base: <baseLabel or "empty tree">` · `Round #<id>` · segmented `All / Since round <prev>` (hidden when `prevRoundId == 0`) · **Refresh** · **Send review (N)** (disabled when `draftCount == 0 && no carried comments`, or `sending`). Banners: `previousTreeLost` → "Round <prev>'s snapshot is gone — showing all changes"; `truncated` → "The diff is too large; later files show without hunks"; `lastSend == .typed` → "Line pasted — press Return in the terminal"; `.copied` → "Copied — paste it into the terminal"; `.held` → "Will be sent when the agent's turn ends".
- **Left (`ReviewFileListView`):** the intent card (each context item's text, intent and `planText` collapsed to 3 lines with "more"; `missing` → "plan file missing" / "task not found"), then files: status glyph, path (middle-truncated), `+a −d`, a Viewed checkbox, a comment-count badge; collapsed files (`collapsedReason`) in a "Folded" group at the bottom with the reason.
- **Right:** `MonacoDiffView` with the selected file's sides (`sides.old.text`/`sides.new.text`); binary → "Binary file"; too large → "Too large to show — open in Files" (button → `activateFileViewerSelecting(path)` the way the header's path link does); below it the comment list of that file (draft → editable `TextEditor` with Delete; carried → body, agent reply, **Resolve** / **Edit**; outdated → quote in grey + **Resolve**).
- `onComment` opens a small sheet anchored to the pane with a `TextEditor`; **Add** → `model.addComment(...)`.
- Load states: `.loading` → `ProgressView`; `.failed(msg)` → the message and **Retry**.
- Re-snapshot on `NSWindow.didBecomeKeyNotification` for this window and when the session's agent state turns to a turn-over kind, by calling `model.refresh()` only when the round is open and the pane is visible; never while `sending`.

Wire: `WorkspacePaneView.content` → `.changes(id)` → `ReviewChangesPaneView(model: vm.reviewModel(sessionID: id, projectID: project.id))`; the split picker gets `Button("Changes") { show(.changes(currentSessionID)) }` when a session is current; `TerminalSessionRow` context menu gets **Review Changes** (after "Show Worktree in Finder", always shown for a workbench session) → `actions.reviewChanges(session)` → `vm.showChanges(sessionID:projectID:)` = `showInPane(primarySlot, item: .changes(id), …)`.

`vm.reviewModel(sessionID:projectID:)` caches models in `[Int64: ReviewChangesModel]` on `WorkbenchesViewModel`, created with `cli`, the app's `DatabasePool`, and `lineDelivery`; dropped when the session is deleted (hook into the existing session-delete cleanup path).

- [ ] **Step 6: Bridge check, build, lint**

Run: `make editor-bridge-check` (extended with the diff page smoke), `make test-swift FILTER='WorkspaceLayoutChangesTests|ReviewChangesModelTests'`, `make lint-swift`.
Expected: PASS; the app builds (`cd WatchtowerDesktop && swift build`).

- [ ] **Step 7: Commit**

```bash
git add WatchtowerDesktop scripts/editor-bridge-check.swift
git commit -m "feat(desktop): Changes pane with Monaco diff, comments and Send (board #328)"
```

---

### Task 10: Inventory, PROJ-12 amendment, feature note

**Depends on:** Tasks 1–9

**Files:**
- Create: `docs/inventory/review.md`, `docs/features/diff-reviewer.md`
- Modify: `docs/inventory/README.md` (new row), `docs/inventory/workbench.md` (PROJ-12 amendment + changelog), `CLAUDE.md` (feature list link)
- Test: guard tests already written — rename them to the `TestReviewNN_` / `testReviewNN_` convention where they pin a contract:
  - REVIEW-01: `TestSnapshot_IncludesUntrackedAndLeavesIndexAndRefsAlone` → `TestReview01_SnapshotWritesNoRefNoIndex`
  - REVIEW-03: `testCarryCopiesMovedAndOutdatesLost` → `testReview03_CarryNeverDropsAComment`; `ReviewCommentAnchorTests.testLostWhenQuoteGone` stays as support
  - REVIEW-04: `TestReviewRounds_OneOpenPerSessionAndGuardedSend` → `TestReview04_SendIsGuardedAndStoredBeforeTheLine`; `testSendTwiceTypesOnce` → `testReview04_SendTypesOnce`
  - REVIEW-05: `TestReview05_SnapshotAndDiffRunNothingFromTheFolder` (already named)

**Interfaces:** none (docs).

- [ ] **Step 1: `docs/inventory/review.md`** — entries in the workbench.md format (`## ID — title`, **Status:**, **Observable:**, **Why locked:**, **Test guards:**, **Locked since:** 2026-10-16), owner approval: spec review ask #179:
  - **REVIEW-01 — the reviewer never writes a ref, the owner's index or a work-tree file** (Plan 1 has no writer at all; Plan 3 adds Undo and lessons as the two owner-pressed exceptions and amends this entry).
  - **REVIEW-03 — a review comment is never silently lost across rounds** (carried or outdated with its quote).
  - **REVIEW-04 — a round's delivery is stored before anything is typed, and the line goes only through PROJ-12's gates.**
  - **REVIEW-05 — every git call of the reviewer runs with the background-read hardening; none runs a filter driver, hook or fsmonitor from the folder.**
  - REVIEW-02 (Undo) is reserved for Plan 3; say so in a one-line note at the top.
  - Note the AGENT-06 scope exception: `get_review`'s unaudited `sent → delivered` write, same as `get_ask`.

- [ ] **Step 2: PROJ-12 amendment** — in `docs/inventory/workbench.md` PROJ-12: append to **Status:** "amended 2026-10-16 with the owner's approval (spec review ask #179, board #328): the diff reviewer's round line uses the same delivery"; in **Observable:** one paragraph: the second fixed line `Review round #<id> sent (<n> comment[s]) — read it with get_review <id> using the watchtower-workbench skill.` (Swift `ReviewDeliveryLine`, Go `reviewdiff.DeliveryLine`, pinned by `internal/reviewdiff/testdata/lines`) is typed through `SessionLineDelivery` with `LineKey.review`, under exactly the gates above, only after `review send` stored the round as `sent`. Add the Swift test to **Test guards:**. Changelog bullet dated 2026-10-16.

- [ ] **Step 3: README row and feature note**
  - `docs/inventory/README.md`: `| Diff reviewer (board #328) | [review.md](review.md) | \`internal/reviewdiff/\`, \`internal/db/review_rounds.go\`, \`cmd/workbench_review*.go\`, \`internal/tools/workbench_review.go\`, \`WatchtowerDesktop/Sources/WatchtowerCore/Services/Review/\`, \`WatchtowerDesktop/Sources/ViewModels/ReviewChangesModel.swift\` |`; also add `internal/gitbin/run.go` (ExecEnv, content reads) to the row that owns gitbin if one does.
  - `docs/features/diff-reviewer.md`: what shipped in Plan 1 (snapshot/base/diff/file, rounds and statuses, carry-over, Viewed keyed by hunk ids, `get_review`, delivery line and brief line, the Changes pane and how to open it), the v1 limits (name-pattern generated detection only — no `linguist-generated`; Quick mode only; LFS repositories with a local `filter.lfs.*` snapshot raw content; no Undo yet), and the plan/spec links.
  - `CLAUDE.md` Feature Notes: one bullet after the Workbench entry: `- [Diff reviewer — guided review of a session's changes (2026-10-16, Plan 1 of 3)](docs/features/diff-reviewer.md) — \`internal/reviewdiff\` temp-index snapshot and tree diff, migration 00117 \`review_rounds\`/\`review_comments\`/\`review_viewed\`, \`workbench review start|diff|file|send|context\`, \`get_review\` + PROJ-12 round line, Changes pane (Monaco diff, carry-over, Viewed); REVIEW-01/03/04/05.`

- [ ] **Step 4: Verify and commit**

Run: `go test ./internal/reviewdiff ./internal/db -run 'TestReview0' && make test-swift FILTER='ReviewQueriesTests|ReviewChangesModelTests'`
Expected: PASS under the new names.

```bash
git add docs CLAUDE.md internal WatchtowerDesktop/Tests
git commit -m "docs(review): inventory REVIEW-01/03/04/05, PROJ-12 amendment, feature note (board #328)"
```

---

## Phase gate (controller, once, after Task 10)

`make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...`, `make editor-bridge-check`; then a manual check by the owner (an ask with a checklist): open Review Changes on a session with edits, comment two lines, Send, see the agent call `get_review`, let it edit, open the next round in "Since round N", see carried comments and Viewed kept on untouched files.
