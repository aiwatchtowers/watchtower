package sessionreport

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"slices"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// repoBoard is newFeatureRepo's repository bound to a workbench whose
// session 1 works epic 100 on feature/x: 101 wt/m (in progress, merged into
// feature/x), 102 wt/open (todo, open) and 103 wt/fresh (in review, no work
// of its own). It returns the database file too, for a second handle.
func repoBoard(t *testing.T) (d *db.DB, id int64, dir, path string) {
	t.Helper()
	dir = newFeatureRepo(t)
	path = filepath.Join(t.TempDir(), "test.db")
	d, err := db.Open(path)
	require.NoError(t, err)
	t.Cleanup(func() { d.Close() })
	id, err = d.CreateWorkbench("acme", dir)
	require.NoError(t, err)
	runSQL(t, d, `INSERT INTO targets (id, text, period_start, period_end, parent_id, status, project_id, branch) VALUES
		(100, 'Epic', '2026-09-28', '2026-10-05', NULL, 'in_progress', ?, 'feature/x'),
		(101, 'm', '2026-09-28', '2026-10-05', 100, 'in_progress', ?, 'wt/m'),
		(102, 'open', '2026-09-28', '2026-10-05', 100, 'todo', ?, 'wt/open'),
		(103, 'fresh', '2026-09-28', '2026-10-05', 100, 'in_review', ?, 'wt/fresh')`, id, id, id, id)
	runSQL(t, d, `INSERT INTO terminal_sessions (id, project_id, kind, title, target_id, folder_path, claude_session_id)
		VALUES (1, ?, 'claude', 'S1', 100, ?, 'u1')`, id, dir)
	return d, id, dir, path
}

// Review M2: a verdict git read but the cache could not store still counts
// in this run's rows, and the note says it was not saved — not "not read".
func TestRefreshedSummaries_AnUnsavedVerdictStillCounts(t *testing.T) {
	d, id, _, _ := repoBoard(t)
	runSQL(t, d, `CREATE TRIGGER no_cache BEFORE INSERT ON workbench_pr_states BEGIN SELECT RAISE(ABORT, 'test: no cache'); END`)
	rows, res, err := RefreshedSummaries(context.Background(), d, id, RefreshOptions{})
	require.NoError(t, err)
	require.Len(t, rows, 1)
	assert.Equal(t, []int{0, 3, 1}, []int{rows[0].Done, rows[0].Total, rows[0].Merged}, "the fresh verdict counts")
	assert.Contains(t, res.Note, "the state of 3 ref(s) was read but could not be saved")
	assert.NotContains(t, res.Note, "could not be read")
	assert.Empty(t, states(t, d, id))
}

// Review F2: with another process holding the write lock, each cache write
// of the row lines' refresh gives up after summaryWriteWait, not after the
// handle's 5 s busy_timeout (three refs: 15 s at 5 s each).
func TestRefreshedSummaries_CacheWritesWaitBriefly(t *testing.T) {
	d, id, _, path := repoBoard(t)
	other, err := db.Open(path)
	require.NoError(t, err)
	t.Cleanup(func() { other.Close() })
	tx, err := other.Begin() // BEGIN IMMEDIATE: holds the write lock
	require.NoError(t, err)
	t.Cleanup(func() { _ = tx.Rollback() })

	start := time.Now()
	rows, res, err := RefreshedSummaries(context.Background(), d, id, RefreshOptions{Budget: time.Minute})
	elapsed := time.Since(start)
	require.NoError(t, err)
	assert.Less(t, elapsed, 10*time.Second, "three writes of at most %s each", summaryWriteWait)
	assert.Contains(t, res.Note, "was read but could not be saved")
	require.Len(t, rows, 1)
	assert.Equal(t, 1, rows[0].Merged)
}

// Review major (envelope symmetry): merged_stale says the row's merged
// share holds verdicts this run could not check.
func TestRefreshedSummaries_MergedStale(t *testing.T) {
	t.Run("all checked", func(t *testing.T) {
		d, id, _, _ := repoBoard(t)
		rows, res, err := RefreshedSummaries(context.Background(), d, id, RefreshOptions{})
		require.NoError(t, err)
		assert.Empty(t, res.Note)
		require.Len(t, rows, 1)
		assert.Equal(t, 1, rows[0].Merged)
		assert.False(t, rows[0].MergedStale)
	})
	t.Run("unresolvable base, and no blinking off while it lasts", func(t *testing.T) {
		d, id, _, _ := repoBoard(t)
		runSQL(t, d, `UPDATE targets SET branch = 'gone/base' WHERE id = 100`)
		for i, at := range []time.Time{refreshNow, refreshNow.Add(15 * time.Second)} {
			rows, res, err := RefreshedSummaries(context.Background(), d, id, RefreshOptions{Now: func() time.Time { return at }})
			require.NoError(t, err)
			assert.Contains(t, res.Note, "base branch gone/base could not be resolved", "run %d", i)
			require.Len(t, rows, 1)
			assert.True(t, rows[0].MergedStale, "run %d: the failed read is due again, not fresh", i)
		}
	})
	t.Run("a folder outside git has no verdict to miss", func(t *testing.T) {
		d := mergedFixture(t)
		rows, res, err := RefreshedSummaries(context.Background(), d, 1, RefreshOptions{Now: fixedNow})
		require.NoError(t, err)
		assert.Contains(t, res.Note, "not a git work tree")
		require.Len(t, rows, 1)
		assert.False(t, rows[0].MergedStale)
	})
	t.Run("Summaries refreshes nothing", func(t *testing.T) {
		d, id, _, _ := repoBoard(t)
		rows, err := Summaries(context.Background(), d, id)
		require.NoError(t, err)
		require.Len(t, rows, 1)
		assert.False(t, rows[0].MergedStale)
	})
}

