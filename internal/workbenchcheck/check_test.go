package workbenchcheck

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/gitbin"
)

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

func commitFile(t *testing.T, dir, name, content, msg string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	gitRun(t, dir, "add", name)
	gitRun(t, dir, "commit", "-q", "-m", msg)
}

// newRepo builds a repository on main with these branches:
//
//	ff       — one commit, merged into main by a fast-forward
//	freshold — cut from main before main moved on, no commits of its own
//	merged   — merged into main with a merge commit
//	stacked  — cut from merged's tip after that merge, no commits of its own
//	squash   — its diff squashed into one commit on main
//	nearsquash — squashed into main after main changed a line near its hunks
//	rebase   — two commits re-applied onto main as new commits (a rebase merge)
//	rebasedmerged — one commit, rebased onto main, then merged with a merge commit
//	synced       — one commit, main merged into it, then merged with a merge commit
//	rebasedfresh — commit-less, cut from main~1 and rebased onto main
//	resetback    — one commit, then reset back onto main (no work left)
//	open     — one commit main lacks
//	fresh    — cut from main's tip, no commits of its own
func newRepo(t *testing.T) string {
	t.Helper()
	gitEnv(t)
	dir := t.TempDir()
	gitRun(t, dir, "init", "-q", "-b", "main")
	commitFile(t, dir, "README.md", "hello\n", "init")

	gitRun(t, dir, "checkout", "-q", "-b", "ff")
	commitFile(t, dir, "f.txt", "f\n", "f")
	gitRun(t, dir, "checkout", "-q", "main")
	gitRun(t, dir, "merge", "-q", "--ff-only", "ff")
	gitRun(t, dir, "branch", "freshold")

	gitRun(t, dir, "checkout", "-q", "-b", "merged")
	commitFile(t, dir, "a.txt", "a\n", "a")
	gitRun(t, dir, "checkout", "-q", "main")
	gitRun(t, dir, "merge", "-q", "--no-ff", "-m", "merge a", "merged")
	gitRun(t, dir, "branch", "stacked", "merged")

	gitRun(t, dir, "checkout", "-q", "-b", "squash")
	commitFile(t, dir, "b.txt", "b1\n", "b1")
	commitFile(t, dir, "b.txt", "b1\nb2\n", "b2")
	gitRun(t, dir, "checkout", "-q", "main")
	gitRun(t, dir, "merge", "-q", "--squash", "squash")
	gitRun(t, dir, "commit", "-q", "-m", "squash b")

	gitRun(t, dir, "checkout", "-q", "-b", "rebase")
	commitFile(t, dir, "d.txt", "d1\n", "d1")
	commitFile(t, dir, "e.txt", "e1\n", "e1")
	gitRun(t, dir, "checkout", "-q", "main")
	commitFile(t, dir, "g.txt", "g\n", "main moves on")
	gitRun(t, dir, "cherry-pick", "rebase~1", "rebase")

	// Merged with a merge commit after their last change was not a plain
	// commit: rebased onto main first, or main merged into them.
	gitRun(t, dir, "checkout", "-q", "-b", "rebasedmerged", "main~1")
	commitFile(t, dir, "i.txt", "i\n", "i")
	gitRun(t, dir, "rebase", "-q", "main")
	gitRun(t, dir, "checkout", "-q", "-b", "synced", "main~1")
	commitFile(t, dir, "j.txt", "j\n", "j")
	gitRun(t, dir, "merge", "-q", "--no-edit", "main")
	gitRun(t, dir, "checkout", "-q", "main")
	gitRun(t, dir, "merge", "-q", "--no-ff", "-m", "merge rebasedmerged", "rebasedmerged")
	gitRun(t, dir, "merge", "-q", "--no-ff", "-m", "merge synced", "synced")

	gitRun(t, dir, "branch", "rebasedfresh", "main~1")
	gitRun(t, dir, "checkout", "-q", "rebasedfresh")
	gitRun(t, dir, "rebase", "-q", "main")
	gitRun(t, dir, "checkout", "-q", "-b", "resetback")
	commitFile(t, dir, "h.txt", "h\n", "abandoned")
	gitRun(t, dir, "reset", "-q", "--hard", "HEAD~1")
	gitRun(t, dir, "checkout", "-q", "main")

	// main changes line 12 between the fork and the squash: no conflict,
	// but the squash's diff context differs from the branch's own.
	lines := make([]string, 30)
	for i := range lines {
		lines[i] = strconv.Itoa(i + 1)
	}
	nfile := func(edit map[int]string) string {
		out := slices.Clone(lines)
		for i, v := range edit {
			out[i-1] = v
		}
		return strings.Join(out, "\n") + "\n"
	}
	commitFile(t, dir, "n.txt", nfile(nil), "n")
	gitRun(t, dir, "checkout", "-q", "-b", "nearsquash")
	commitFile(t, dir, "n.txt", nfile(map[int]string{15: "fifteen"}), "n15")
	commitFile(t, dir, "n.txt", nfile(map[int]string{15: "fifteen", 16: "sixteen"}), "n16")
	gitRun(t, dir, "checkout", "-q", "main")
	commitFile(t, dir, "n.txt", nfile(map[int]string{12: "twelve"}), "n12")
	gitRun(t, dir, "merge", "-q", "--squash", "nearsquash")
	gitRun(t, dir, "commit", "-q", "-m", "squash n")

	gitRun(t, dir, "checkout", "-q", "-b", "open")
	commitFile(t, dir, "c.txt", "c\n", "c")
	gitRun(t, dir, "checkout", "-q", "main")
	gitRun(t, dir, "branch", "fresh")
	return dir
}

var testNow = time.Now().UTC()

func ago(d time.Duration) string { return testNow.Add(-d).Format(time.RFC3339) }

func node(id int, status, branch string, moved time.Duration, children ...db.BoardNode) db.BoardNode {
	return db.BoardNode{
		Target:      db.Target{ID: id, Text: "target " + branch, Status: status, Branch: branch, UpdatedAt: ago(moved)},
		StatusSince: ago(moved),
		Children:    children,
	}
}

func kinds(r Report) map[int][]string {
	out := map[int][]string{}
	for _, f := range r.Findings {
		out[f.TargetID] = append(out[f.TargetID], f.Kind)
	}
	return out
}

