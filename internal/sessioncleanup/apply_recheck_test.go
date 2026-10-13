package sessioncleanup

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

// secondOrphanIn is another orphan of root, next to orphanIn's.
func secondOrphanIn(root string) Proc {
	p := orphanIn(root)
	p.PID, p.Exe = 602, filepath.Join(root, ".build", "debug", "other-stub")
	return p
}

// TestApply_NoOrphanIsSignalledUnlessEveryOneIsNamed: an orphan the apply
// does not name, or one whose pid now carries another start time, keeps
// the worktree and no orphan of it is signalled.
func TestApply_NoOrphanIsSignalledUnlessEveryOneIsNamed(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name   string
		only   func(root string) []string
		reused bool
	}{
		{"one not named", func(root string) []string {
			return []string{"worktree:" + root, procKey(orphanIn(root))}
		}, false},
		{"one is another process now", func(string) []string { return nil }, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			f := newFixture(t)
			root := f.pushedWork("wt", "feat/x")
			f.record(root, "feat/x")
			procs := &dyingProcs{list: []Proc{orphanIn(root), secondOrphanIn(root)}, dies: true}
			if tc.reused {
				procs.onScan = func(n int) {
					if n == 2 {
						procs.mu.Lock()
						procs.list[1].Start = "Mon Oct 12 11:00:00 2026"
						procs.mu.Unlock()
					}
				}
			}
			res := f.apply(Request{}, tc.only(root), func(d *Deps) { d.Procs = procs })
			it := wantResultItem(t, res, "worktree:"+root, ActionKeep, ReasonProcessRunning, false)
			if !strings.Contains(it.Detail, "not named") || len(procs.terminated) != 0 || !exists(root) {
				t.Fatalf("detail %q, signalled %v", it.Detail, procs.terminated)
			}
		})
	}
}

// TestApply_OrphanThatExitedOnItsOwnIsNotReportedKept: an orphan gone
// before the re-check is recorded done with its removed worktree, never
// kept, and nothing is signalled.
func TestApply_OrphanThatExitedOnItsOwnIsNotReportedKept(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.pushedWork("wt", "feat/x")
	f.record(root, "feat/x")
	procs := &dyingProcs{list: []Proc{orphanIn(root)}}
	procs.onScan = func(n int) {
		if n == 2 {
			procs.mu.Lock()
			procs.list = nil
			procs.mu.Unlock()
		}
	}
	res := f.apply(Request{}, nil, func(d *Deps) { d.Procs = procs })
	wantResultItem(t, res, "worktree:"+root, ActionRemove, "", true)
	wantResultItem(t, res, procKey(orphanIn(root)), ActionRemove, "", true)
	if len(procs.terminated) != 0 || exists(root) {
		t.Fatalf("signalled %v, or the worktree stays", procs.terminated)
	}
}

// TestApply_DirtyWorktreeWithAnOrphanIsNotSignalled: a worktree that turns
// dirty by its re-check is kept before any orphan of it is signalled.
func TestApply_DirtyWorktreeWithAnOrphanIsNotSignalled(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.pushedWork("wt", "feat/x")
	f.record(root, "feat/x")
	procs := &dyingProcs{list: []Proc{orphanIn(root)}, dies: true}
	procs.onScan = func(n int) {
		if n == 2 {
			writeFile(t, filepath.Join(root, "late.txt"), "x\n")
		}
	}
	res := f.apply(Request{}, nil, func(d *Deps) { d.Procs = procs })
	wantResultItem(t, res, "worktree:"+root, ActionKeep, ReasonUncommittedChanges, false)
	wantResultItem(t, res, procKey(orphanIn(root)), ActionKeep, ReasonWorktreeKept, false)
	if len(procs.terminated) != 0 || !exists(root) {
		t.Fatalf("signalled %v", procs.terminated)
	}
}

// TestApply_GracePollScansProcessesOnly: while an orphan winds down only
// the process scan repeats; the full re-check runs once after it is gone
// and once more right before the removal.
func TestApply_GracePollScansProcessesOnly(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.pushedWork("wt", "feat/x")
	f.record(root, "feat/x")
	procs := &dyingProcs{list: []Proc{orphanIn(root)}}
	procs.onScan = func(n int) {
		if n == 6 { // the fourth poll after the signal
			procs.mu.Lock()
			procs.list = nil
			procs.mu.Unlock()
		}
	}
	log := &opLog{}
	f.git = &loggingGit{log: log}
	res := f.apply(Request{}, []string{"worktree:" + root, procKey(orphanIn(root))},
		func(d *Deps) { d.Procs, d.OrphanGrace = procs, 5*time.Second })
	wantResultItem(t, res, "worktree:"+root, ActionRemove, "", true)
	statuses := 0
	for _, op := range log.list() {
		if strings.HasPrefix(op, "git status") {
			statuses++
		}
	}
	// The evaluation, the first re-check, the one after the orphan left
	// and the one before the removal.
	if statuses != 4 || procs.scans != 8 {
		t.Fatalf("git status ran %d times, %d scans: %v", statuses, procs.scans, log.list())
	}
}

