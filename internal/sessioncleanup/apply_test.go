package sessioncleanup

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"
)

// opLog is the order of every git run and LaunchServices call of an apply.
type opLog struct {
	mu  sync.Mutex
	ops []string
}

func (l *opLog) add(op string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.ops = append(l.ops, op)
}

func (l *opLog) list() []string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return slices.Clone(l.ops)
}

// gitAnswer stands in for a git run's outcome.
type gitAnswer struct {
	code int
	err  error
}

// loggingGit is the real git that logs every run; before, when set, runs
// first and may answer the run itself (a non-nil answer).
type loggingGit struct {
	SystemGit
	log    *opLog
	before func(args []string) *gitAnswer
}

func (g *loggingGit) RunGit(ctx context.Context, dir, bin string, args ...string) ([]byte, int, error) {
	g.log.add("git " + strings.Join(args, " "))
	if g.before != nil {
		if ans := g.before(args); ans != nil {
			return nil, ans.code, ans.err
		}
	}
	return g.SystemGit.RunGit(ctx, dir, bin, args...)
}

// fakeLS lists one bundle per worktree root and logs each unregister.
type fakeLS struct {
	log      *opLog
	failWith error
}

func (l *fakeLS) Bundles(root string) []string { return []string{filepath.Join(root, "Build", "App.app")} }

func (l *fakeLS) Unregister(_ context.Context, bundle string) error {
	l.log.add("lsregister -u " + bundle)
	return l.failWith
}

func (l *fakeLS) Stale(context.Context, string) ([]string, error) { return nil, nil }

// dyingProcs is a scan whose signalled processes exit when dies is set;
// onScan runs before the n-th scan returns (1-based).
type dyingProcs struct {
	mu         sync.Mutex
	list       []Proc
	dies       bool
	terminated []Proc
	scans      int
	onScan     func(n int)
}

func (p *dyingProcs) Scan(context.Context) ([]Proc, error) {
	p.mu.Lock()
	p.scans++
	n, hook := p.scans, p.onScan
	list := slices.Clone(p.list)
	p.mu.Unlock()
	if hook != nil {
		hook(n)
	}
	return list, nil
}

func (p *dyingProcs) Terminate(pr Proc) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.terminated = append(p.terminated, pr)
	if p.dies {
		p.list = slices.DeleteFunc(p.list, func(x Proc) bool { return x.PID == pr.PID })
	}
	return nil
}

// fakeResults records the saved cleanup result.
type fakeResults struct {
	sessionID int64
	body, at  string
	failWith  error
}

func (s *fakeResults) SaveCleanupResult(_ context.Context, id int64, body, at string) error {
	s.sessionID, s.body, s.at = id, body, at
	return s.failWith
}

func (f *fixture) apply(r Request, only []string, adjust func(*Deps)) Result {
	f.t.Helper()
	if r.SessionID == 0 && !r.Sweep {
		r.SessionID = testSession
	}
	if r.Sweep {
		r.WorkbenchID = testWorkbench
	}
	d := f.deps()
	if adjust != nil {
		adjust(&d)
	}
	res, err := Apply(context.Background(), d, r, only)
	if err != nil {
		f.t.Fatalf("Apply: %v", err)
	}
	return res
}

func wantResultItem(t *testing.T, res Result, key, action, reason string, done bool) Item {
	t.Helper()
	it := wantItem(t, res.Plan, key, action, reason)
	if it.Done != done {
		t.Fatalf("%s done = %v, want %v (%+v)", key, it.Done, done, it)
	}
	return it
}

func exists(path string) bool {
	_, err := os.Lstat(path)
	return err == nil
}

func (f *fixture) branchExists(name string) bool {
	f.t.Helper()
	out := gitIn(f.t, f.repo, "for-each-ref", "--format=%(refname)", "refs/heads/"+name)
	return out != ""
}

func (f *fixture) listsWorktree(root string) bool {
	f.t.Helper()
	return strings.Contains(gitIn(f.t, f.repo, "worktree", "list", "--porcelain"), "worktree "+root+"\n")
}

