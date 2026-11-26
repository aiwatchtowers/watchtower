package sessioncleanup

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

// planReason is the lock reason the tests' plan rule writes.
const planReason = "plan running"

// idleLater is a clock idleFor and a day past now: every worktree the
// test made is idle by it.
func idleLater() func() time.Time {
	at := time.Now().Add(idleFor + 24*time.Hour)
	return func() time.Time { return at }
}

// mergedWork is pushedWork whose branch is then merged into main (a merge
// commit) and main pushed: the branch has a commit of its own and its work
// is in the default branch.
func (f *fixture) mergedWork(name, branch string) string {
	f.t.Helper()
	root := f.pushedWork(name, branch)
	gitIn(f.t, f.repo, "merge", "-q", "--no-ff", "-m", "merge "+branch, branch)
	gitIn(f.t, f.repo, "push", "-q", "origin", "main")
	return root
}

// lock locks root as a plan does.
func (f *fixture) lock(root string) {
	f.t.Helper()
	gitIn(f.t, f.repo, "worktree", "lock", "--reason", planReason, root)
}

// adminOf is root's admin dir (<common>/worktrees/<name>).
func adminOf(t *testing.T, root string) string {
	t.Helper()
	return gitIn(t, root, "rev-parse", "--absolute-git-dir")
}

// lockOf reads root's lock: its reason, and whether it is locked at all.
func lockOf(t *testing.T, root string) (string, bool) {
	t.Helper()
	body, err := os.ReadFile(filepath.Join(adminOf(t, root), "locked"))
	if errors.Is(err, os.ErrNotExist) {
		return "", false
	}
	if err != nil {
		t.Fatal(err)
	}
	return string(body), true
}

func wantLocked(t *testing.T, root string) {
	t.Helper()
	// git writes the reason with a newline.
	if reason, ok := lockOf(t, root); !ok || reason != planReason+"\n" {
		t.Fatalf("%s: locked %v with %q, want %q", root, ok, reason, planReason+"\n")
	}
	if exists(filepath.Join(adminOf(t, root), unlockMarker)) {
		t.Fatalf("%s: the unlock marker is still there", root)
	}
}

// interruptedUnlock leaves root as a pass killed between its unlock and its
// remove does: the marker with the old reason, and no lock.
func interruptedUnlock(t *testing.T, f *fixture, root string) {
	t.Helper()
	writeFile(t, filepath.Join(adminOf(t, root), unlockMarker), planReason+"\n")
	gitIn(t, f.repo, "worktree", "unlock", root)
}

// TestProj18_LockedMergedIdleWorktreeGoes (#2402 §3): a locked worktree
// whose branch is merged with a commit of its own and that has been idle
// for idleFor is unlocked right before its removal and goes, its branch
// with it.
func TestProj18_LockedMergedIdleWorktreeGoes(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.mergedWork("wt", "feat/x")
	f.record(root, "feat/x")
	f.lock(root)
	f.clock = idleLater()

	wantItem(t, f.plan(Request{}), "worktree:"+root, ActionRemove, "")
	res := f.apply(Request{}, nil, nil)
	wantResultItem(t, res, "worktree:"+root, ActionRemove, "", true)
	wantResultItem(t, res, "branch:feat/x", ActionRemove, "", true)
	if exists(root) || f.listsWorktree(root) {
		t.Fatal("the worktree stayed")
	}
}

// TestProj18_CommitlessLockedBranchStays: a locked worktree on a branch cut
// from main with no commit of its own is not merged (a freshly cut
// umbrella), however idle; nor is a detached HEAD.
func TestProj18_CommitlessLockedBranchStays(t *testing.T) {
	t.Parallel()
	t.Run("commit-less branch", func(t *testing.T) {
		t.Parallel()
		f := newFixture(t)
		root := f.worktree("wt", "feat/umbrella")
		f.record(root, "feat/umbrella")
		f.lock(root)
		f.clock = idleLater()

		res := f.apply(Request{}, nil, nil)
		wantResultItem(t, res, "worktree:"+root, ActionKeep, ReasonLocked, false)
		wantLocked(t, root)
	})
	t.Run("detached HEAD", func(t *testing.T) {
		t.Parallel()
		f := newFixture(t)
		root := f.mergedWork("wt", "feat/x")
		gitIn(t, root, "switch", "-q", "--detach")
		f.record(root, "")
		f.lock(root)
		f.clock = idleLater()

		res := f.apply(Request{}, nil, nil)
		wantResultItem(t, res, "worktree:"+root, ActionKeep, ReasonLocked, false)
		wantLocked(t, root)
	})
}

