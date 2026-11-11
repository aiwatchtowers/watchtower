package sessionreport

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/gitbin"
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

// mergeRefsOf is session sessionID's into: refs.
func mergeRefsOf(t *testing.T, d *db.DB, sessionID int64) []string {
	t.Helper()
	_, sc, err := loadScope(context.Background(), d, 1, sessionID)
	require.NoError(t, err)
	return sc.mergeRefs()
}

func TestSessionRefs_EndWithTheMergeVerdicts(t *testing.T) {
	d := mergedFixture(t)
	want := []string{"into:feature/x:wt/b", "into:feature/x:wt/f", "into:feature/x:wt/c",
		"into:feature/x-ui:wt/g"}
	assert.Equal(t, want, mergeRefsOf(t, d, 1), "board order of first appearance")
	refs, err := SessionRefs(context.Background(), d, 1, 1)
	require.NoError(t, err)
	assert.Equal(t, mergeRefsOf(t, d, 1), refs[len(refs)-len(want):], "the PR and branch refs, then the verdicts")
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
	assert.Contains(t, res.Note, "the state of 1 ref(s) could not be read (into:nope:wt/m: git could not read its merge state)",
		"a failed read is counted; the missing wt/gone stays quiet")
	assert.Empty(t, calls(), "a merge verdict never runs gh")
	got := states(t, d, id)
	assert.Equal(t, "merged", got["into:feature/x:wt/m"].State)
	assert.Equal(t, "open", got["into:feature/x:wt/fresh"].State, "a fresh branch has no work of its own")
	assert.Equal(t, "open", got["into:feature/x:wt/open"].State)
	assert.Equal(t, "unknown", got["into:feature/x:wt/gone"].State, "a missing branch is no conclusion, only stamped")
	assert.Equal(t, "unknown", got["into:nope:wt/m"].State, "a missing base is no conclusion, only stamped")

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
	for _, feature := range []string{"installed-git", "supported", "unsupported"} {
		t.Run(feature, func(t *testing.T) {
			dir := newFeatureRepo(t)
			calls := ghStub(t)
			d, id := newWorkbench(t, dir)
			prev := run
			// Build the supported atom's fixture from this real repository,
			// before counting Refresh calls. This exercises both paths even
			// on a machine whose installed git predates %(ahead-behind).
			baseOut, _, err := prev(context.Background(), dir, nil, "git", "rev-parse", "refs/heads/feature/x")
			require.NoError(t, err)
			base := strings.TrimSpace(string(baseOut))
			format := "--format=%(objecttype) %(refname) %(objectname) %(committerdate:unix)"
			refs, _, err := prev(context.Background(), dir, nil, "git", "for-each-ref", format, "refs/heads", "refs/remotes/origin")
			require.NoError(t, err)
			var rows []string
			for _, row := range strings.Split(strings.TrimSpace(string(refs)), "\n") {
				fields := strings.Fields(row)
				require.Len(t, fields, 4)
				counts, _, err := prev(context.Background(), dir, nil, "git", "rev-list", "--left-right", "--count", fields[1]+"..."+base)
				require.NoError(t, err)
				rows = append(rows, row+" "+strings.TrimSpace(string(counts)))
			}
			var gitArgs [][]string
			probes, probeFailures := 0, 0
			run = func(ctx context.Context, dir string, stdin []byte, name string, args ...string) ([]byte, int, error) {
				if name == "git" {
					gitArgs = append(gitArgs, args)
				}
				atom := name == "git" && len(args) > 1 && args[0] == "for-each-ref" && strings.Contains(args[1], "%(ahead-behind:")
				if atom {
					probes++
					if feature == "supported" {
						return []byte(strings.Join(rows, "\n") + "\n"), 0, nil
					}
					if feature == "unsupported" {
						probeFailures++
						return nil, 128, fmt.Errorf("fixture git has no ahead-behind atom")
					}
				}
				out, code, err := prev(ctx, dir, stdin, name, args...)
				if atom && err != nil {
					probeFailures++
				}
				return out, code, err
			}
			t.Cleanup(func() { run = prev })
			Refresh(context.Background(), d, id, []string{"into:feature/x:wt/m", "into:feature/x:wt/open"},
				RefreshOptions{Network: true, Now: fixedNow})
			assert.Empty(t, calls())
			batches, metadataReads, rawReads := 0, 0, 0
			for _, args := range gitArgs {
				assert.NotContains(t, args, "refs/remotes/origin/HEAD", "the default branch is never looked up")
				if len(args) == 0 || args[0] != "for-each-ref" {
					continue
				}
				rawReads++
				require.GreaterOrEqual(t, len(args), 4)
				assert.Equal(t, []string{"refs/heads", "refs/remotes/origin"}, args[len(args)-2:], "every batch serves all leaves")
				switch {
				case strings.Contains(args[1], "%(ahead-behind:"):
					assert.Equal(t, format+" %(ahead-behind:"+base+")", args[1])
					if probeFailures == 0 {
						batches++
					}
				case strings.HasPrefix(args[1], "--merged="):
					assert.Equal(t, "--merged="+base, args[1], "only the requested base is queried")
					batches++
				default:
					assert.Equal(t, format, args[1])
					metadataReads++
				}
			}
			assert.Equal(t, 1, batches, "one semantic merged-base batch serves every leaf of a base")
			assert.Equal(t, 1, probes, "feature support is probed once, never per leaf")
			assert.LessOrEqual(t, probeFailures, 1)
			assert.Equal(t, probeFailures, metadataReads, "legacy metadata is read only after a failed feature probe")
			assert.Equal(t, 1+2*probeFailures, rawReads, "only the fixed-cost compatibility path may add commands")
			if feature == "supported" {
				assert.Zero(t, probeFailures)
			}
			if feature == "unsupported" {
				assert.Equal(t, 1, probeFailures)
			}
			got := states(t, d, id)
			assert.Equal(t, "merged", got["into:feature/x:wt/m"].State)
			assert.Equal(t, "open", got["into:feature/x:wt/open"].State)
		})
	}
}

