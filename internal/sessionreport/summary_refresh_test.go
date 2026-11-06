package sessionreport

import (
	"context"
	"path/filepath"
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