// TestProj16_MergedAndPushedWorkIsRemoved is business done-criterion 1: a
// merged and a pushed worktree of the session, with their branches, go.
func TestProj16_MergedAndPushedWorkIsRemoved(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	pushed := f.worktree("wt-pushed", "feat/pushed")
	f.commit(pushed, "p.txt", "work\n")
	gitIn(t, pushed, "push", "-q", "-u", "origin", "feat/pushed") // leaves a config section
	merged := f.worktree("wt-merged", "feat/merged")
	f.commit(merged, "m.txt", "work\n")
	gitIn(t, f.repo, "merge", "-q", "--no-edit", "feat/merged")
	f.record(pushed, "feat/pushed")
	f.record(merged, "feat/merged")
	results := &fakeResults{}

	res := f.apply(Request{}, nil, func(d *Deps) { d.Results = results })
	for _, root := range []string{pushed, merged} {
		wantResultItem(t, res, "worktree:"+root, ActionRemove, "", true)
		if exists(root) || f.listsWorktree(root) {
			t.Fatalf("%s is still there", root)
		}
	}
	for _, br := range []string{"feat/pushed", "feat/merged"} {
		wantResultItem(t, res, "branch:"+br, ActionRemove, "", true)
		if f.branchExists(br) {
			t.Fatalf("branch %s is still there", br)
		}
	}
	if out := gitIn(t, f.repo, "config", "--get-regexp", "^branch\\.", "--default", ""); strings.Contains(out, "feat/pushed") {
		t.Fatalf("the pushed branch's config section stays: %q", out)
	}
	if res.Mode != ModeApply || res.SessionID != testSession || res.WorkbenchID != testWorkbench {
		t.Fatalf("result envelope = %+v", res)
	}
	if !strings.HasPrefix(res.Summary, "2 worktrees, 2 branches removed") {
		t.Fatalf("summary = %q", res.Summary)
	}
	if !res.ResultSaved || res.ResultError != "" || results.sessionID != testSession {
		t.Fatalf("result not saved: %+v / %+v", res, results)
	}
}

func TestProj16_ClaudeHistoryAndMainBuildUntouched(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	home := filepath.Join(f.base, "home")
	f.home = func() (string, error) { return home, nil }
	history := filepath.Join(home, ".claude", "projects", "repo", "session.jsonl")
	writeFile(t, history, "{}\n")
	agent := filepath.Join(home, ".claude", "worktrees", "agent-1")
	gitIn(t, f.repo, "worktree", "add", "-q", "-b", "feat/agent", agent, "main")
	f.record(agent, "feat/agent")
	writeFile(t, filepath.Join(f.repo, ".gitignore"), ".build/\n")
	gitIn(t, f.repo, "add", ".gitignore")
	gitIn(t, f.repo, "commit", "-q", "-m", "ignore")
	gitIn(t, f.repo, "push", "-q", "origin", "main")
	mainBuild := filepath.Join(f.repo, "WatchtowerDesktop", ".build", "debug", "Watchtower")
	writeFile(t, mainBuild, "binary")
	f.record(f.repo, "main")

	res := f.apply(Request{DeclaredWorktrees: []string{f.repo, agent}, DeclaredBranches: []string{"main"}}, nil, nil)
	wantResultItem(t, res, "worktree:"+agent, ActionKeep, ReasonClaudeHome, false)
	wantResultItem(t, res, "worktree:"+f.repo, ActionKeep, ReasonMainFolder, false)
	wantResultItem(t, res, "branch:main", ActionKeep, ReasonDefaultBranch, false)
	for _, p := range []string{history, agent, mainBuild} {
		if !exists(p) {
			t.Fatalf("%s was removed", p)
		}
	}
	if !f.branchExists("main") || !f.branchExists("feat/agent") {
		t.Fatal("a protected branch was deleted")
	}
}