// The wire shape: merged_stale is always present (false by default).
func TestSummary_MergedStaleKey(t *testing.T) {
	b, err := json.Marshal(Summary{SessionID: 1})
	require.NoError(t, err)
	assert.Contains(t, string(b), `"merged_stale":false`)
}

// stubGitCalls answers the named git subcommands (err set: they fail) and
// runs every other call for real.
func stubGitCalls(t *testing.T, answers map[string]string, failing ...string) {
	t.Helper()
	prev := run
	run = func(ctx context.Context, dir string, stdin []byte, name string, args ...string) ([]byte, int, error) {
		if name == "git" && len(args) > 0 {
			if slices.Contains(failing, args[0]) {
				return nil, 1, errors.New("git " + args[0] + " broke")
			}
			if out, ok := answers[args[0]]; ok {
				return []byte(out), 0, nil
			}
		}
		return prev(ctx, dir, stdin, name, args...)
	}
	t.Cleanup(func() { run = prev })
}

// Verify R1: where git only cannot tell (an empty cherry, a diff of two
// patches) the verdict stays as it was, quietly: no note, no merged_stale,
// the ordinary stamp.
func TestRefreshedSummaries_GitCannotTellIsQuiet(t *testing.T) {
	d, id, _, _ := repoBoard(t)
	stubGitCalls(t, map[string]string{"cherry": "", "patch-id": "aaa 111\nbbb 222\n"})
	rows, res, err := RefreshedSummaries(context.Background(), d, id, RefreshOptions{Now: fixedNow})
	require.NoError(t, err)
	assert.Empty(t, res.Note)
	require.Len(t, rows, 1)
	assert.False(t, rows[0].MergedStale)
	row := states(t, d, id)["into:feature/x:wt/open"]
	assert.Equal(t, "unknown", row.State)
	assert.Equal(t, refreshNow.Format(time.RFC3339), row.CheckedAt, "the ordinary backoff, not due again")
}

// Verify R2: merged_stale follows the refs Merged reads. A session bound to
// a done leaf counts no merge verdict, so a sibling's failed read (one its
// phase line reads) leaves the row's mark off.
func TestRefreshedSummaries_PhaseOnlyFailureLeavesTheRowUnmarked(t *testing.T) {
	d, id, _, _ := repoBoard(t)
	runSQL(t, d, `UPDATE targets SET status = 'done' WHERE id = 101; UPDATE terminal_sessions SET target_id = 101 WHERE id = 1`)
	stubGitCalls(t, nil, "cherry")
	rows, res, err := RefreshedSummaries(context.Background(), d, id, RefreshOptions{Now: fixedNow})
	require.NoError(t, err)
	assert.Contains(t, res.Note, "into:feature/x:wt/open: git could not read its merge state", "the sibling failed")
	require.Len(t, rows, 1)
	assert.Equal(t, []int{1, 1, 0}, []int{rows[0].Done, rows[0].Total, rows[0].Merged})
	assert.False(t, rows[0].MergedStale, "the row's Merged reads no verdict")
}

// Verify R3: a failed read stamped due again waits behind a ref that became
// due earlier, though its check time is older.
func TestRefresh_AFailedReadGoesLast(t *testing.T) {
	d, id, _, _ := repoBoard(t)
	failing, ok := "into:nope:wt/m", "into:feature/x:wt/m"
	require.NoError(t, d.UpsertPRState(db.PRState{WorkbenchID: id, Ref: failing, State: "merged",
		CheckedAt: dueAgain("merged", refreshNow)}))
	seed(t, d, id, ok, "open", 2*time.Minute)
	require.Less(t, states(t, d, id)[failing].CheckedAt, states(t, d, id)[ok].CheckedAt, "the failed row's stamp is older")

	var mu sync.Mutex
	tick := 0
	clock := func() time.Time {
		mu.Lock()
		defer mu.Unlock()
		tick++
		return refreshNow.Add(15*time.Second + time.Duration(tick)*4*time.Second)
	}
	res := Refresh(context.Background(), d, id, []string{failing, ok}, RefreshOptions{Budget: 10 * time.Second, Now: clock})
	assert.Contains(t, res.Note, "1 ref(s) keep their cached state")
	got := states(t, d, id)
	assert.Equal(t, "merged", got[ok].State, "the ref due longer is read first")
	assert.Equal(t, dueAgain("merged", refreshNow), got[failing].CheckedAt, "the failed one waits")
}
