package sessioncleanup

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"
)

// newRepoPassFixture is an autoFixture whose pass also runs the repository
// pass over the test workbench, with no session candidate, at a clock by
// which every worktree the test made is idle.
func newRepoPassFixture(t *testing.T) *autoFixture {
	t.Helper()
	a := newAutoFixture(t)
	a.clock = idleLater()
	a.benches = []int64{testWorkbench}
	return a
}

// claudeWorktree adds a linked worktree under the main checkout's
// .claude/worktrees on a new branch from main, as Claude Code's
// `isolation: worktree` and Watchtower's placement do.
func (f *fixture) claudeWorktree(name, branch string) string {
	f.t.Helper()
	return f.rootedWorktree(".claude/worktrees/"+name, branch)
}

// mergedClaudeWork is claudeWorktree whose branch carries a commit of its
// own, pushed and merged into main (main pushed too).
func (f *fixture) mergedClaudeWork(name, branch string) string {
	f.t.Helper()
	root := f.claudeWorktree(name, branch)
	f.commit(root, name+".txt", "work\n")
	gitIn(f.t, root, "push", "-q", "origin", branch)
	gitIn(f.t, f.repo, "merge", "-q", "--no-ff", "-m", "merge "+branch, branch)
	gitIn(f.t, f.repo, "push", "-q", "origin", "main")
	return root
}

// ageWorktree sets the mtimes of root's admin HEAD, index and logs/HEAD to
// at: its last activity, with no build folder and no ledger sighting.
func ageWorktree(t *testing.T, root string, at time.Time) {
	t.Helper()
	admin := adminOf(t, root)
	for _, name := range []string{"HEAD", "index", filepath.Join("logs", "HEAD")} {
		p := filepath.Join(admin, name)
		if !exists(p) {
			continue
		}
		if err := os.Chtimes(p, at, at); err != nil {
			t.Fatal(err)
		}
	}
}

// dirLog is the real git that records each run as "<dir>: <args>".
type dirLog struct {
	SystemGit
	mu  sync.Mutex
	ops []string
}

func (g *dirLog) RunGit(ctx context.Context, dir, bin string, args ...string) ([]byte, int, error) {
	g.mu.Lock()
	g.ops = append(g.ops, dir+": "+strings.Join(args, " "))
	g.mu.Unlock()
	return g.SystemGit.RunGit(ctx, dir, bin, args...)
}

func (g *dirLog) list() []string {
	g.mu.Lock()
	defer g.mu.Unlock()
	return slices.Clone(g.ops)
}

func (f *fixture) gone(root string) bool {
	f.t.Helper()
	return !exists(root) && !f.listsWorktree(root)
}

// TestProj18_RepositoryPassStaysUnderClaudeWorktrees (#2402 §2): the pass
// reaches only linked worktrees whose root is under the main checkout's
// .claude/worktrees — never one the owner made elsewhere, one beside it
// whose name merely starts the same way, or one under another .claude
// folder — although every one of them could go in the owner's sweep.
func TestProj18_RepositoryPassStaysUnderClaudeWorktrees(t *testing.T) {
	t.Parallel()
	a := newRepoPassFixture(t)
	inside := a.claudeWorktree("agent-1a2b", "worktree-agent-1a2b")
	deeper := a.rootedWorktree(".claude/worktrees/lane/x", "wt/deeper")
	outside := a.worktree("hand-made", "feat/hand")
	sibling := a.rootedWorktree(".claude/worktreesx/y", "wt/sibling")
	other := a.rootedWorktree(".claude/other/z", "wt/other")
	for _, root := range []string{outside, sibling, other} {
		wantItem(t, a.plan(Request{Sweep: true}), "worktree:"+root, ActionRemove, "")
	}

	res, err := a.run(time.Now())
	if err != nil || res.RepoFailed != 0 {
		t.Fatalf("res %+v, err %v", res, err)
	}
	if !a.gone(inside) || !a.gone(deeper) {
		t.Fatal("a worktree under .claude/worktrees stayed")
	}
	for _, root := range []string{outside, sibling, other} {
		if !exists(root) || !a.listsWorktree(root) {
			t.Fatalf("%s went", root)
		}
	}
	if a.branchExists("worktree-agent-1a2b") || !a.branchExists("feat/hand") {
		t.Fatal("the branches went the wrong way")
	}
	if res.RepoChanged != 1 {
		t.Fatalf("res %+v", res)
	}
}