// TestProj16_ApplyRechecksAndActsOnlyOnNamedItems: a worktree that turned
// dirty after the plan, or right before it is acted on, is kept; items
// outside the named set are never touched.
func TestProj16_ApplyRechecksAndActsOnlyOnNamedItems(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	roots := map[string]string{}
	for _, n := range []string{"1", "2", "3", "4"} {
		roots[n] = f.pushedWork("wt"+n, "feat/b"+n)
		f.record(roots[n], "feat/b"+n)
	}
	for _, it := range f.plan(Request{}).Items {
		if it.Action != ActionRemove {
			t.Fatalf("the plan keeps %+v", it)
		}
	}
	writeFile(t, filepath.Join(roots["1"], "new.txt"), "between plan and apply\n")
	procs := &dyingProcs{onScan: func(n int) {
		if n == 2 { // the apply's first re-check, after its own evaluation
			writeFile(t, filepath.Join(roots["2"], "late.txt"), "right before the removal\n")
		}
	}}
	only := []string{"worktree:" + roots["1"], "worktree:" + roots["2"], "worktree:" + roots["3"],
		"branch:feat/b1", "branch:feat/b3", "branch:feat/unknown"}

	res := f.apply(Request{}, only, func(d *Deps) { d.Procs = procs })
	wantResultItem(t, res, "worktree:"+roots["1"], ActionKeep, ReasonUncommittedChanges, false)
	wantResultItem(t, res, "worktree:"+roots["2"], ActionKeep, ReasonUncommittedChanges, false)
	wantResultItem(t, res, "worktree:"+roots["3"], ActionRemove, "", true)
	wantResultItem(t, res, "worktree:"+roots["4"], ActionKeep, ReasonNotSelected, false)
	wantResultItem(t, res, "branch:feat/b1", ActionKeep, ReasonCheckedOut, false)
	wantResultItem(t, res, "branch:feat/b3", ActionRemove, "", true)
	wantResultItem(t, res, "branch:feat/b4", ActionKeep, ReasonNotSelected, false)
	wantResultItem(t, res, "branch:feat/unknown", ActionKeep, ReasonNotInPlan, false)
	for _, n := range []string{"1", "2", "4"} {
		if !exists(roots[n]) || !f.branchExists("feat/b"+n) {
			t.Fatalf("worktree %s or its branch was touched", n)
		}
	}
	if exists(roots["3"]) || f.branchExists("feat/b3") {
		t.Fatal("the named eligible worktree and branch stay")
	}
}

func TestProj16_BranchThatMovedAfterThePlanIsKept(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	for _, b := range []string{"feat/early", "feat/late"} {
		gitIn(t, f.repo, "branch", b, "main")
	}
	f.store.targetBranches = []string{"feat/early", "feat/late"}
	wantItem(t, f.plan(Request{}), "branch:feat/early", ActionRemove, "")
	wantItem(t, f.plan(Request{}), "branch:feat/late", ActionRemove, "")

	// Moved after the plan to a commit nobody has: the re-check keeps it.
	unpushed := gitIn(t, f.repo, "commit-tree", "main^{tree}", "-p", "main", "-m", "local only")
	gitIn(t, f.repo, "update-ref", "refs/heads/feat/early", unpushed)
	// Moved between the re-check and the delete: the compare-and-delete keeps it.
	main := gitIn(t, f.repo, "rev-parse", "main")
	gitIn(t, f.repo, "commit", "-q", "--allow-empty", "-m", "main moves on")
	gitIn(t, f.repo, "push", "-q", "origin", "main")
	gitIn(t, f.repo, "update-ref", "refs/heads/feat/late", main)
	newMain := gitIn(t, f.repo, "rev-parse", "main")
	g := &loggingGit{log: &opLog{}}
	g.before = func(args []string) *gitAnswer {
		if len(args) > 2 && args[0] == "update-ref" && args[2] == "refs/heads/feat/late" {
			gitIn(t, f.repo, "update-ref", "refs/heads/feat/late", newMain)
		}
		return nil
	}
	f.git = g

	res := f.apply(Request{}, nil, nil)
	wantResultItem(t, res, "branch:feat/early", ActionKeep, ReasonUnpushedCommits, false)
	it := wantResultItem(t, res, "branch:feat/late", ActionKeep, ReasonMoved, false)
	if !strings.Contains(it.Detail, "expected") {
		t.Fatalf("detail %q is not git's compare-and-delete refusal", it.Detail)
	}
	if got := gitIn(t, f.repo, "rev-parse", "feat/early"); got != unpushed {
		t.Fatalf("feat/early = %s, want %s", got, unpushed)
	}
	if got := gitIn(t, f.repo, "rev-parse", "feat/late"); got != newMain {
		t.Fatalf("feat/late = %s, want the moved tip %s", got, newMain)
	}
}

