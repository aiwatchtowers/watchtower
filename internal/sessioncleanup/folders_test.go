package sessioncleanup

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"testing"
	"time"

	"watchtower/internal/db"
)

// otherRepo adds a second repository beside the fixture's, on main and
// pushed to its own bare origin (origin/HEAD set): another folder of the
// bench (multi-folder workbench, #2003).
func (f *fixture) otherRepo(name string) string {
	f.t.Helper()
	dir := filepath.Join(f.base, name)
	gitIn(f.t, f.base, "init", "-q", "--bare", "-b", "main", name+"-remote.git")
	gitIn(f.t, f.base, "init", "-q", "-b", "main", name)
	f.commit(dir, "README.md", "hello\n")
	gitIn(f.t, dir, "remote", "add", "origin", filepath.Join(f.base, name+"-remote.git"))
	gitIn(f.t, dir, "push", "-q", "-u", "origin", "main")
	gitIn(f.t, dir, "remote", "set-head", "origin", "main")
	return dir
}

// pushedWorkIn is pushedWork in repository repo.
func (f *fixture) pushedWorkIn(repo, name, branch string) string {
	f.t.Helper()
	root := filepath.Join(f.base, name)
	gitIn(f.t, repo, "worktree", "add", "-q", "-b", branch, root, "main")
	f.commit(root, name+".txt", "work\n")
	gitIn(f.t, root, "push", "-q", "origin", branch)
	return root
}

func branchIn(t *testing.T, repo, name string) bool {
	t.Helper()
	return gitIn(t, repo, "for-each-ref", "--format=%(refname)", "refs/heads/"+name) != ""
}

// TestProj18_PlansEachSessionInItsFolderRepository: a session started for
// one of the bench's folders is planned and applied in that folder's
// repository; the home folder's repository is not its plan.
func TestProj18_PlansEachSessionInItsFolderRepository(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	hub := f.otherRepo("hub")
	f.store.bench = []string{f.repo, hub}
	f.store.session.Folder = hub
	hubWork := f.pushedWorkIn(hub, "hub-wt", "feat/h")
	homeWork := f.pushedWork("home-wt", "feat/a")
	f.record(hubWork, "feat/h")
	f.record(homeWork, "feat/a")

	p := f.plan(Request{})
	wantItem(t, p, "worktree:"+hubWork, ActionRemove, "")
	wantItem(t, p, "branch:feat/h", ActionRemove, "")
	if hasItem(p, "worktree:"+homeWork) || hasItem(p, "branch:feat/a") {
		t.Fatalf("the home folder's repository is in the plan of a hub session: %+v", p.Items)
	}

	res := f.apply(Request{}, nil, nil)
	wantResultItem(t, res, "worktree:"+hubWork, ActionRemove, "", true)
	wantResultItem(t, res, "branch:feat/h", ActionRemove, "", true)
	if exists(hubWork) || branchIn(t, hub, "feat/h") {
		t.Fatal("the hub session's merged work stayed")
	}
	if !exists(homeWork) || !f.branchExists("feat/a") {
		t.Fatal("a hub session's cleanup touched the home folder's repository")
	}
}

