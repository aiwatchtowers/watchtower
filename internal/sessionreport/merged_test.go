package sessionreport

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// mergedFixture (board #986): session 1 bound to epic 100 on feature/x.
// Group 110 carries no branch, so its leaves' base is the epic's branch;
// group 120 carries feature/x-ui, the base of its own leaves.
//
//	111 done        wt/a  (merged, but done counts as done)
//	112 in_review   wt/b  merged
//	113 todo        wt/c  merged (git decides, not the status)
//	114 in_progress feature/x (the epic's own branch: never merged)
//	115 todo        no branch
//	116 blocked     wt/f  open
//	121 in_progress wt/g  merged into feature/x-ui
//	122 todo        feature/x-ui (its group's branch: never merged)
func mergedFixture(t *testing.T) *db.DB {
	t.Helper()
	d := db.OpenTestDB(t)
	runSQL(t, d, `INSERT INTO projects (id, name, folder_path) VALUES (1, 'acme', '/tmp/acme');
		INSERT INTO targets (id, text, period_start, period_end, parent_id, status, project_id, branch) VALUES
		(100, 'Epic', '2026-09-28', '2026-10-05', NULL, 'in_progress', 1, 'feature/x'),
		(110, 'Group', '2026-09-28', '2026-10-05', 100, 'in_progress', 1, ''),
		(111, 'a', '2026-09-28', '2026-10-05', 110, 'done', 1, 'wt/a'),
		(112, 'b', '2026-09-28', '2026-10-05', 110, 'in_review', 1, 'wt/b'),
		(113, 'c', '2026-09-28', '2026-10-05', 110, 'todo', 1, 'wt/c'),
		(114, 'd', '2026-09-28', '2026-10-05', 110, 'in_progress', 1, 'feature/x'),
		(115, 'e', '2026-09-28', '2026-10-05', 110, 'todo', 1, ''),
		(116, 'f', '2026-09-28', '2026-10-05', 110, 'blocked', 1, 'wt/f'),
		(120, 'UI', '2026-09-28', '2026-10-05', 100, 'in_progress', 1, 'feature/x-ui'),
		(121, 'g', '2026-09-28', '2026-10-05', 120, 'in_progress', 1, 'wt/g'),
		(122, 'h', '2026-09-28', '2026-10-05', 120, 'todo', 1, 'feature/x-ui');
		INSERT INTO terminal_sessions (id, project_id, kind, title, target_id, folder_path, claude_session_id) VALUES
		(1, 1, 'claude', 'S1', 100, '/tmp/acme', 'u1');
		INSERT INTO workbench_pr_states (project_id, ref, state, checked_at) VALUES
		(1, 'into:feature/x:wt/a', 'merged', '2026-10-02T12:00:00Z'),
		(1, 'into:feature/x:wt/b', 'merged', '2026-10-02T12:00:00Z'),
		(1, 'into:feature/x:wt/c', 'merged', '2026-10-02T12:00:00Z'),
		(1, 'into:feature/x:feature/x', 'merged', '2026-10-02T12:00:00Z'),
		(1, 'into:feature/x:wt/f', 'open', '2026-10-02T12:00:00Z'),
		(1, 'into:feature/x-ui:wt/g', 'merged', '2026-10-02T12:00:00Z'),
		(1, 'into:feature/x:wt/g', 'open', '2026-10-02T12:00:00Z'),
		(1, 'into:feature/x:feature/x-ui', 'merged', '2026-10-02T12:00:00Z')`)
	return d
}