func TestRefresh_BadIntoRefIsSkipped(t *testing.T) {
	dir := newFeatureRepo(t)
	d, id := newWorkbench(t, dir)
	res := Refresh(context.Background(), d, id, []string{"into:feature/x", "into::wt/m"}, RefreshOptions{Now: fixedNow})
	assert.Contains(t, res.Note, "the state of 2 ref(s) could not be read")
	assert.Empty(t, states(t, d, id))
}

// TestProj14_MergedSurvivesCleanupOfAPushedBranch (review F1): a branch
// pushed, merged into its base by a fast-forward and then deleted locally by
// session cleanup is read from origin, where git cannot tell the merge from
// a branch with no work; the cached merged stays. Without a merged row the
// same origin-only shape reads open.
func TestProj14_MergedSurvivesCleanupOfAPushedBranch(t *testing.T) {
	dir := newFeatureRepo(t)
	gitRun(t, dir, "checkout", "-q", "feature/x")
	gitRun(t, dir, "checkout", "-q", "-b", "wt/ff")
	commitFile(t, dir, "ff.txt", "ff")
	gitRun(t, dir, "checkout", "-q", "feature/x")
	gitRun(t, dir, "merge", "-q", "--ff-only", "wt/ff")
	gitRun(t, dir, "checkout", "-q", "main")
	gitRun(t, dir, "update-ref", "refs/remotes/origin/wt/ff", "wt/ff") // pushed
	gitRun(t, dir, "update-ref", "refs/remotes/origin/wt/pushedfresh", "feature/x")
	d, id := newWorkbench(t, dir)
	ref := "into:feature/x:wt/ff"

	Refresh(context.Background(), d, id, []string{ref}, RefreshOptions{Now: fixedNow})
	require.Equal(t, "merged", states(t, d, id)[ref].State)

	gitRun(t, dir, "branch", "-q", "-D", "wt/ff") // session cleanup
	later := refreshNow.Add(time.Hour)
	Refresh(context.Background(), d, id, []string{ref, "into:feature/x:wt/pushedfresh"},
		RefreshOptions{Now: func() time.Time { return later }})
	got := states(t, d, id)
	assert.Equal(t, "merged", got[ref].State, "the cleaned-up, still pushed branch stays merged")
	assert.Equal(t, later.Format(time.RFC3339), got[ref].CheckedAt, "kept, but stamped: it backs off")
	assert.Equal(t, "open", got["into:feature/x:wt/pushedfresh"].State, "no merged row: origin's word stands")
}