// TestProj18_SweepCoversEveryFolder: the owner's sweep lists every live
// folder's repository once, as one listing; on a bench of several folders
// every branch is keyed with its folder, home included, so a name in two
// repositories is two items, and an apply acts in the repository the key
// names. A folder in no repository or missing is skipped with a note; a
// folder over the home repository (a linked worktree on the bench) adds no
// second copy and is never a candidate.
func TestProj18_SweepCoversEveryFolder(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	hub := f.otherRepo("hub")
	plain := filepath.Join(f.base, "docs")
	if err := os.MkdirAll(plain, 0o755); err != nil {
		t.Fatal(err)
	}
	side := f.worktree("side", "side")
	missing := filepath.Join(f.base, "moved-away")
	f.store.bench = []string{f.repo, hub, plain, side, missing}
	homeWork := f.pushedWork("home-wt", "feat/same")
	hubWork := f.pushedWorkIn(hub, "hub-wt", "feat/same")
	hubOnly := f.pushedWorkIn(hub, "hub-only", "feat/hub")
	hubKey := "branch:" + hub + ":feat/same"
	homeKey := "branch:" + f.repo + ":feat/same"

	rec := &recorder{}
	res := f.planWith(Request{Sweep: true, Observer: rec}, nil)
	wantItem(t, res.Plan, "worktree:"+homeWork, ActionRemove, "")
	wantItem(t, res.Plan, "worktree:"+hubWork, ActionRemove, "")
	wantItem(t, res.Plan, "worktree:"+hubOnly, ActionRemove, "")
	wantItem(t, res.Plan, homeKey, ActionRemove, "")
	wantItem(t, res.Plan, hubKey, ActionRemove, "")
	if hasItem(res.Plan, "branch:feat/same") {
		t.Fatal("a branch of a several-folder bench carries an unbound key")
	}
	for _, note := range []string{plain + ": not a repository, not swept", missing + ": missing, not swept"} {
		if !slices.Contains(res.Notes, note) {
			t.Fatalf("notes = %q, want %q", res.Notes, note)
		}
	}
	wantItem(t, res.Plan, "branch:"+hub+":feat/hub", ActionRemove, "")
	if hasItem(res.Plan, "worktree:"+side) || hasItem(res.Plan, "branch:side") {
		t.Fatal("a bench folder is a sweep candidate")
	}
	if hasItem(res.Plan, "branch:feat/hub") {
		t.Fatal("a hub branch carries an unbound key")
	}
	seen := map[string]bool{}
	for _, it := range res.Items {
		if seen[it.Key] {
			t.Fatalf("item %s listed twice: %+v", it.Key, res.Items)
		}
		seen[it.Key] = true
	}
	listed := rec.of("listed")
	if len(listed) != 1 {
		t.Fatalf("listed %d times, want one listing of every folder", len(listed))
	}
	keys := map[string]bool{}
	for _, it := range listed[0].items {
		keys[it.Key] = true
	}
	if !keys["worktree:"+homeWork] || !keys["worktree:"+hubWork] {
		t.Fatalf("the listing misses a folder: %+v", listed[0].items)
	}

	ares := f.apply(Request{Sweep: true}, []string{"worktree:" + hubWork, hubKey}, nil)
	wantResultItem(t, ares, "worktree:"+hubWork, ActionRemove, "", true)
	wantResultItem(t, ares, hubKey, ActionRemove, "", true)
	for _, it := range ares.Items {
		if it.Reason == ReasonNotInPlan {
			t.Fatalf("a key of one folder reads as not in plan: %+v", it)
		}
	}
	if exists(hubWork) || branchIn(t, hub, "feat/same") {
		t.Fatal("the named hub work stayed")
	}
	if !exists(homeWork) || !f.branchExists("feat/same") || !exists(hubOnly) || !branchIn(t, hub, "feat/hub") {
		t.Fatal("a sweep apply touched an item it was not given")
	}
}

// TestProj18_SweepKeyOfNoFolderIsNotInPlanOnce: a named key no folder's
// repository has is listed once, kept not_in_plan.
func TestProj18_SweepKeyOfNoFolderIsNotInPlanOnce(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	hub := f.otherRepo("hub")
	f.store.bench = []string{f.repo, hub}
	res := f.apply(Request{Sweep: true}, []string{"branch:nowhere"}, nil)
	n := 0
	for _, it := range res.Items {
		if it.Key == "branch:nowhere" {
			n++
			if it.Reason != ReasonNotInPlan {
				t.Fatalf("unknown key = %+v, want not_in_plan", it)
			}
		}
	}
	if n != 1 {
		t.Fatalf("unknown key listed %d times, want once", n)
	}
}