// TestProj14_MergedLeafCountsAsMerged (board #986, ask #525): a not-done
// leaf whose branch git found in its base counts as merged, apart from done,
// in the report, the row line and the phases.
func TestProj14_MergedLeafCountsAsMerged(t *testing.T) {
	d := mergedFixture(t)
	r := build(t, d, 1)
	assert.Equal(t, Progress{Done: 1, Total: 8, Merged: 3}, r.Progress, "112, 113 and 121")
	s := summaryOf(t, d, 1)
	assert.Equal(t, []int{1, 8, 3}, []int{s.Done, s.Total, s.Merged}, "the row line agrees")

	g := phaseByID(t, r.Phases, 110)
	assert.Equal(t, []int{1, 6, 2}, []int{g.Done, g.Total, g.Merged})
	ui := phaseByID(t, r.Phases, 120)
	assert.Equal(t, []int{0, 2, 1}, []int{ui.Done, ui.Total, ui.Merged})

	// Nothing merged: the numbers are today's.
	runSQL(t, d, `DELETE FROM workbench_pr_states`)
	assert.Equal(t, Progress{Done: 1, Total: 8}, build(t, d, 1).Progress)
}

// TestProj14_SharedBranchNeverCountsMerged: a leaf on its nearest
// branch-carrying ancestor's own branch, or with no branch, is never merged,
// whatever the cache holds.
func TestProj14_SharedBranchNeverCountsMerged(t *testing.T) {
	d := mergedFixture(t)
	runSQL(t, d, `UPDATE targets SET branch = '' WHERE id IN (112, 113, 121)`)
	assert.Equal(t, Progress{Done: 1, Total: 8}, build(t, d, 1).Progress)
}

func TestMergeBase(t *testing.T) {
	d := mergedFixture(t)
	b, err := loadBoard(d, 1)
	require.NoError(t, err)
	for id, want := range map[int64]string{
		111: "feature/x", 112: "feature/x", 116: "feature/x", 121: "feature/x-ui",
		114: "", 115: "", 122: "", 100: "", 120: "feature/x",
	} {
		base, _, ok := b.mergeBase(b.byID[id])
		assert.Equal(t, want != "", ok, "target %d", id)
		assert.Equal(t, want, base, "target %d", id)
	}
}

func TestSessionMergeRefs_NotDoneLeavesWithABase(t *testing.T) {
	d := mergedFixture(t)
	refs, err := SessionMergeRefs(context.Background(), d, 1, 1)
	require.NoError(t, err)
	assert.ElementsMatch(t, []string{"into:feature/x:wt/b", "into:feature/x:wt/c", "into:feature/x:wt/f",
		"into:feature/x-ui:wt/g"}, refs)
	all, err := WorkbenchMergeRefs(context.Background(), d, 1)
	require.NoError(t, err)
	assert.Equal(t, refs, all)
}

// newFeatureRepo builds main and feature/x (one commit), with leaf branches
// cut from feature/x: wt/m merged into it, wt/fresh with no commits of its
// own and wt/open with a commit feature/x lacks.
func newFeatureRepo(t *testing.T) string {
	t.Helper()
	gitEnv(t)
	dir := t.TempDir()
	gitRun(t, dir, "init", "-q", "-b", "main")
	commitFile(t, dir, "README.md", "init")
	gitRun(t, dir, "checkout", "-q", "-b", "feature/x")
	commitFile(t, dir, "x.txt", "x")
	gitRun(t, dir, "checkout", "-q", "-b", "wt/m")
	commitFile(t, dir, "m.txt", "m")
	gitRun(t, dir, "checkout", "-q", "feature/x")
	gitRun(t, dir, "merge", "-q", "--no-ff", "-m", "merge m", "wt/m")
	gitRun(t, dir, "branch", "wt/fresh")
	gitRun(t, dir, "checkout", "-q", "-b", "wt/open")
	commitFile(t, dir, "o.txt", "o")
	gitRun(t, dir, "checkout", "-q", "main")
	return dir
}

