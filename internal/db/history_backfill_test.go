package db

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestHistoryBackfill_StartIsIdempotent(t *testing.T) {
	d := OpenTestDB(t)
	now := time.Date(2026, 10, 15, 12, 0, 0, 0, time.UTC)
	created, err := d.StartHistoryBackfill("slack", 1, 100, 200, now)
	require.NoError(t, err)
	assert.True(t, created)
	created, err = d.StartHistoryBackfill("slack", 1, 50, 300, now)
	require.NoError(t, err)
	assert.False(t, created, "second start for the same source is a no-op")

	rows, err := d.ListHistoryBackfills()
	require.NoError(t, err)
	require.Len(t, rows, 1)
	assert.Equal(t, 100.0, rows[0].FloorTS)
	assert.Equal(t, 200.0, rows[0].UpperTS)
	assert.Equal(t, 200.0, rows[0].ReachedTS)
	assert.Equal(t, "running", rows[0].Status)
}

func TestHistoryBackfill_AdvanceToFloorIsDone(t *testing.T) {
	d := OpenTestDB(t)
	now := time.Date(2026, 10, 15, 12, 0, 0, 0, time.UTC)
	_, err := d.StartHistoryBackfill("gmail", 2, 100, 200, now)
	require.NoError(t, err)
	rows, _ := d.ListHistoryBackfills()
	id := rows[0].ID

	_, err = d.RecordHistoryBackfillFailure(id, "boom", now)
	require.NoError(t, err)
	require.NoError(t, d.SetHistoryBackfillWaiting(id, "plan_limit", now))
	require.NoError(t, d.AdvanceHistoryBackfill(id, 150, now))
	rows, _ = d.ListHistoryBackfills()
	assert.Equal(t, 150.0, rows[0].ReachedTS)
	assert.Equal(t, 0, rows[0].ChunkFailures)
	assert.Equal(t, "", rows[0].LastError)
	assert.Equal(t, "", rows[0].Waiting)
	assert.Equal(t, "running", rows[0].Status)

	require.NoError(t, d.AdvanceHistoryBackfill(id, 100, now))
	rows, _ = d.ListHistoryBackfills()
	assert.Equal(t, "done", rows[0].Status)
	require.NotNil(t, rows[0].DoneAt)
}

func TestHistoryBackfill_FailuresCountAndActive(t *testing.T) {
	d := OpenTestDB(t)
	now := time.Date(2026, 10, 15, 12, 0, 0, 0, time.UTC)
	active, err := d.HasActiveHistoryBackfill()
	require.NoError(t, err)
	assert.False(t, active)

	_, _ = d.StartHistoryBackfill("imap", 3, 100, 200, now)
	rows, _ := d.ListHistoryBackfills()
	id := rows[0].ID
	n, err := d.RecordHistoryBackfillFailure(id, "a", now)
	require.NoError(t, err)
	assert.Equal(t, 1, n)
	n, _ = d.RecordHistoryBackfillFailure(id, "b", now)
	assert.Equal(t, 2, n)

	active, _ = d.HasActiveHistoryBackfill()
	assert.True(t, active)
	require.NoError(t, d.SetHistoryBackfillStatus(id, "paused", now))
	active, _ = d.HasActiveHistoryBackfill()
	assert.True(t, active, "paused still holds memory back")
	require.NoError(t, d.SetHistoryBackfillStatus(id, "off", now))
	active, _ = d.HasActiveHistoryBackfill()
	assert.False(t, active)
}