// TestProj18_RepositoryPassSkipsActiveWorktrees (#2402 §2): a worktree a
// session works in — live in the session host, or a row not ended that
// reported from inside within a day — or one active within idleFor is
// skipped: never evaluated, never removed, its build never pruned.
func TestProj18_RepositoryPassSkipsActiveWorktrees(t *testing.T) {
	t.Parallel()
	a := newRepoPassFixture(t)
	live := a.claudeWorktree("live", "wt/live")
	reporting := a.claudeWorktree("reporting", "wt/reporting")
	recent := a.claudeWorktree("recent", "wt/recent")
	writeFile(t, filepath.Join(recent, ".gitignore"), ".build/\n")
	recentBuild := swiftBuild(t, filepath.Join(recent, ".build"))
	now := a.clock()
	ageWorktree(t, recent, now.Add(-time.Hour))
	if err := os.Chtimes(recentBuild, now.Add(-time.Hour), now.Add(-time.Hour)); err != nil {
		t.Fatal(err)
	}
	a.store.activity = []SessionActivity{
		{ID: 21, WorkbenchID: testWorkbench, Title: "live", AgentCwd: live, Finished: true},
		{ID: 22, WorkbenchID: testWorkbench, Title: "reporting", AgentCwd: reporting, ReportedAt: now.Add(-time.Hour)},
	}
	a.live = map[int64]bool{21: true}
	dirs := &dirLog{}
	a.git = dirs

	res, err := a.run(time.Now())
	if err != nil || res.RepoFailed != 0 || res.RepoChanged != 0 {
		t.Fatalf("res %+v, err %v", res, err)
	}
	for _, root := range []string{live, reporting, recent} {
		if !exists(root) || !a.listsWorktree(root) {
			t.Fatalf("%s went", root)
		}
		for _, op := range dirs.list() {
			if strings.Contains(op, "worktree remove") || strings.HasPrefix(op, root+":") {
				t.Fatalf("%s was evaluated or acted on: %s", root, op)
			}
		}
	}
	if !exists(filepath.Join(recentBuild, buildMarker)) {
		t.Fatal("the recent build went")
	}
}

// TestProj18_RepositoryPassRemovesAnUnownedMergedWorktree (#2402 §2): an
// agent-* worktree no subagent record and no session names, merged with a
// commit of its own and idle, goes with its branch — in sweep mode, with
// the sweep's catches.
func TestProj18_RepositoryPassRemovesAnUnownedMergedWorktree(t *testing.T) {
	t.Parallel()
	a := newRepoPassFixture(t)
	root := a.mergedClaudeWork("agent-9f3c", "worktree-agent-9f3c")
	var lines []string
	var mu sync.Mutex
	a.logf = func(format string, args ...any) {
		mu.Lock()
		defer mu.Unlock()
		lines = append(lines, fmt.Sprintf(format, args...))
	}

	res, err := a.run(time.Now())
	if err != nil || res.RepoChanged != 1 || res.RepoFailed != 0 {
		t.Fatalf("res %+v, err %v", res, err)
	}
	if !a.gone(root) || a.branchExists("worktree-agent-9f3c") {
		t.Fatal("the unowned merged worktree or its branch stayed")
	}
	if len(lines) != 1 || !strings.Contains(lines[0], "repository") || !strings.Contains(lines[0], "removed") {
		t.Fatalf("log %q", lines)
	}
	if a.results.body != "" {
		t.Fatal("the repository pass wrote a session's result")
	}
}

