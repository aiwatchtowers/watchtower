package daemon

import (
	"context"
	"database/sql"
	"os/exec"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// specReviewAsk files a review ask with a queued review stamped queuedAt.
func specReviewAsk(t *testing.T, database *db.DB, queuedAt time.Time) int64 {
	t.Helper()
	wb, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	var id int64
	require.NoError(t, database.WithTx(func(tx *sql.Tx) error {
		var err error
		id, _, err = database.InsertOwnerAsk(tx, db.OwnerAsk{
			WorkbenchID: wb, Kind: "review", Title: "Review the spec",
			DocPath: "docs/specs/x-design.md", DocSnapshot: "# Spec\n", DocType: "spec",
		})
		if err != nil {
			return err
		}
		return database.QueueSpecReview(tx, id, queuedAt)
	}))
	return id
}

func recordLaunches(d *Daemon) *[]int64 {
	var got []int64
	d.SetSpecReviewLaunch(func(id int64) error {
		got = append(got, id)
		return nil
	})
	return &got
}

func TestSpecReviewSweep_RelaunchesStaleQueued(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	launched := recordLaunches(d)
	stale := specReviewAsk(t, database, time.Now().Add(-5*time.Minute))
	specReviewAsk(t, database, time.Now())

	d.phaseSpecReviewSweep(context.Background())

	assert.Equal(t, []int64{stale}, *launched, "only the row older than 60 s is launched")
	row, err := database.GetSpecReview(stale)
	require.NoError(t, err)
	assert.Equal(t, "queued", row.Status)
	assert.Equal(t, 2, row.Attempt, "a launch counts")
	d.phaseSpecReviewSweep(context.Background())
	assert.Equal(t, []int64{stale}, *launched, "the minute restarts after a launch")
}

func TestSpecReviewSweep_AtMostThreePerCycle(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	launched := recordLaunches(d)
	for range 5 {
		specReviewAsk(t, database, time.Now().Add(-5*time.Minute))
	}
	d.phaseSpecReviewSweep(context.Background())
	assert.Len(t, *launched, 3)
}

func TestSpecReviewSweep_FailsDeadRunning(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	launched := recordLaunches(d)
	id := specReviewAsk(t, database, time.Now().Add(-5*time.Minute))

	helper := exec.Command("true")
	require.NoError(t, helper.Run()) // started and reaped: its pid is gone
	ok, err := database.ClaimSpecReview(id, helper.Process.Pid, time.Now())
	require.NoError(t, err)
	require.True(t, ok)

	d.phaseSpecReviewSweep(context.Background())

	row, err := database.GetSpecReview(id)
	require.NoError(t, err)
	assert.Equal(t, "failed", row.Status)
	assert.Equal(t, "reviewer process ended without a result", row.Reason)
	assert.Empty(t, *launched)
}

func TestSpecReviewSweep_KeepsLiveRunning(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	recordLaunches(d)
	id := specReviewAsk(t, database, time.Now().Add(-time.Minute))
	helper := exec.Command("sleep", "30")
	require.NoError(t, helper.Start())
	t.Cleanup(func() { _ = helper.Process.Kill(); _ = helper.Wait() })
	ok, err := database.ClaimSpecReview(id, helper.Process.Pid, time.Now())
	require.NoError(t, err)
	require.True(t, ok)

	d.phaseSpecReviewSweep(context.Background())

	row, err := database.GetSpecReview(id)
	require.NoError(t, err)
	assert.Equal(t, "running", row.Status)
}

func TestSpecReviewSweep_FailsOverdueRunning(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	recordLaunches(d)
	id := specReviewAsk(t, database, time.Now().Add(-time.Hour))
	helper := exec.Command("sleep", "30")
	require.NoError(t, helper.Start())
	t.Cleanup(func() { _ = helper.Process.Kill(); _ = helper.Wait() })
	ok, err := database.ClaimSpecReview(id, helper.Process.Pid, time.Now().Add(-30*time.Minute))
	require.NoError(t, err)
	require.True(t, ok)

	d.phaseSpecReviewSweep(context.Background())

	row, err := database.GetSpecReview(id)
	require.NoError(t, err)
	assert.Equal(t, "failed", row.Status, "a live pid does not save a run past its timeout")
}

func TestSpecReviewSweep_GivesUpAfterThreeAttempts(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	launched := recordLaunches(d)
	id := specReviewAsk(t, database, time.Now().Add(-5*time.Minute))
	for range 2 { // attempt 1 -> 3
		require.NoError(t, database.WithTx(func(tx *sql.Tx) error {
			return database.QueueSpecReview(tx, id, time.Now().Add(-5*time.Minute))
		}))
	}

	d.phaseSpecReviewSweep(context.Background())

	row, err := database.GetSpecReview(id)
	require.NoError(t, err)
	assert.Equal(t, "failed", row.Status)
	assert.Equal(t, "could not start", row.Reason)
	assert.Empty(t, *launched)
}

func TestSpecReviewSweep_NoLauncherNoSweep(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	id := specReviewAsk(t, database, time.Now().Add(-5*time.Minute))
	d.phaseSpecReviewSweep(context.Background())
	row, err := database.GetSpecReview(id)
	require.NoError(t, err)
	assert.Equal(t, 1, row.Attempt)
}
