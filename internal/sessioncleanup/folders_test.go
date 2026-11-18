package sessioncleanup

import (
	"os"
	"path/filepath"
	"testing"
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
// folder's repository once, as one listing; a branch of a folder other than
// home is keyed with its folder, so a name in two repositories is two
// items, and an apply acts in the repository the key names. A folder in no
// repository is skipped; a folder over the home repository (a linked
// worktree on the bench) adds no second copy and is never a candidate.
func TestProj18_SweepCoversEveryFolder(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	hub := f.otherRepo("hub")
	plain := filepath.Join(f.base, "docs")
	if err := os.MkdirAll(plain, 0o755); err != nil {
		t.Fatal(err)
	}
	side := f.worktree("side", "side")
	f.store.bench = []string{f.repo, hub, plain, side}
	homeWork := f.pushedWork("home-wt", "feat/same")
	hubWork := f.pushedWorkIn(hub, "hub-wt", "feat/same")
	hubOnly := f.pushedWorkIn(hub, "hub-only", "feat/hub")
	hubKey := "branch:" + hub + ":feat/same"

	rec := &recorder{}
	res := f.planWith(Request{Sweep: true, Observer: rec}, nil)
	wantItem(t, res.Plan, "worktree:"+homeWork, ActionRemove, "")
	wantItem(t, res.Plan, "worktree:"+hubWork, ActionRemove, "")
	wantItem(t, res.Plan, "worktree:"+hubOnly, ActionRemove, "")
	wantItem(t, res.Plan, "branch:feat/same", ActionRemove, "")
	wantItem(t, res.Plan, hubKey, ActionRemove, "")
	wantItem(t, res.Plan, "branch:"+hub+":feat/hub", ActionRemove, "")
	if hasItem(res.Plan, "worktree:"+side) || hasItem(res.Plan, "branch:side") {
		t.Fatal("a bench folder is a sweep candidate")
	}
	if hasItem(res.Plan, "branch:feat/hub") {
		t.Fatal("a hub branch carries the home folder's key")
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
// the ones that left it included, is a workbench folder (W1): the sweep
// never lists it, and a session that recorded it keeps it.
func TestProj18_RemovedFolderIsNeverACandidate(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	gone := f.pushedWork("gone-folder", "feat/gone")
	f.store.extraFolders = []string{gone} // a folder that left its bench: still in WorkbenchFolders
	f.record(gone, "feat/gone")
	if p := f.plan(Request{Sweep: true}); hasItem(p, "worktree:"+gone) {
		t.Fatalf("a removed bench folder is a sweep candidate: %+v", p.Items)
	}
	wantItem(t, f.plan(Request{DeclaredWorktrees: []string{gone}}), "worktree:"+gone, ActionKeep, ReasonWorkbenchFolder)
}