// TestProj18_RepositoryPassPrunesAKeptIdleWorktreesBuild (#2402 §2, §4): an
// idle worktree under .claude/worktrees kept for its unpushed work loses
// its build output, and keeps everything else; the owner's own sweep never
// prunes, whatever it asks.
func TestProj18_RepositoryPassPrunesAKeptIdleWorktreesBuild(t *testing.T) {
	t.Parallel()
	a := newRepoPassFixture(t)
	root := a.claudeWorktree("agent-77", "worktree-agent-77")
	a.commit(root, ".gitignore", ".build/\n")
	build := swiftBuild(t, filepath.Join(root, ".build"))

	sweep := a.apply(Request{Sweep: true, PruneBuilds: true}, []string{"worktree:" + root}, nil)
	it := wantResultItem(t, sweep, "worktree:"+root, ActionKeep, ReasonUnpushedCommits, false)
	if len(it.BuildsRemoved) > 0 || !exists(filepath.Join(build, buildMarker)) {
		t.Fatal("the owner's sweep pruned")
	}

	res, err := a.run(time.Now())
	if err != nil || res.RepoChanged != 1 || res.RepoFailed != 0 {
		t.Fatalf("res %+v, err %v", res, err)
	}
	if exists(build) {
		t.Fatal("the build stayed")
	}
	if !a.listsWorktree(root) || !exists(filepath.Join(root, ".gitignore")) || !a.branchExists("worktree-agent-77") {
		t.Fatal("the worktree or its work went")
	}
}

// TestAutoRun_RepositoryPassNeedsLiveRuns (#2402 failure modes): when the
// session host cannot be asked for its live runs the repository is skipped
// for this pass — no lock, nothing evaluated — and the failure is counted
// and logged.
func TestAutoRun_RepositoryPassNeedsLiveRuns(t *testing.T) {
	t.Parallel()
	a := newRepoPassFixture(t)
	root := a.mergedClaudeWork("agent-1", "worktree-agent-1")
	a.liveErr = errors.New("host refused")
	var lines []string
	a.logf = func(format string, args ...any) { lines = append(lines, fmt.Sprintf(format, args...)) }

	res, err := a.run(time.Now())
	if err != nil || res.RepoFailed != 1 || res.RepoChanged != 0 {
		t.Fatalf("res %+v, err %v", res, err)
	}
	if !exists(root) || len(a.locked) != 0 {
		t.Fatal("the repository was evaluated without the live runs")
	}
	if len(lines) != 1 || !strings.Contains(lines[0], "host refused") {
		t.Fatalf("log %q", lines)
	}
}

// TestAutoRun_RepositoryPassWaitsForTheLock (#2402 failure modes): another
// cleanup holding the repository's lock (the owner's Clean Up, a session's)
// makes the pass leave the repository for the next one — no failure — and
// the next pass does the work.
func TestAutoRun_RepositoryPassWaitsForTheLock(t *testing.T) {
	t.Parallel()
	a := newRepoPassFixture(t)
	root := a.mergedClaudeWork("agent-1", "worktree-agent-1")
	a.busy = true
	res, err := a.run(time.Now())
	if err != nil || res.RepoFailed != 0 || res.RepoChanged != 0 || !exists(root) {
		t.Fatalf("busy: res %+v, err %v", res, err)
	}
	a.busy = false
	if res, err := a.run(time.Now()); err != nil || res.RepoChanged != 1 || !a.gone(root) {
		t.Fatalf("free: res %+v, err %v", res, err)
	}
	if want := filepath.Join(a.repo, ".git"); len(a.locked) != 1 || a.locked[0] != want {
		t.Fatalf("locked %v, want %s", a.locked, want)
	}
}