// TestProj18_LockedMergedRemoveFailureRelocks: when `git worktree remove`
// fails after the unlock — git's refusal or a failure of git itself — the
// worktree is locked again with its old reason, the marker is gone, and it
// is kept as check_failed.
func TestProj18_LockedMergedRemoveFailureRelocks(t *testing.T) {
	t.Parallel()
	for name, ans := range map[string]*gitAnswer{
		"git refuses": {code: 128, err: &GitError{Args: []string{"worktree", "remove"}, Code: 128,
			Stderr: "fatal: injected refusal"}},
		"git fails": {code: -1, err: errors.New("injected: git could not run")},
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			f := newFixture(t)
			root := f.mergedWork("wt", "feat/x")
			f.record(root, "feat/x")
			f.lock(root)
			f.clock = idleLater()
			f.git = &loggingGit{log: &opLog{}, before: func(args []string) *gitAnswer {
				if slices.Equal(args, []string{"worktree", "remove", root}) {
					return ans
				}
				return nil
			}}

			res := f.apply(Request{}, nil, nil)
			it := wantResultItem(t, res, "worktree:"+root, ActionKeep, ReasonCheckFailed, false)
			if !strings.Contains(it.Detail, "injected") || !strings.Contains(it.Detail, "locked again") {
				t.Fatalf("detail %q", it.Detail)
			}
			if !f.listsWorktree(root) {
				t.Fatal("the worktree went")
			}
			wantLocked(t, root)
		})
	}
}

// TestProj18_UnlockedByAnInterruptedPassIsRelocked: a pass killed between
// its unlock and its remove left the marker; the next apply locks the
// worktree again with the saved reason and deletes the marker before it
// evaluates anything. A worktree that may not go then stays locked; one
// that may goes as usual (re-evaluated). A pass killed between the marker
// and the unlock left the lock in place: the marker alone goes.
func TestProj18_UnlockedByAnInterruptedPassIsRelocked(t *testing.T) {
	t.Parallel()
	t.Run("kept: not merged", func(t *testing.T) {
		t.Parallel()
		f := newFixture(t)
		root := f.pushedWork("wt", "feat/x")
		f.record(root, "feat/x")
		f.lock(root)
		interruptedUnlock(t, f, root)

		res := f.apply(Request{}, nil, nil)
		wantResultItem(t, res, "worktree:"+root, ActionKeep, ReasonLocked, false)
		wantLocked(t, root)
	})
	t.Run("re-evaluated: merged and idle", func(t *testing.T) {
		t.Parallel()
		f := newFixture(t)
		root := f.mergedWork("wt", "feat/x")
		f.record(root, "feat/x")
		f.lock(root)
		interruptedUnlock(t, f, root)
		f.clock = idleLater()

		res := f.apply(Request{}, nil, nil)
		wantResultItem(t, res, "worktree:"+root, ActionRemove, "", true)
	})
	t.Run("killed before the unlock", func(t *testing.T) {
		t.Parallel()
		f := newFixture(t)
		root := f.pushedWork("wt", "feat/x")
		f.record(root, "feat/x")
		f.lock(root)
		writeFile(t, filepath.Join(adminOf(t, root), unlockMarker), "a stale reason")

		f.apply(Request{}, nil, nil)
		wantLocked(t, root)
	})
	t.Run("the plan alone writes nothing", func(t *testing.T) {
		t.Parallel()
		f := newFixture(t)
		root := f.pushedWork("wt", "feat/x")
		f.record(root, "feat/x")
		f.lock(root)
		interruptedUnlock(t, f, root)

		wantItem(t, f.plan(Request{}), "worktree:"+root, ActionKeep, ReasonCheckFailed)
		if _, locked := lockOf(t, root); locked || !exists(filepath.Join(adminOf(t, root), unlockMarker)) {
			t.Fatal("the plan relocked the worktree")
		}
	})
}

