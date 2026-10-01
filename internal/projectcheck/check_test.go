package projectcheck

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"watchtower/internal/db"
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
// a missing branch nor a merge verdict.
func TestProj07_GitErrorsAreNeverFindings(t *testing.T) {
	dir := newRepo(t)
	run := func(ctx context.Context, d string, in []byte, name string, args ...string) ([]byte, int, error) {
		if len(args) > 0 && (args[0] == "rev-list" || args[0] == "cherry") || (len(args) > 3 && strings.Contains(args[3], "nowhere")) {
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
// before it and drops the cut-short one (which would read as missing).
func TestProj07_MidWalkDeadlineKeepsEarlierFindingsOnly(t *testing.T) {
	dir := newRepo(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	run := func(c context.Context, d string, in []byte, name string, args ...string) ([]byte, int, error) {
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
	readOnly := []string{"rev-parse", "symbolic-ref", "log", "rev-list", "merge-base", "diff", "patch-id", "cherry", "reflog"}
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