// cancelAfterRemove is the real git that cancels the pass right after the
// first `git worktree remove` finished: the daemon stopping mid-pass.
type cancelAfterRemove struct {
	SystemGit
	cancel context.CancelFunc
	once   sync.Once
}

func (g *cancelAfterRemove) RunGit(ctx context.Context, dir, bin string, args ...string) ([]byte, int, error) {
	out, code, err := g.SystemGit.RunGit(ctx, dir, bin, args...)
	if len(args) >= 2 && args[0] == "worktree" && args[1] == "remove" {
		g.once.Do(g.cancel)
	}
	return out, code, err
}

// TestAutoRun_StoppedMidRepositoryPassReplans (#2402 failure modes): a pass
// stopped part-way (its ctx done) removes nothing more and says why; the
// next pass plans the repository from scratch and does the rest. Nothing
// is left half-done: no lock, no marker.
func TestAutoRun_StoppedMidRepositoryPassReplans(t *testing.T) {
	t.Parallel()
	a := newRepoPassFixture(t)
	first := a.claudeWorktree("agent-1", "worktree-agent-1")
	second := a.claudeWorktree("agent-2", "worktree-agent-2")
	ageWorktree(t, first, time.Now().Add(-2*time.Hour))
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	a.git = &cancelAfterRemove{cancel: cancel}
	a.ctx = ctx

	res, err := a.run(time.Now())
	if !errors.Is(err, context.Canceled) || res.RepoFailed != 0 {
		t.Fatalf("res %+v, err %v", res, err)
	}
	if !a.gone(first) || !exists(second) || !a.listsWorktree(second) {
		t.Fatal("the stopped pass did not stop after its first removal")
	}

	a.git, a.ctx = nil, nil
	if res, err := a.run(time.Now()); err != nil || res.RepoChanged != 1 || !a.gone(second) {
		t.Fatalf("next pass: res %+v, err %v", res, err)
	}
	if a.branchExists("worktree-agent-2") {
		t.Fatal("the next pass left the branch of the worktree it removed")
	}
	if entries, _ := os.ReadDir(filepath.Join(a.repo, ".git", "worktrees")); len(entries) != 0 {
		t.Fatalf("admin dirs left: %v", entries)
	}
}

// TestAutoRun_RepositoryPassBatchCap (#2402 §2): at most sweepBatch
// worktrees are removed per repository per pass, the oldest activity
// first; the rest wait for the next pass.
func TestAutoRun_RepositoryPassBatchCap(t *testing.T) {
	t.Parallel()
	a := newRepoPassFixture(t)
	base := time.Now().Add(-48 * time.Hour)
	var roots []string
	for i := range sweepBatch + 1 {
		root := a.claudeWorktree(fmt.Sprintf("agent-%02d", i), fmt.Sprintf("worktree-agent-%02d", i))
		ageWorktree(t, root, base.Add(time.Duration(i)*time.Minute))
		roots = append(roots, root)
	}
	newest := roots[len(roots)-1]

	res, err := a.run(time.Now())
	if err != nil || res.RepoChanged != 1 || res.RepoFailed != 0 {
		t.Fatalf("res %+v, err %v", res, err)
	}
	for _, root := range roots[:sweepBatch] {
		if !a.gone(root) {
			t.Fatalf("%s stayed", root)
		}
	}
	if !a.listsWorktree(newest) {
		t.Fatal("more than sweepBatch went in one pass")
	}
	if _, err := a.run(time.Now()); err != nil || !a.gone(newest) {
		t.Fatalf("the next pass left %s: %v", newest, err)
	}
}