// TestProj18_FailedRelockKeepsTheWorktree: a marker whose relock fails stays,
// and its worktree is kept as check_failed even when it is merged and idle;
// the next apply relocks it.
func TestProj18_FailedRelockKeepsTheWorktree(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.mergedWork("wt", "feat/x")
	f.record(root, "feat/x")
	f.lock(root)
	interruptedUnlock(t, f, root)
	f.clock = idleLater()
	f.git = &loggingGit{log: &opLog{}, before: func(args []string) *gitAnswer {
		if len(args) > 1 && args[0] == "worktree" && args[1] == "lock" {
			return &gitAnswer{code: 128, err: &GitError{Args: args, Code: 128, Stderr: "fatal: injected"}}
		}
		return nil
	}}

	res := f.apply(Request{}, nil, nil)
	wantResultItem(t, res, "worktree:"+root, ActionKeep, ReasonCheckFailed, false)
	if !f.listsWorktree(root) || !exists(filepath.Join(adminOf(t, root), unlockMarker)) {
		t.Fatal("the worktree or its marker went")
	}
	if !slices.ContainsFunc(res.Notes, func(n string) bool { return strings.Contains(n, "injected") }) {
		t.Fatalf("notes %v", res.Notes)
	}

	f.git = nil
	f.clock = nil
	f.apply(Request{}, nil, nil)
	wantLocked(t, root)
}

// TestProj18_SweepUnlocksOnlyRightBeforeTheRemove: the Clean Up screen's
// sweep removes a locked, merged, idle worktree; the unlock is the git run
// right before `git worktree remove`, after the final re-check's listing,
// and a plan never unlocks.
func TestProj18_SweepUnlocksOnlyRightBeforeTheRemove(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.mergedWork("wt", "feat/x")
	f.lock(root)
	f.clock = idleLater()
	log := &opLog{}
	f.git = &loggingGit{log: log}

	wantItem(t, f.plan(Request{Sweep: true}), "worktree:"+root, ActionRemove, "")
	if slices.ContainsFunc(log.list(), func(op string) bool { return strings.Contains(op, "worktree unlock") }) {
		t.Fatal("the plan unlocked")
	}
	res := f.apply(Request{Sweep: true}, []string{"worktree:" + root}, nil)
	wantResultItem(t, res, "worktree:"+root, ActionRemove, "", true)
	ops := log.list()
	unlock := slices.Index(ops, "git worktree unlock "+root)
	remove := slices.Index(ops, "git worktree remove "+root)
	if unlock < 0 || remove != unlock+1 {
		t.Fatalf("unlock at %d, remove at %d: %v", unlock, remove, ops)
	}
	lastList := -1
	for i, op := range ops {
		if op == "git worktree list --porcelain" && i < unlock {
			lastList = i
		}
	}
	// The final re-check (its listing, then every catch) runs after the
	// evaluation's and the first re-check's listings, before the unlock.
	if lists := countOps(ops[:unlock], "git worktree list --porcelain"); lists < 3 || lastList < 0 {
		t.Fatalf("%d listings before the unlock: %v", lists, ops)
	}
	if strings.Count(strings.Join(ops, "\n"), "worktree unlock") != 1 {
		t.Fatalf("more than one unlock: %v", ops)
	}
}

func countOps(ops []string, op string) int {
	n := 0
	for _, o := range ops {
		if o == op {
			n++
		}
	}
	return n
}

// TestProj18_SessionStartedBeforeTheRemoveKeepsIt: a session that starts
// working in the worktree after the plan, seen by the final re-check, keeps
// it — locked, with no unlock run and no marker.
func TestProj18_SessionStartedBeforeTheRemoveKeepsIt(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.mergedWork("wt", "feat/x")
	f.record(root, "feat/x")
	f.lock(root)
	f.clock = idleLater()
	log := &opLog{}
	// Listings: the evaluation's, the first re-check's, the final one's;
	// the session starts right before the final one.
	lists := 0
	f.git = &loggingGit{log: log, before: func(args []string) *gitAnswer {
		if slices.Equal(args, []string{"worktree", "list", "--porcelain"}) {
			if lists++; lists == 3 {
				f.store.activity = append(f.store.activity, SessionActivity{ID: 99, WorkbenchID: testWorkbench,
					Title: "other", AgentCwd: root, ReportedAt: f.clock()})
			}
		}
		return nil
	}}
	res := f.apply(Request{}, nil, nil)
	wantResultItem(t, res, "worktree:"+root, ActionKeep, ReasonSessionInIt, false)
	wantLocked(t, root)
	if slices.ContainsFunc(log.list(), func(op string) bool { return strings.Contains(op, "unlock") }) {
		t.Fatal("unlocked")
	}
}

