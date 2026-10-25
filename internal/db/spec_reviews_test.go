package db

import (
	"database/sql"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func newReviewAsk(t *testing.T, d *DB) int64 {
	t.Helper()
	pid := newTestWorkbench(t, d)
	return mustInsertAsk(t, d, OwnerAsk{WorkbenchID: pid, Kind: "review", Title: "spec", DocPath: "docs/spec.md", DocType: "spec"})
}

func queueSpecReview(t *testing.T, d *DB, askID int64, now time.Time) {
	t.Helper()
	require.NoError(t, d.WithTx(func(tx *sql.Tx) error { return d.QueueSpecReview(tx, askID, now) }))
}

func TestSpecReview_QueueClaimFinish(t *testing.T) {
	d := openTestDB(t)
	askID := newReviewAsk(t, d)
	now := time.Date(2026, 10, 25, 10, 0, 0, 0, time.UTC)
	queueSpecReview(t, d, askID, now)

	ok, err := d.ClaimSpecReview(askID, 7, now)
	require.NoError(t, err)
	assert.True(t, ok)
	ok, err = d.ClaimSpecReview(askID, 8, now)
	require.NoError(t, err)
	assert.False(t, ok)

	require.NoError(t, d.FinishSpecReview(askID, 8, SpecReview{Result: "wrong"}, now))
	got, err := d.GetSpecReview(askID)
	require.NoError(t, err)
	assert.Equal(t, "running", got.Status)
	assert.Equal(t, "", got.Result)

	require.NoError(t, d.FinishSpecReview(askID, 7, SpecReview{Result: "{}", Provider: "claude", Model: "m", DocSHA: "abc", Dropped: 2}, now))
	got, err = d.GetSpecReview(askID)
	require.NoError(t, err)
	assert.Equal(t, "done", got.Status)
	assert.Equal(t, "{}", got.Result)
	assert.Equal(t, 2, got.Dropped)
	assert.NotEmpty(t, got.FinishedAt)
}

func TestSpecReview_FailAndSkip(t *testing.T) {
	d := openTestDB(t)
	askID := newReviewAsk(t, d)
	now := time.Date(2026, 10, 25, 10, 0, 0, 0, time.UTC)
	queueSpecReview(t, d, askID, now)
	ok, err := d.ClaimSpecReview(askID, 7, now)
	require.NoError(t, err)
	require.True(t, ok)
	require.NoError(t, d.FailSpecReview(askID, 9, "no", now))
	got, _ := d.GetSpecReview(askID)
	assert.Equal(t, "running", got.Status)
	require.NoError(t, d.FailSpecReview(askID, 7, "boom", now))
	got, _ = d.GetSpecReview(askID)
	assert.Equal(t, "failed", got.Status)
	assert.Equal(t, "boom", got.Reason)

	require.NoError(t, d.SkipSpecReview(askID, "off", now))
	got, _ = d.GetSpecReview(askID)
	assert.Equal(t, "skipped", got.Status)

	_, err = d.GetSpecReview(askID + 100)
	assert.ErrorIs(t, err, ErrSpecReviewNotFound)
}

func TestSpecReview_RequeueKeepsMarks(t *testing.T) {
	d := openTestDB(t)
	askID := newReviewAsk(t, d)
	now := time.Date(2026, 10, 25, 10, 0, 0, 0, time.UTC)
	queueSpecReview(t, d, askID, now)
	ok, err := d.ClaimSpecReview(askID, 7, now)
	require.NoError(t, err)
	require.True(t, ok)
	require.NoError(t, d.FinishSpecReview(askID, 7, SpecReview{Result: "{}"}, now))
	_, err = d.Exec(`INSERT INTO spec_review_marks (ask_id, item_key, state, body, about, updated_at) VALUES (?, 'f1', 'comment', 'hi', 'Threads stay muted', 'x')`, askID)
	require.NoError(t, err)

	queueSpecReview(t, d, askID, now.Add(time.Minute))
	got, err := d.GetSpecReview(askID)
	require.NoError(t, err)
	assert.Equal(t, "queued", got.Status)
	assert.Equal(t, 2, got.Attempt)
	assert.Equal(t, "", got.Result)
	assert.Equal(t, 0, got.PID)
	marks, err := d.ListSpecReviewMarks(askID)
	require.NoError(t, err)
	assert.Equal(t, SpecReviewMark{State: "comment", Body: "hi", About: "Threads stay muted", UpdatedAt: "x"}, marks["f1"])
}

func TestSpecReview_CascadeOnAskDelete(t *testing.T) {
	d := openTestDB(t)
	askID := newReviewAsk(t, d)
	queueSpecReview(t, d, askID, time.Now())
	_, err := d.Exec(`INSERT INTO spec_review_marks (ask_id, item_key, state, updated_at) VALUES (?, 'f1', 'ok', 'x')`, askID)
	require.NoError(t, err)
	_, err = d.Exec(`DELETE FROM owner_asks WHERE id = ?`, askID)
	require.NoError(t, err)
	_, err = d.GetSpecReview(askID)
	assert.ErrorIs(t, err, ErrSpecReviewNotFound)
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM spec_review_marks`).Scan(&n))
	assert.Equal(t, 0, n)
}

func TestSpecReview_SweepPicksStale(t *testing.T) {
	d := openTestDB(t)
	now := time.Date(2026, 10, 25, 10, 0, 0, 0, time.UTC)
	old, fresh, run := newReviewAsk(t, d), newReviewAsk(t, d), newReviewAsk(t, d)
	queueSpecReview(t, d, old, now.Add(-61*time.Second))
	queueSpecReview(t, d, fresh, now.Add(-30*time.Second))
	queueSpecReview(t, d, run, now.Add(-10*time.Second))
	ok, err := d.ClaimSpecReview(run, 5, now)
	require.NoError(t, err)
	require.True(t, ok)

	queued, running, err := d.SpecReviewsToSweep(now)
	require.NoError(t, err)
	assert.Equal(t, []int64{old}, queued)
	require.Len(t, running, 1)
	assert.Equal(t, run, running[0].AskID)
	assert.Equal(t, 5, running[0].PID)
}

func TestRequeueSpecReview_States(t *testing.T) {
	d := openTestDB(t)
	askID := newReviewAsk(t, d)
	now := time.Date(2026, 10, 25, 10, 0, 0, 0, time.UTC)

	require.NoError(t, d.RequeueSpecReview(askID, false, now), "no row: queued")
	got, err := d.GetSpecReview(askID)
	require.NoError(t, err)
	assert.Equal(t, "queued", got.Status)
	assert.Equal(t, 1, got.Attempt)
	require.NoError(t, d.RequeueSpecReview(askID, true, now), "queued: left as is")
	got, err = d.GetSpecReview(askID)
	require.NoError(t, err)
	assert.Equal(t, 1, got.Attempt)

	ok, err := d.ClaimSpecReview(askID, 7, now)
	require.NoError(t, err)
	require.True(t, ok)
	err = d.RequeueSpecReview(askID, true, now)
	require.ErrorIs(t, err, ErrSpecReviewBusy)
	assert.Contains(t, err.Error(), "already running")

	require.NoError(t, d.FailSpecReview(askID, 7, "boom", now))
	err = d.RequeueSpecReview(askID, false, now)
	require.ErrorIs(t, err, ErrSpecReviewBusy)
	assert.Contains(t, err.Error(), "failed")
	require.NoError(t, d.RequeueSpecReview(askID, true, now))
	got, err = d.GetSpecReview(askID)
	require.NoError(t, err)
	assert.Equal(t, "queued", got.Status)
	assert.Equal(t, 1, got.Attempt, "the owner's run starts the launch count over")
	assert.Empty(t, got.Reason)
}

// The owner's start resets the sweep's launch count, on a forced re-run and
// on a row still queued after automatic relaunches.
func TestRequeueSpecReview_ResetsAttempt(t *testing.T) {
	d := openTestDB(t)
	askID := newReviewAsk(t, d)
	now := time.Date(2026, 10, 25, 10, 0, 0, 0, time.UTC)
	queueSpecReview(t, d, askID, now)
	for range 2 {
		ok, err := d.RelaunchQueuedSpecReview(askID, 3, now)
		require.NoError(t, err)
		require.True(t, ok)
	}
	got, err := d.GetSpecReview(askID)
	require.NoError(t, err)
	require.Equal(t, 3, got.Attempt)
	require.NoError(t, d.RequeueSpecReview(askID, false, now))
	got, err = d.GetSpecReview(askID)
	require.NoError(t, err)
	assert.Equal(t, 1, got.Attempt, "start on a queued row")

	ok, err := d.ClaimSpecReview(askID, 7, now)
	require.NoError(t, err)
	require.True(t, ok)
	require.NoError(t, d.FailSpecReview(askID, 7, "could not start", now))
	require.NoError(t, d.RequeueSpecReview(askID, true, now))
	got, err = d.GetSpecReview(askID)
	require.NoError(t, err)
	assert.Equal(t, "queued", got.Status)
	assert.Equal(t, 1, got.Attempt, "start --force")
}

// The sweep's re-queue never touches a row that is no longer queued, and stops
// at the launch cap.
func TestRelaunchQueuedSpecReview_OnlyQueued(t *testing.T) {
	d := openTestDB(t)
	askID := newReviewAsk(t, d)
	now := time.Date(2026, 10, 25, 10, 0, 0, 0, time.UTC)
	queueSpecReview(t, d, askID, now)
	later := now.Add(5 * time.Minute)

	ok, err := d.RelaunchQueuedSpecReview(askID, 2, later)
	require.NoError(t, err)
	assert.True(t, ok)
	got, err := d.GetSpecReview(askID)
	require.NoError(t, err)
	assert.Equal(t, 2, got.Attempt)
	assert.Equal(t, specReviewTime(later), got.QueuedAt)
	ok, err = d.RelaunchQueuedSpecReview(askID, 2, later)
	require.NoError(t, err)
	assert.False(t, ok, "out of launches")

	ok, err = d.ClaimSpecReview(askID, 9, later)
	require.NoError(t, err)
	require.True(t, ok)
	ok, err = d.RelaunchQueuedSpecReview(askID, 10, later)
	require.NoError(t, err)
	assert.False(t, ok, "a claimed row is never re-queued")
	got, err = d.GetSpecReview(askID)
	require.NoError(t, err)
	assert.Equal(t, "running", got.Status)
	assert.Equal(t, 9, got.PID)
}