// TestAutoRun_RepositoryPassKeptWorktreesDoNotStarveTheRest (#2402 §2): old
// worktrees that stay (their work is not saved) do not hold the batch: the
// pass evaluates the candidates sweepBatch at a time, so a newer one that
// may go still goes. Between two batches the repository's lock is let go:
// another cleanup waiting for it (the owner's Clean Up) gets it, and the
// pass leaves the rest to the next one.
func TestAutoRun_RepositoryPassKeptWorktreesDoNotStarveTheRest(t *testing.T) {
	t.Parallel()
	a := newRepoPassFixture(t)
	base := time.Now().Add(-48 * time.Hour)
	for i := range sweepBatch {
		root := a.claudeWorktree(fmt.Sprintf("kept-%02d", i), fmt.Sprintf("wt/kept-%02d", i))
		writeFile(t, filepath.Join(root, "notes.txt"), "unsaved\n")
		ageWorktree(t, root, base.Add(time.Duration(i)*time.Minute))
	}
	newer := a.claudeWorktree("agent-new", "worktree-agent-new")
	ageWorktree(t, newer, base.Add(time.Hour))

	a.busyAfter = 1 // another cleanup takes the lock once the first batch let it go
	res, err := a.run(time.Now())
	if err != nil || res.RepoFailed != 0 || !a.listsWorktree(newer) {
		t.Fatalf("lock taken between batches: res %+v, err %v", res, err)
	}
	a.busyAfter = 0
	res, err = a.run(time.Now())
	if err != nil || res.RepoChanged != 1 || res.RepoFailed != 0 || !a.gone(newer) {
		t.Fatalf("res %+v, err %v", res, err)
	}
}

// TestAutoRun_RepositoryPassHasItsOwnBudget (#2402 §2, step 0): the session
// applies and the repository pass each run under a budget of their own,
// derived from the pass's ctx: a session part that spent all of its budget
// still lets the repository pass run, with its full budget.
func TestAutoRun_RepositoryPassHasItsOwnBudget(t *testing.T) {
	t.Parallel()
	a := newRepoPassFixture(t)
	sess := a.pushedWork("wt", "feat/x")
	a.record(sess, "feat/x")
	a.endSession()
	now := time.Now()
	a.cands = []AutoCandidate{{SessionID: testSession, WorkbenchID: testWorkbench, FinishedAt: now}}
	agent := a.mergedClaudeWork("agent-1", "worktree-agent-1")
	var asked []time.Duration
	a.budget = func(parent context.Context, d time.Duration) (context.Context, context.CancelFunc) {
		asked = append(asked, d)
		if len(asked) == 1 {
			// The session part's budget, already spent: no wall-clock wait.
			return context.WithDeadline(parent, time.Unix(1, 0))
		}
		return context.WithTimeout(parent, d)
	}
	var liveCtxs []context.Context
	a.liveCtx = func(ctx context.Context) { liveCtxs = append(liveCtxs, ctx) }

	res, err := a.run(now)
	if !errors.Is(err, context.DeadlineExceeded) || res.Applied != 0 || res.RepoChanged != 1 {
		t.Fatalf("res %+v, err %v", res, err)
	}
	if !slices.Equal(asked, []time.Duration{sessionApplyBudget, repoPassBudget}) {
		t.Fatalf("budgets %v", asked)
	}
	if !exists(sess) || !a.gone(agent) {
		t.Fatal("the session part ran past its budget, or the repository pass did not run")
	}
	if len(liveCtxs) == 0 {
		t.Fatal("the repository pass never asked for the live runs")
	}
	for _, c := range liveCtxs {
		if _, ok := c.Deadline(); !ok {
			t.Fatal("the repository pass runs without a budget")
		}
	}
}