// Review F2: a ref that reads no verdict is stamped, so it backs off, and
// the least recently checked refs go first.
func TestRefresh_UnresolvableRefsBackOffAndGoLast(t *testing.T) {
	dir := newFeatureRepo(t)
	d, id := newWorkbench(t, dir)
	gone, ok := "into:feature/x:wt/gone", "into:feature/x:wt/m"
	Refresh(context.Background(), d, id, []string{gone}, RefreshOptions{Now: fixedNow})
	require.Equal(t, "unknown", states(t, d, id)[gone].State)

	gits := countGit(t)
	Refresh(context.Background(), d, id, []string{gone}, RefreshOptions{Now: func() time.Time { return refreshNow.Add(30 * time.Second) }})
	assert.Zero(t, gits(), "a stamped ref is fresh: no git")

	// Both stale: the never-checked ref is read first, so a budget that
	// allows one read spends it there.
	var mu sync.Mutex
	tick := 0
	clock := func() time.Time {
		mu.Lock()
		defer mu.Unlock()
		tick++
		return refreshNow.Add(2*time.Minute + time.Duration(tick)*4*time.Second)
	}
	res := Refresh(context.Background(), d, id, []string{gone, ok}, RefreshOptions{Budget: 10 * time.Second, Now: clock})
	assert.Contains(t, res.Note, "1 ref(s) keep their cached state")
	got := states(t, d, id)
	assert.Equal(t, "merged", got[ok].State, "read first")
	assert.Equal(t, refreshNow.Format(time.RFC3339), got[gone].CheckedAt, "not reached")
}

// Review F3: a phase counts merged over every leaf under its parent, so the
// refresh names those leaves' refs too, not only the progress leaves'.
func TestMergeRefs_CoverThePhaseLeaves(t *testing.T) {
	d := mergedFixture(t)
	runSQL(t, d, `UPDATE terminal_sessions SET target_id = NULL WHERE id = 1;
		INSERT INTO terminal_session_targets (session_id, target_id, first_at, last_at) VALUES
		(1, 112, '2026-10-01T10:00:00Z', '2026-10-01T10:00:00Z')`)
	r := build(t, d, 1)
	assert.Equal(t, Progress{Total: 1, Merged: 1}, r.Progress, "rule 2: 112 only")
	g := phaseByID(t, r.Phases, 110)
	assert.Equal(t, []int{1, 6, 2}, []int{g.Done, g.Total, g.Merged}, "the phase counts its whole group")
	assert.ElementsMatch(t, []string{"into:feature/x:wt/b", "into:feature/x:wt/c", "into:feature/x:wt/f"}, mergeRefsOf(t, d, 1),
		"every not-done leaf the phase counts is refreshed")
}

// Review F10: the row lines' refresh stops at SummaryRefreshBudget — here
// a fake clock moving 1 s per git call, on a real repository — keeps the
// verdicts it did not reach, marks the row's merged share stale and still
// returns the row line, its counts from the cache.
func TestRefreshedSummaries_StopAtTheSummaryBudget(t *testing.T) {
	d, id, _, _ := repoBoard(t)
	var mu sync.Mutex
	now := refreshNow
	clock := func() time.Time {
		mu.Lock()
		defer mu.Unlock()
		return now
	}
	prev := run
	run = func(ctx context.Context, dir string, stdin []byte, name string, args ...string) ([]byte, int, error) {
		mu.Lock()
		now = now.Add(time.Second)
		mu.Unlock()
		return prev(ctx, dir, stdin, name, args...)
	}
	t.Cleanup(func() { run = prev })
	rows, res, err := RefreshedSummaries(context.Background(), d, id, RefreshOptions{Now: clock})
	require.NoError(t, err)
	assert.Contains(t, res.Note, "the 3s time budget ran out")
	got := states(t, d, id)
	assert.NotEmpty(t, got, "the refs read before the budget's end are stored")
	assert.Less(t, len(got), 3, "a ref past the budget is not read")
	require.Len(t, rows, 1)
	assert.Equal(t, 3, rows[0].Total)
	assert.True(t, rows[0].MergedStale, "a verdict the row reads was not checked")
}

