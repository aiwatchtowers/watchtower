package sessionreport

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"watchtower/internal/db"
)

var refreshNow = time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)

func fixedNow() time.Time { return refreshNow }

// gitEnv isolates every git call of a test from the developer's own config.
func gitEnv(t *testing.T) {
	t.Helper()
	t.Setenv("GIT_CONFIG_GLOBAL", os.DevNull)
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	t.Setenv("GIT_AUTHOR_NAME", "Test")
	t.Setenv("GIT_AUTHOR_EMAIL", "test@example.com")
	t.Setenv("GIT_COMMITTER_NAME", "Test")
	t.Setenv("GIT_COMMITTER_EMAIL", "test@example.com")
}

func gitRun(t *testing.T, dir string, args ...string) {
	t.Helper()
	c := exec.Command("git", args...)
	c.Dir = dir
	if out, err := c.CombinedOutput(); err != nil {
		t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, out)
	}
}

func commitFile(t *testing.T, dir, name, msg string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(name+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitRun(t, dir, "add", name)
	gitRun(t, dir, "commit", "-q", "-m", msg)
}

// newRepo builds a repository on main with a branch "merged" (merged with a
// merge commit) and a branch "open" (one commit main lacks).
func newRepo(t *testing.T) string {
	t.Helper()
	gitEnv(t)
	dir := t.TempDir()
	gitRun(t, dir, "init", "-q", "-b", "main")
	commitFile(t, dir, "README.md", "init")
	gitRun(t, dir, "checkout", "-q", "-b", "merged")
	commitFile(t, dir, "a.txt", "a")
	gitRun(t, dir, "checkout", "-q", "main")
	gitRun(t, dir, "merge", "-q", "--no-ff", "-m", "merge a", "merged")
	gitRun(t, dir, "checkout", "-q", "-b", "open")
	commitFile(t, dir, "b.txt", "b")
	gitRun(t, dir, "checkout", "-q", "main")
	return dir
}

// newWorkbench opens a fresh database with one workbench bound to folder.
func newWorkbench(t *testing.T, folder string) (*db.DB, int64) {
	t.Helper()
	d, err := db.Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { d.Close() })
	id, err := d.CreateWorkbench("acme", folder)
	if err != nil {
		t.Fatal(err)
	}
	return d, id
}

// ghStubScript answers the gh calls the tests make; anything else fails.
// pr 15 hangs until it is killed (with its child: the process group).
const ghStubScript = `#!/bin/sh
echo "$*" >> '%LOG%'
case "$*" in
"auth status") exit 0 ;;
"pr view 11 --json state,title,additions,deletions,mergedAt")
  echo '{"state":"OPEN","title":"Open one","additions":5,"deletions":2,"mergedAt":null}' ;;
"pr view 12 --json state,title,additions,deletions,mergedAt"|"pr view 14 --json state,title,additions,deletions,mergedAt"|"pr view 21 --json state,title,additions,deletions,mergedAt")
  echo '{"state":"MERGED","title":"Merged one","additions":40,"deletions":7,"mergedAt":"2026-10-02T09:30:00Z"}' ;;
"pr view 13 --json state,title,additions,deletions,mergedAt")
  echo '{"state":"CLOSED","title":"Closed one","additions":1,"deletions":1,"mergedAt":null}' ;;
"pr view 15 --json state,title,additions,deletions,mergedAt") sleep 60 ;;
"pr list --head feature --state all --limit 1 --json number,state,title,additions,deletions,mergedAt")
  echo '[{"number":21,"state":"MERGED","title":"Feature","additions":9,"deletions":3,"mergedAt":"2026-10-01T08:00:00Z"}]' ;;
"pr list --head "*) echo '[]' ;;
*) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
`

