package sessioncleanup

import (
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"watchtower/internal/db"
)

// recordCommand adds a command ledger row (auto cleanup spec 2026-11-10
// §2a): kind "worktree" with its root and branch, or kind "branch" whose
// root is the repository's top level.
func (f *fixture) recordCommand(kind, root, branch string) {
	f.store.ledger = append(f.store.ledger, db.SessionWorktree{
		Root: root, Branch: branch, FirstAt: "2026-10-12T12:00:00.000Z", Source: "command", Kind: kind,
	})
}

// useScratchBases points scratchBases at bases for one test. Tests that call
// it must not be parallel: scratchBases is a package variable.
func useScratchBases(t *testing.T, bases ...string) {
	t.Helper()
	prev := scratchBases
	scratchBases = func() []string { return bases }
	t.Cleanup(func() { scratchBases = prev })
}

const testUUID = "0b7c2a4e-1d3f-4a5b-9c8d-7e6f5a4b3c2d"

// scratchWorktree adds a pushed worktree inside the Claude scratchpad of
// testUUID under f.base: <base>/claude-<uid>/<slug>/<uuid>/scratchpad/<name>.
func (f *fixture) scratchWorktree(name, branch string) string {
	f.t.Helper()
	rel := filepath.Join(fmt.Sprintf("claude-%d", os.Getuid()), "-tmp-acme", testUUID, "scratchpad", name)
	return f.pushedWork(rel, branch)
}

func TestProj18_CommandLedgerAdoptsWorktree(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.worktree("wt-agent", "feat/agent") // merged: HEAD is main's
	f.recordCommand("worktree", root, "feat/agent")
	// A branch row's root is the repository's top level and never a
	// worktree root: a linked worktree recorded there adopts nothing.
	other := f.pushedWork("wt-other", "feat/other")
	f.recordCommand("branch", other, "feat/elsewhere")

	p := f.plan(Request{})
	wantItem(t, p, "worktree:"+root, ActionRemove, "")
	wantItem(t, p, "branch:feat/agent", ActionRemove, "")
	if hasItem(p, "worktree:"+other) {
		t.Fatalf("a branch row's root was adopted as a worktree: %+v", p.Items)
	}
}

// The agent's worktree branch counts as named: a worktree with it checked
// out is observed although its root was never recorded.
func TestCommandWorktreeBranchIsNamed(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.pushedWork("wt-moved", "feat/named")
	f.recordCommand("worktree", filepath.Join(f.base, "wt-typo"), "feat/named")

	wantItem(t, f.plan(Request{}), "worktree:"+root, ActionRemove, "")
}

func TestProj18_CommandNamedBranchOlderThanSessionIsKept(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	gitIn(t, f.repo, "branch", "feat/old", "main") // merged: only the age keeps it
	wt := f.pushedWork("wt-old", "feat/old-wt")
	f.sessionCreated = time.Now().Add(time.Hour) // another session made both earlier
	f.recordCommand("branch", f.repo, "feat/old")
	f.recordCommand("branch", f.repo, "feat/old-wt") // a failed `git checkout -b feat/old-wt`

	p := f.plan(Request{})
	wantItem(t, p, "branch:feat/old", ActionKeep, ReasonExistedBeforeSession)
	wantItem(t, p, "worktree:"+wt, ActionKeep, ReasonExistedBeforeSession)
	wantItem(t, p, "branch:feat/old-wt", ActionKeep, ReasonCheckedOut)
}

func TestProj18_CommandRowUnpushedIsKept(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.worktree("wt", "feat/x")
	f.commit(root, "local.txt", "only here\n")
	f.recordCommand("worktree", root, "feat/x")
	gitIn(t, f.repo, "branch", "feat/alone", "feat/x")
	f.recordCommand("branch", f.repo, "feat/alone")

	p := f.plan(Request{})
	wantItem(t, p, "worktree:"+root, ActionKeep, ReasonUnpushedCommits)
	wantItem(t, p, "branch:feat/x", ActionKeep, ReasonCheckedOut)
	wantItem(t, p, "branch:feat/alone", ActionKeep, ReasonUnpushedCommits)
}