// TestProj16_NoForceNoFetchAnywhere: no git run of an apply carries a
// force flag or fetches, every ref delete names the checked tip, and no
// source file of the package spells a force flag or a fetch.
func TestProj16_NoForceNoFetchAnywhere(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	for _, n := range []string{"a", "b"} {
		root := f.pushedWork("wt-"+n, "feat/"+n)
		f.record(root, "feat/"+n)
	}
	log := &opLog{}
	f.git = &loggingGit{log: log}
	res := f.apply(Request{}, nil, func(d *Deps) { d.LS = &fakeLS{log: log} })
	if !strings.HasPrefix(res.Summary, "2 worktrees, 2 branches, 2 LaunchServices entries removed") {
		t.Fatalf("summary = %q", res.Summary)
	}
	for _, op := range log.list() {
		args := strings.Fields(op)
		if slices.Contains(args, "--force") || slices.Contains(args, "-f") || slices.Contains(args, "fetch") ||
			slices.Contains(args, "prune") {
			t.Fatalf("forbidden git run: %s", op)
		}
		if len(args) > 2 && args[1] == "update-ref" && (len(args) != 5 || args[2] != "-d") {
			t.Fatalf("a ref delete without the checked tip: %s", op)
		}
	}
	assertNoForceInSources(t)
}

func assertNoForceInSources(t *testing.T) {
	t.Helper()
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range files {
		if strings.HasSuffix(name, "_test.go") {
			continue
		}
		src, err := os.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		for _, bad := range []string{`"--force"`, `"-f"`, `"fetch"`, `"prune"`, `"-D"`, "SIGKILL"} {
			if strings.Contains(string(src), bad) {
				t.Fatalf("%s spells %s", name, bad)
			}
		}
	}
}

func TestProj16_LsregisterRunsBeforeWorktreeRemove(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.pushedWork("wt", "feat/x")
	f.record(root, "feat/x")
	log := &opLog{}
	f.git = &loggingGit{log: log}

	res := f.apply(Request{}, nil, func(d *Deps) { d.LS = &fakeLS{log: log} })
	wantResultItem(t, res, "lsreg:"+filepath.Join(root, "Build", "App.app"), ActionRemove, "", true)
	ops := log.list()
	unregister := slices.Index(ops, "lsregister -u "+filepath.Join(root, "Build", "App.app"))
	remove := slices.Index(ops, "git worktree remove "+root)
	if unregister < 0 || remove < 0 || unregister > remove {
		t.Fatalf("lsregister at %d, worktree remove at %d: %v", unregister, remove, ops)
	}
}

// TestProj16_FailureMidwayLeavesTheRestUntouched: a git run that fails
// (not git's refusal) stops the apply; what follows is not touched and is
// reported.
func TestProj16_FailureMidwayLeavesTheRestUntouched(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	roots := []string{f.pushedWork("wt-a", "feat/a"), f.pushedWork("wt-b", "feat/b")}
	f.record(roots[0], "feat/a")
	f.record(roots[1], "feat/b")
	failed := false
	g := &loggingGit{log: &opLog{}}
	g.before = func(args []string) *gitAnswer {
		if len(args) > 1 && args[0] == "worktree" && args[1] == "remove" && !failed {
			failed = true
			return &gitAnswer{code: -1, err: errors.New("injected: git did not run")}
		}
		return nil
	}
	f.git = g

	res := f.apply(Request{}, nil, nil)
	nFailed, skipped := 0, 0
	for _, root := range roots {
		it := findItem(t, res.Plan, "worktree:"+root)
		switch {
		case it.Reason == ReasonCheckFailed && strings.Contains(it.Detail, "injected"):
			nFailed++
		case it.Reason == ReasonNotAttempted:
			skipped++
		}
		if !exists(root) || !f.listsWorktree(root) {
			t.Fatalf("%s was removed after the failure", root)
		}
	}
	if nFailed != 1 || skipped != 1 {
		t.Fatalf("failed %d, not attempted %d, want 1 and 1: %+v", nFailed, skipped, res.Items)
	}
	for _, br := range []string{"feat/a", "feat/b"} {
		wantResultItem(t, res, "branch:"+br, ActionKeep, ReasonNotAttempted, false)
		if !f.branchExists(br) {
			t.Fatalf("branch %s was deleted after the failure", br)
		}
	}
	if !strings.Contains(res.Summary, "kept 2 worktrees, 2 branches") {
		t.Fatalf("summary = %q", res.Summary)
	}
}