func TestProj07_GitRules(t *testing.T) {
	dir := newRepo(t)
	board := []db.BoardNode{
		node(1, "in_progress", "merged", time.Hour),
		node(2, "in_review", "squash", time.Hour),
		node(3, "done", "open", time.Hour),
		node(4, "in_progress", "fresh", time.Hour),
		node(5, "in_progress", "nowhere", time.Hour),
		node(6, "todo", "nowhere", time.Hour),
		node(7, "done", "merged", time.Hour),
		node(8, "done", "open", 30*24*time.Hour), // closed long ago: history, not drift
		node(9, "in_progress", "", time.Hour),    // (an open target on "open" would share #3's branch: see SharedBranchAndParents)
		node(10, "dismissed", "merged", time.Hour),
		node(11, "todo", "main", time.Hour), // the default branch itself is never checked
		node(12, "done", "squash", time.Hour),
		node(13, "in_progress", "rebase", time.Hour),
		node(14, "done", "rebase", time.Hour),
		node(15, "in_progress", "ff", time.Hour),
		node(16, "in_progress", "stacked", time.Hour),  // a new branch on top of merged work
		node(17, "in_progress", "freshold", time.Hour), // main moved past a branch with no commits yet
		node(18, "in_progress", "rebasedfresh", time.Hour),
		node(19, "in_progress", "resetback", time.Hour),
		node(20, "in_progress", "rebasedmerged", time.Hour),
		node(21, "in_progress", "synced", time.Hour),
		node(22, "in_progress", "nearsquash", time.Hour),
	}
	r := Check(context.Background(), 1, board, Options{Folder: dir, Now: testNow})
	if !r.Git || r.Base != "main" {
		t.Fatalf("git=%v base=%q notes=%v", r.Git, r.Base, r.Notes)
	}
	want := map[int][]string{
		1:  {KindMergedOpen},
		2:  {KindMergedOpen},
		3:  {KindDoneUnmerged},
		5:  {KindBranchMissing},
		13: {KindMergedOpen},
		15: {KindMergedOpen},
		20: {KindMergedOpen},
		21: {KindMergedOpen},
		22: {KindMergedOpen},
	}
	got := kinds(r)
	if len(got) != len(want) {
		t.Fatalf("findings = %v, want %v", got, want)
	}
	for id, k := range want {
		if strings.Join(got[id], ",") != strings.Join(k, ",") {
			t.Fatalf("target %d: kinds %v, want %v (all: %v)", id, got[id], k, got)
		}
	}
	for _, f := range r.Findings {
		if f.Fix == "" || f.Detail == "" {
			t.Fatalf("finding %+v must carry a detail and a fix", f)
		}
		if f.Blocking() == (f.Kind == KindDoneUnmerged) {
			t.Fatalf("only done_but_unmerged (an offline guess) is advisory, got %+v blocking=%v", f, f.Blocking())
		}
	}
	// Alone on its branch (no open target sharing it), a done target whose
	// branch was squashed next to a main change is merged work, not drift.
	r = Check(context.Background(), 1, []db.BoardNode{node(1, "done", "nearsquash", time.Hour)}, Options{Folder: dir, Now: testNow})
	if len(r.Findings) != 0 {
		t.Fatalf("a squash-merged done target is not drift, got %+v", r.Findings)
	}
}

// A done plan task on the feature branch is a finished step of unfinished
// work while an open target still carries that branch; a parent flagged as
// merged is told to move its sub-targets, never itself (PROJ-05).
func TestProj07_SharedBranchAndParents(t *testing.T) {
	dir := newRepo(t)
	board := []db.BoardNode{
		node(1, "in_progress", "open", time.Hour, node(2, "done", "open", time.Hour), node(3, "todo", "", time.Hour)),
		node(4, "in_progress", "merged", time.Hour, node(5, "todo", "", time.Hour)),
	}
	r := Check(context.Background(), 1, board, Options{Folder: dir, Now: testNow})
	got := kinds(r)
	if len(got) != 1 || len(got[4]) != 1 || got[4][0] != KindMergedOpen {
		t.Fatalf("only the merged parent is drift, got %v", got)
	}
	if f := r.Findings[0]; !strings.Contains(f.Fix, "sub-target") || strings.HasPrefix(f.Fix, "set it done") {
		t.Fatalf("a parent's fix must point at its sub-targets: %q", f.Fix)
	}
}

// A git call that fails for any reason but "no such ref" is unknown, never
// a missing branch nor a merge verdict. The batch branch read fails too, so
// each branch is read on its own (TestProj07_GitErrorsAfterTheBatchReadAreNeverFindings
// covers the batch read's path).
func TestProj07_GitErrorsAreNeverFindings(t *testing.T) {
	dir := newRepo(t)
	run := func(ctx context.Context, d string, in []byte, name string, args ...string) ([]byte, int, error) {
		if len(args) > 0 && (args[0] == "rev-list" || args[0] == "cherry" || args[0] == "for-each-ref") || (len(args) > 3 && strings.Contains(args[3], "nowhere")) {
			return nil, 128, os.ErrPermission
		}
		return ExecRunner(ctx, d, in, name, args...)
	}
	board := []db.BoardNode{
		node(1, "in_progress", "merged", time.Hour),
		node(2, "done", "open", time.Hour),
		node(3, "in_progress", "nowhere", time.Hour),
	}
	r := Check(context.Background(), 1, board, Options{Folder: dir, Now: testNow, Run: run})
	if len(r.Findings) != 0 {
		t.Fatalf("failed git calls must yield no findings, got %+v", r.Findings)
	}
}