// TestLocked_ActiveMergedWorktreeStays: merged but not idle keeps the lock.
func TestLocked_ActiveMergedWorktreeStays(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.mergedWork("wt", "feat/x")
	f.record(root, "feat/x")
	f.lock(root)

	res := f.apply(Request{}, nil, nil)
	wantResultItem(t, res, "worktree:"+root, ActionKeep, ReasonLocked, false)
	wantLocked(t, root)
}

// TestLocked_UnlockFailureKeepsTheLock: an unlock git refuses leaves the
// worktree locked with its reason and no marker (check_failed).
func TestLocked_UnlockFailureKeepsTheLock(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.mergedWork("wt", "feat/x")
	f.record(root, "feat/x")
	f.lock(root)
	f.clock = idleLater()
	f.git = &loggingGit{log: &opLog{}, before: func(args []string) *gitAnswer {
		if slices.Equal(args, []string{"worktree", "unlock", root}) {
			return &gitAnswer{code: 128, err: &GitError{Args: args, Code: 128, Stderr: "fatal: injected"}}
		}
		return nil
	}}

	res := f.apply(Request{}, nil, nil)
	wantResultItem(t, res, "worktree:"+root, ActionKeep, ReasonCheckFailed, false)
	wantLocked(t, root)
}

// TestLocked_MergeCheckFailureKeepsTheLock: a merge check git cannot
// answer is "not merged": the lock stays (fail closed).
func TestLocked_MergeCheckFailureKeepsTheLock(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.mergedWork("wt", "feat/x")
	f.record(root, "feat/x")
	f.lock(root)
	f.clock = idleLater()
	f.git = failGitOn("reflog")

	res := f.apply(Request{}, nil, nil)
	wantResultItem(t, res, "worktree:"+root, ActionKeep, ReasonLocked, false)
	wantLocked(t, root)
}

// TestRestoreLocks_ListsNothingWithoutWorktrees: a repository with no
// linked worktree has nothing to restore.
func TestRestoreLocks_ListsNothingWithoutWorktrees(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	if notes := restoreLocks(context.Background(), gitCmd{run: SystemGit{}, bin: gitBinOrSkip(t)}, f.repo,
		filepath.Join(f.repo, ".git")); len(notes) != 0 {
		t.Fatalf("notes %v", notes)
	}
}

func gitBinOrSkip(t *testing.T) string {
	t.Helper()
	bin, ok := SystemGit{}.GitBinary()
	if !ok {
		t.Skip("git is not available")
	}
	return bin
}

// TestLocked_AgentLockAfterTheFinalCheckWins: a worktree the final re-check
// listed unlocked is never unlocked by the apply, even when an agent locks
// it right after (here during the final re-check's status, after W3): git
// refuses the remove and the agent's lock stays.
func TestLocked_AgentLockAfterTheFinalCheckWins(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.mergedWork("wt", "feat/x")
	f.record(root, "feat/x")
	f.clock = idleLater()
	log := &opLog{}
	statuses := 0
	f.git = &loggingGit{log: log, before: func(args []string) *gitAnswer {
		if len(args) > 2 && args[0] == "status" && args[2] == "--untracked-files=normal" {
			// W4's status: the evaluation's, the first re-check's, the final one's.
			if statuses++; statuses == 3 {
				f.lock(root)
			}
		}
		return nil
	}}

	res := f.apply(Request{}, nil, nil)
	wantResultItem(t, res, "worktree:"+root, ActionKeep, ReasonGitRefused, false)
	wantLocked(t, root)
	if slices.ContainsFunc(log.list(), func(op string) bool { return strings.Contains(op, "worktree unlock") }) {
		t.Fatal("the apply unlocked the agent's lock")
	}
}

// TestLocked_SquashMergedBranchGoes (fix round 1, F1): a branch of several
// commits squash-merged into main is merged — the drift check's squash
// detection pipes the branch diff into `git patch-id`, so stdin must reach
// git — and its idle locked worktree goes.
func TestLocked_SquashMergedBranchGoes(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.worktree("wt", "feat/x")
	f.commit(root, "a.txt", "a\n")
	f.commit(root, "b.txt", "b\n")
	gitIn(t, root, "push", "-q", "origin", "feat/x")
	gitIn(t, f.repo, "merge", "-q", "--squash", "feat/x")
	gitIn(t, f.repo, "commit", "-q", "-m", "feat/x squashed")
	gitIn(t, f.repo, "push", "-q", "origin", "main")
	f.record(root, "feat/x")
	f.lock(root)
	f.clock = idleLater()

	res := f.apply(Request{}, nil, nil)
	wantResultItem(t, res, "worktree:"+root, ActionRemove, "", true)
}