// TestProj14_MergedSurvivesBranchCleanup: git reads the verdicts; once
// session cleanup deletes the merged branch the cached merged stays.
func TestProj14_MergedSurvivesBranchCleanup(t *testing.T) {
	dir := newFeatureRepo(t)
	calls := ghStub(t)
	d, id := newWorkbench(t, dir)
	refs := []string{"into:feature/x:wt/m", "into:feature/x:wt/fresh", "into:feature/x:wt/open", "into:feature/x:wt/gone",
		"into:nope:wt/m"}
	res := Refresh(context.Background(), d, id, refs, RefreshOptions{Network: true, Now: fixedNow})
	assert.Contains(t, res.Note, "base branch nope could not be resolved")
	assert.Empty(t, calls(), "a merge verdict never runs gh")
	got := states(t, d, id)
	assert.Equal(t, "merged", got["into:feature/x:wt/m"].State)
	assert.Equal(t, "open", got["into:feature/x:wt/fresh"].State, "a fresh branch has no work of its own")
	assert.Equal(t, "open", got["into:feature/x:wt/open"].State)
	assert.NotContains(t, got, "into:feature/x:wt/gone", "a missing branch is no conclusion")
	assert.NotContains(t, got, "into:nope:wt/m", "a missing base is no conclusion")

	gitRun(t, dir, "branch", "-q", "-D", "wt/m")
	later := func() time.Time { return refreshNow.Add(time.Hour) }
	Refresh(context.Background(), d, id, refs[:1], RefreshOptions{Now: later})
	assert.Equal(t, "merged", states(t, d, id)["into:feature/x:wt/m"].State, "the cleaned-up branch stays merged")
}

// TestProj14_MergeRefreshWritesOnlyThePRCache: the merge refresh writes
// workbench_pr_states and nothing on the board.
func TestProj14_MergeRefreshWritesOnlyThePRCache(t *testing.T) {
	dir := newFeatureRepo(t)
	d, id := newWorkbench(t, dir)
	for _, table := range []string{"targets", "project_comments", "target_status_history", "owner_asks",
		"terminal_sessions", "terminal_session_targets"} {
		for _, op := range []string{"INSERT", "UPDATE", "DELETE"} {
			runSQL(t, d, `CREATE TRIGGER proj14m_`+table+`_`+op+` BEFORE `+op+` ON `+table+
				` BEGIN SELECT RAISE(ABORT, 'PROJ-14: the merge refresh wrote `+table+`'); END`)
		}
	}
	res := Refresh(context.Background(), d, id, []string{"into:feature/x:wt/m"}, RefreshOptions{Now: fixedNow})
	assert.Empty(t, res.Note)
	assert.Equal(t, "merged", states(t, d, id)["into:feature/x:wt/m"].State)
}

// A merge verdict alone reads neither the default branch nor gh: only git
// against its base.
func TestRefresh_MergeRefsOnlyReadTheirBase(t *testing.T) {
	dir := newFeatureRepo(t)
	calls := ghStub(t)
	d, id := newWorkbench(t, dir)
	var gitArgs [][]string
	prev := run
	run = func(ctx context.Context, dir string, stdin []byte, name string, args ...string) ([]byte, int, error) {
		if name == "git" {
			gitArgs = append(gitArgs, args)
		}
		return prev(ctx, dir, stdin, name, args...)
	}
	t.Cleanup(func() { run = prev })
	Refresh(context.Background(), d, id, []string{"into:feature/x:wt/m", "into:feature/x:wt/open"},
		RefreshOptions{Network: true, Now: fixedNow})
	assert.Empty(t, calls())
	for _, a := range gitArgs {
		assert.NotContains(t, a, "refs/remotes/origin/HEAD", "the default branch is never looked up")
	}
	n := 0
	for _, a := range gitArgs {
		if len(a) > 0 && a[0] == "for-each-ref" {
			n++
		}
	}
	assert.Equal(t, 1, n, "one batch read serves every leaf of a base")
}

func TestRefresh_BadIntoRefIsSkipped(t *testing.T) {
	dir := newFeatureRepo(t)
	d, id := newWorkbench(t, dir)
	res := Refresh(context.Background(), d, id, []string{"into:feature/x", "into::wt/m"}, RefreshOptions{Now: fixedNow})
	assert.Contains(t, res.Note, "the state of 2 ref(s) could not be read")
	assert.Empty(t, states(t, d, id))
}