// TestApply_WorktreeDirtiedRightBeforeTheRemoveIsKept: a change after the
// orphans and bundles are handled is caught by the re-check right before
// `git worktree remove` (or by git's refusal), and the bundles unregistered
// for the worktree are registered again and not counted as removed.
func TestApply_WorktreeDirtiedRightBeforeTheRemoveIsKept(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name, reason string
		atGit        bool
	}{
		{"after lsregister", ReasonUncommittedChanges, false},
		{"at git worktree remove", ReasonGitRefused, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			f := newFixture(t)
			root := f.pushedWork("wt", "feat/x")
			f.record(root, "feat/x")
			log := &opLog{}
			dirty := func() { writeFile(t, filepath.Join(root, "late.txt"), "x\n") }
			g := &loggingGit{log: log}
			ls := &fakeLS{log: log}
			if tc.atGit {
				g.before = func(args []string) *gitAnswer {
					if len(args) > 1 && args[0] == "worktree" && args[1] == "remove" {
						dirty()
					}
					return nil
				}
			} else {
				ls.onUnregister = func(string) { dirty() }
			}
			f.git = g
			res := f.apply(Request{}, nil, func(d *Deps) { d.LS = ls })
			wantResultItem(t, res, "worktree:"+root, ActionKeep, tc.reason, false)
			bundle := filepath.Join(root, "Build", "App.app")
			wantResultItem(t, res, "lsreg:"+bundle, ActionKeep, ReasonWorktreeKept, false)
			if !slices.Contains(log.list(), "lsregister "+bundle) || !exists(filepath.Join(root, "late.txt")) {
				t.Fatalf("not registered again, or the change is gone: %v", log.list())
			}
			if tc.atGit == false && slices.Contains(log.list(), "git worktree remove "+root) {
				t.Fatal("git worktree remove ran after the re-check kept the worktree")
			}
			if strings.Contains(res.Summary, "removed") {
				t.Fatalf("summary = %q", res.Summary)
			}
		})
	}
}

// TestApply_BranchCheckedOutRightBeforeTheDeleteIsKept: a worktree that
// checks the branch out after its re-check keeps it; `git worktree list`
// is read again right before the delete.
func TestApply_BranchCheckedOutRightBeforeTheDeleteIsKept(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	gitIn(t, f.repo, "branch", "feat/x", "main")
	f.store.targetBranches = []string{"feat/x"}
	late := filepath.Join(f.base, "wt-late")
	lists := 0
	g := &loggingGit{log: &opLog{}}
	g.before = func(args []string) *gitAnswer {
		if len(args) > 1 && args[0] == "worktree" && args[1] == "list" {
			if lists++; lists == 3 { // after the evaluation's and the re-check's
				gitIn(t, f.repo, "worktree", "add", "-q", late, "feat/x")
			}
		}
		return nil
	}
	f.git = g
	res := f.apply(Request{}, nil, nil)
	it := wantResultItem(t, res, "branch:feat/x", ActionKeep, ReasonCheckedOut, false)
	if it.Detail != late || !f.branchExists("feat/x") {
		t.Fatalf("detail %q, or the branch is gone", it.Detail)
	}
}

// TestApply_PrunableWorktreeGoesThroughWorktreeRemove: a worktree whose
// directory is gone is dropped by `git worktree remove` (never prune) and
// reported removed with 0 bytes.
func TestApply_PrunableWorktreeGoesThroughWorktreeRemove(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.pushedWork("wt", "feat/x")
	f.record(root, "feat/x")
	if err := os.RemoveAll(root); err != nil { // the fixture's own temp worktree
		t.Fatal(err)
	}
	log := &opLog{}
	f.git = &loggingGit{log: log}
	res := f.apply(Request{}, nil, nil)
	it := wantResultItem(t, res, "worktree:"+root, ActionRemove, "", true)
	if it.Bytes != 0 || !it.BytesKnown || res.RemovedBytes != 0 || f.listsWorktree(root) {
		t.Fatalf("prunable result = %+v / %+v", it, res)
	}
	if !slices.Contains(log.list(), "git worktree remove "+root) {
		t.Fatalf("not removed through git worktree remove: %v", log.list())
	}
	wantResultItem(t, res, "branch:feat/x", ActionRemove, "", true)
}