func TestApply_GitRefusalIsKeptWithDetail(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	roots := []string{f.pushedWork("wt-a", "feat/a"), f.pushedWork("wt-b", "feat/b")}
	f.record(roots[0], "feat/a")
	f.record(roots[1], "feat/b")
	g := &loggingGit{log: &opLog{}}
	g.before = func(args []string) *gitAnswer {
		if len(args) == 3 && args[1] == "remove" && args[2] == roots[0] {
			writeFile(t, filepath.Join(roots[0], "sneaked-in.txt"), "x\n")
		}
		return nil
	}
	f.git = g

	res := f.apply(Request{}, nil, nil)
	it := wantResultItem(t, res, "worktree:"+roots[0], ActionKeep, ReasonGitRefused, false)
	if !strings.Contains(it.Detail, "untracked") {
		t.Fatalf("detail %q is not git's message", it.Detail)
	}
	wantResultItem(t, res, "worktree:"+roots[1], ActionRemove, "", true)
	wantResultItem(t, res, "branch:feat/a", ActionKeep, ReasonCheckedOut, false)
	wantResultItem(t, res, "branch:feat/b", ActionRemove, "", true)
	if !exists(filepath.Join(roots[0], "sneaked-in.txt")) {
		t.Fatal("the refused worktree lost its file")
	}
}

func TestApply_LsregisterFailureDoesNotBlockRemoval(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.pushedWork("wt", "feat/x")
	f.record(root, "feat/x")

	res := f.apply(Request{}, nil, func(d *Deps) {
		d.LS = &fakeLS{log: &opLog{}, failWith: errors.New("lsregister: exit 1")}
	})
	it := findItem(t, res.Plan, "lsreg:"+filepath.Join(root, "Build", "App.app"))
	if it.Done || it.Error == "" {
		t.Fatalf("lsreg item = %+v, want an error", it)
	}
	wantResultItem(t, res, "worktree:"+root, ActionRemove, "", true)
	if exists(root) || !strings.Contains(res.Summary, "1 error") {
		t.Fatalf("worktree stays or summary %q misses the error", res.Summary)
	}
}

func TestApply_SweepWithoutItemsIsRefused(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.pushedWork("wt", "feat/x")
	f.git = noGit{t: t}
	res, err := Apply(context.Background(), f.deps(), Request{Sweep: true, WorkbenchID: testWorkbench}, nil)
	if !errors.Is(err, ErrSweepNeedsItems) {
		t.Fatalf("err = %v, want ErrSweepNeedsItems", err)
	}
	if res.Items == nil || len(res.Items) != 0 || !exists(root) {
		t.Fatalf("result = %+v; the worktree must stay", res)
	}
}

func TestApply_SweepRemovesOnlyNamedItemsAndNeverSignals(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	a, b := f.pushedWork("wt-a", "feat/a"), f.pushedWork("wt-b", "feat/b")
	results := &fakeResults{}
	res := f.apply(Request{Sweep: true}, []string{"worktree:" + a}, func(d *Deps) { d.Results = results })
	wantResultItem(t, res, "worktree:"+a, ActionRemove, "", true)
	wantResultItem(t, res, "worktree:"+b, ActionKeep, ReasonNotSelected, false)
	if exists(a) || !exists(b) || !f.branchExists("feat/a") {
		t.Fatal("the sweep acted outside the named item")
	}
	if results.body != "" || res.ResultSaved || res.ResultError != "" || len(f.procs.terminated) != 0 {
		t.Fatalf("a sweep saved a session result or signalled: %+v", res)
	}
}

func orphanIn(root string) Proc {
	return Proc{PID: 601, PPID: 1, UID: os.Getuid(), Start: "Mon Oct 12 10:00:00 2026",
		Exe: filepath.Join(root, ".build", "debug", "stub"), Cwd: root}
}

func TestApply_OrphanSurvivingSIGTERMKeepsTheWorktree(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.pushedWork("wt", "feat/x")
	f.record(root, "feat/x")
	procs := &dyingProcs{list: []Proc{orphanIn(root)}}

	res := f.apply(Request{}, nil, func(d *Deps) { d.Procs, d.OrphanGrace = procs, 50*time.Millisecond })
	it := wantResultItem(t, res, "worktree:"+root, ActionKeep, ReasonProcessRunning, false)
	if !strings.Contains(it.Detail, "survived SIGTERM") || len(procs.terminated) != 1 {
		t.Fatalf("detail %q, terminated %v", it.Detail, procs.terminated)
	}
	wantResultItem(t, res, procKey(orphanIn(root)), ActionKeep, ReasonWorktreeKept, false)
	if !exists(root) {
		t.Fatal("the worktree went although its orphan survived")
	}
}