// TestAutoRun_RepositoryPassSessionStartedMidPassKeepsIt (#2402 writers):
// the session host starting a session in a selected worktree after the
// pass read the live runs is seen by the live runs read again right before
// the removal: the worktree stays.
func TestAutoRun_RepositoryPassSessionStartedMidPassKeepsIt(t *testing.T) {
	t.Parallel()
	a := newRepoPassFixture(t)
	root := a.mergedClaudeWork("agent-1", "worktree-agent-1")
	a.store.activity = []SessionActivity{{ID: 31, WorkbenchID: testWorkbench, Title: "resumed", AgentCwd: root,
		Finished: true}}
	reads := 0
	a.liveFn = func() (map[int64]bool, error) {
		if reads++; reads == 1 {
			return map[int64]bool{}, nil
		}
		return map[int64]bool{31: true}, nil
	}

	res, err := a.run(time.Now())
	if err != nil || res.RepoChanged != 0 {
		t.Fatalf("res %+v, err %v", res, err)
	}
	if !exists(root) || !a.listsWorktree(root) || !a.branchExists("worktree-agent-1") {
		t.Fatal("removed under a session the host started")
	}
	if reads < 2 {
		t.Fatalf("live runs read %d times", reads)
	}
}

// TestAutoRun_RepositoryPassLiveReadFailureMidPassKeeps: the live runs
// unreadable at the re-check right before a removal keep the worktree and
// count as the repository's failure.
func TestAutoRun_RepositoryPassLiveReadFailureMidPassKeeps(t *testing.T) {
	t.Parallel()
	a := newRepoPassFixture(t)
	root := a.mergedClaudeWork("agent-1", "worktree-agent-1")
	reads := 0
	a.liveFn = func() (map[int64]bool, error) {
		if reads++; reads == 1 {
			return map[int64]bool{}, nil
		}
		return nil, errors.New("host gone")
	}
	res, err := a.run(time.Now())
	if err != nil || res.RepoFailed != 1 || res.RepoChanged != 0 {
		t.Fatalf("res %+v, err %v", res, err)
	}
	if !exists(root) || !a.branchExists("worktree-agent-1") {
		t.Fatal("removed without the live runs")
	}
}

// TestAutoRun_RepositoryPassOncePerRepository: two workbenches over one
// repository give one repository pass; a workbench whose folders cannot be
// read is a failure of the pass that leaves the others alone.
func TestAutoRun_RepositoryPassOncePerRepository(t *testing.T) {
	t.Parallel()
	a := newRepoPassFixture(t)
	root := a.mergedClaudeWork("agent-1", "worktree-agent-1")
	a.store.folders[testWorkbench+1] = a.repo
	a.benches = []int64{testWorkbench, testWorkbench + 1}
	res, err := a.run(time.Now())
	if err != nil || res.RepoChanged != 1 || !a.gone(root) || len(a.locked) != 1 {
		t.Fatalf("res %+v, err %v, locked %v", res, err, a.locked)
	}
}

// TestAutoRun_RepositoryPassTakesAnIdleLockedMergedPlanWorktree (#2402 §2,
// §3): a locked plan worktree under .claude/worktrees whose branch is
// merged with a commit of its own and that is idle goes, unlocked right
// before its removal; one whose branch is not merged stays locked and
// loses its build.
func TestAutoRun_RepositoryPassTakesAnIdleLockedMergedPlanWorktree(t *testing.T) {
	t.Parallel()
	a := newRepoPassFixture(t)
	merged := a.mergedClaudeWork("plan-a", "feat/plan-a")
	a.lock(merged)
	open := a.claudeWorktree("plan-b", "feat/plan-b")
	a.commit(open, ".gitignore", ".build/\n")
	build := swiftBuild(t, filepath.Join(open, ".build"))
	a.lock(open)

	res, err := a.run(time.Now())
	if err != nil || res.RepoChanged != 1 || res.RepoFailed != 0 {
		t.Fatalf("res %+v, err %v", res, err)
	}
	if !a.gone(merged) || a.branchExists("feat/plan-a") {
		t.Fatal("the merged idle plan worktree stayed")
	}
	if !a.listsWorktree(open) || exists(build) {
		t.Fatal("the unmerged plan worktree went, or kept its build")
	}
	wantLocked(t, open)
}

