package daemon

import (
	"context"
	"database/sql"
	"errors"
	"os/exec"
	"syscall"
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
		return database.QueueSpecReview(tx, id, queuedAt, nil)
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
	assert.NoError(t, helper.Process.Signal(syscall.Signal(0)),
		"a process that does not lead its own group, or started after the claim, is not the reviewer: never signalled")
}

// An overdue reviewer that still runs is stopped (SIGTERM to its process
// group) before its row is failed.
func TestSpecReviewSweep_StopsOverdueReviewer(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	recordLaunches(d)
	id := specReviewAsk(t, database, time.Now().Add(-time.Hour))
	helper := exec.Command("sleep", "60")
	helper.SysProcAttr = &syscall.SysProcAttr{Setsid: true} // as LaunchSpecReview starts it
	require.NoError(t, helper.Start())
	exited := make(chan error, 1)
	go func() { exited <- helper.Wait() }()
	t.Cleanup(func() {
		_ = syscall.Kill(-helper.Process.Pid, syscall.SIGKILL)
		<-exited
	})
	ok, err := database.ClaimSpecReview(id, helper.Process.Pid, time.Now())
	require.NoError(t, err)
	require.True(t, ok)
	prev := specReviewOverdueAfter
	specReviewOverdueAfter = -time.Second // started_at has whole seconds
	t.Cleanup(func() { specReviewOverdueAfter = prev })

	d.phaseSpecReviewSweep(context.Background())

	row, err := database.GetSpecReview(id)
	require.NoError(t, err)
	assert.Equal(t, "failed", row.Status)
	select {
	case err := <-exited:
		var ee *exec.ExitError
		require.True(t, errors.As(err, &ee), "the reviewer was stopped: %v", err)
		ws, _ := ee.Sys().(syscall.WaitStatus)
		assert.Equal(t, syscall.SIGTERM, ws.Signal())
		exited <- err // for the cleanup
	case <-time.After(10 * time.Second):
		t.Fatal("the overdue reviewer is still running")
	}
}

// A reviewer that claims the row between the sweep's listing and its
// re-queue keeps it: the row stays running under its pid and no second
// reviewer is launched.
func TestSpecReviewSweep_ClaimBeforeRequeueWins(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	launched := recordLaunches(d)
	id := specReviewAsk(t, database, time.Now().Add(-5*time.Minute))
	helper := exec.Command("sleep", "30")
	require.NoError(t, helper.Start())
	t.Cleanup(func() { _ = helper.Process.Kill(); _ = helper.Wait() })
	specReviewBeforeRelaunch = func(askID int64) {
		ok, err := database.ClaimSpecReview(askID, helper.Process.Pid, time.Now())
		require.NoError(t, err)
		require.True(t, ok)
	}
	t.Cleanup(func() { specReviewBeforeRelaunch = nil })

	d.phaseSpecReviewSweep(context.Background())

	assert.Empty(t, *launched, "no second reviewer")
	row, err := database.GetSpecReview(id)
	require.NoError(t, err)
	assert.Equal(t, "running", row.Status)
	assert.Equal(t, helper.Process.Pid, row.PID)
	assert.Equal(t, 1, row.Attempt)
}

func TestSpecReviewSweep_GivesUpAfterThreeAttempts(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	launched := recordLaunches(d)
	id := specReviewAsk(t, database, time.Now().Add(-5*time.Minute))
	for range 2 { // attempt 1 -> 3
		require.NoError(t, database.WithTx(func(tx *sql.Tx) error {
			return database.QueueSpecReview(tx, id, time.Now().Add(-5*time.Minute), nil)
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

// specLoopAsk makes specReviewAsk's review an author loop; bound gives the ask
// a live terminal session.
func specLoopAsk(t *testing.T, database *db.DB, bound bool) int64 {
	t.Helper()
	id := specReviewAsk(t, database, time.Now().Add(-5*time.Minute))
	_, err := database.Exec(`UPDATE spec_reviews SET loop = 'author', round = 1 WHERE ask_id = ?`, id)
	require.NoError(t, err)
	if bound {
		res, err := database.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id)
			SELECT project_id, 'claude', 'S', '/tmp/x', 'uuid-1' FROM owner_asks WHERE id = ?`, id)
		require.NoError(t, err)
		sid, err := res.LastInsertId()
		require.NoError(t, err)
		_, err = database.Exec(`UPDATE owner_asks SET session_id = ? WHERE id = ?`, sid, id)
		require.NoError(t, err)
	}
	return id
}

func specLoopDone(t *testing.T, database *db.DB, id int64, finished time.Time) {
	t.Helper()
	_, err := database.Exec(`UPDATE spec_reviews SET status = 'done', result = '{}', finished_at = ? WHERE ask_id = ?`,
		finished.UTC().Format("2006-01-02T15:04:05Z"), id)
	require.NoError(t, err)
}

func loopEnd(t *testing.T, database *db.DB, id int64) (string, string) {
	t.Helper()
	row, err := database.GetSpecReview(id)
	require.NoError(t, err)
	return row.Loop, row.LoopEnd
}

func TestSpecReviewSweep_LoopTimeoutReveals(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	stale := specLoopAsk(t, database, true)
	specLoopDone(t, database, stale, time.Now().Add(-31*time.Minute))
	fresh := specLoopAsk(t, database, true)
	specLoopDone(t, database, fresh, time.Now().Add(-5*time.Minute))

	d.phaseSpecReviewSweep(context.Background())

	loop, end := loopEnd(t, database, stale)
	assert.Equal(t, "owner", loop)
	assert.Equal(t, "timeout", end)
	loop, _ = loopEnd(t, database, fresh)
	assert.Equal(t, "author", loop, "inside the 30 minutes")
}

func TestSpecReviewSweep_LoopSessionGoneReveals(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	gone := specLoopAsk(t, database, false)
	live := specLoopAsk(t, database, true)

	d.phaseSpecReviewSweep(context.Background())

	loop, end := loopEnd(t, database, gone)
	assert.Equal(t, "owner", loop)
	assert.Equal(t, "session_gone", end)
	loop, _ = loopEnd(t, database, live)
	assert.Equal(t, "author", loop)
}

func TestSpecReviewSweep_LoopRunsWithoutLauncher(t *testing.T) {
	d, database, _ := newBackfillDaemon(t) // no SetSpecReviewLaunch
	id := specLoopAsk(t, database, false)
	d.phaseSpecReviewSweep(context.Background())
	loop, _ := loopEnd(t, database, id)
	assert.Equal(t, "owner", loop)
}

func TestSpecReviewSweep_DeadReviewerRevealsLoop(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	recordLaunches(d)
	id := specLoopAsk(t, database, true)
	helper := exec.Command("true")
	require.NoError(t, helper.Run())
	ok, err := database.ClaimSpecReview(id, helper.Process.Pid, time.Now())
	require.NoError(t, err)
	require.True(t, ok)

	d.phaseSpecReviewSweep(context.Background())

	row, err := database.GetSpecReview(id)
	require.NoError(t, err)
	assert.Equal(t, "failed", row.Status)
	assert.Equal(t, "owner", row.Loop)
	assert.Equal(t, "reviewer_failed", row.LoopEnd)
}