func TestProj18_ScratchpadWorktreeIsTheSessions(t *testing.T) {
	f := newFixture(t)
	useScratchBases(t, f.base)
	root := f.scratchWorktree("lane", "feat/lane")
	f.store.agentIDs = []string{"older-id", testUUID}
	f.store.uuidOwners = map[string][]int64{testUUID: {testSession}}

	p := f.plan(Request{})
	wantItem(t, p, "worktree:"+root, ActionRemove, "")
	// The scratchpad adopts the worktree only (spec §2b): its branch needs a
	// ledger or named source of its own, as a placed row's other branches do.
	wantItem(t, p, "branch:feat/lane", ActionKeep, ReasonNotThisSession)

	// Every catch still applies: an uncommitted change keeps it.
	writeFile(t, filepath.Join(root, "dirty.txt"), "unsaved\n")
	wantItem(t, f.plan(Request{}), "worktree:"+root, ActionKeep, ReasonUncommittedChanges)
}

func TestProj18_ScratchpadUUIDSharedAdoptsNothing(t *testing.T) {
	f := newFixture(t)
	useScratchBases(t, f.base)
	root := f.scratchWorktree("lane", "feat/lane")
	f.store.agentIDs = []string{testUUID}
	f.store.uuidOwners = map[string][]int64{testUUID: {testSession, testSession + 1}} // resumed in another tab

	p := f.plan(Request{})
	if hasItem(p, "worktree:"+root) || hasItem(p, "branch:feat/lane") {
		t.Fatalf("a shared uuid adopted the scratchpad worktree: %+v", p.Items)
	}

	// A uuid the row never had adopts nothing either.
	f.store.agentIDs = []string{"other-id"}
	f.store.uuidOwners = map[string][]int64{"other-id": {testSession}}
	if p := f.plan(Request{}); hasItem(p, "worktree:"+root) {
		t.Fatalf("another uuid's scratchpad was adopted: %+v", p.Items)
	}
}

// A scratchpad worktree older than the session is kept like any other.
func TestScratchpadWorktreeOlderThanSessionIsKept(t *testing.T) {
	f := newFixture(t)
	useScratchBases(t, f.base)
	root := f.scratchWorktree("lane", "feat/lane")
	f.sessionCreated = time.Now().Add(time.Hour)
	f.store.agentIDs = []string{testUUID}
	f.store.uuidOwners = map[string][]int64{testUUID: {testSession}}

	wantItem(t, f.plan(Request{}), "worktree:"+root, ActionKeep, ReasonExistedBeforeSession)
}

func TestScratchBases_IncludeSlashTmpWhateverTMPDIR(t *testing.T) {
	tmp, err := filepath.EvalSymlinks("/tmp")
	if err != nil {
		t.Skip("no /tmp here")
	}
	other := t.TempDir()
	t.Setenv("TMPDIR", other)
	t.Setenv("CLAUDE_CODE_TMPDIR", other)
	got := scratchBases()
	if !slices.Contains(got, tmp) {
		t.Fatalf("scratchBases() = %v, want it to hold %s", got, tmp)
	}
	otherResolved, err := filepath.EvalSymlinks(other)
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Contains(got, otherResolved) {
		t.Fatalf("scratchBases() = %v, want it to hold TMPDIR %s", got, otherResolved)
	}
	seen := map[string]bool{}
	for _, b := range got {
		if seen[b] {
			t.Fatalf("scratchBases() = %v has %s twice", got, b)
		}
		seen[b] = true
	}
}

func TestScratchLaneMatch(t *testing.T) {
	uid := os.Getuid()
	o := observed{scratch: []string{fmt.Sprintf("/b/claude-%d", uid)}, scratchIDs: map[string]bool{"u1": true}}
	for root, want := range map[string]bool{
		fmt.Sprintf("/b/claude-%d/slug/u1/scratchpad/x", uid): true,
		fmt.Sprintf("/b/claude-%d/slug/u1/x", uid):            true,
		fmt.Sprintf("/b/claude-%d/slug/u1", uid):              false, // the prefix itself
		fmt.Sprintf("/b/claude-%d/u1/x/y", uid):               false, // no slug segment
		fmt.Sprintf("/b/claude-%d/a/b/u1/x", uid):             false, // two segments before the uuid
		fmt.Sprintf("/b/claude-%d/slug/u2/x", uid):            false,
		fmt.Sprintf("/b/claude-%d/slug/u1/x", uid+1):          false,
		"/c/claude-0/slug/u1/x":                               false,
	} {
		if got := o.inScratch(root); got != want {
			t.Errorf("inScratch(%s) = %v, want %v", root, got, want)
		}
	}
}