// TestProj18_RemovedFolderKeepsAllButItsSessionsWorktrees: in a folder that
// left the bench a session's cleanup removes only the worktrees its own cwd
// ledger recorded; a worktree it only named or declared, and every branch,
// are the owner's and stay (spec 2026-11-18 §8 PROJ-18).
func TestProj18_RemovedFolderKeepsAllButItsSessionsWorktrees(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	hub := f.otherRepo("hub")
	f.store.session.Folder, f.store.session.FolderRemoved = hub, true
	own := f.pushedWorkIn(hub, "own", "feat/own")
	f.record(own, "feat/own")
	named := f.pushedWorkIn(hub, "named", "feat/named")
	f.store.targetBranches = []string{"feat/named"}
	declared := f.pushedWorkIn(hub, "declared", "feat/declared")
	gitIn(t, hub, "branch", "feat/owner", "main")
	gitIn(t, hub, "push", "-q", "origin", "feat/owner")
	r := Request{DeclaredWorktrees: []string{declared}, DeclaredBranches: []string{"feat/owner"}}

	p := f.plan(r)
	wantItem(t, p, "worktree:"+own, ActionRemove, "")
	for _, key := range []string{"worktree:" + named, "worktree:" + declared, "branch:feat/own", "branch:feat/owner"} {
		if it := wantItem(t, p, key, ActionKeep, ReasonNotThisSession); it.Detail != detailFolderLeft {
			t.Fatalf("%s detail = %q, want %q", key, it.Detail, detailFolderLeft)
		}
	}
	// Checked out in a worktree that stays: B2 keeps them first.
	wantItem(t, p, "branch:feat/named", ActionKeep, ReasonCheckedOut)
	wantItem(t, p, "branch:feat/declared", ActionKeep, ReasonCheckedOut)

	res := f.apply(r, nil, nil)
	wantResultItem(t, res, "worktree:"+own, ActionRemove, "", true)
	if exists(own) {
		t.Fatal("the session's own recorded worktree stayed")
	}
	if !exists(named) || !exists(declared) {
		t.Fatal("a worktree the session did not record was removed from a folder that left the bench")
	}
	for _, b := range []string{"feat/own", "feat/named", "feat/declared", "feat/owner"} {
		if !branchIn(t, hub, b) {
			t.Fatalf("branch %s was deleted in a folder that left the bench", b)
		}
	}
}