// No git process at all outside a repository: on a Mac without the
// developer tools /usr/bin/git itself opens an install dialog.
func TestProj07_NoGitCallOutsideARepository(t *testing.T) {
	gitEnv(t)
	for _, network := range []bool{false, true} {
		var gitCalls int
		run := func(_ context.Context, _ string, _ []byte, name string, _ ...string) ([]byte, int, error) {
			if name == "git" {
				gitCalls++
			}
			return nil, -1, exec.ErrNotFound
		}
		r := Check(context.Background(), 1, []db.BoardNode{node(1, "in_progress", "merged", time.Hour)},
			Options{Folder: t.TempDir(), Now: testNow, Network: network, Run: run})
		if gitCalls != 0 || r.Git {
			t.Fatalf("network=%v: %d git calls outside a repository", network, gitCalls)
		}
	}
	// A linked worktree's .git file counts as a repository.
	wt := t.TempDir()
	if err := os.WriteFile(filepath.Join(wt, ".git"), []byte("gitdir: /nowhere\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if !insideRepository(filepath.Join(wt)) {
		t.Fatal("a .git file must count as a repository")
	}
}

// The deadline hitting mid-walk keeps the findings of the targets checked
// before it and drops the cut-short one (which would read as missing). The
// batch branch read fails, so "nowhere" is looked up on its own.
func TestProj07_MidWalkDeadlineKeepsEarlierFindingsOnly(t *testing.T) {
	dir := newRepo(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	run := func(c context.Context, d string, in []byte, name string, args ...string) ([]byte, int, error) {
		if len(args) > 0 && args[0] == "for-each-ref" {
			return nil, 128, os.ErrPermission
		}
		if strings.Contains(strings.Join(args, " "), "nowhere") {
			cancel()
			return nil, -1, context.Canceled
		}
		return ExecRunner(c, d, in, name, args...)
	}
	board := []db.BoardNode{node(1, "in_progress", "merged", time.Hour), node(2, "in_progress", "nowhere", time.Hour)}
	r := Check(ctx, 1, board, Options{Folder: dir, Now: testNow, Run: run})
	got := kinds(r)
	if !r.Incomplete || len(got) != 1 || len(got[1]) != 1 || got[1][0] != KindMergedOpen {
		t.Fatalf("want incomplete with only #1's finding, got incomplete=%v %v", r.Incomplete, got)
	}
}

func TestCheck_OriginDefaultBranchIsTheBase(t *testing.T) {
	origin := newRepo(t)
	clone := t.TempDir()
	gitRun(t, clone, "clone", "-q", origin, ".")
	// The owner merged "open" on the remote; the clone's local main is behind.
	gitRun(t, origin, "merge", "-q", "--no-ff", "-m", "merge c", "open")
	gitRun(t, clone, "fetch", "-q")
	r := Check(context.Background(), 1, []db.BoardNode{node(1, "in_progress", "open", time.Hour)},
		Options{Folder: clone, Now: testNow})
	if r.Base != "origin/main" {
		t.Fatalf("base = %q, want origin/main", r.Base)
	}
	if k := kinds(r)[1]; len(k) != 1 || k[0] != KindMergedOpen {
		t.Fatalf("a branch merged on origin (local main behind) must read as merged, got %v", k)
	}
}

func TestCheck_Stale(t *testing.T) {
	dir := newRepo(t)
	board := []db.BoardNode{
		node(1, "in_progress", "", 5*24*time.Hour),
		node(2, "in_progress", "", 2*24*time.Hour),
		// A parent's status follows its children (PROJ-05): only leaves count.
		node(3, "in_progress", "", 5*24*time.Hour, node(4, "in_progress", "", time.Hour)),
		node(5, "blocked", "", 10*24*time.Hour),
		// A commit on its branch is movement too ("fresh" points at main's newest commit).
		node(6, "in_progress", "fresh", 5*24*time.Hour),
	}
	r := Check(context.Background(), 1, board, Options{Folder: dir, Now: testNow})
	got := kinds(r)
	if len(got) != 1 || len(got[1]) != 1 || got[1][0] != KindStale {
		t.Fatalf("only target 1 is stale, got %v", got)
	}
	if r.Findings[0].Blocking() {
		t.Fatal("a stale finding must not block the Stop hook")
	}
	r = Check(context.Background(), 1, board, Options{Folder: dir, Now: testNow, StaleAfter: 24 * time.Hour})
	if k := kinds(r); len(k[2]) != 1 {
		t.Fatalf("StaleAfter 1 day must flag target 2 too, got %v", k)
	}
}

func TestCheck_NotAGitFolderSkipsBranchRules(t *testing.T) {
	gitEnv(t)
	r := Check(context.Background(), 1, []db.BoardNode{node(1, "in_progress", "merged", time.Hour)},
		Options{Folder: t.TempDir(), Now: testNow})
	if r.Git || len(r.Findings) != 0 || len(r.Notes) == 0 {
		t.Fatalf("outside a work tree: no branch findings and a note, got %+v", r)
	}
}

func TestProj07_ReadsNothingButGit(t *testing.T) {
	dir := newRepo(t)
	before := snapshotRefs(t, dir)
	var names []string
	run := func(ctx context.Context, d string, in []byte, name string, args ...string) ([]byte, int, error) {
		names = append(names, name+" "+strings.Join(args, " "))
		return ExecRunner(ctx, d, in, name, args...)
	}
	objectsBefore := countObjects(t, dir)
	Check(context.Background(), 1, []db.BoardNode{node(1, "in_progress", "squash", time.Hour), node(2, "done", "open", time.Hour),
		node(3, "in_progress", "rebase", time.Hour), node(4, "in_progress", "fresh", time.Hour)},
		Options{Folder: dir, Now: testNow, Run: run})
	if after := countObjects(t, dir); after != objectsBefore {
		t.Fatalf("the check wrote objects: %s -> %s", objectsBefore, after)
	}
	readOnly := []string{"rev-parse", "symbolic-ref", "log", "rev-list", "merge-base", "diff", "patch-id", "cherry", "reflog", "for-each-ref"}
	for _, n := range names {
		f := strings.Fields(n)
		if f[0] != "git" || !slices.Contains(readOnly, f[1]) || (f[1] == "reflog" && f[2] != "show") {
			t.Fatalf("the check runs only read-only git subcommands, ran %q", n)
		}
	}
	if after := snapshotRefs(t, dir); after != before {
		t.Fatalf("refs changed:\n%s\n---\n%s", before, after)
	}
}

func countObjects(t *testing.T, dir string) string {
	t.Helper()
	c := exec.Command("git", "count-objects", "-v")
	c.Dir = dir
	out, err := c.Output()
	if err != nil {
		t.Fatal(err)
	}
	return string(out)
}

func snapshotRefs(t *testing.T, dir string) string {
	t.Helper()
	c := exec.Command("git", "for-each-ref")
	c.Dir = dir
	out, err := c.Output()
	if err != nil {
		t.Fatal(err)
	}
	return string(out)
}

func TestCheck_PullRequestStates(t *testing.T) {
	gitEnv(t)
	dir := t.TempDir()
	states := map[string]string{"11": "MERGED", "12": "OPEN", "13": "CLOSED", "14": "OPEN"}
	run := func(_ context.Context, _ string, _ []byte, name string, args ...string) ([]byte, int, error) {
		if name != "gh" {
			return nil, 128, os.ErrNotExist // no git repository here
		}
		if args[0] == "auth" {
			return nil, 0, nil
		}
		return []byte(`{"state":"` + states[args[2]] + `"}`), 0, nil
	}
	pr := func(id int, status, ref string) db.BoardNode {
		n := node(id, status, "", time.Hour)
		n.Target.PR = ref
		return n
	}
	board := []db.BoardNode{pr(1, "in_progress", "#11"), pr(2, "done", "12"), pr(3, "todo", "13"), pr(4, "in_progress", "14")}
	r := Check(context.Background(), 1, board, Options{Folder: dir, Now: testNow, Network: true, Run: run})
	if !r.PRChecked {
		t.Fatalf("gh signed in: PRChecked must be set, notes %v", r.Notes)
	}
	got := kinds(r)
	want := map[int]string{1: KindMergedOpen, 2: KindDoneUnmerged, 3: KindPRClosed}
	if len(got) != len(want) {
		t.Fatalf("findings %v, want %v", got, want)
	}
	for id, k := range want {
		if len(got[id]) != 1 || got[id][0] != k {
			t.Fatalf("target %d: %v, want %s", id, got[id], k)
		}
	}

	// Without Network, gh is never run.
	r = Check(context.Background(), 1, board, Options{Folder: dir, Now: testNow, Run: func(ctx context.Context, d string, in []byte, name string, args ...string) ([]byte, int, error) {
		if name == "gh" {
			t.Fatal("gh ran without Network")
		}
		return run(ctx, d, in, name, args...)
	}})
	if r.PRChecked || len(r.Findings) != 0 {
		t.Fatalf("offline: %+v", r)
	}
}

func TestCheck_GHMissingIsANote(t *testing.T) {
	gitEnv(t)
	run := func(context.Context, string, []byte, string, ...string) ([]byte, int, error) {
		return nil, -1, exec.ErrNotFound
	}
	r := Check(context.Background(), 1, nil, Options{Folder: t.TempDir(), Network: true, Run: run})
	if r.PRChecked || !strings.Contains(strings.Join(r.Notes, "\n"), "gh CLI not found") {
		t.Fatalf("notes %v", r.Notes)
	}
}

// A deadline never turns into findings: a git call cut short reads as "not
// found", which must not be reported as a missing branch.
func TestProj07_DeadlineReportsIncompleteNeverFalseFindings(t *testing.T) {
	dir := newRepo(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	r := Check(ctx, 1, []db.BoardNode{node(1, "in_progress", "merged", time.Hour), node(2, "in_progress", "nowhere", time.Hour)},
		Options{Folder: dir, Now: testNow})
	if !r.Incomplete || len(r.Findings) != 0 {
		t.Fatalf("a cancelled check must be incomplete with no findings, got %+v", r)
	}
}

// origin/HEAD naming a default branch that no longer resolves (renamed on
// the remote, the old ref pruned) skips the branch checks and says why, so
// "branch checks did not run" never comes with no notes.
func TestProj07_UnresolvableDefaultBranchIsANote(t *testing.T) {
	gitEnv(t)
	dir := t.TempDir()
	gitRun(t, dir, "init", "-q", "-b", "trunk")
	commitFile(t, dir, "README.md", "hello\n", "init")
	gitRun(t, dir, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/master")

	r := Check(context.Background(), 1, []db.BoardNode{node(1, "in_progress", "feature", time.Hour)}, Options{Folder: dir, Now: testNow})
	if !r.Git || len(r.Findings) != 0 {
		t.Fatalf("git=%v findings=%+v", r.Git, r.Findings)
	}
	if !slices.ContainsFunc(r.Notes, func(n string) bool { return strings.Contains(n, "default branch master could not be resolved") }) {
		t.Fatalf("notes must say why the branch checks were skipped: %v", r.Notes)
	}
}

// On a Mac without the developer tools the only git is the /usr/bin/git
// shim, which pops the install dialog: the check locates git through
// gitbin, runs none when there is none, and says so in a note.
func TestProj07_GitUnavailableIsANote(t *testing.T) {
	gitEnv(t)
	dir := t.TempDir()
	if err := os.Mkdir(filepath.Join(dir, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	prev := locateGit
	t.Cleanup(func() { locateGit = prev })
	locateGit = func() (string, bool) { return "", false }

	if out, code, err := ExecRunner(context.Background(), dir, nil, "git", "--version"); !errors.Is(err, gitbin.ErrUnavailable) || code != -1 || out != nil {
		t.Fatalf("ExecRunner without git: out=%q code=%d err=%v", out, code, err)
	}
	pr := node(1, "in_progress", "merged", time.Hour)
	pr.Target.PR = "#7"
	board := []db.BoardNode{pr, node(2, "done", "open", time.Hour)}
	for _, network := range []bool{false, true} {
		// gh reads the repository through git from its own PATH — the shim
		// without the developer tools — so it does not run either.
		var ghCalls int
		run := func(ctx context.Context, d string, in []byte, name string, args ...string) ([]byte, int, error) {
			if name == "gh" {
				ghCalls++
			}
			return ExecRunner(ctx, d, in, name, args...)
		}
		r := Check(context.Background(), 1, board, Options{Folder: dir, Now: testNow, Network: network, Run: run})
		if r.Git || r.Base != "" || r.PRChecked || len(r.Findings) != 0 || r.Incomplete || ghCalls != 0 {
			t.Fatalf("network=%v, no git: want git=false, no base, no findings, no gh call; got %d gh calls, %+v", network, ghCalls, r)
		}
		if !slices.Contains(r.Notes, "git is not available (no Command Line Tools); branch checks skipped") {
			t.Fatalf("network=%v: notes must say git is unavailable: %v", network, r.Notes)
		}
		if prNote := slices.Contains(r.Notes, "git is not available; pull request states not checked"); prNote != network {
			t.Fatalf("network=%v: the pull request note must appear exactly when the network is on: %v", network, r.Notes)
		}
	}
}

// ExecRunner runs the git gitbin located, not whatever "git" PATH names,
// with the inherited repository variables dropped and the folder's
// fsmonitor command, hooks and signature checks off.
func TestExecRunner_RunsTheLocatedGit(t *testing.T) {
	bin := filepath.Join(t.TempDir(), "located-git")
	if err := os.WriteFile(bin, []byte("#!/bin/sh\necho \"located $* ${GIT_DIR-unset}\"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	prev := locateGit
	t.Cleanup(func() { locateGit = prev })
	locateGit = func() (string, bool) { return bin, true }
	t.Setenv("GIT_DIR", "/elsewhere/.git")

	out, code, err := ExecRunner(context.Background(), t.TempDir(), nil, "git", "rev-parse")
	if err != nil || code != 0 || strings.TrimSpace(string(out)) != "located -c core.fsmonitor=false -c core.hooksPath=/dev/null -c log.showSignature=false rev-parse unset" {
		t.Fatalf("want the located git without GIT_DIR, got out=%q code=%d err=%v", out, code, err)
	}
}

// A planted .git/config never runs a command during a check: the squash
// rule's diffs run no textconv driver, and a status-like read through
// ExecRunner no fsmonitor command and no filter driver (on an edited file);
// the findings are what they were.
func TestCheck_UntrustedConfigRunsNoCommand(t *testing.T) {
	dir := newRepo(t)
	marker := filepath.Join(t.TempDir(), "ran")
	script := filepath.Join(t.TempDir(), "planted")
	if err := os.WriteFile(script, []byte("#!/bin/sh\ntouch '"+marker+"'\ncat \"$1\" 2>/dev/null\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	gitRun(t, dir, "config", "diff.planted.textconv", script)
	gitRun(t, dir, "config", "core.fsmonitor", script)
	gitRun(t, dir, "config", "filter.planted.clean", script)
	gitRun(t, dir, "config", "filter.planted.required", "true")
	if err := os.WriteFile(filepath.Join(dir, "README.md"), []byte("HELLO\n"), 0o644); err != nil { // same size: content is hashed
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, ".git", "info", "attributes"), []byte("* diff=planted filter=planted\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	r := Check(context.Background(), 1, []db.BoardNode{node(2, "in_review", "squash", time.Hour)}, Options{Folder: dir, Now: testNow})
	if got := kinds(r); strings.Join(got[2], ",") != KindMergedOpen {
		t.Fatalf("the squash is still merged work, got %v (notes %v)", got, r.Notes)
	}
	if _, _, err := ExecRunner(context.Background(), dir, nil, "git", "status", "--porcelain"); err != nil {
		t.Fatalf("git status: %v", err)
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("a command from the folder's git config ran")
	}
}

// A filter driver key git -c cannot blank (it holds a '=') refuses the
// squash check's diff reads: the check names it once in Notes rather than
// silently reading the squash as unknown (target 155).
func TestCheck_FilterGuardFailureIsANote(t *testing.T) {
	dir := newRepo(t)
	gitRun(t, dir, "config", "filter.a=b.clean", "cat")
	board := []db.BoardNode{node(2, "in_review", "squash", time.Hour), node(22, "in_progress", "nearsquash", time.Hour)}
	r := Check(context.Background(), 1, board, Options{Folder: dir, Now: testNow})
	var guard []string
	for _, n := range r.Notes {
		if strings.Contains(n, "squash-merge checks skipped") {
			guard = append(guard, n)
		}
	}
	if len(guard) != 1 || !strings.Contains(guard[0], "cannot override") {
		t.Fatalf("want one filter-guard note, got notes %v", r.Notes)
	}
	if got := kinds(r); len(got[2]) != 0 {
		t.Fatalf("an unread squash is never a finding, got %v", got)
	}
}

// The Stop hook checks open targets only: its blocking verdict is the full
// check's, without the advisory done_but_unmerged.
func TestCheck_OpenOnlyKeepsTheBlockingVerdict(t *testing.T) {
	dir := newRepo(t)
	board := []db.BoardNode{
		node(1, "done", "open", time.Hour),
		node(2, "in_progress", "merged", time.Hour),
		node(3, "in_review", "nowhere", time.Hour),
		node(4, "done", "squash", time.Hour),
	}
	full := Check(context.Background(), 1, board, Options{Folder: dir, Now: testNow})
	open := Check(context.Background(), 1, board, Options{Folder: dir, Now: testNow, OpenOnly: true})
	if got, want := kinds(Report{Findings: open.BlockingFindings()}), kinds(Report{Findings: full.BlockingFindings()}); fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("open-only blocking %v, full blocking %v", got, want)
	}
	if got := kinds(open); len(got[1]) != 0 || len(got[2]) != 1 || len(got[3]) != 1 {
		t.Fatalf("open-only findings %v", got)
	}
}

// gitRulesBoard is TestProj07_GitRules' board and its findings.
func gitRulesBoard() ([]db.BoardNode, map[int][]string) {
	board := []db.BoardNode{
		node(1, "in_progress", "merged", time.Hour), node(2, "in_review", "squash", time.Hour),
		node(3, "done", "open", time.Hour), node(4, "in_progress", "fresh", time.Hour),
		node(5, "in_progress", "nowhere", time.Hour), node(12, "done", "squash", time.Hour),
		node(13, "in_progress", "rebase", time.Hour), node(15, "in_progress", "ff", time.Hour),
		node(16, "in_progress", "stacked", time.Hour), node(17, "in_progress", "freshold", time.Hour),
		node(18, "in_progress", "rebasedfresh", time.Hour), node(19, "in_progress", "resetback", time.Hour),
		node(20, "in_progress", "rebasedmerged", time.Hour), node(21, "in_progress", "synced", time.Hour),
		node(22, "in_progress", "nearsquash", time.Hour),
		node(23, "done", "merged", time.Hour), node(24, "in_progress", "merged", time.Hour), // a shared branch, read once
	}
	want := map[int][]string{1: {KindMergedOpen}, 2: {KindMergedOpen}, 3: {KindDoneUnmerged}, 5: {KindBranchMissing},
		13: {KindMergedOpen}, 15: {KindMergedOpen}, 20: {KindMergedOpen}, 21: {KindMergedOpen}, 22: {KindMergedOpen},
		24: {KindMergedOpen}}
	return board, want
}

// The batch branch read gives the same findings as reading each branch on
// its own: with %(ahead-behind), without it (git before 2.41, refused like
// an unknown atom), and with no batch read at all.
func TestCheck_BatchReadMatchesPerBranchReads(t *testing.T) {
	dir := newRepo(t)
	board, want := gitRulesBoard()
	cases := map[string]func(args []string) bool{
		"ahead-behind": func([]string) bool { return false },
		"merged lists": func(args []string) bool {
			return args[0] == "for-each-ref" && strings.Contains(strings.Join(args, " "), "ahead-behind")
		},
		"per branch": func(args []string) bool { return args[0] == "for-each-ref" },
	}
	calls := map[string]int{}
	for name, refuse := range cases {
		run := func(ctx context.Context, d string, in []byte, n string, args ...string) ([]byte, int, error) {
			calls[name]++
			if n == "git" && len(args) > 0 && refuse(args) {
				return nil, 128, os.ErrPermission
			}
			return ExecRunner(ctx, d, in, n, args...)
		}
		r := Check(context.Background(), 1, board, Options{Folder: dir, Now: testNow, Run: run})
		if got := kinds(r); fmt.Sprint(got) != fmt.Sprint(want) {
			t.Fatalf("%s: findings %v, want %v", name, got, want)
		}
	}
	// The batch read is used, not silently dropped for per-branch reads.
	for _, name := range []string{"ahead-behind", "merged lists"} {
		if calls[name] >= calls["per branch"] {
			t.Fatalf("%s ran %d git calls, per branch %d: the batch read was not used", name, calls[name], calls["per branch"])
		}
	}
}

// With the batch read answering, a later git call that fails (first-parent
// line, counts, reflog, cherry, the squash reads) still gives no merge
// verdict: only a branch the listing shows missing is a finding.
func TestProj07_GitErrorsAfterTheBatchReadAreNeverFindings(t *testing.T) {
	dir := newRepo(t)
	run := func(ctx context.Context, d string, in []byte, name string, args ...string) ([]byte, int, error) {
		if len(args) > 0 && !slices.Contains([]string{"for-each-ref", "rev-parse", "symbolic-ref"}, args[0]) {
			return nil, 128, os.ErrPermission
		}
		return ExecRunner(ctx, d, in, name, args...)
	}
	board, _ := gitRulesBoard()
	r := Check(context.Background(), 1, board, Options{Folder: dir, Now: testNow, Run: run})
	for _, f := range r.Findings {
		if f.Kind != KindBranchMissing || f.Branch != "nowhere" {
			t.Fatalf("failed git calls after the batch read must yield no verdict, got %+v", f)
		}
	}
}

// A target naming a branch in another case than its loose ref resolves as
// git resolves it, never as missing from the batch listing.
func TestCheck_BranchInAnotherCaseIsLookedUpOnItsOwn(t *testing.T) {
	dir := newRepo(t)
	gitRun(t, dir, "branch", "casey", "main")
	if _, err := os.Stat(filepath.Join(dir, ".git", "refs", "heads", "CASEY")); err != nil {
		t.Skip("case-sensitive file system: git resolves refs by exact case")
	}
	r := Check(context.Background(), 1, []db.BoardNode{node(1, "in_progress", "CASEY", time.Hour)}, Options{Folder: dir, Now: testNow})
	for _, f := range r.Findings {
		if f.Kind == KindBranchMissing {
			t.Fatalf("a loose ref in another case is not missing: %+v", f)
		}
	}
}

// A deadline during the batch read is an incomplete check with no finding.
func TestCheck_BatchReadDeadlineIsIncomplete(t *testing.T) {
	dir := newRepo(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	run := func(c context.Context, d string, in []byte, name string, args ...string) ([]byte, int, error) {
		if len(args) > 0 && args[0] == "for-each-ref" {
			cancel()
			return nil, -1, context.Canceled
		}
		return ExecRunner(c, d, in, name, args...)
	}
	board, _ := gitRulesBoard()
	r := Check(ctx, 1, board, Options{Folder: dir, Now: testNow, Run: run})
	if !r.Incomplete || len(r.Findings) != 0 {
		t.Fatalf("want incomplete with no findings, got incomplete=%v %+v", r.Incomplete, r.Findings)
	}
}

// hubRepo is a second repository on main with a branch "hubonly" holding
// one commit main lacks, and a branch "open" of its own; no other
// repository has "hubonly".
func hubRepo(t *testing.T) string {
	t.Helper()
	gitEnv(t)
	dir := t.TempDir()
	gitRun(t, dir, "init", "-q", "-b", "main")
	commitFile(t, dir, "hub.md", "hub\n", "init")
	gitRun(t, dir, "checkout", "-q", "-b", "hubonly")
	commitFile(t, dir, "h.txt", "h\n", "h")
	gitRun(t, dir, "checkout", "-q", "-b", "open", "main")
	commitFile(t, dir, "o.txt", "o\n", "o")
	gitRun(t, dir, "checkout", "-q", "main")
	return dir
}

// countingRunner is ExecRunner counting the repository probes (rev-parse
// --is-inside-work-tree) per folder; gh is never found.
func countingRunner(probes map[string]int) Runner {
	return func(ctx context.Context, dir string, stdin []byte, name string, args ...string) ([]byte, int, error) {
		if name == "gh" {
			return nil, -1, exec.ErrNotFound
		}
		if slices.Equal(args, []string{"rev-parse", "--is-inside-work-tree"}) {
			probes[dir]++
		}
		return ExecRunner(ctx, dir, stdin, name, args...)
	}
}

// Spec 2026-11-18 §6.10: each target's branch is read in the repository of
// its own folder, and each folder is probed once however many targets it
// holds.
func TestProj07_ChecksRunInTheTargetsFolder(t *testing.T) {
	app, hub := newRepo(t), hubRepo(t)
	board := []db.BoardNode{
		node(1, "in_progress", "merged", time.Hour),  // app: merged into app's main
		node(2, "in_progress", "hubonly", time.Hour), // hub: open work there
		node(3, "in_progress", "hubonly", time.Hour), // app (no folder): app has no hubonly
		node(4, "in_review", "hubonly", time.Hour),   // hub again: no second probe
	}
	folderOf := func(id int64) (string, bool) {
		if id == 2 || id == 4 {
			return hub, false
		}
		return "", false // the home folder
	}
	probes := map[string]int{}
	r := Check(context.Background(), 1, board, Options{Folder: app, FolderOf: folderOf, Now: testNow, Run: countingRunner(probes)})
	got := kinds(r)
	if !slices.Equal(got[1], []string{KindMergedOpen}) {
		t.Errorf("target 1 (app): %v, want merged_but_open", got[1])
	}
	if len(got[2]) != 0 || len(got[4]) != 0 {
		t.Errorf("targets 2 and 4 (hub): %v / %v, want none: hubonly is open work in hub", got[2], got[4])
	}
	if !slices.Equal(got[3], []string{KindBranchMissing}) {
		t.Errorf("target 3 (app): %v, want branch_missing", got[3])
	}
	if probes[app] != 1 || probes[hub] != 1 {
		t.Errorf("probes per folder %v, want one each", probes)
	}
	if !r.Git || r.Base != "main" {
		t.Errorf("the report's repository fields are the home folder's: git %v base %q", r.Git, r.Base)
	}

	// The same branch name in two folders is two pieces of work: open work
	// on hub's "open" does not excuse a done target on app's "open".
	board = []db.BoardNode{node(5, "done", "open", time.Hour), node(6, "in_progress", "open", time.Hour)}
	r = Check(context.Background(), 1, board, Options{Folder: app, Now: testNow, Run: countingRunner(map[string]int{}),
		FolderOf: func(id int64) (string, bool) {
			if id == 6 {
				return hub, false
			}
			return app, false
		}})
	got = kinds(r)
	if !slices.Equal(got[5], []string{KindDoneUnmerged}) {
		t.Errorf("target 5: %v, want done_but_unmerged (hub's open work is not app's)", got[5])
	}
	if len(got[6]) != 0 {
		t.Errorf("target 6: %v, want none: hub's open is open work", got[6])
	}
}

// Spec 2026-11-18 §6.3: a target whose folder left the bench reports
// folder_removed for its branch/PR: never a git verdict, never a command
// run in that folder, and never a finding the Stop hook blocks on.
func TestProj07_RemovedFolderReportsFolderRemoved(t *testing.T) {
	app := newRepo(t)
	gone := filepath.Join(t.TempDir(), "hub")
	pr := node(3, "in_progress", "", time.Hour)
	pr.Target.PR = "#7"
	board := []db.BoardNode{
		node(1, "in_progress", "merged", time.Hour),
		node(2, "in_progress", "nowhere", time.Hour),
		pr,
		node(4, "todo", "", time.Hour), // nothing to check: no finding
	}
	var dirs []string
	probes := map[string]int{}
	counting := countingRunner(probes)
	run := func(ctx context.Context, dir string, stdin []byte, name string, args ...string) ([]byte, int, error) {
		dirs = append(dirs, dir)
		return counting(ctx, dir, stdin, name, args...)
	}
	folderOf := func(id int64) (string, bool) {
		if id == 1 {
			return "", false
		}
		return gone, true
	}
	r := Check(context.Background(), 1, board, Options{Folder: app, FolderOf: folderOf, Now: testNow, Network: true, Run: run})
	got := kinds(r)
	if !slices.Equal(got[1], []string{KindMergedOpen}) {
		t.Errorf("target 1 (home): %v", got[1])
	}
	for _, id := range []int{2, 3} {
		if !slices.Equal(got[id], []string{KindFolderRemoved}) {
			t.Errorf("target %d: %v, want only folder_removed", id, got[id])
		}
	}
	if len(got[4]) != 0 {
		t.Errorf("target 4 carries no branch or PR: %v", got[4])
	}
	lines := map[int]string{}
	for _, f := range r.Findings {
		if f.Kind != KindFolderRemoved {
			continue
		}
		lines[f.TargetID] = f.Line()
		if f.Blocking() {
			t.Errorf("folder_removed must never block a turn: %+v", f)
		}
	}
	if !strings.Contains(lines[2], "folder removed: "+gone) || !strings.Contains(lines[2], "branch nowhere") {
		t.Errorf("line %q", lines[2])
	}
	if !strings.Contains(lines[3], "pull request #7") {
		t.Errorf("the PR-only finding names the PR: %q", lines[3])
	}
	if b := r.BlockingFindings(); len(b) != 1 || b[0].TargetID != 1 {
		t.Errorf("blocking: %+v, want only target 1's", b)
	}
	if slices.Contains(dirs, gone) {
		t.Errorf("a command ran in the removed folder: %v", dirs)
	}
}

// A folder whose branch checks cannot run — gone from disk, no repository —
// is named in Report.Skipped, the home folder too when it is gone; the
// other folders' targets are still checked.
func TestProj07_SkippedFoldersAreReported(t *testing.T) {
	app := newRepo(t)
	plain := t.TempDir() // a folder on the bench that is no repository
	gone := filepath.Join(t.TempDir(), "gone")
	board := []db.BoardNode{
		node(1, "in_progress", "merged", time.Hour),
		node(2, "in_progress", "x", time.Hour),
		node(3, "in_progress", "y", time.Hour),
		node(4, "in_progress", "", time.Hour), // no branch: its folder is never probed
	}
	at := map[int64]string{2: plain, 3: gone, 4: filepath.Join(t.TempDir(), "never")}
	var dirs []string
	run := func(ctx context.Context, dir string, stdin []byte, name string, args ...string) ([]byte, int, error) {
		dirs = append(dirs, dir)
		return ExecRunner(ctx, dir, stdin, name, args...)
	}
	r := Check(context.Background(), 1, board, Options{Folder: app, Now: testNow, Run: run,
		FolderOf: func(id int64) (string, bool) { return at[id], false }})
	if got := kinds(r); !slices.Equal(got[1], []string{KindMergedOpen}) || len(got[2]) != 0 || len(got[3]) != 0 {
		t.Fatalf("findings %v", got)
	}
	want := []FolderSkip{
		{Folder: plain, Reason: "the folder is not a git work tree; branch checks skipped"},
		{Folder: gone, Reason: missingFolderNote},
	}
	if !slices.Equal(r.Skipped, want) {
		t.Errorf("skipped %+v, want %+v", r.Skipped, want)
	}
	if slices.Contains(dirs, gone) {
		t.Errorf("a command ran in the missing folder")
	}

	// The home folder gone: skipped, and another folder's target still gets
	// its verdict.
	at = map[int64]string{1: app}
	board = []db.BoardNode{node(1, "in_progress", "merged", time.Hour), node(2, "in_progress", "z", time.Hour)}
	r = Check(context.Background(), 1, board, Options{Folder: gone, Now: testNow,
		FolderOf: func(id int64) (string, bool) { return at[id], false }})
	if got := kinds(r); !slices.Equal(got[1], []string{KindMergedOpen}) || len(got[2]) != 0 {
		t.Errorf("findings %v", got)
	}
	if !slices.Equal(r.Skipped, []FolderSkip{{Folder: gone, Reason: missingFolderNote}}) || r.Git {
		t.Errorf("home gone: skipped %+v git %v", r.Skipped, r.Git)
	}
	if r.Skipped == nil {
		t.Error("Skipped is never nil (JSON [])")
	}
}

// One gh sign-in probe and one ghBudget serve every folder of a check; a
// folder with no pull request target never runs gh.
func TestCheck_OneGHSessionAcrossFolders(t *testing.T) {
	gitEnv(t)
	home, hub, plain := t.TempDir(), t.TempDir(), t.TempDir()
	start := time.Date(2026, 11, 18, 10, 0, 0, 0, time.UTC)
	now := start
	var auth int
	ghDirs := map[string]int{}
	run := func(_ context.Context, dir string, _ []byte, name string, args ...string) ([]byte, int, error) {
		if name != "gh" {
			return nil, 128, os.ErrNotExist
		}
		ghDirs[dir]++
		if args[0] == "auth" {
			auth++
			return nil, 0, nil
		}
		now = now.Add(ghBudget + time.Second) // the first read spends the whole budget
		return []byte(`{"state":"MERGED"}`), 0, nil
	}
	withPR := func(id int, ref string) db.BoardNode {
		n := node(id, "in_progress", "", time.Hour)
		n.Target.PR = ref
		return n
	}
	board := []db.BoardNode{withPR(1, "#1"), withPR(2, "#2"), node(3, "in_progress", "feature/x", time.Hour)}
	at := map[int64]string{2: hub, 3: plain}
	r := Check(context.Background(), 1, board, Options{Folder: home, Now: testNow, Network: true, Run: run,
		clock: func() time.Time { return now }, FolderOf: func(id int64) (string, bool) { return at[id], false }})
	if auth != 1 {
		t.Errorf("gh auth status ran %d times, want once", auth)
	}
	if ghDirs[plain] != 0 {
		t.Errorf("gh ran in a folder with no pull request target: %v", ghDirs)
	}
	got := kinds(r)
	if !slices.Equal(got[1], []string{KindMergedOpen}) {
		t.Errorf("target 1: %v", got[1])
	}
	if len(got[2]) != 0 || ghDirs[hub] != 0 {
		t.Errorf("target 2 read after the shared budget was spent: %v, gh in hub %d", got[2], ghDirs[hub])
	}
	if r.PRChecked || !strings.Contains(strings.Join(r.Notes, "\n"), hub+": the state of 1 pull request(s) could not be read (the gh time budget was spent)") {
		t.Errorf("pr_checked %v notes %v", r.PRChecked, r.Notes)
	}
}

// A missing home folder never reads as "gh not signed in": the sign-in
// probe runs from a directory that exists, and the other folders' pull
// requests are still read.
func TestCheck_GHProbeRunsFromAnExistingDirectory(t *testing.T) {
	gitEnv(t)
	gone, hub := filepath.Join(t.TempDir(), "gone"), t.TempDir()
	var authDir string
	run := func(_ context.Context, dir string, _ []byte, name string, args ...string) ([]byte, int, error) {
		if name != "gh" {
			return nil, 128, os.ErrNotExist
		}
		if _, err := os.Stat(dir); err != nil {
			return nil, -1, err // exec fails in a missing working directory
		}
		if args[0] == "auth" {
			authDir = dir
			return nil, 0, nil
		}
		return []byte(`{"state":"MERGED"}`), 0, nil
	}
	n := node(1, "in_progress", "", time.Hour)
	n.Target.PR = "#5"
	r := Check(context.Background(), 1, []db.BoardNode{n}, Options{Folder: gone, Now: testNow, Network: true, Run: run,
		FolderOf: func(int64) (string, bool) { return hub, false }})
	if authDir != os.TempDir() {
		t.Errorf("auth probe ran in %q, want %q", authDir, os.TempDir())
	}
	if !r.PRChecked || !slices.Equal(kinds(r)[1], []string{KindMergedOpen}) {
		t.Errorf("pr_checked %v findings %v notes %v", r.PRChecked, r.Findings, r.Notes)
	}
}

// Each gh call's timeout is at most what is left of the shared budget, so
// all the reads together never pass ghBudget.
func TestCheck_GHCallTimeoutCappedByTheSharedBudget(t *testing.T) {
	gitEnv(t)
	home := t.TempDir()
	start := time.Date(2026, 11, 18, 10, 0, 0, 0, time.UTC)
	now := start
	var timeouts []time.Duration
	run := func(ctx context.Context, _ string, _ []byte, name string, args ...string) ([]byte, int, error) {
		if name != "gh" {
			return nil, 128, os.ErrNotExist
		}
		if args[0] == "auth" {
			return nil, 0, nil
		}
		dl, ok := ctx.Deadline()
		if !ok {
			t.Fatal("a gh call without a deadline")
		}
		timeouts = append(timeouts, time.Until(dl))
		now = now.Add(ghBudget - 3*time.Second) // the first read leaves 3 s of the budget
		return []byte(`{"state":"OPEN"}`), 0, nil
	}
	pr := func(id int, ref string) db.BoardNode {
		n := node(id, "in_progress", "", time.Hour)
		n.Target.PR = ref
		return n
	}
	Check(context.Background(), 1, []db.BoardNode{pr(1, "#1"), pr(2, "#2")}, Options{Folder: home, Now: testNow, Network: true,
		Run: run, clock: func() time.Time { return now }})
	if len(timeouts) != 2 {
		t.Fatalf("gh reads %d, want 2", len(timeouts))
	}
	if timeouts[0] <= 3*time.Second || timeouts[0] > ghCallTimeout {
		t.Errorf("first call's timeout %v, want the full %v", timeouts[0], ghCallTimeout)
	}
	if timeouts[1] <= 0 || timeouts[1] > 3*time.Second {
		t.Errorf("second call's timeout %v, want at most the 3 s left of the budget", timeouts[1])
	}
}
