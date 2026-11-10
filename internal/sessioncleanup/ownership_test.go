package sessioncleanup

import (
	"context"
	"errors"
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

// scratchRoot is <base>/claude-<uid>/<slug>/<testUUID>/scratchpad/<name>.
func (f *fixture) scratchRoot(name string) string {
	return filepath.Join(f.base, fmt.Sprintf("claude-%d", os.Getuid()), "-tmp-acme", testUUID, "scratchpad", name)
}

// scratchWorktree adds a pushed worktree inside the Claude scratchpad of
// testUUID under f.base.
func (f *fixture) scratchWorktree(name, branch string) string {
	f.t.Helper()
	rel, err := filepath.Rel(f.base, f.scratchRoot(name))
	if err != nil {
		f.t.Fatal(err)
	}
	return f.pushedWork(rel, branch)
}

// ownUUID makes the test session a claude row that is testUUID's only
// owner, acquired at since.
func (f *fixture) ownUUID(since time.Time) {
	f.store.session.Kind = "claude"
	f.store.agentIDs = []db.AgentSessionID{{ID: "older-id", Since: "2026-10-01T00:00:00Z"}, {ID: testUUID, Since: since.UTC().Format(time.RFC3339)}}
	f.store.uuidOwners = map[string][]int64{testUUID: {testSession}}
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
	a := f.worktree("wt-a", "feat/a")
	b := f.pushedWork("wt-b", "feat/named")
	f.recordCommand("worktree", a, "feat/named")

	p := f.plan(Request{})
	wantItem(t, p, "worktree:"+a, ActionRemove, "")
	wantItem(t, p, "worktree:"+b, ActionRemove, "")
}

// A command run in another repository names nothing here, whichever its
// kind: its root is no worktree of the planned repository.
func TestProj18_CommandBranchFromOtherRepoNamesNothing(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	otherRepo := filepath.Join(f.base, "other")
	gitIn(t, f.base, "init", "-q", "-b", "main", "other")
	f.commit(otherRepo, "README.md", "other\n")
	otherWT := filepath.Join(f.base, "other-wt")
	gitIn(t, otherRepo, "worktree", "add", "-q", "-b", "feat/shared-wt", otherWT, "main")
	f.recordCommand("branch", otherRepo, "feat/shared")
	f.recordCommand("worktree", otherWT, "feat/shared-wt")
	f.recordCommand("worktree", filepath.Join(f.base, "gone"), "feat/shared-gone")

	mine := f.pushedWork("wt-mine", "feat/shared")
	mine2 := f.pushedWork("wt-mine2", "feat/shared-wt")
	mine3 := f.pushedWork("wt-mine3", "feat/shared-gone")

	p := f.plan(Request{})
	for _, key := range []string{"worktree:" + mine, "worktree:" + mine2, "worktree:" + mine3, "worktree:" + otherWT} {
		if hasItem(p, key) {
			t.Fatalf("%s was adopted through another repository's command: %+v", key, p.Items)
		}
	}
	for _, key := range []string{"branch:feat/shared", "branch:feat/shared-wt", "branch:feat/shared-gone"} {
		if hasItem(p, key) {
			t.Fatalf("%s was named through another repository's command: %+v", key, p.Items)
		}
	}
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
	f.ownUUID(time.Now().Add(-30 * time.Minute))
	root := f.scratchWorktree("lane", "feat/lane")

	p := f.plan(Request{})
	wantItem(t, p, "worktree:"+root, ActionRemove, "")
	// The branch checked out in an adopted lane is named: it goes too.
	wantItem(t, p, "branch:feat/lane", ActionRemove, "")

	// Every catch still applies: an uncommitted change keeps it.
	writeFile(t, filepath.Join(root, "dirty.txt"), "unsaved\n")
	wantItem(t, f.plan(Request{}), "worktree:"+root, ActionKeep, ReasonUncommittedChanges)
}

func wantNoLane(t *testing.T, p Plan, root, branch string) {
	t.Helper()
	if hasItem(p, "worktree:"+root) || hasItem(p, "branch:"+branch) {
		t.Fatalf("the scratchpad lane was adopted: %+v", p.Items)
	}
}

func TestProj18_ScratchpadUUIDSharedAdoptsNothing(t *testing.T) {
	f := newFixture(t)
	useScratchBases(t, f.base)
	f.ownUUID(time.Now().Add(-30 * time.Minute))
	f.store.uuidOwners[testUUID] = []int64{testSession, testSession + 1} // resumed in another tab
	root := f.scratchWorktree("lane", "feat/lane")
	wantNoLane(t, f.plan(Request{}), root, "feat/lane")

	// A uuid the row never had adopts nothing either.
	f.store.agentIDs = []db.AgentSessionID{{ID: "other-id", Since: "2026-10-01T00:00:00Z"}}
	f.store.uuidOwners = map[string][]int64{"other-id": {testSession}}
	wantNoLane(t, f.plan(Request{}), root, "feat/lane")
}

// A lane born before this row acquired the uuid was another row's (or
// another tab's) work: it is not adopted.
func TestProj18_ScratchpadLaneBornBeforeUUIDAcquiredIsNotAdopted(t *testing.T) {
	f := newFixture(t)
	useScratchBases(t, f.base)
	root := f.scratchWorktree("lane", "feat/lane")
	f.ownUUID(time.Now().Add(30 * time.Minute))
	wantNoLane(t, f.plan(Request{}), root, "feat/lane")
}

// The row that started the conversation was deleted first (its history
// cascaded away), so this row, which resumed it later, is the uuid's only
// owner: the lane, born before this row acquired the uuid, is still not
// adopted.
func TestScratchpadOtherOwnerDeletedFirstAdoptsNothing(t *testing.T) {
	f := newFixture(t)
	useScratchBases(t, f.base)
	root := f.scratchWorktree("lane", "feat/lane")
	resumed := time.Now().Add(10 * time.Minute)
	f.ownUUID(resumed)
	f.store.uuidOwners = map[string][]int64{testUUID: {testSession}} // only this row is left
	wantNoLane(t, f.plan(Request{}), root, "feat/lane")
}

// An unknown acquisition time or lane birth adopts nothing (fail closed).
func TestScratchpadUnknownTimesAdoptNothing(t *testing.T) {
	f := newFixture(t)
	useScratchBases(t, f.base)
	root := f.scratchWorktree("lane", "feat/lane")
	f.ownUUID(time.Now().Add(-30 * time.Minute))
	f.store.agentIDs[1].Since = "yesterday"
	wantNoLane(t, f.plan(Request{}), root, "feat/lane")

	f.ownUUID(time.Now().Add(-30 * time.Minute))
	f.birth = func(string) (time.Time, bool) { return time.Time{}, false }
	wantNoLane(t, f.plan(Request{}), root, "feat/lane")
}

// Codex rows have no Claude scratchpad (spec §2b): the rule is off.
func TestScratchpadCodexRowAdoptsNothing(t *testing.T) {
	f := newFixture(t)
	useScratchBases(t, f.base)
	root := f.scratchWorktree("lane", "feat/lane")
	f.ownUUID(time.Now().Add(-30 * time.Minute))
	f.store.session.Kind = "codex"
	wantNoLane(t, f.plan(Request{}), root, "feat/lane")
}

// A failed read of the agent session ids or their owners fails the plan:
// nothing is adopted, nothing removed.
func TestScratchpadReadFailureFailsThePlan(t *testing.T) {
	for name, set := range map[string]func(*fakeStore){
		"ids":    func(s *fakeStore) { s.idsErr = errors.New("injected") },
		"owners": func(s *fakeStore) { s.ownersErr = errors.New("injected") },
	} {
		t.Run(name, func(t *testing.T) {
			f := newFixture(t)
			useScratchBases(t, f.base)
			f.scratchWorktree("lane", "feat/lane")
			f.ownUUID(time.Now().Add(-30 * time.Minute))
			set(f.store)
			if res, err := PlanResult(context.Background(), f.deps(), Request{SessionID: testSession}); err == nil {
				t.Fatalf("PlanResult = %+v, want an error", res.Plan.Items)
			}
		})
	}
}

// The lane's branch still has to be born after the session started: a lane
// that checked out an older branch removes the worktree and keeps the branch.
func TestProj18_ScratchpadBranchOlderThanSessionIsKept(t *testing.T) {
	f := newFixture(t)
	useScratchBases(t, f.base)
	gitIn(t, f.repo, "branch", "feat/older", "main") // merged: only the age keeps it
	root := f.scratchRoot("lane")
	gitIn(t, f.repo, "worktree", "add", "-q", root, "feat/older")
	f.sessionCreated = time.Now().Add(time.Hour)
	f.birth = func(string) (time.Time, bool) { return time.Now().Add(2 * time.Hour), true } // the lane is younger
	f.ownUUID(time.Now().Add(-30 * time.Minute))

	p := f.plan(Request{})
	wantItem(t, p, "worktree:"+root, ActionRemove, "")
	wantItem(t, p, "branch:feat/older", ActionKeep, ReasonExistedBeforeSession)
}

// A scratchpad worktree older than the session is kept like any other.
func TestScratchpadWorktreeOlderThanSessionIsKept(t *testing.T) {
	f := newFixture(t)
	useScratchBases(t, f.base)
	f.ownUUID(time.Now().Add(-30 * time.Minute))
	root := f.scratchWorktree("lane", "feat/lane")
	f.sessionCreated = time.Now().Add(time.Hour)

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
	t0 := time.Date(2026, 10, 12, 9, 30, 0, 0, time.UTC)
	dirs := []string{fmt.Sprintf("/b/claude-%d", uid)}
	ids := map[string]time.Time{"u1": t0}
	for root, want := range map[string]bool{
		fmt.Sprintf("/b/claude-%d/slug/u1/scratchpad/x", uid): true,
		fmt.Sprintf("/b/claude-%d/slug/u1/x", uid):            true,
		fmt.Sprintf("/b/claude-%d/slug/u1", uid):              false, // the prefix itself
		fmt.Sprintf("/b/claude-%d/u1/x/y", uid):               false, // no slug segment
		fmt.Sprintf("/b/claude-%d/a/b/u1/x", uid):             false, // two segments before the uuid
		fmt.Sprintf("/b/claude-%d/slug/u2/x", uid):            false,
		fmt.Sprintf("/b/claude-%d/slug/u1x/x", uid):           false,
		fmt.Sprintf("/b/claude-%d/slug/u1-other/x", uid):      false,
		fmt.Sprintf("/b/claude-%d/slug/U1/x", uid):            false,
		fmt.Sprintf("/b/claude-%d/slug/u1/x", uid+1):          false,
		"/c/claude-0/slug/u1/x":                               false,
	} {
		since, got := scratchLane(dirs, ids, root)
		if got != want || (got && !since.Equal(t0)) {
			t.Errorf("scratchLane(%s) = %v, %v; want %v", root, since, got, want)
		}
	}
}

// Row A starts uuid U, row B resumes U and makes a lane, B is deleted first
// (its ledger cascades away): U is tombstoned, so A's plan still sees U as
// shared and adopts nothing of B's (worktree or branch). Real database.
func TestProj18_ScratchpadUUIDOfDeletedRowAdoptsNothing(t *testing.T) {
	f := newFixture(t)
	useScratchBases(t, f.base)
	d := db.OpenTestDB(t)
	wb, err := d.CreateWorkbench("acme", f.repo)
	if err != nil {
		t.Fatal(err)
	}
	start := time.Now().Add(-time.Hour).UTC().Format(time.RFC3339)
	insert := func(created string) int64 {
		t.Helper()
		res, err := d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id, created_at)
			VALUES (?, 'claude', 'T', ?, ?, ?)`, wb, f.repo, testUUID, created)
		if err != nil {
			t.Fatal(err)
		}
		id, _ := res.LastInsertId()
		if _, err := d.Exec(`UPDATE terminal_session_agent_sessions SET first_seen_at = ? WHERE terminal_session_id = ?`, created, id); err != nil {
			t.Fatal(err)
		}
		return id
	}
	a := insert(start)
	root := f.scratchWorktree("lane", "feat/lane")
	plan := func() Plan {
		t.Helper()
		deps := Deps{Git: SystemGit{}, DB: DBStore{DB: d}, Procs: f.procs, WorktreeBirth: stampBirth}
		res, err := PlanResult(context.Background(), deps, Request{SessionID: a})
		if err != nil {
			t.Fatalf("PlanResult: %v", err)
		}
		return res.Plan
	}
	// Control: A alone owns U and adopts its lane.
	p := plan()
	wantItem(t, p, "worktree:"+root, ActionRemove, "")
	wantItem(t, p, "branch:feat/lane", ActionRemove, "")

	b := insert(start)
	if _, err := d.Exec(`DELETE FROM terminal_sessions WHERE id = ?`, b); err != nil {
		t.Fatal(err)
	}
	wantNoLane(t, plan(), root, "feat/lane")
}
