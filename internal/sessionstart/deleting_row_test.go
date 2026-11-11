package sessionstart

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/hub/actions/handlers"
)

// A session being deleted (#1716) is deleted as far as a start is
// concerned: spec §4 "Readers of a row being deleted".

// markDeleting sets delete_requested_at the way the Desktop, its only
// writer, does.
func (w *world) markDeleting(id int64) {
	w.t.Helper()
	_, err := w.db.Exec(`UPDATE terminal_sessions SET delete_requested_at = '2026-11-10T12:00:00Z' WHERE id = ?`, id)
	require.NoError(w.t, err)
}

// latestTargetSession never picks a deleting row: a target's Start or
// Reopen opens the target's other session, or none.
func TestLatestTargetSession_SkipsDeletingRow(t *testing.T) {
	w := newWorld(t)
	tid := w.target("Ship it")
	older := w.existingSession(tid)
	newer := w.existingSession(tid)
	_, err := w.db.Exec(`UPDATE terminal_sessions SET last_active_at = '2026-11-10T11:00:00Z' WHERE id = ?`, older)
	require.NoError(t, err)
	_, err = w.db.Exec(`UPDATE terminal_sessions SET last_active_at = '2026-11-10T12:00:00Z' WHERE id = ?`, newer)
	require.NoError(t, err)

	got, found, err := latestTargetSession(context.Background(), w.db, tid, w.wb, "", nil)
	require.NoError(t, err)
	require.True(t, found)
	assert.Equal(t, newer, got.id)

	w.markDeleting(newer)
	got, found, err = latestTargetSession(context.Background(), w.db, tid, w.wb, "", nil)
	require.NoError(t, err)
	require.True(t, found)
	assert.Equal(t, older, got.id, "the deleting row is skipped")

	w.markDeleting(older)
	_, found, err = latestTargetSession(context.Background(), w.db, tid, w.wb, "", nil)
	require.NoError(t, err)
	assert.False(t, found, "only deleting rows: none")
}

// Starting a deleting row by id is refused as for a missing row.
func TestStart_DeletingRowIsNotFound(t *testing.T) {
	w := newWorld(t)
	id := w.begin(handlers.StartRequest{Workbench: w.wb})
	w.markDeleting(id)
	err := Finish(context.Background(), w.deps(), id, "auto", "", false)
	require.ErrorIs(t, err, db.ErrTerminalSessionNotFound)
	_, live := findRun(w.list(), w.deps().scope(), id)
	assert.False(t, live, "nothing launched")
}

// The delete is requested between the finish's row check and its launch:
// the run is stopped at once, as for a row deleted outright.
func TestADeleteRequestBetweenTheCheckAndTheLaunchStopsTheRun(t *testing.T) {
	w := newWorld(t)
	id := w.begin(handlers.StartRequest{Workbench: w.wb})
	beforeLaunch = func(sid int64) { w.markDeleting(sid) }
	t.Cleanup(func() { beforeLaunch = nil })
	err := Finish(context.Background(), w.deps(), id, "auto", "", false)
	require.ErrorContains(t, err, "was deleted before it started")
	eventually(t, "the run is stopped", func() bool {
		info, ok := findRun(w.list(), w.deps().scope(), id)
		return !ok || info.Exited
	})
}