// TestAutoRun_RepositoryPassRestoresAnInterruptedUnlockFirst (#2402 §3):
// the pass first turns an unlock an interrupted apply left back into the
// lock, under the repository's lock, before it evaluates anything.
func TestAutoRun_RepositoryPassRestoresAnInterruptedUnlockFirst(t *testing.T) {
	t.Parallel()
	a := newRepoPassFixture(t)
	root := a.claudeWorktree("plan-c", "feat/plan-c")
	a.commit(root, "work.txt", "unpushed\n")
	a.lock(root)
	interruptedUnlock(t, a.fixture, root)

	if _, err := a.run(time.Now()); err != nil {
		t.Fatal(err)
	}
	if !a.listsWorktree(root) {
		t.Fatal("the worktree went")
	}
	wantLocked(t, root)
}

// TestAutoRun_RepositoryPassActiveAgainBeforeTheRemoveKeepsIt (#2402
// writers): an agent or the owner working in a chosen worktree again
// (its HEAD moved) before the final re-check keeps it: idleness, which let
// the pass take it, is read again right before the removal.
func TestAutoRun_RepositoryPassActiveAgainBeforeTheRemoveKeepsIt(t *testing.T) {
	t.Parallel()
	a := newRepoPassFixture(t)
	root := a.mergedClaudeWork("agent-1", "worktree-agent-1")
	admin := adminOf(t, root)
	lists := 0
	a.git = &loggingGit{log: &opLog{}, before: func(args []string) *gitAnswer {
		// Listings: the batch's facts, the first re-check's, the final
		// one's; the worktree is used again right before the final one.
		if slices.Equal(args, []string{"worktree", "list", "--porcelain"}) {
			if lists++; lists == 3 {
				at := a.clock().Add(-time.Minute)
				if err := os.Chtimes(filepath.Join(admin, "HEAD"), at, at); err != nil {
					t.Error(err)
				}
			}
		}
		return nil
	}}

	res, err := a.run(time.Now())
	if err != nil || res.RepoChanged != 0 || res.RepoFailed != 0 {
		t.Fatalf("res %+v, err %v", res, err)
	}
	if lists < 3 || !a.listsWorktree(root) || !a.branchExists("worktree-agent-1") {
		t.Fatalf("removed although active again (%d listings)", lists)
	}
}

// TestAutoRun_RepositoryPassUnreadableFoldersAreFailures: a workbench whose
// folders cannot be read, and a folder whose repository git cannot read,
// are failures of the pass, logged; nothing is evaluated there. A folder
// in no repository is no failure.
func TestAutoRun_RepositoryPassUnreadableFoldersAreFailures(t *testing.T) {
	t.Parallel()
	a := newRepoPassFixture(t)
	root := a.mergedClaudeWork("agent-1", "worktree-agent-1")
	var lines []string
	a.logf = func(format string, args ...any) { lines = append(lines, fmt.Sprintf(format, args...)) }

	a.store.benchErr = errors.New("database is locked")
	if res, err := a.run(time.Now()); err != nil || res.RepoFailed != 1 || !exists(root) {
		t.Fatalf("unreadable folders: res %+v, err %v", res, err)
	}
	a.store.benchErr = nil
	a.git = failGitOn("rev-parse", "--git-common-dir")
	if res, err := a.run(time.Now()); err != nil || res.RepoFailed != 1 || !exists(root) {
		t.Fatalf("unreadable repository: res %+v, err %v", res, err)
	}
	if len(lines) != 2 || !strings.Contains(lines[0], "database is locked") ||
		!strings.Contains(lines[1], "injected failure") {
		t.Fatalf("log %q", lines)
	}
	a.git = nil
	a.store.folders[testWorkbench] = t.TempDir() // in no repository
	if res, err := a.run(time.Now()); err != nil || res.RepoFailed != 0 || len(a.locked) != 0 {
		t.Fatalf("no repository: res %+v, err %v", res, err)
	}
}