func TestApply_OrphanThatExitsLetsTheWorktreeGo(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.pushedWork("wt", "feat/x")
	f.record(root, "feat/x")
	procs := &dyingProcs{list: []Proc{orphanIn(root)}, dies: true}

	res := f.apply(Request{}, nil, func(d *Deps) { d.Procs = procs })
	wantResultItem(t, res, "worktree:"+root, ActionRemove, "", true)
	wantResultItem(t, res, procKey(orphanIn(root)), ActionRemove, "", true)
	if exists(root) {
		t.Fatal("the worktree stays")
	}
}

func TestApply_UnnamedOrphanIsNeverSignalled(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.pushedWork("wt", "feat/x")
	f.record(root, "feat/x")
	procs := &dyingProcs{list: []Proc{orphanIn(root)}, dies: true}

	res := f.apply(Request{}, []string{"worktree:" + root}, func(d *Deps) { d.Procs = procs })
	wantResultItem(t, res, "worktree:"+root, ActionKeep, ReasonProcessRunning, false)
	if len(procs.terminated) != 0 || !exists(root) {
		t.Fatalf("signalled %v without the item named", procs.terminated)
	}
}

func TestApply_SavesTheResultAndReportsASaveFailure(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.pushedWork("wt", "feat/x")
	f.record(root, "feat/x")
	results := &fakeResults{}
	res := f.apply(Request{}, nil, func(d *Deps) { d.Results = results })
	var stored Result
	if err := json.Unmarshal([]byte(results.body), &stored); err != nil {
		t.Fatalf("stored result %q: %v", results.body, err)
	}
	if !stored.ResultSaved || stored.Summary != res.Summary || len(stored.Items) != len(res.Items) || results.at == "" {
		t.Fatalf("stored %+v at %q, returned %+v", stored, results.at, res)
	}

	f2 := newFixture(t)
	root2 := f2.pushedWork("wt", "feat/x")
	f2.record(root2, "feat/x")
	res2 := f2.apply(Request{}, nil, func(d *Deps) { d.Results = &fakeResults{failWith: errors.New("db is locked")} })
	if res2.ResultSaved || !strings.Contains(res2.ResultError, "db is locked") || exists(root2) {
		t.Fatalf("save failure: %+v", res2)
	}
}

func TestSummarize_Wording(t *testing.T) {
	t.Parallel()
	const gb = int64(1_000_000_000)
	wt := func(done bool, bytes int64, known bool) Item {
		return Item{Kind: KindWorktree, Action: ActionRemove, Done: done, Bytes: bytes, BytesKnown: known}
	}
	br := Item{Kind: KindBranch, Action: ActionRemove, Done: true, BytesKnown: true}
	kept := Item{Kind: KindWorktree, Action: ActionKeep, Reason: ReasonUncommittedChanges}
	for _, tc := range []struct {
		name  string
		items []Item
		want  string
	}{
		{"nothing", nil, "nothing to clean up"},
		{"removed only", []Item{wt(true, 12 * gb, true), wt(true, 2 * gb, true), br, br, br, br},
			"2 worktrees, 4 branches removed (~14 GB)"},
		{"kept only", []Item{kept}, "kept 1 worktree — uncommitted changes"},
		{"mixed", []Item{wt(true, 1_500_000_000, true), br, kept,
			{Kind: KindBranch, Action: ActionKeep, Reason: ReasonCheckedOut}},
			"1 worktree, 1 branch removed (~1.5 GB); kept 1 worktree, 1 branch — uncommitted changes, checked out"},
		{"unknown size", []Item{wt(true, 0, false)}, "1 worktree removed (size unknown)"},
		{"partly unknown", []Item{wt(true, 3 * gb, true), wt(true, 0, false)},
			"2 worktrees removed (~3.0 GB, some sizes unknown)"},
		{"plan", []Item{wt(false, 500_000_000, true), {Kind: KindBranch, Action: ActionRemove, BytesKnown: true}},
			"1 worktree, 1 branch to remove (~500 MB)"},
	} {
		if got := Summarize(tc.items); got != tc.want {
			t.Errorf("%s: Summarize = %q, want %q", tc.name, got, tc.want)
		}
	}
}