// ghStub puts a fake gh first on PATH, runs it through ghProcs, and returns
// a reader of the calls it got.
func ghStub(t *testing.T) func() []string {
	t.Helper()
	dir := t.TempDir()
	logPath := filepath.Join(dir, "calls.log")
	script := strings.ReplaceAll(ghStubScript, "%LOG%", logPath)
	if err := os.WriteFile(filepath.Join(dir, "gh"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	trackGH(t)
	return func() []string {
		b, err := os.ReadFile(logPath)
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		if err != nil {
			t.Fatal(err)
		}
		return strings.Split(strings.TrimSpace(string(b)), "\n")
	}
}

// trackGH runs every gh call in its own process group, killed through
// exec's Cancel. exec can call Cancel after the process was already reaped,
// so Cancel first asks os.Process (Signal(0) returns os.ErrProcessDone once
// Wait reaped it) and kills the group only while the process is still ours.
// A microsecond window between that check and the kill remains (a reap and
// a PID reuse in between); it is accepted for a test stub. t.Cleanup cancels
// every call still running and waits for each to finish.
func trackGH(t *testing.T) {
	t.Helper()
	stop, cancelAll := context.WithCancel(context.Background())
	var wg sync.WaitGroup
	prev := run
	run = func(ctx context.Context, dir string, stdin []byte, name string, args ...string) ([]byte, int, error) {
		if name != "gh" {
			return prev(ctx, dir, stdin, name, args...)
		}
		wg.Add(1)
		defer wg.Done()
		ctx, cancel := context.WithCancel(ctx)
		defer cancel()
		defer context.AfterFunc(stop, cancel)()
		c := exec.CommandContext(ctx, "gh", args...)
		c.Dir = dir
		c.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		c.Cancel = func() error {
			if err := c.Process.Signal(syscall.Signal(0)); err != nil {
				return err // reaped already (os.ErrProcessDone): its PID is no longer ours
			}
			return syscall.Kill(-c.Process.Pid, syscall.SIGKILL)
		}
		c.WaitDelay = time.Second
		if stdin != nil {
			c.Stdin = bytes.NewReader(stdin)
		}
		var out bytes.Buffer
		c.Stdout = &out
		var exitErr *exec.ExitError
		switch err := c.Run(); {
		case err == nil:
			return out.Bytes(), 0, nil
		case errors.As(err, &exitErr):
			return out.Bytes(), exitErr.ExitCode(), fmt.Errorf("gh %s: %w", strings.Join(args, " "), err)
		default:
			return nil, -1, err
		}
	}
	t.Cleanup(func() {
		cancelAll()
		wg.Wait()
		run = prev
	})
}

// countGit counts the git processes Refresh starts.
func countGit(t *testing.T) func() int {
	t.Helper()
	var mu sync.Mutex
	n := 0
	prev := run
	run = func(ctx context.Context, dir string, stdin []byte, name string, args ...string) ([]byte, int, error) {
		if name == "git" {
			mu.Lock()
			n++
			mu.Unlock()
		}
		return prev(ctx, dir, stdin, name, args...)
	}
	t.Cleanup(func() { run = prev })
	return func() int {
		mu.Lock()
		defer mu.Unlock()
		return n
	}
}

func states(t *testing.T, d *db.DB, id int64) map[string]db.PRState {
	t.Helper()
	m, err := d.PRStates(id)
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func seed(t *testing.T, d *db.DB, id int64, ref, state string, age time.Duration) db.PRState {
	t.Helper()
	s := db.PRState{WorkbenchID: id, Ref: ref, State: state, Title: "cached " + ref,
		CheckedAt: refreshNow.Add(-age).Format(time.RFC3339)}
	if err := d.UpsertPRState(s); err != nil {
		t.Fatal(err)
	}
	return s
}

func n64(v int64) sql.NullInt64 { return sql.NullInt64{Int64: v, Valid: true} }

func TestRefresh_PullRequestAndBranchStatesFromGH(t *testing.T) {
	dir := newRepo(t)
	calls := ghStub(t)
	d, id := newWorkbench(t, dir)
	refs := []string{"pr:11", "pr:12", "pr:13", "branch:feature", "branch:open", "branch:merged", "pr:11"}
	res := Refresh(context.Background(), d, id, refs, RefreshOptions{Network: true, Now: fixedNow})
	if res.Note != "" {
		t.Fatalf("note %q, want none", res.Note)
	}
	at := refreshNow.Format(time.RFC3339)
	want := map[string]db.PRState{
		"pr:11":          {State: "open", PRNumber: n64(11), Title: "Open one", Additions: n64(5), Deletions: n64(2)},
		"pr:12":          {State: "merged", PRNumber: n64(12), Title: "Merged one", Additions: n64(40), Deletions: n64(7), MergedAt: "2026-10-02T09:30:00Z"},
		"pr:13":          {State: "closed", PRNumber: n64(13), Title: "Closed one", Additions: n64(1), Deletions: n64(1)},
		"branch:feature": {State: "merged", PRNumber: n64(21), Title: "Feature", Additions: n64(9), Deletions: n64(3), MergedAt: "2026-10-01T08:00:00Z"},
		"branch:open":    {State: "none"}, // gh knows no PR, git: not merged
		"branch:merged":  {State: "merged"},
	}
	got := states(t, d, id)
	if len(got) != len(want) {
		t.Fatalf("rows %v, want %d", got, len(want))
	}
	for ref, w := range want {
		w.WorkbenchID, w.Ref, w.CheckedAt = id, ref, at
		if got[ref] != w {
			t.Errorf("%s: %+v, want %+v", ref, got[ref], w)
		}
	}
	// pr:11 is listed twice but read once.
	n := 0
	for _, c := range calls() {
		if strings.HasPrefix(c, "pr view 11 ") {
			n++
		}
	}
	if n != 1 {
		t.Fatalf("pr 11 read %d times, calls %v", n, calls())
	}

	// A branch whose PR is cached is re-read by number, not listed again.
	seed(t, d, id, "branch:other", "open", time.Hour)
	row := states(t, d, id)["branch:other"]
	row.PRNumber = n64(14)
	if err := d.UpsertPRState(row); err != nil {
		t.Fatal(err)
	}
	Refresh(context.Background(), d, id, []string{"branch:other"}, RefreshOptions{Network: true, Now: fixedNow})
	if got := states(t, d, id)["branch:other"]; got.State != "merged" || got.PRNumber != n64(14) {
		t.Fatalf("branch:other %+v, want merged PR 14", got)
	}
	last := calls()[len(calls())-1]
	if !strings.HasPrefix(last, "pr view 14 ") {
		t.Fatalf("last gh call %q, want pr view 14", last)
	}
}

func TestRefresh_GHMissingKeepsBranchStateOnly(t *testing.T) {
	dir := newRepo(t)
	t.Setenv("PATH", t.TempDir()) // no gh anywhere; git is located by gitbin, not PATH
	d, id := newWorkbench(t, dir)
	cached := seed(t, d, id, "pr:11", "open", time.Hour)
	res := Refresh(context.Background(), d, id, []string{"pr:11", "branch:merged", "branch:open", "branch:gone"},
		RefreshOptions{Network: true, Now: fixedNow})
	if !strings.Contains(res.Note, "gh CLI not found") {
		t.Fatalf("note %q, want gh missing", res.Note)
	}
	got := states(t, d, id)
	if got["pr:11"] != cached {
		t.Fatalf("pr:11 %+v, want its cached row %+v", got["pr:11"], cached)
	}
	if got["branch:merged"].State != "merged" || got["branch:open"].State != "open" {
		t.Fatalf("branches %+v / %+v, want merged / open", got["branch:merged"], got["branch:open"])
	}
	// Only gh names a branch's PR: a git-only row carries no PR fields.
	for _, ref := range []string{"branch:merged", "branch:open"} {
		if r := got[ref]; r.PRNumber.Valid || r.Title != "" || r.Additions.Valid || r.Deletions.Valid || r.MergedAt != "" {
			t.Fatalf("%s without gh %+v, want no PR fields", ref, r)
		}
	}
	if _, ok := got["branch:gone"]; ok {
		t.Fatalf("a missing branch without gh is no conclusion, got %+v", got["branch:gone"])
	}
}

func TestRefresh_NetworkOffRunsNoGH(t *testing.T) {
	dir := newRepo(t)
	calls := ghStub(t)
	d, id := newWorkbench(t, dir)
	res := Refresh(context.Background(), d, id, []string{"pr:11", "branch:merged"}, RefreshOptions{Now: fixedNow})
	if c := calls(); len(c) != 0 {
		t.Fatalf("gh ran without Network: %v", c)
	}
	if !strings.Contains(res.Note, "network off") {
		t.Fatalf("note %q, want network off", res.Note)
	}
	got := states(t, d, id)
	if _, ok := got["pr:11"]; ok || got["branch:merged"].State != "merged" {
		t.Fatalf("rows %+v, want branch:merged only", got)
	}
}

func TestRefresh_BudgetKeepsUncheckedRowsCached(t *testing.T) {
	dir := newRepo(t)
	ghStub(t)
	d, id := newWorkbench(t, dir)
	second := seed(t, d, id, "pr:12", "open", time.Hour)
	third := seed(t, d, id, "pr:13", "open", time.Hour)
	// Every clock read moves 4 s: the budget check before pr:11 passes
	// (4 s), its write reads 8 s, and the check before pr:12 is past 10 s.
	var mu sync.Mutex
	tick := 0
	clock := func() time.Time {
		mu.Lock()
		defer mu.Unlock()
		at := refreshNow.Add(time.Duration(tick) * 4 * time.Second)
		tick++
		return at
	}
	res := Refresh(context.Background(), d, id, []string{"pr:11", "pr:12", "pr:13"},
		RefreshOptions{Network: true, Budget: 10 * time.Second, Now: clock})
	if !strings.Contains(res.Note, "the 10s time budget ran out; 2 ref(s) keep their cached state") {
		t.Fatalf("note %q, want the budget note", res.Note)
	}
	got := states(t, d, id)
	if got["pr:11"].State != "open" || got["pr:11"].Title != "Open one" {
		t.Fatalf("pr:11 %+v, want checked", got["pr:11"])
	}
	if got["pr:12"] != second || got["pr:13"] != third {
		t.Fatalf("unchecked refs changed: %+v / %+v", got["pr:12"], got["pr:13"])
	}
}

func TestRefresh_CacheFreshness(t *testing.T) {
	dir := newRepo(t)
	calls := ghStub(t)
	d, id := newWorkbench(t, dir)
	seed(t, d, id, "pr:11", "open", 30*time.Second)   // fresh
	seed(t, d, id, "pr:12", "open", 61*time.Second)   // stale
	seed(t, d, id, "pr:13", "merged", 5*time.Minute)  // settled, fresh
	seed(t, d, id, "pr:14", "merged", 11*time.Minute) // settled, stale
	Refresh(context.Background(), d, id, []string{"pr:11", "pr:12", "pr:13", "pr:14"},
		RefreshOptions{Network: true, Now: fixedNow})
	var viewed []string
	for _, c := range calls() {
		if strings.HasPrefix(c, "pr view ") {
			viewed = append(viewed, strings.Fields(c)[2])
		}
	}
	if strings.Join(viewed, ",") != "12,14" {
		t.Fatalf("re-checked %v, want 12,14", viewed)
	}

	// Nothing stale: no process at all.
	gits := countGit(t)
	before := len(calls())
	Refresh(context.Background(), d, id, []string{"pr:11", "pr:13"}, RefreshOptions{Network: true, Now: fixedNow})
	if len(calls()) != before || gits() != 0 {
		t.Fatalf("fresh refs ran %d gh / %d git calls", len(calls())-before, gits())
	}
}

func TestRefresh_PlainFolderSpawnsNoGit(t *testing.T) {
	gitEnv(t)
	calls := ghStub(t)
	gits := countGit(t)
	d, id := newWorkbench(t, t.TempDir())
	res := Refresh(context.Background(), d, id, []string{"branch:open", "pr:11"}, RefreshOptions{Network: true, Now: fixedNow})
	if gits() != 0 {
		t.Fatalf("%d git calls in a plain folder", gits())
	}
	if c := calls(); len(c) != 0 {
		t.Fatalf("gh ran in a plain folder: %v", c)
	}
	if !strings.Contains(res.Note, "not a git work tree") {
		t.Fatalf("note %q", res.Note)
	}
	if got := states(t, d, id); len(got) != 0 {
		t.Fatalf("rows %+v, want none", got)
	}
}

func TestRefresh_UnknownWorkbenchIsANote(t *testing.T) {
	d, _ := newWorkbench(t, t.TempDir())
	if res := Refresh(context.Background(), d, 999, []string{"pr:1"}, RefreshOptions{}); !strings.Contains(res.Note, "not refreshed") {
		t.Fatalf("note %q", res.Note)
	}
}

// Without gh, git never turns a PR state gh saw into "open": an unmerged
// branch keeps its cached row whole; a merged one is upgraded to merged with
// its PR fields kept.
func TestRefresh_OfflineKeepsGHBranchState(t *testing.T) {
	dir := newRepo(t)
	calls := ghStub(t)
	d, id := newWorkbench(t, dir)
	closed := func(ref string) db.PRState {
		s := db.PRState{WorkbenchID: id, Ref: ref, State: "closed", PRNumber: n64(7), Title: "Closed PR",
			Additions: n64(3), Deletions: n64(1), CheckedAt: refreshNow.Add(-11 * time.Minute).Format(time.RFC3339)}
		if err := d.UpsertPRState(s); err != nil {
			t.Fatal(err)
		}
		return s
	}
	open, merged := closed("branch:open"), closed("branch:merged")
	Refresh(context.Background(), d, id, []string{"branch:open", "branch:merged"}, RefreshOptions{Now: fixedNow})
	if c := calls(); len(c) != 0 {
		t.Fatalf("gh ran without Network: %v", c)
	}
	got := states(t, d, id)
	if got["branch:open"] != open {
		t.Fatalf("unmerged branch %+v, want its cached row %+v", got["branch:open"], open)
	}
	merged.State, merged.CheckedAt = "merged", refreshNow.Format(time.RFC3339)
	if got["branch:merged"] != merged {
		t.Fatalf("merged branch %+v, want %+v", got["branch:merged"], merged)
	}
}

// The real budget running out during the last ref's read still says so:
// the cut read is neither stored nor counted as a failed read.
func TestRefresh_BudgetCutOnTheLastRefIsNoted(t *testing.T) {
	dir := newRepo(t)
	ghStub(t)
	d, id := newWorkbench(t, dir)
	res := Refresh(context.Background(), d, id, []string{"pr:15"},
		RefreshOptions{Network: true, Budget: time.Second, Now: fixedNow})
	if !strings.Contains(res.Note, "time budget ran out; 1 ref(s) keep their cached state") ||
		strings.Contains(res.Note, "could not be read") {
		t.Fatalf("note %q, want only the budget note", res.Note)
	}
	if got := states(t, d, id); len(got) != 0 {
		t.Fatalf("rows %+v, want none", got)
	}
}