// statusHook runs at at-th W4 status (the evaluation's, the first
// re-check's, the final re-check's for one worktree), after W3.
func statusHook(at int, hook func()) func(args []string) *gitAnswer {
	n := 0
	return func(args []string) *gitAnswer {
		if len(args) > 2 && args[0] == "status" && args[2] == "--untracked-files=normal" {
			if n++; n == at {
				hook()
			}
		}
		return nil
	}
}

// TestLocked_LockReplacedAfterW3IsKept (fix round 1, F5): an agent drops
// the lock W3 judged and takes a new one while the final re-check's later
// catches run: the apply does not unlock the new lock, and the worktree
// stays with it.
func TestLocked_LockReplacedAfterW3IsKept(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.mergedWork("wt", "feat/x")
	f.record(root, "feat/x")
	f.lock(root)
	f.clock = idleLater()
	log := &opLog{}
	f.git = &loggingGit{log: log, before: statusHook(3, func() {
		gitIn(t, f.repo, "worktree", "unlock", root)
		gitIn(t, f.repo, "worktree", "lock", "--reason", "agent B", root)
	})}

	res := f.apply(Request{}, nil, nil)
	wantResultItem(t, res, "worktree:"+root, ActionKeep, ReasonLocked, false)
	if reason, ok := lockOf(t, root); !ok || reason != "agent B\n" {
		t.Fatalf("lock %v %q", ok, reason)
	}
	if exists(filepath.Join(adminOf(t, root), unlockMarker)) ||
		slices.Contains(log.list(), "git worktree unlock "+root) {
		t.Fatal("the apply unlocked the new lock")
	}
}

// failingScan fails every process scan: the evaluation cannot load its
// facts.
type failingScan struct{}

func (failingScan) Scan(context.Context) ([]Proc, error) {
	return nil, errors.New("injected scan failure")
}
func (failingScan) Terminate(Proc) error { return nil }

// TestLocked_RestoreRunsBeforeTheFactsLoad (fix round 1, F6): an apply
// whose evaluation cannot load its facts still turns an interrupted
// pass's marker back into the lock first.
func TestLocked_RestoreRunsBeforeTheFactsLoad(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.pushedWork("wt", "feat/x")
	f.record(root, "feat/x")
	f.lock(root)
	interruptedUnlock(t, f, root)
	d := f.deps()
	d.Procs = failingScan{}
	if _, err := Apply(context.Background(), d, Request{SessionID: testSession}, nil); err == nil {
		t.Fatal("the apply loaded its facts")
	}
	wantLocked(t, root)
}

// TestLocked_UnlockStepFailureStopsTheApply (fix round 1, F7): a failure
// of the unlock step that is not git's own refusal — the marker cannot be
// written, git cannot run — keeps the worktree locked as check_failed and
// stops the apply (its branch is not attempted).
func TestLocked_UnlockStepFailureStopsTheApply(t *testing.T) {
	t.Parallel()
	for name, setup := range map[string]func(f *fixture, root string){
		"the marker cannot be written": func(f *fixture, root string) {
			f.git = &loggingGit{log: &opLog{}, before: statusHook(3, func() {
				if err := os.Mkdir(filepath.Join(adminOf(t, root), unlockMarker), 0o755); err != nil {
					t.Error(err)
				}
			})}
		},
		"git cannot run": func(f *fixture, root string) {
			f.git = &loggingGit{log: &opLog{}, before: func(args []string) *gitAnswer {
				if slices.Equal(args, []string{"worktree", "unlock", root}) {
					return &gitAnswer{code: -1, err: errors.New("injected: git could not start")}
				}
				return nil
			}}
		},
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			f := newFixture(t)
			root := f.mergedWork("wt", "feat/x")
			f.record(root, "feat/x")
			f.lock(root)
			f.clock = idleLater()
			setup(f, root)

			res := f.apply(Request{}, nil, nil)
			wantResultItem(t, res, "worktree:"+root, ActionKeep, ReasonCheckFailed, false)
			wantResultItem(t, res, "branch:feat/x", ActionKeep, ReasonNotAttempted, false)
			if reason, ok := lockOf(t, root); !ok || reason != planReason+"\n" {
				t.Fatalf("lock %v %q", ok, reason)
			}
		})
	}
}