// TestProj18_RemovedFolderIsNeverACandidate: every folder of every bench,
// the ones that left it included, is a workbench folder (W1), read through
// the real DBStore: the sweep
// never lists it.
func TestProj18_RemovedFolderIsNeverACandidate(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	gone := f.pushedWork("gone-folder", "feat/gone")
	d := db.OpenTestDB(t)
	wb, err := d.CreateWorkbench("acme", f.repo)
	if err != nil {
		t.Fatal(err)
	}
	store := DBStore{DB: d}
	// A folder that was on the bench and left it: a removed row.
	addFolderRow(t, store, wb, gone, 1, true)
	deps := f.deps()
	deps.DB = store
	res, err := PlanResult(context.Background(), deps, Request{Sweep: true, WorkbenchID: wb})
	if err != nil {
		t.Fatal(err)
	}
	if hasItem(res.Plan, "worktree:"+gone) {
		t.Fatalf("a folder that left the bench is a sweep candidate: %+v", res.Items)
	}

	// A session of the bench that declares it keeps it as a workbench folder.
	row, err := d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id, created_at)
		VALUES (?, 'claude', 'one', ?, 'c1', ?)`, wb, f.repo, f.sessionCreated.UTC().Format(time.RFC3339))
	if err != nil {
		t.Fatal(err)
	}
	sid, _ := row.LastInsertId()
	res, err = PlanResult(context.Background(), deps, Request{SessionID: sid, DeclaredWorktrees: []string{gone}})
	if err != nil {
		t.Fatal(err)
	}
	wantItem(t, res.Plan, "worktree:"+gone, ActionKeep, ReasonWorkbenchFolder)
}

// homeSwitch is a store whose bench is home A until the first BenchFolders
// read, and home B for every read after it: the home changed while an
// apply ran.
type homeSwitch struct {
	*fakeStore
	mu    sync.Mutex
	reads int
	after string
}

func (s *homeSwitch) switched() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.reads > 0
}

func (s *homeSwitch) BenchFolders(ctx context.Context, id int64) ([]string, error) {
	s.mu.Lock()
	s.reads++
	first := s.reads == 1
	s.mu.Unlock()
	if first {
		return s.fakeStore.BenchFolders(ctx, id)
	}
	return []string{s.after}, nil
}

func (s *homeSwitch) WorkbenchFolder(ctx context.Context, id int64) (string, error) {
	if s.switched() {
		return s.after, nil
	}
	return s.fakeStore.WorkbenchFolder(ctx, id)
}

// TestProj18_SweepApplyStaysInTheFolderItEvaluated: the home of a one-folder
// bench changes from A to B while a sweep apply runs; the re-checks do not
// read B's repository for A's deletes: everything is kept (check_failed)
// and nothing is removed in either repository.
func TestProj18_SweepApplyStaysInTheFolderItEvaluated(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	hub := f.otherRepo("hub")
	work := f.pushedWork("wt", "feat/x")
	hubWork := f.pushedWorkIn(hub, "hub-wt", "feat/x")
	gitIn(t, hub, "worktree", "remove", hubWork)
	res := f.apply(Request{Sweep: true}, []string{"worktree:" + work, "branch:feat/x"}, func(d *Deps) {
		d.DB = &homeSwitch{fakeStore: f.store, after: hub}
	})
	wantResultItem(t, res, "worktree:"+work, ActionKeep, ReasonCheckFailed, false)
	if !exists(work) || !f.branchExists("feat/x") || !branchIn(t, hub, "feat/x") {
		t.Fatal("an apply acted after the bench's home changed")
	}
}

// TestProj18_SweepOfABenchWhoseHomeIsNoRepository: a bench whose home is a
// plain folder is swept over its other folders; the home is noted.
func TestProj18_SweepOfABenchWhoseHomeIsNoRepository(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	hub := f.otherRepo("hub")
	plain := filepath.Join(f.base, "notes")
	if err := os.MkdirAll(plain, 0o755); err != nil {
		t.Fatal(err)
	}
	f.store.bench = []string{plain, hub}
	hubWork := f.pushedWorkIn(hub, "hub-wt", "feat/h")
	p := f.plan(Request{Sweep: true})
	wantItem(t, p, "worktree:"+hubWork, ActionRemove, "")
	wantItem(t, p, "branch:"+hub+":feat/h", ActionRemove, "")
	if !slices.Contains(p.Notes, plain+": not a repository, not swept") {
		t.Fatalf("notes = %q", p.Notes)
	}
	// No repository left at all: the sweep fails.
	f.store.bench = []string{plain, filepath.Join(f.base, "gone")}
	if _, err := PlanResult(context.Background(), f.deps(), Request{Sweep: true, WorkbenchID: testWorkbench}); err == nil {
		t.Fatal("a sweep with no repository planned something")
	}
}

// TestProj18_SweepSelectionIsBoundToItsRepository: a selection from a plan
// of a several-folder bench names its repository; after the home folder left
// and another folder became home (a one-folder bench, plain keys again), it
// matches nothing there and nothing is removed.
func TestProj18_SweepSelectionIsBoundToItsRepository(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	hub := f.otherRepo("hub")
	f.store.bench = []string{f.repo, hub}
	f.pushedWork("home-wt", "feat/same")
	hubWork := f.pushedWorkIn(hub, "hub-wt", "feat/same")
	gitIn(t, hub, "worktree", "remove", hubWork) // the branch alone is left, removable
	hubKey := "branch:" + hub + ":feat/same"
	p := f.plan(Request{Sweep: true})
	wantItem(t, p, hubKey, ActionRemove, "")
	// The home repository's feat/same, by the key this plan gave it.
	homeKey := ""
	for _, it := range p.Items {
		if it.Kind == KindBranch && it.Name == "feat/same" && it.Key != hubKey {
			homeKey = it.Key
		}
	}
	if homeKey == "" {
		t.Fatalf("no home feat/same in %+v", p.Items)
	}

	// The home folder leaves the bench; hub is promoted to home.
	f.store.folders[testWorkbench], f.store.bench = hub, []string{hub}
	res := f.apply(Request{Sweep: true}, []string{homeKey, hubKey}, nil)
	for _, key := range []string{homeKey, hubKey} {
		wantResultItem(t, res, key, ActionKeep, ReasonNotInPlan, false)
	}
	if !branchIn(t, hub, "feat/same") || !f.branchExists("feat/same") {
		t.Fatal("an older selection removed a branch after the home folder moved")
	}
}
