package db

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// A run left in 'running' by a process that died is the only row the reap may
// touch: not a run still inside the window, and not an old finished run.
func TestFailStalePipelineRuns(t *testing.T) {
	d := openTestDB(t)
	now := time.Now().UTC()
	backdate := func(id int64, age time.Duration) {
		_, err := d.Exec(`UPDATE pipeline_runs SET started_at=? WHERE id=?`,
			now.Add(-age).Format("2006-01-02T15:04:05Z"), id)
		require.NoError(t, err)
	}

	stale, err := d.CreatePipelineRun("memory", "daemon", "auto")
	require.NoError(t, err)
	backdate(stale, 25*time.Hour)
	fresh, err := d.CreatePipelineRun("ask", "cli", "auto")
	require.NoError(t, err)
	backdate(fresh, time.Hour)
	done, err := d.CreatePipelineRun("people", "daemon", "auto")
	require.NoError(t, err)
	backdate(done, 48*time.Hour)
	require.NoError(t, d.CompletePipelineRun(done, 3, 0, 0, 0, 0, nil, nil, ""))

	n, err := d.FailStalePipelineRuns(now.Add(-24*time.Hour), "interrupted")
	require.NoError(t, err)
	assert.Equal(t, int64(1), n, "only the abandoned run is reaped")

	byID := map[int64]PipelineRun{}
	runs, err := d.GetPipelineRuns(10)
	require.NoError(t, err)
	for _, r := range runs {
		byID[r.ID] = r
	}
	assert.Equal(t, "error", byID[stale].Status)
	assert.Equal(t, "interrupted", byID[stale].ErrorMsg, "the reaped run explains itself")
	assert.NotNil(t, byID[stale].FinishedAt, "a reaped run is finished")
	assert.Equal(t, "running", byID[fresh].Status, "a run still inside the window is left alone")
	assert.Equal(t, "done", byID[done].Status, "an old finished run is not a stale one")
	assert.Equal(t, 3, byID[done].ItemsFound)

	// Idempotent: nothing left to reap on a second pass.
	n, err = d.FailStalePipelineRuns(now.Add(-24*time.Hour), "interrupted")
	require.NoError(t, err)
	assert.Zero(t, n)
}