// Review H2: a squash read the filter guard refused leaves the verdict
// unknown, and the note says why.
func TestRefresh_RefusedSquashReadIsNamed(t *testing.T) {
	dir := newFeatureRepo(t)
	d, id := newWorkbench(t, dir)
	prev := run
	run = func(ctx context.Context, dir string, stdin []byte, name string, args ...string) ([]byte, int, error) {
		if name == "git" && len(args) > 0 && args[0] == "diff" {
			return nil, -1, fmt.Errorf("%w: test", gitbin.ErrFilterGuard)
		}
		return prev(ctx, dir, stdin, name, args...)
	}
	t.Cleanup(func() { run = prev })
	ref := "into:feature/x:wt/open"
	res := Refresh(context.Background(), d, id, []string{ref}, RefreshOptions{Now: fixedNow})
	assert.Contains(t, res.Note, "squash-merge checks skipped: "+gitbin.ErrFilterGuard.Error())
	assert.Contains(t, res.Note, "the state of 1 ref(s) could not be read ("+ref)
	assert.Equal(t, "unknown", states(t, d, id)[ref].State, "no verdict without the squash read")
}

// Review (test gap 1): the --session refresh mixes the kinds. One Refresh
// over a PR, a branch and a merge verdict reads the PR through gh, the
// branch against the default branch and the verdict against its own base,
// with no note.
func TestRefresh_MixedRefKinds(t *testing.T) {
	dir := newFeatureRepo(t)
	calls := ghStub(t)
	d, id := newWorkbench(t, dir)
	res := Refresh(context.Background(), d, id, []string{"pr:12", "branch:wt/m", "into:feature/x:wt/m"},
		RefreshOptions{Network: true, Now: fixedNow})
	assert.Empty(t, res.Note)
	assert.Contains(t, calls(), "pr view 12 --json state,title,additions,deletions,mergedAt")
	got := states(t, d, id)
	assert.Equal(t, "merged", got["pr:12"].State)
	assert.Equal(t, "none", got["branch:wt/m"].State, "no PR, and not merged into main")
	assert.Equal(t, "merged", got["into:feature/x:wt/m"].State, "merged into its own base")
}

// Review (test gap 3): a cached merged verdict whose local branch gains new
// work reads open again.
func TestRefresh_MergedBranchWithNewWorkReadsOpen(t *testing.T) {
	dir := newFeatureRepo(t)
	d, id := newWorkbench(t, dir)
	ref := "into:feature/x:wt/m"
	Refresh(context.Background(), d, id, []string{ref}, RefreshOptions{Now: fixedNow})
	require.Equal(t, "merged", states(t, d, id)[ref].State)

	gitRun(t, dir, "checkout", "-q", "wt/m")
	commitFile(t, dir, "more.txt", "more")
	gitRun(t, dir, "checkout", "-q", "main")
	later := refreshNow.Add(time.Hour)
	res := Refresh(context.Background(), d, id, []string{ref}, RefreshOptions{Now: func() time.Time { return later }})
	assert.Empty(t, res.Note)
	assert.Equal(t, "open", states(t, d, id)[ref].State, "unmerged work on the branch again")
}

// siblingsBoard is a database whose session 1 works epic 100 with group
// 110 of n sibling leaves (every tenth done), and the refs mergeRefs owes:
// one per not-done leaf, in board order.
func siblingsBoard(t *testing.T, n int) (*db.DB, []string) {
	t.Helper()
	d := db.OpenTestDB(t)
	runSQL(t, d, `INSERT INTO projects (id, name, folder_path) VALUES (1, 'acme', '/tmp/acme');
		INSERT INTO targets (id, text, period_start, period_end, parent_id, status, project_id, branch) VALUES
		(100, 'Epic', '2026-09-28', '2026-10-05', NULL, 'in_progress', 1, 'feature/x'),
		(110, 'Group', '2026-09-28', '2026-10-05', 100, 'in_progress', 1, '');
		INSERT INTO terminal_sessions (id, project_id, kind, title, target_id, folder_path, claude_session_id) VALUES
		(1, 1, 'claude', 'S1', 100, '/tmp/acme', 'u1')`)
	var want, rows []string
	for i := range n {
		status := "todo"
		if i%10 == 0 {
			status = "done"
		} else {
			want = append(want, fmt.Sprintf("into:feature/x:wt/%d", i))
		}
		rows = append(rows, fmt.Sprintf("(%d, 'l', '2026-09-28', '2026-10-05', 110, '%s', 1, 'wt/%d')", 1000+i, status, i))
	}
	// The status rollup re-reads every sibling on each insert (quadratic in
	// n); the group is in progress either way, so the fixture skips it.
	runSQL(t, d, `DROP TRIGGER targets_project_status_rollup_ai`)
	runSQL(t, d, `INSERT INTO targets (id, text, period_start, period_end, parent_id, status, project_id, branch) VALUES `+
		strings.Join(rows, ", "))
	return d, want
}

