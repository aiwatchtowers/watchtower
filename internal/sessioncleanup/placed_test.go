package sessioncleanup

import (
	"context"
	"path/filepath"
	"testing"
	"time"
)

// placedWork adds a worktree the way placement does: under the repository's
// .claude/worktrees on wt/<slug>, its branch carrying one pushed commit, so
// the unpushed catches (W7, B4) let it pass.
func (f *fixture) placedWork(slug string) string {
	f.t.Helper()
	root := filepath.Join(f.repo, ".claude", "worktrees", slug)
	gitIn(f.t, f.repo, "worktree", "add", "-q", "-b", "wt/"+slug, root, "main")
	f.commit(root, slug+".txt", "work\n")
	gitIn(f.t, root, "push", "-q", "origin", "wt/"+slug)
	return root
}

// place marks the test session as placed: folder_path cwd, worktree_branch
// branch.
func (f *fixture) place(cwd, branch string) {
	f.store.session.PlacedCwd, f.store.session.PlacedBranch = cwd, branch
}

// A placed row: Watchtower created the worktree and its wt/ branch before
// inserting the row, so both are born before created_at; by record they are
// the session's anyway (spec §9). Every other catch still runs.
func TestCleanupPlacedRowOwnsItsWorktreeAndBranch(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.placedWork("p")
	f.sessionCreated = time.Now().Add(time.Minute) // the row was inserted after the worktree
	f.place(root, "wt/p")

	p := f.plan(Request{})
	wantItem(t, p, "worktree:"+root, ActionRemove, "")
	wantItem(t, p, "branch:wt/p", ActionRemove, "")
}

func TestCleanupPlacedSubfolderRowOwnsItsWorktree(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.placedWork("s")
	f.sessionCreated = time.Now().Add(time.Minute)
	f.place(filepath.Join(root, "app", "web"), "wt/s")

	wantItem(t, f.plan(Request{}), "worktree:"+root, ActionRemove, "")
}

func TestCleanupPlacedRowStillKeepsUncommittedWork(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.placedWork("d")
	writeFile(t, filepath.Join(root, "README.md"), "edited\n")
	f.sessionCreated = time.Now().Add(time.Minute)
	f.place(root, "wt/d")

	p := f.plan(Request{})
	wantItem(t, p, "worktree:"+root, ActionKeep, ReasonUncommittedChanges)
	wantItem(t, p, "branch:wt/d", ActionKeep, ReasonCheckedOut)
}

func TestCleanupUnplacedOldWorktreeStillKept(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	old := f.placedWork("o")
	placed := f.placedWork("p2")
	f.record(old, "wt/o") // the session also walked into another worktree
	f.sessionCreated = time.Now().Add(time.Minute)
	f.place(placed, "wt/p2")

	p := f.plan(Request{})
	wantItem(t, p, "worktree:"+old, ActionKeep, ReasonExistedBeforeSession)
	wantItem(t, p, "branch:wt/o", ActionKeep, ReasonCheckedOut)
	wantItem(t, p, "worktree:"+placed, ActionRemove, "")
	wantItem(t, p, "branch:wt/p2", ActionRemove, "")
}

// Only the row's worktree_branch is owned by record: another branch
// checked out in the placed worktree meets B3 as before (never observed).
func TestCleanupPlacedRowOwnsOnlyItsOwnBranch(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.placedWork("b")
	gitIn(t, root, "switch", "-q", "-c", "feat/other")
	gitIn(t, root, "push", "-q", "origin", "feat/other")
	f.sessionCreated = time.Now().Add(time.Minute)
	f.place(root, "wt/b")

	p := f.plan(Request{})
	wantItem(t, p, "worktree:"+root, ActionRemove, "")
	wantItem(t, p, "branch:feat/other", ActionKeep, ReasonNotThisSession)
	wantItem(t, p, "branch:wt/b", ActionRemove, "")
}

// The sweep has no by-record ownership: a recent owner still keeps the
// placed worktree.
func TestCleanupPlacedRowSweepUnchanged(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.placedWork("w")
	f.place(root, "wt/w")
	f.store.rootOwners = map[string][]int64{root: {testSession}}
	f.store.activity = []SessionActivity{{ID: testSession, WorkbenchID: testWorkbench, LastActive: time.Now()}}

	wantItem(t, f.plan(Request{Sweep: true}), "worktree:"+root, ActionKeep, ReasonSessionRecent)
}

func TestPlacedWorktreeIsTheLongestContainingRoot(t *testing.T) {
	t.Parallel()
	main := worktree{Root: "/r", Main: true}
	outer := worktree{Root: "/r/.claude/worktrees/a"}
	inner := worktree{Root: "/r/.claude/worktrees/a/sub"}
	sibling := worktree{Root: "/r/.claude/worktrees/ab"}
	all := []worktree{main, outer, inner, sibling}

	o := observed{placedCwd: "/r/.claude/worktrees/a/sub/app"}
	for _, c := range []struct {
		w    worktree
		want bool
	}{{main, false}, {outer, false}, {inner, true}, {sibling, false}} {
		if got := o.placedWorktree(c.w, all); got != c.want {
			t.Errorf("placedWorktree(%s) = %v, want %v", c.w.Root, got, c.want)
		}
	}
	if (observed{}).placedWorktree(inner, all) {
		t.Error("an unplaced row owns a worktree by record")
	}
	if (observed{placedCwd: "/r"}).placedWorktree(main, all) {
		t.Error("the main worktree is owned by record")
	}
}

func TestDBStore_CleanupSessionReadsThePlacement(t *testing.T) {
	s, _, id := storeFixture(t)
	got, err := s.CleanupSession(context.Background(), id)
	if err != nil {
		t.Fatal(err)
	}
	if got.PlacedCwd != "" || got.PlacedBranch != "" {
		t.Fatalf("an unplaced row = %+v, want no placement", got)
	}
	if _, err := s.DB.Exec(`UPDATE terminal_sessions SET worktree_branch = 'wt/a' WHERE id = ?`, id); err != nil {
		t.Fatal(err)
	}
	if got, err = s.CleanupSession(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	if got.PlacedCwd != "/tmp/example" || got.PlacedBranch != "wt/a" {
		t.Fatalf("a placed row = %+v, want /tmp/example on wt/a", got)
	}
}
