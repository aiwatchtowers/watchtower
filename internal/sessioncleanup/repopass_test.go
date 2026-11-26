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
	"sync/atomic"
	"testing"
	"time"

	"watchtower/internal/gitbin"
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
	// The restore's short hold, then the batch (residual R2): both the
	// repository's own lock.
	if want := filepath.Join(a.repo, ".git"); !slices.Equal(a.locked, []string{want, want}) {
		t.Fatalf("locked %v, want %s twice", a.locked, want)
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
	// The removal before the stop counts (fix round 1 C9).
	if !errors.Is(err, context.Canceled) || res.RepoFailed != 0 || res.RepoChanged != 1 {
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
	// One pass: the restore's short hold, then one batch (residual R2).
	want := []string{filepath.Join(a.repo, ".git"), filepath.Join(a.repo, ".git")}
	if err != nil || res.RepoChanged != 1 || !a.gone(root) || !slices.Equal(a.locked, want) {
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
		// Listings: the unlocked measure's facts, the batch's, the first
		// re-check's, the final one's; the worktree is used again right
		// before the final one.
		if slices.Equal(args, []string{"worktree", "list", "--porcelain"}) {
			if lists++; lists == 4 {
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
	if lists < 4 || !a.listsWorktree(root) || !a.branchExists("worktree-agent-1") {
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

// plantHook installs an executable reference-transaction hook in the
// repository that appends to the returned file whenever it runs.
func (f *fixture) plantHook() string {
	f.t.Helper()
	marker := filepath.Join(f.base, "hook-ran")
	hook := filepath.Join(f.repo, ".git", "hooks", "reference-transaction")
	writeFile(f.t, hook, "#!/bin/sh\necho ran >> '"+marker+"'\n")
	if err := os.Chmod(hook, 0o755); err != nil {
		f.t.Fatal(err)
	}
	return marker
}

// TestProj18_RepositoryPassRunsNoRepositoryHook (#2402, fix round 1 C1):
// the repository pass writes on its own, over trees no session of the
// owner's owns, so its writes (the branch's compare-and-delete among them)
// run no hook of the repository; the owner's own Clean Up still does.
func TestProj18_RepositoryPassRunsNoRepositoryHook(t *testing.T) {
	t.Parallel()
	a := newRepoPassFixture(t)
	root := a.mergedClaudeWork("agent-1", "worktree-agent-1")
	marker := a.plantHook()

	res, err := a.run(time.Now())
	if err != nil || res.RepoChanged != 1 || !a.gone(root) || a.branchExists("worktree-agent-1") {
		t.Fatalf("res %+v, err %v", res, err)
	}
	if exists(marker) {
		t.Fatal("the repository pass ran the repository's hook")
	}

	// Control: the hook is live; the owner's sweep runs it.
	other := a.mergedClaudeWork("agent-2", "worktree-agent-2")
	if err := os.Remove(marker); err != nil { // the set-up's own commits ran it
		t.Fatal(err)
	}
	a.apply(Request{Sweep: true}, []string{"worktree:" + other, "branch:worktree-agent-2"}, nil)
	if !exists(marker) {
		t.Fatal("the control did not run the hook")
	}
}

// TestProj18_RepositoryPassKeepsATreeASessionOfAnyWorkbenchSawLately
// (#2402, fix round 1 C2): a session of another workbench — or of a folder
// that left its bench — that recorded the tree 4 days ago and has not
// finished still owns it by the sweep's W2 (recentOwnerWindow), although
// the tree is idle for the pass: it stays.
func TestProj18_RepositoryPassKeepsATreeASessionOfAnyWorkbenchSawLately(t *testing.T) {
	t.Parallel()
	a := newRepoPassFixture(t)
	root := a.mergedClaudeWork("agent-1", "worktree-agent-1")
	a.store.ledgerOwners = map[string][]int64{root: {41}}
	a.store.activity = []SessionActivity{{ID: 41, WorkbenchID: 99, Title: "elsewhere",
		LastActive: a.clock().Add(-4 * 24 * time.Hour)}}

	res, err := a.run(time.Now())
	if err != nil || res.RepoChanged != 0 {
		t.Fatalf("res %+v, err %v", res, err)
	}
	if !a.listsWorktree(root) || !a.branchExists("worktree-agent-1") {
		t.Fatal("a tree a recent session of another workbench saw went")
	}
}

// TestAutoRun_RepositoryPassSessionLiveDuringTheIdleWalkKeepsIt (#2402, fix
// round 1 C3): a terminal the host starts in the chosen worktree while the
// final re-check walks it for idleness — after that re-check read the live
// runs — is seen by the live runs read again right before the removal: the
// worktree stays.
func TestAutoRun_RepositoryPassSessionLiveDuringTheIdleWalkKeepsIt(t *testing.T) {
	t.Parallel()
	a := newRepoPassFixture(t)
	root := a.mergedClaudeWork("agent-1", "worktree-agent-1")
	a.store.activity = []SessionActivity{{ID: 31, WorkbenchID: testWorkbench, Title: "started", AgentCwd: root,
		Finished: true}}
	var mu sync.Mutex
	live, walks := false, 0
	a.store.onLastSeen = func(string) {
		mu.Lock()
		defer mu.Unlock()
		// Walks: the candidates' measure, then the final re-check's.
		if walks++; walks == 2 {
			live = true
		}
	}
	a.liveFn = func() (map[int64]bool, error) {
		mu.Lock()
		defer mu.Unlock()
		return map[int64]bool{31: live}, nil
	}

	res, err := a.run(time.Now())
	if err != nil || res.RepoChanged != 0 {
		t.Fatalf("res %+v, err %v", res, err)
	}
	if walks < 2 || !a.listsWorktree(root) || !a.branchExists("worktree-agent-1") {
		t.Fatalf("removed under a session started during the idle walk (%d walks)", walks)
	}
}

// TestAutoRun_RepositoryPassSessionLiveBeforeABuildDeleteKeepsIt (#2402, fix
// round 1 C3): a terminal started in a kept worktree right before its build
// folder is deleted — after the prune's re-check — keeps the build.
func TestAutoRun_RepositoryPassSessionLiveBeforeABuildDeleteKeepsIt(t *testing.T) {
	t.Parallel()
	a := newRepoPassFixture(t)
	root := a.claudeWorktree("agent-77", "worktree-agent-77")
	a.commit(root, ".gitignore", ".build/\n")
	build := swiftBuild(t, filepath.Join(root, ".build"))
	a.store.activity = []SessionActivity{{ID: 31, WorkbenchID: testWorkbench, Title: "started", AgentCwd: root,
		Finished: true}}
	live := false
	a.liveFn = func() (map[int64]bool, error) { return map[int64]bool{31: live}, nil }
	a.git = &loggingGit{log: &opLog{}, before: func(args []string) *gitAnswer {
		if lsFilesOfABuild(args) {
			live = true // the prune's ls-files of the folder, after its re-check
		}
		return nil
	}}

	if _, err := a.run(time.Now()); err != nil {
		t.Fatal(err)
	}
	if !exists(filepath.Join(build, buildMarker)) {
		t.Fatal("the build went under a session started right before its delete")
	}
}

// movedRepository is the real git whose `rev-parse --git-common-dir` names
// another repository once it ran after times: the folder re-pointed right
// after the pass's discovery (after = 1) or its unlocked measure (2) read
// it.
type movedRepository struct {
	SystemGit
	reads atomic.Int32
	after int32
	to    string
}

func (g *movedRepository) RunGit(ctx context.Context, dir, bin string, args ...string) ([]byte, int, error) {
	if slices.Equal(args, []string{"rev-parse", "--git-common-dir"}) && g.reads.Add(1) > g.after {
		return []byte(g.to + "\n"), 0, nil
	}
	return g.SystemGit.RunGit(ctx, dir, bin, args...)
}

// TestAutoRun_RepositoryPassSkipsARepositoryItsFolderLeft (#2402, fix round
// 1 C4): the pass locks the repository it found, and a folder that
// resolves to another repository once that lock is held makes it skip the
// repository this pass — nothing evaluated under a lock that is not the
// repository's. A folder that left before the batch's lock (seen by the
// unlocked measure, final review F2) skips it after the restore's short
// hold alone (residual R2), which names the repository found.
func TestAutoRun_RepositoryPassSkipsARepositoryItsFolderLeft(t *testing.T) {
	t.Parallel()
	for _, after := range []int32{1, 2} {
		a := newRepoPassFixture(t)
		root := a.mergedClaudeWork("agent-1", "worktree-agent-1")
		g := &movedRepository{after: after, to: filepath.Join(a.otherRepo("elsewhere"), ".git")}
		a.git = g

		res, err := a.run(time.Now())
		if err != nil || res.RepoChanged != 0 {
			t.Fatalf("after %d: res %+v, err %v", after, res, err)
		}
		if !a.listsWorktree(root) || !a.branchExists("worktree-agent-1") {
			t.Fatalf("after %d: acted on a repository whose folder left it", after)
		}
		found := filepath.Join(a.repo, ".git")
		want := []string{found, found}
		if after == 1 {
			want = []string{found}
		}
		if !slices.Equal(a.locked, want) {
			t.Fatalf("after %d: locked %v, want %v", after, a.locked, want)
		}
	}
}

// TestAutoRun_RepositoryPassUnregistersTheRemovedWorktreesBundles (#2402,
// fix round 1 C5): the LaunchServices entries of an app bundle inside a
// worktree the pass removes go with it, as a Clean Up row's do — never
// left not_selected and registered to a deleted path.
func TestAutoRun_RepositoryPassUnregistersTheRemovedWorktreesBundles(t *testing.T) {
	t.Parallel()
	a := newRepoPassFixture(t)
	root := a.mergedClaudeWork("agent-1", "worktree-agent-1")
	log := &opLog{}
	a.ls = &fakeLS{log: log}

	if res, err := a.run(time.Now()); err != nil || res.RepoChanged != 1 || !a.gone(root) {
		t.Fatalf("res %+v, err %v", res, err)
	}
	if want := "lsregister -u " + filepath.Join(root, "Build", "App.app"); !slices.Contains(log.list(), want) {
		t.Fatalf("ops %v, want %q", log.list(), want)
	}
}

// TestAutoRun_RepositoryPassRemovesTheOldestFirst (#2402, fix round 1 C6):
// within a batch the removals run oldest activity first, whatever git's
// listing order: a pass stopped after its first removal has taken the
// oldest one.
func TestAutoRun_RepositoryPassRemovesTheOldestFirst(t *testing.T) {
	t.Parallel()
	a := newRepoPassFixture(t)
	newer := a.claudeWorktree("agent-a", "worktree-agent-a") // listed first
	older := a.claudeWorktree("agent-b", "worktree-agent-b")
	ageWorktree(t, newer, time.Now().Add(-time.Hour))
	ageWorktree(t, older, time.Now().Add(-48*time.Hour))
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	a.git = &cancelAfterRemove{cancel: cancel}
	a.ctx = ctx

	if _, err := a.run(time.Now()); !errors.Is(err, context.Canceled) {
		t.Fatalf("err %v", err)
	}
	if !a.gone(older) || !a.listsWorktree(newer) {
		t.Fatal("the pass did not remove the oldest first")
	}
}

// TestAutoRun_RepositoryPassNeverTouchesAGoneTree (#2402, fix round 2
// R2-1, round 3 R3-6): a worktree whose directory is gone after a cut off
// `git worktree remove` — git lists it prunable — is never a candidate of
// the unattended pass: its admin entry and branch stay for the owner's
// Clean Up.
func TestAutoRun_RepositoryPassNeverTouchesAGoneTree(t *testing.T) {
	t.Parallel()
	a := newRepoPassFixture(t)
	gone := a.mergedClaudeWork("agent-gone", "worktree-agent-gone")
	if err := os.RemoveAll(gone); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(gitIn(t, a.repo, "worktree", "list", "--porcelain"), "prunable") {
		t.Fatal("the fixture is not prunable")
	}
	wantPrunableUntouched(t, a, "agent-gone")
}

// TestAutoRun_RepositoryPassNeverTouchesAnUnreadableTree (R2-1, R3-6): a
// worktree whose directory is there but cannot be read (a volume not
// mounted reads the same) is prunable to git, and never touched either.
func TestAutoRun_RepositoryPassNeverTouchesAnUnreadableTree(t *testing.T) {
	t.Parallel()
	a := newRepoPassFixture(t)
	hidden := a.mergedClaudeWork("agent-hidden", "worktree-agent-hidden")
	if err := os.Chmod(hidden, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(hidden, 0o755) })
	if listing := gitIn(t, a.repo, "worktree", "list", "--porcelain"); !strings.Contains(listing, "prunable") {
		t.Skipf("git does not list an unreadable tree as prunable here (running as root?): %s", listing)
	}
	wantPrunableUntouched(t, a, "agent-hidden")
}

func wantPrunableUntouched(t *testing.T, a *autoFixture, name string) {
	t.Helper()
	res, err := a.run(time.Now())
	if err != nil || res.RepoChanged != 0 {
		t.Fatalf("res %+v, err %v", res, err)
	}
	if !exists(filepath.Join(a.repo, ".git", "worktrees", name)) || !a.branchExists("worktree-"+name) {
		t.Fatalf("%s: its admin entry or branch went", name)
	}
}

// TestAutoRun_RepositoryPassCountsKeptFailures (#2402, fix round 1 C8): a
// worktree git refused to remove, or one a check could not be made for,
// is a failure of the repository's pass, logged.
func TestAutoRun_RepositoryPassCountsKeptFailures(t *testing.T) {
	t.Parallel()
	a := newRepoPassFixture(t)
	root := a.mergedClaudeWork("agent-1", "worktree-agent-1")
	var lines []string
	a.logf = func(format string, args ...any) { lines = append(lines, fmt.Sprintf(format, args...)) }

	a.git = failGitOn("worktree", "remove")
	res, err := a.run(time.Now())
	if err != nil || res.RepoFailed != 1 || res.RepoChanged != 0 || !a.listsWorktree(root) {
		t.Fatalf("refused: res %+v, err %v", res, err)
	}
	if len(lines) != 1 || !strings.Contains(lines[0], ReasonGitRefused) {
		t.Fatalf("log %q", lines)
	}

	lines = nil
	a.git = failGitOn("status")
	res, err = a.run(time.Now())
	if err != nil || res.RepoFailed != 1 || !a.listsWorktree(root) {
		t.Fatalf("check failed: res %+v, err %v", res, err)
	}
	if len(lines) != 1 || !strings.Contains(lines[0], ReasonCheckFailed) {
		t.Fatalf("log %q", lines)
	}
}

// TestAutoRun_RepositoryPassStartedPastItsBudgetDoesNothing (fix round 1):
// a repository pass whose ctx is done before it starts reads nothing and
// counts no failure: it only says it stopped.
func TestAutoRun_RepositoryPassStartedPastItsBudgetDoesNothing(t *testing.T) {
	t.Parallel()
	a := newRepoPassFixture(t)
	root := a.mergedClaudeWork("agent-1", "worktree-agent-1")
	a.store.benchErr = errors.New("must not be read")
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	a.ctx = ctx
	res, err := a.run(time.Now())
	if !errors.Is(err, context.Canceled) || res.RepoFailed != 0 || !exists(root) {
		t.Fatalf("res %+v, err %v", res, err)
	}
}

// TestLoadOwners_EachSessionOnce (fix round 1): two spellings of one root
// name each owner once.
func TestLoadOwners_EachSessionOnce(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.claudeWorktree("agent-1", "worktree-agent-1")
	f.store.ledgerOwners = map[string][]int64{root: {5, 6}, root + "/": {5}}
	b := &builder{deps: f.deps(), req: Request{Sweep: true, allOwners: true}}
	if err := b.loadOwners(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got := b.rootOwners[root]; !slices.Equal(got, []int64{5, 6}) && !slices.Equal(got, []int64{6, 5}) {
		t.Fatalf("owners %v", got)
	}
}

// TestGitArgv_RepositoryPassWritesNameTheLockedRepository (#2402, fix round
// 2 R2-3): under the repository pass's mark every write — the removal, its
// unlock and relock, the ref delete, the config section's — names the
// common dir whose lock is held, after the hooks-off guard; a read of a
// worktree's content does not, and without the mark a write is the
// owner's as before.
func TestGitArgv_RepositoryPassWritesNameTheLockedRepository(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	wt := f.claudeWorktree("agent-1", "worktree-agent-1")
	bin, _ := gitbin.Locate()
	common := filepath.Join(f.repo, ".git")
	ctx := withBackgroundWrites(context.Background(), common)
	for _, args := range [][]string{
		{"worktree", "remove", wt}, {"worktree", "unlock", wt}, {"update-ref", "-d", "refs/heads/x", "abc"},
		{"config", "--remove-section", "branch.x"}, {"--git-dir=" + common, "worktree", "lock", "--reason", "r", wt},
	} {
		argv, err := gitArgv(ctx, f.repo, bin, args)
		if err != nil {
			t.Fatal(err)
		}
		joined := strings.Join(argv, " ")
		if strings.Count(joined, "--git-dir=") != 1 || !strings.Contains(joined, "--git-dir="+common+" ") ||
			!strings.Contains(joined, "core.hooksPath=/dev/null") {
			t.Errorf("%v: argv %q", args, joined)
		}
	}
	read, err := gitArgv(ctx, wt, bin, []string{"status", "--porcelain"})
	if err != nil || strings.Contains(strings.Join(read, " "), "--git-dir") {
		t.Fatalf("read argv %q, %v", read, err)
	}
	owner, err := gitArgv(context.Background(), f.repo, bin, []string{"update-ref", "-d", "refs/heads/x", "abc"})
	if err != nil || strings.Contains(strings.Join(owner, " "), "--git-dir") || strings.Contains(strings.Join(owner, " "), "hooksPath") {
		t.Fatalf("owner argv %q, %v", owner, err)
	}
}

// TestLiveClear_EveryWayALiveSessionHoldsTheTree (#2402, fix round 2 R2-4,
// R2-5, M1): right before a destructive step, a live session holds the
// tree when its working directory is inside — as stored or resolved —,
// when it recorded the tree in its ledger (the sweep's W2 owners), when
// its row is gone, or when it has not said where it works, whatever its
// workbench (R3-2). A live session that says it works elsewhere does not.
func TestLiveClear_EveryWayALiveSessionHoldsTheTree(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.claudeWorktree("agent-1", "worktree-agent-1")
	link := filepath.Join(f.base, "link")
	if err := os.Symlink(f.repo, link); err != nil {
		t.Fatal(err)
	}
	inside := filepath.Join(root, "sub")
	outside := filepath.Join(f.base, "outside")
	if err := os.MkdirAll(outside, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(root, "out")); err != nil {
		t.Fatal(err)
	}
	f.store.ledgerOwners = map[string][]int64{root + "/": {42}}
	f.store.activity = []SessionActivity{
		{ID: 40, WorkbenchID: testWorkbench, AgentCwd: inside},
		{ID: 41, WorkbenchID: testWorkbench, AgentCwd: filepath.Join(link, ".claude", "worktrees", "agent-1")},
		{ID: 42, WorkbenchID: 99, AgentCwd: filepath.Join(f.base, "elsewhere")},
		{ID: 44, WorkbenchID: testWorkbench},
		{ID: 45, WorkbenchID: 99},
		{ID: 46, WorkbenchID: testWorkbench, AgentCwd: filepath.Join(f.base, "elsewhere")},
		// Inside as stored, outside once resolved: W6's stored form counts.
		{ID: 47, WorkbenchID: testWorkbench, AgentCwd: filepath.Join(root, "out")},
		// Fix round 4 (R4-1): a plain shell never reports a cwd. It holds a
		// tree only when it was opened in it (W5 sees one that cd'd in).
		{ID: 48, WorkbenchID: testWorkbench, Kind: "shell", Folder: f.repo},
		{ID: 49, WorkbenchID: testWorkbench, Kind: "shell", Folder: filepath.Join(root, "sub")},
		{ID: 50, WorkbenchID: testWorkbench, Kind: "shell"},
	}
	// 45 (fix round 3, R3-2): a live session that has not said where it
	// works holds every tree, whatever its workbench.
	for id, holds := range map[int64]bool{40: true, 41: true, 42: true, 43: true, 44: true, 45: true, 46: false,
		47: true, 48: false, 49: true, 50: false} {
		a := &applier{deps: f.deps(), req: Request{
			liveNow: func(context.Context) ([]int64, error) { return []int64{id}, nil }}}
		err := a.liveClear(context.Background(), root)
		if got := errors.Is(err, errLiveInIt); got != holds || (!holds && err != nil) {
			t.Errorf("live session %d: err %v, want holds %v", id, err, holds)
		}
	}
}

// TestAutoRun_RepositoryPassLiveLedgerOwnerKeepsIt (#2402, fix round 2
// R2-4): a session that recorded the tree and goes live during the final
// idle walk keeps it, although it reports from elsewhere.
func TestAutoRun_RepositoryPassLiveLedgerOwnerKeepsIt(t *testing.T) {
	t.Parallel()
	a := newRepoPassFixture(t)
	root := a.mergedClaudeWork("agent-1", "worktree-agent-1")
	a.store.ledgerOwners = map[string][]int64{root: {31}}
	a.store.activity = []SessionActivity{{ID: 31, WorkbenchID: 99, Title: "owner", Finished: true,
		AgentCwd: filepath.Join(a.base, "elsewhere")}}
	var mu sync.Mutex
	live, walks := false, 0
	a.store.onLastSeen = func(string) {
		mu.Lock()
		defer mu.Unlock()
		if walks++; walks == 2 {
			live = true
		}
	}
	a.liveFn = func() (map[int64]bool, error) {
		mu.Lock()
		defer mu.Unlock()
		return map[int64]bool{31: live}, nil
	}
	if res, err := a.run(time.Now()); err != nil || res.RepoChanged != 0 || !a.listsWorktree(root) {
		t.Fatalf("res %+v, err %v", res, err)
	}
}

// TestAutoRun_StoppedAfterUnregisteringRegistersTheBundlesAgain (#2402,
// fix round 2 R2-6): a pass stopped between unregistering a worktree's app
// bundles and removing it registers them again on a ctx of its own, so a
// worktree that stays never loses its LaunchServices entries.
func TestAutoRun_StoppedAfterUnregisteringRegistersTheBundlesAgain(t *testing.T) {
	t.Parallel()
	a := newRepoPassFixture(t)
	root := a.mergedClaudeWork("agent-1", "worktree-agent-1")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	log := &opLog{}
	var registerErr error
	registered := false
	a.ls = &fakeLS{log: log, onUnregister: func(string) { cancel() },
		onRegister: func(c context.Context) { registered, registerErr = true, c.Err() }}
	a.ctx = ctx

	if _, err := a.run(time.Now()); !errors.Is(err, context.Canceled) {
		t.Fatalf("err %v", err)
	}
	if !a.listsWorktree(root) {
		t.Fatal("removed after the stop")
	}
	if !registered || registerErr != nil {
		t.Fatalf("registered again %v, on a ctx done with %v; ops %v", registered, registerErr, log.list())
	}
}

// TestAutoRun_RepositoryPassUnreadableLiveRunsAtAPruneStopTheRepository
// (#2402, fix round 2 R2-7): live runs that cannot be read right before a
// build folder's delete keep it and stop the repository's pass — as an
// unreadable live set before a batch does — so no later build is deleted
// on the strength of an older read. A failure, logged.
func TestAutoRun_RepositoryPassUnreadableLiveRunsAtAPruneStopTheRepository(t *testing.T) {
	t.Parallel()
	a := newRepoPassFixture(t)
	var builds []string
	for i, name := range []string{"agent-a", "agent-b"} {
		root := a.claudeWorktree(name, "worktree-"+name)
		a.commit(root, ".gitignore", ".build/\n")
		builds = append(builds, swiftBuild(t, filepath.Join(root, ".build")))
		ageWorktree(t, root, time.Now().Add(-time.Duration(48-i)*time.Hour))
	}
	failNext, failed := false, false
	a.liveFn = func() (map[int64]bool, error) {
		if failNext {
			failNext = false
			return nil, errors.New("host gone")
		}
		return map[int64]bool{}, nil
	}
	a.git = &loggingGit{log: &opLog{}, before: func(args []string) *gitAnswer {
		if lsFilesOfABuild(args) && !failed {
			// The read right before the first folder's delete fails, once.
			failNext, failed = true, true
		}
		return nil
	}}

	res, err := a.run(time.Now())
	if err != nil || res.RepoFailed != 1 {
		t.Fatalf("res %+v, err %v", res, err)
	}
	for _, b := range builds {
		if !exists(filepath.Join(b, buildMarker)) {
			t.Fatalf("%s went after the live runs could not be read", b)
		}
	}
}

// refuseFirstCancelSecond is the real git whose first `worktree remove`
// is refused (git's own refusal), and that cancels the pass right after
// its second one finished.
type refuseFirstCancelSecond struct {
	SystemGit
	cancel  context.CancelFunc
	removes int
}

func (g *refuseFirstCancelSecond) RunGit(ctx context.Context, dir, bin string, args ...string) ([]byte, int, error) {
	if len(args) >= 2 && args[0] == "worktree" && args[1] == "remove" {
		if g.removes++; g.removes == 1 {
			return nil, 128, &GitError{Args: args, Code: 128, Stderr: "fatal: refused for the test"}
		}
		out, code, err := g.SystemGit.RunGit(ctx, dir, bin, args...)
		g.cancel()
		return out, code, err
	}
	return g.SystemGit.RunGit(ctx, dir, bin, args...)
}

// TestAutoRun_StoppedRepositoryPassKeepsItsEarlierFailures (#2402, fix
// round 2 R2-8): a pass stopped part-way still counts and logs what failed
// before the stop — a removal git refused — and what it removed; the
// interrupted step is no failure.
func TestAutoRun_StoppedRepositoryPassKeepsItsEarlierFailures(t *testing.T) {
	t.Parallel()
	a := newRepoPassFixture(t)
	var roots []string
	for i, name := range []string{"agent-a", "agent-b", "agent-c"} {
		root := a.claudeWorktree(name, "worktree-"+name)
		ageWorktree(t, root, time.Now().Add(-time.Duration(48-i)*time.Hour))
		roots = append(roots, root)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	a.git = &refuseFirstCancelSecond{cancel: cancel}
	a.ctx = ctx
	var lines []string
	a.logf = func(format string, args ...any) { lines = append(lines, fmt.Sprintf(format, args...)) }

	res, err := a.run(time.Now())
	if !errors.Is(err, context.Canceled) || res.RepoFailed != 1 || res.RepoChanged != 1 {
		t.Fatalf("res %+v, err %v", res, err)
	}
	if !a.listsWorktree(roots[0]) || !a.gone(roots[1]) || !a.listsWorktree(roots[2]) {
		t.Fatal("the fixture did not stop where the test meant")
	}
	if len(lines) != 1 || !strings.Contains(lines[0], ReasonGitRefused) || strings.Contains(lines[0], "context canceled") {
		t.Fatalf("log %q", lines)
	}
}

// TestGitArgv_RepositoryPassChecksNameTheLockedRepository (#2402, fix
// round 3 R3-1): under the pass's mark the repository-wide reads a delete
// is decided on — the worktree list, the refs, the ancestry checks — name
// the locked common dir too; reads of a worktree's own content, of HEAD,
// and the identity check (`rev-parse --git-common-dir`) keep their folder's
// context.
func TestGitArgv_RepositoryPassChecksNameTheLockedRepository(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	bin, _ := gitbin.Locate()
	common := filepath.Join(f.repo, ".git")
	ctx := withBackgroundWrites(context.Background(), common)
	for _, tc := range []struct {
		args   []string
		pinned bool
	}{
		{[]string{"worktree", "list", "--porcelain"}, true},
		{[]string{"for-each-ref", "--format=%(refname:short)", "refs/heads"}, true},
		{[]string{"for-each-ref", "--count=1", "--contains", "abc", "refs/remotes"}, true},
		{[]string{"show-ref", "--verify", "--quiet", "refs/heads/x"}, true},
		{[]string{"merge-base", "--is-ancestor", "abc", "refs/heads/main"}, true},
		{[]string{"symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"}, true},
		{[]string{"symbolic-ref", "-q", "HEAD"}, false},
		{[]string{"status", "--porcelain"}, false},
		{[]string{"ls-files", "-z", "--cached"}, false},
		{[]string{"rev-parse", "--git-common-dir"}, false},
		{[]string{"rev-parse", "--show-toplevel"}, false},
		// Fix round 4 (R4-2): the merge check behind W3's unlock
		// (workbenchcheck) reads these against the base.
		{[]string{"rev-parse", "--verify", "--quiet", "refs/heads/main^{commit}"}, true},
		{[]string{"rev-parse", "--verify", "--quiet", "refs/heads/main~3"}, true},
		{[]string{"reflog", "show", "--format=%H %gs", "refs/heads/x", "--"}, true},
		{[]string{"rev-list", "--count", "abc..def"}, true},
		{[]string{"rev-list", "--first-parent", "refs/heads/main"}, true},
		{[]string{"cherry", "refs/heads/main", "abc"}, true},
		{[]string{"log", "-1", "--format=%ct", "abc", "--"}, true},
		{[]string{"diff", "--no-color", "--no-ext-diff", "--no-textconv", "-U0", "abc", "def"}, true},
		{[]string{"rev-parse", "--is-inside-work-tree"}, false},
		{[]string{"rev-parse", "--verify", "--quiet", "HEAD^{commit}"}, false},
		{[]string{"log", "-1", "--format=%ct"}, false},
		{[]string{"rev-list", "--count", "HEAD~2..abc"}, false},
		{[]string{"diff", "--stat"}, false},
	} {
		argv, err := gitArgv(ctx, f.repo, bin, tc.args)
		if err != nil {
			t.Fatal(err)
		}
		if got := strings.Contains(strings.Join(argv, " "), "--git-dir="+common+" "+tc.args[0]); got != tc.pinned {
			t.Errorf("%v: argv %q, pinned %v, want %v", tc.args, argv, got, tc.pinned)
		}
	}
	argv, err := gitArgv(context.Background(), f.repo, bin, []string{"worktree", "list", "--porcelain"})
	if err != nil || strings.Contains(strings.Join(argv, " "), "--git-dir") {
		t.Fatalf("unmarked read argv %q, %v", argv, err)
	}
}

// TestAutoRun_RepositoryPassTreeGonePrunableAfterSelectionStays (#2402, fix
// round 3 R3-3, round 4 R4-5): a tree git starts to list as prunable after
// the pass chose it — its directory moved aside, as an unmounted volume's
// contents vanish; no privilege can see through that — is rejected by the
// re-check: no bundle is unregistered and no `worktree remove` runs.
func TestAutoRun_RepositoryPassTreeGonePrunableAfterSelectionStays(t *testing.T) {
	t.Parallel()
	a := newRepoPassFixture(t)
	root := a.mergedClaudeWork("agent-1", "worktree-agent-1")
	aside := root + ".aside"
	ops := &opLog{}
	a.ls = &fakeLS{log: ops}
	lists := 0
	a.git = &loggingGit{log: ops, before: func(args []string) *gitAnswer {
		// Listings: the batch's facts, then the first re-check's.
		if len(args) > 1 && args[len(args)-2] == "list" && args[len(args)-1] == "--porcelain" {
			if lists++; lists == 2 {
				if err := os.Rename(root, aside); err != nil {
					t.Error(err)
				}
			}
		}
		return nil
	}}

	if _, err := a.run(time.Now()); err != nil {
		t.Fatal(err)
	}
	if lists < 2 || !exists(filepath.Join(aside, "agent-1.txt")) || !a.listsWorktree(root) ||
		!a.branchExists("worktree-agent-1") {
		t.Fatalf("acted on a tree that turned prunable (%d listings)", lists)
	}
	for _, op := range ops.list() {
		if strings.Contains(op, "lsregister -u") || strings.Contains(op, "worktree remove") {
			t.Fatalf("acted on it: %s", op)
		}
	}
}

// TestAutoRun_RepositoryPassUnreadableSessionsAtAPruneStopTheRepository
// (#2402, fix round 3 R3-4): the sessions or the ledger's owners that the
// prune's fresh re-check cannot read stop the repository's pass as
// unreadable live runs do: no later build goes on an older read.
func TestAutoRun_RepositoryPassUnreadableSessionsAtAPruneStopTheRepository(t *testing.T) {
	t.Parallel()
	for name, fail := range map[string]func(*fakeStore){
		"activity": func(s *fakeStore) { s.activityFailAt = 2 },
		"owners":   func(s *fakeStore) { s.ownersFailAt = 2 },
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			a := newRepoPassFixture(t)
			var builds []string
			for i, n := range []string{"agent-a", "agent-b"} {
				root := a.claudeWorktree(n, "worktree-"+n)
				a.commit(root, ".gitignore", ".build/\n")
				builds = append(builds, swiftBuild(t, filepath.Join(root, ".build")))
				ageWorktree(t, root, time.Now().Add(-time.Duration(48-i)*time.Hour))
			}
			// Read 1 is the batch's facts, read 2 the first prune's re-check.
			fail(a.store)
			res, err := a.run(time.Now())
			if err != nil || res.RepoFailed != 1 {
				t.Fatalf("res %+v, err %v", res, err)
			}
			for _, b := range builds {
				if !exists(filepath.Join(b, buildMarker)) {
					t.Fatalf("%s went after the sessions could not be read", b)
				}
			}
		})
	}
}

// expiringCtx is a pass budget the test runs out on purpose: Done closes
// and Err reports DeadlineExceeded once expire is called. No wall clock.
type expiringCtx struct {
	context.Context
	done chan struct{}
	once sync.Once
}

func newExpiringCtx() *expiringCtx {
	return &expiringCtx{Context: context.Background(), done: make(chan struct{})}
}

func (c *expiringCtx) expire()                     { c.once.Do(func() { close(c.done) }) }
func (c *expiringCtx) Done() <-chan struct{}       { return c.done }
func (c *expiringCtx) Deadline() (time.Time, bool) { return time.Time{}, false }
func (c *expiringCtx) Value(key any) any           { return c.Context.Value(key) }
func (c *expiringCtx) Err() error {
	select {
	case <-c.done:
		return context.DeadlineExceeded
	default:
		return nil
	}
}

// timeoutThenExpire is the real git whose first ls-files of a build folder
// fails as a per-command timeout would (the pass still running), and whose
// second runs only after the pass's budget ran out — git is killed.
type timeoutThenExpire struct {
	SystemGit
	budget *expiringCtx
	n      int
}

func (g *timeoutThenExpire) RunGit(ctx context.Context, dir, bin string, args ...string) ([]byte, int, error) {
	if lsFilesOfABuild(args) {
		if g.n++; g.n == 1 {
			return nil, -1, fmt.Errorf("git %s: %w", strings.Join(args, " "), context.DeadlineExceeded)
		}
		g.budget.expire()
	}
	return g.SystemGit.RunGit(ctx, dir, bin, args...)
}

// TestAutoRun_StoppedRepositoryPassCountsByWhenNotByText (#2402, fix round
// 3 R3-5): whether a failure came from the stop is told when it is
// handled — the pass's ctx done or not then — never from its text. A
// per-command timeout while the pass still ran counts (its text names a
// deadline, as the stop's does); a step the expired budget killed does
// not.
func TestAutoRun_StoppedRepositoryPassCountsByWhenNotByText(t *testing.T) {
	t.Parallel()
	a := newRepoPassFixture(t)
	var roots []string
	for i, n := range []string{"agent-a", "agent-b"} {
		root := a.claudeWorktree(n, "worktree-"+n)
		a.commit(root, ".gitignore", ".build/\n")
		swiftBuild(t, filepath.Join(root, ".build"))
		ageWorktree(t, root, time.Now().Add(-time.Duration(48-i)*time.Hour))
		roots = append(roots, root)
	}
	budget := newExpiringCtx()
	a.git = &timeoutThenExpire{budget: budget}
	a.budget = func(parent context.Context, d time.Duration) (context.Context, context.CancelFunc) {
		if d == repoPassBudget {
			return budget, func() {}
		}
		return context.WithTimeout(parent, d)
	}
	var lines []string
	a.logf = func(format string, args ...any) { lines = append(lines, fmt.Sprintf(format, args...)) }

	res, err := a.run(time.Now())
	if !errors.Is(err, context.DeadlineExceeded) || res.RepoFailed != 1 {
		t.Fatalf("res %+v, err %v", res, err)
	}
	if len(lines) != 1 || !strings.Contains(lines[0], "worktree:"+roots[0]+" build") ||
		strings.Contains(lines[0], "worktree:"+roots[1]) {
		t.Fatalf("log %q", lines)
	}
}

// TestGitArgv_PassArgumentsStillRefuseADirtyTree (#2402, fix round 3
// guard): with the repository pass's own arguments — hooks off, filters
// blanked, --git-dir naming the common dir — real git's `worktree remove`
// still refuses a tree with a modified file, and the tree stays.
func TestGitArgv_PassArgumentsStillRefuseADirtyTree(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.claudeWorktree("agent-1", "worktree-agent-1")
	writeFile(t, filepath.Join(root, "README.md"), "changed\n")
	bin, _ := gitbin.Locate()
	ctx := withBackgroundWrites(context.Background(), filepath.Join(f.repo, ".git"))
	_, code, err := SystemGit{}.RunGit(ctx, f.repo, bin, "worktree", "remove", root)
	if err == nil || code <= 0 {
		t.Fatalf("git removed a dirty tree: code %d, err %v", code, err)
	}
	if !f.listsWorktree(root) || !exists(filepath.Join(root, "README.md")) {
		t.Fatal("the dirty tree went")
	}
}

// TestProj18_SessionApplyPruneGoesOnAfterAnUnreadableRead (#2402, fix round
// 4 R4-4): only the repository pass halts on who-works-where reads it
// cannot make; a session-end apply keeps today's behaviour — the failed
// folder records its BuildError and the prune goes on with the next.
func TestProj18_SessionApplyPruneGoesOnAfterAnUnreadableRead(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	var roots []string
	for _, n := range []string{"wt-a", "wt-b"} {
		root := f.worktree(n, "feat/"+n)
		f.commit(root, ".gitignore", ".build/\n")
		swiftBuild(t, filepath.Join(root, ".build"))
		f.record(root, "feat/"+n)
		roots = append(roots, root)
	}
	f.endSession()
	// Read 1 is the apply's evaluation, read 2 the first prune's re-check.
	f.store.activityFailAt = 2

	res := f.apply(Request{PruneBuilds: true, RequireEnded: true}, nil, nil)
	failed, pruned := 0, 0
	for _, root := range roots {
		it := wantResultItem(t, res, "worktree:"+root, ActionKeep, ReasonUnpushedCommits, false)
		if it.BuildError != "" {
			failed++
		}
		if len(it.BuildsRemoved) > 0 {
			pruned++
		}
	}
	if failed != 1 || pruned != 1 {
		t.Fatalf("failed %d, pruned %d; want 1 and 1: %+v", failed, pruned, res.Items)
	}
}

// expiringRepoPass is a repository-pass fixture whose pass budget the test
// runs out (expiringCtx), with a logged LaunchServices and the log lines.
func expiringRepoPass(t *testing.T) (*autoFixture, *expiringCtx, *[]string) {
	t.Helper()
	a := newRepoPassFixture(t)
	budget := newExpiringCtx()
	a.budget = func(parent context.Context, d time.Duration) (context.Context, context.CancelFunc) {
		if d == repoPassBudget {
			return budget, func() {}
		}
		return context.WithTimeout(parent, d)
	}
	var lines []string
	a.logf = func(format string, args ...any) { lines = append(lines, fmt.Sprintf(format, args...)) }
	return a, budget, &lines
}

// TestAutoRun_RepositoryPassStopIsToldWhenTheFailureIsRecorded (#2402, fix
// round 4 R4-3): a failure is the stop's only when the pass's budget had
// run out at the moment it was recorded — never decided at the end of the
// item's step, after its recovery.
func TestAutoRun_RepositoryPassStopIsToldWhenTheFailureIsRecorded(t *testing.T) {
	t.Parallel()
	t.Run("a refusal before the stop counts, though the budget runs out while the bundles are put back", func(t *testing.T) {
		t.Parallel()
		a, budget, lines := expiringRepoPass(t)
		root := a.mergedClaudeWork("agent-1", "worktree-agent-1")
		a.git = failGitOn("worktree", "remove")
		a.ls = &fakeLS{log: &opLog{}, onRegister: func(context.Context) { budget.expire() }}
		res, err := a.run(time.Now())
		if !errors.Is(err, context.DeadlineExceeded) || res.RepoFailed != 1 || !a.listsWorktree(root) {
			t.Fatalf("res %+v, err %v", res, err)
		}
		if len(*lines) != 1 || !strings.Contains((*lines)[0], ReasonGitRefused) {
			t.Fatalf("log %q", *lines)
		}
	})
	t.Run("a bundle and its worktree failing after the stop do not count", func(t *testing.T) {
		t.Parallel()
		a, budget, lines := expiringRepoPass(t)
		a.mergedClaudeWork("agent-1", "worktree-agent-1")
		a.ls = &fakeLS{log: &opLog{}, failWith: errors.New("lsregister failed"),
			onUnregister: func(string) { budget.expire() }}
		res, err := a.run(time.Now())
		if !errors.Is(err, context.DeadlineExceeded) || res.RepoFailed != 0 || len(*lines) != 0 {
			t.Fatalf("res %+v, err %v, log %q", res, err, *lines)
		}
	})
	t.Run("a check that fails at evaluation after the stop does not count", func(t *testing.T) {
		t.Parallel()
		a, budget, lines := expiringRepoPass(t)
		a.mergedClaudeWork("agent-1", "worktree-agent-1")
		a.git = &loggingGit{log: &opLog{}, before: func(args []string) *gitAnswer {
			if args[0] == "status" {
				budget.expire()
				return &gitAnswer{code: 128, err: &GitError{Args: args, Code: 128, Stderr: "fatal: killed"}}
			}
			return nil
		}}
		res, err := a.run(time.Now())
		if !errors.Is(err, context.DeadlineExceeded) || res.RepoFailed != 0 || len(*lines) != 0 {
			t.Fatalf("res %+v, err %v, log %q", res, err, *lines)
		}
	})
}

// TestAutoRun_RepositoryPassMeasuresCandidatesOutsideTheLock (final review
// F2): the candidates' idle measure — up to nestedScanBudget per worktree —
// runs before the repository lock is taken, so the owner's Clean Up never
// waits on it; idleness is still read again under the lock before the
// removal.
func TestAutoRun_RepositoryPassMeasuresCandidatesOutsideTheLock(t *testing.T) {
	t.Parallel()
	a := newRepoPassFixture(t)
	root := a.mergedClaudeWork("agent-1", "worktree-agent-1")
	var mu sync.Mutex
	var held []bool
	a.store.onLastSeen = func(r string) {
		if r != root {
			return
		}
		mu.Lock()
		defer mu.Unlock()
		held = append(held, a.held.Load())
	}

	res, err := a.run(time.Now())
	if err != nil || res.RepoChanged != 1 || !a.gone(root) {
		t.Fatalf("res %+v, err %v", res, err)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(held) < 2 || held[0] || !slices.Contains(held, true) {
		t.Fatalf("lock held at each idle read: %v (want the first unheld, a later one held)", held)
	}
}

// TestAutoRun_RepositoryPassBranchGoesOnlyWithItsWorktree (final review C5):
// the pass deletes a branch only when its worktree went in the same batch.
// A worktree used again before its removal — here switched to another
// branch, so its own branch is no longer checked out anywhere — stays, and
// so does that branch.
func TestAutoRun_RepositoryPassBranchGoesOnlyWithItsWorktree(t *testing.T) {
	t.Parallel()
	a := newRepoPassFixture(t)
	root := a.mergedClaudeWork("agent-1", "worktree-agent-1")
	admin := adminOf(t, root)
	lists := 0
	a.git = &loggingGit{log: &opLog{}, before: func(args []string) *gitAnswer {
		// Listings: the unlocked measure's facts, the batch's, the first
		// re-check's, the final one's; the worktree switches branch right
		// before the final one.
		if slices.Equal(args, []string{"worktree", "list", "--porcelain"}) {
			if lists++; lists == 4 {
				gitIn(t, root, "switch", "-q", "-c", "wt/other")
				at := a.clock().Add(-time.Minute) // used now, by the pass's clock
				if err := os.Chtimes(filepath.Join(admin, "HEAD"), at, at); err != nil {
					t.Error(err)
				}
			}
		}
		return nil
	}}

	res, err := a.run(time.Now())
	if err != nil || res.RepoChanged != 0 {
		t.Fatalf("res %+v, err %v", res, err)
	}
	if lists < 4 || !a.listsWorktree(root) {
		t.Fatalf("the worktree went (%d listings)", lists)
	}
	if !a.branchExists("worktree-agent-1") {
		t.Fatal("the branch of a worktree that stayed went")
	}
}

// TestAutoRun_RepositoryPassRestoresBeforeItsMeasureFails (final review
// residual R2): an interrupted unlock is restored under a short hold of the
// repository's lock before the unlocked measure, so a measure that fails
// (git cannot list the worktrees) still leaves no worktree unlocked.
func TestAutoRun_RepositoryPassRestoresBeforeItsMeasureFails(t *testing.T) {
	t.Parallel()
	a := newRepoPassFixture(t)
	root := a.claudeWorktree("plan-c", "feat/plan-c")
	a.commit(root, "work.txt", "unpushed\n")
	a.lock(root)
	interruptedUnlock(t, a.fixture, root)
	a.git = &loggingGit{log: &opLog{}, before: func(args []string) *gitAnswer {
		if slices.Equal(args, []string{"worktree", "list", "--porcelain"}) {
			return &gitAnswer{code: 128, err: &GitError{Args: args, Code: 128, Stderr: "fatal: injected failure"}}
		}
		return nil
	}}

	res, err := a.run(time.Now())
	if err != nil || res.RepoFailed != 1 || res.RepoChanged != 0 {
		t.Fatalf("res %+v, err %v", res, err)
	}
	a.git = nil
	wantLocked(t, root)
	if want := []string{filepath.Join(a.repo, ".git")}; !slices.Equal(a.locked, want) || a.held.Load() {
		t.Fatalf("locked %v (held %v), want one short hold of %v", a.locked, a.held.Load(), want)
	}
}