// siblingsGrowth is how many times more siblings the big group has than
// the small one, and siblingsMaxGrowth the most mergeRefs's CPU time may
// grow: linear work grows by about siblingsGrowth, the per-leaf walk or a
// list scan of the keys by siblingsGrowth² = 64.
const (
	siblingsGrowth    = 8
	siblingsMaxGrowth = 3 * siblingsGrowth
)

// Board #1016: a group of 1000 sibling leaves is walked once, not once per
// leaf (counted, so the memo is pinned without a clock), and every key is
// checked in a set — the refs come back in board order, one per not-done
// leaf, and 8× the siblings cost about 8× the CPU time, not the 64× of a
// list scan (CPU time, fastest of interleaved runs, so a loaded machine
// cannot fail it).
func TestMergeRefs_ManySiblingsAreLinear(t *testing.T) {
	const n = 1000
	small, smallWant := siblingsBoard(t, n)
	big, bigWant := siblingsBoard(t, n*siblingsGrowth)
	mergeRefs := func(d *db.DB, want []string) time.Duration {
		_, sc, err := loadScope(context.Background(), d, 1, 1)
		require.NoError(t, err)
		before := sc.b.walks
		var got []string
		took := cpuTime(t, func() { got = sc.mergeRefs() })
		assert.Equal(t, want, got)
		assert.Equal(t, 1, sc.b.walks-before, "the shared parent is walked once, not once per leaf")
		return took
	}
	fastSmall, fastBig := time.Duration(1<<62), time.Duration(1<<62)
	for range 3 {
		fastSmall = min(fastSmall, mergeRefs(small, smallWant))
		fastBig = min(fastBig, mergeRefs(big, bigWant))
	}
	ratio := float64(fastBig) / float64(max(fastSmall, time.Millisecond))
	t.Logf("mergeRefs CPU: %v over %d siblings, %v over %d, x%.2f", fastBig, n*siblingsGrowth, fastSmall, n, ratio)
	assert.LessOrEqual(t, ratio, float64(siblingsMaxGrowth), "%d× the siblings cost x%.2f CPU, want at most x%d (linear)",
		siblingsGrowth, ratio, siblingsMaxGrowth)
}

// cpuTime is the user plus system CPU time the process spends running f.
// Unlike the wall clock it does not grow while other processes have the
// machine.
func cpuTime(t *testing.T, f func()) time.Duration {
	t.Helper()
	before := processCPU(t)
	f()
	return processCPU(t) - before
}

func processCPU(t *testing.T) time.Duration {
	t.Helper()
	var ru syscall.Rusage
	require.NoError(t, syscall.Getrusage(syscall.RUSAGE_SELF, &ru))
	return time.Duration(ru.Utime.Nano() + ru.Stime.Nano())
}

// Board #1016: a key two leaves resolve to — a second leaf on the same
// branch, and a progress leaf its parent's walk also reaches — is listed
// once, at its first appearance.
func TestMergeRefs_ASharedKeyIsListedOnce(t *testing.T) {
	d := mergedFixture(t)
	runSQL(t, d, `INSERT INTO targets (id, text, period_start, period_end, parent_id, status, project_id, branch) VALUES
		(117, 'b2', '2026-09-28', '2026-10-05', 110, 'todo', 1, 'wt/b')`)
	want := []string{"into:feature/x:wt/b", "into:feature/x:wt/f", "into:feature/x:wt/c",
		"into:feature/x-ui:wt/g"}
	assert.Equal(t, want, mergeRefsOf(t, d, 1))
	_, sc, err := loadScope(context.Background(), d, 1, 1)
	require.NoError(t, err)
	assert.Equal(t, want, sc.countedMergeRefs(), "every leaf here is a progress leaf")
}
