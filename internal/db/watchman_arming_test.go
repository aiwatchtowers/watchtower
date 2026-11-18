package db

import (
	"database/sql"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func wmSession(t *testing.T, d *DB, id, projectID int64, kind string, target any, finished bool) {
	t.Helper()
	csid := "sid-" + time.Duration(id).String()
	var fin any
	if finished {
		fin = "2026-11-01T10:00:00.000Z"
	}
	_, err := d.Exec(`INSERT INTO terminal_sessions (id, project_id, kind, title, target_id, folder_path, finished_at, claude_session_id)
		VALUES (?, ?, ?, 'acme', ?, '/tmp/acme-s', ?, ?)`, id, projectID, kind, target, fin, csid)
	require.NoError(t, err)
}

func wmTarget(t *testing.T, d *DB, id int64, parent any) {
	t.Helper()
	_, err := d.Exec(`INSERT INTO targets (id, text, period_start, period_end, parent_id) VALUES (?, 'acme', '2026-11-01', '2026-11-30', ?)`, id, parent)
	require.NoError(t, err)
}

func TestWatchmanArming_UpsertLastWriteWins(t *testing.T) {
	d := openTestDB(t)
	t0 := time.Date(2026, 11, 1, 10, 0, 0, 0, time.UTC)
	require.NoError(t, d.UpsertWatchmanArming(WatchmanArming{Scope: "session", RefID: 7, ArmedAt: t0, ArmedBy: "cli"}))
	require.NoError(t, d.UpsertWatchmanArming(WatchmanArming{Scope: "session", RefID: 7, ArmedAt: t0.Add(time.Hour), ArmedBy: "desktop"}))
	got, err := d.ListWatchmanArming()
	require.NoError(t, err)
	require.Len(t, got, 1)
	require.Equal(t, "desktop", got[0].ArmedBy)
	require.True(t, got[0].ArmedAt.Equal(t0.Add(time.Hour)))
	ok, err := d.DeleteWatchmanArming("session", 7)
	require.NoError(t, err)
	require.True(t, ok)
	ok, err = d.DeleteWatchmanArming("session", 7)
	require.NoError(t, err)
	require.False(t, ok)

	require.NoError(t, d.UpsertWatchmanArming(WatchmanArming{Scope: "session", RefID: 1, ArmedAt: t0, ArmedBy: "cli"}))
	require.NoError(t, d.UpsertWatchmanArming(WatchmanArming{Scope: "target", RefID: 1, ArmedAt: t0, ArmedBy: "cli"}))
	n, err := d.ClearWatchmanArming()
	require.NoError(t, err)
	require.Equal(t, int64(2), n)
	got, err = d.ListWatchmanArming()
	require.NoError(t, err)
	require.Empty(t, got)
}

func TestWatchmanArmedSessions_TargetSubtree(t *testing.T) {
	d := openTestDB(t)
	wmTestWorkbench(t, d, 1)
	wmTarget(t, d, 1, nil)
	wmTarget(t, d, 2, 1)
	wmTarget(t, d, 3, nil)
	wmSession(t, d, 10, 1, "claude", 2, false) // A: under target 1
	wmSession(t, d, 11, 1, "claude", 3, false) // B: unrelated target
	wmSession(t, d, 12, 1, "claude", 2, true)  // C: finished
	require.NoError(t, d.UpsertWatchmanArming(WatchmanArming{Scope: "target", RefID: 1, ArmedAt: time.Now(), ArmedBy: "cli"}))
	got, err := d.WatchmanArmedSessions()
	require.NoError(t, err)
	require.Len(t, got, 1)
	require.Equal(t, int64(10), got[0].SessionID)
	require.Equal(t, int64(2), got[0].TargetID)
	require.Equal(t, int64(1), got[0].WorkbenchID)
	for id, want := range map[int64]bool{10: true, 11: false, 12: false} {
		a, err := d.WatchmanSessionArmed(id)
		require.NoError(t, err)
		require.Equal(t, want, a, id)
	}
	// armed directly
	require.NoError(t, d.UpsertWatchmanArming(WatchmanArming{Scope: "session", RefID: 11, ArmedAt: time.Now(), ArmedBy: "cli"}))
	a, err := d.WatchmanSessionArmed(11)
	require.NoError(t, err)
	require.True(t, a)
}

func TestWatchmanArming_ListOrdersWithinOneSecond(t *testing.T) {
	d := openTestDB(t)
	t0 := time.Date(2026, 11, 1, 10, 0, 0, 0, time.UTC)
	// .05 s sorts after .005 s as a time, but a trimmed fraction would sort it before.
	require.NoError(t, d.UpsertWatchmanArming(WatchmanArming{Scope: "session", RefID: 1, ArmedAt: t0.Add(50 * time.Millisecond), ArmedBy: "cli"}))
	require.NoError(t, d.UpsertWatchmanArming(WatchmanArming{Scope: "session", RefID: 2, ArmedAt: t0.Add(5 * time.Millisecond), ArmedBy: "cli"}))
	got, err := d.ListWatchmanArming()
	require.NoError(t, err)
	require.Len(t, got, 2)
	require.Equal(t, int64(2), got[0].RefID)
	require.Equal(t, int64(1), got[1].RefID)
	require.True(t, got[0].ArmedAt.Equal(t0.Add(5*time.Millisecond)))
}

func TestWatchmanArmedSessions_ExcludesShell(t *testing.T) {
	d := openTestDB(t)
	wmTestWorkbench(t, d, 1)
	wmSession(t, d, 20, 1, "shell", nil, false)
	wmSession(t, d, 21, 1, "claude", nil, false)
	for _, id := range []int64{20, 21} {
		require.NoError(t, d.UpsertWatchmanArming(WatchmanArming{Scope: "session", RefID: id, ArmedAt: time.Now(), ArmedBy: "cli"}))
	}
	got, err := d.WatchmanArmedSessions()
	require.NoError(t, err)
	require.Len(t, got, 1)
	require.Equal(t, int64(21), got[0].SessionID)
	a, err := d.WatchmanSessionArmed(20)
	require.NoError(t, err)
	require.False(t, a)
}

func TestWatchmanLiveSessions_AndTargetWorkbench(t *testing.T) {
	d := openTestDB(t)
	wmTestWorkbench(t, d, 1)
	wmTarget(t, d, 1, nil)
	_, err := d.Exec(`UPDATE targets SET project_id = 1 WHERE id = 1`)
	require.NoError(t, err)
	wmTarget(t, d, 2, nil)
	wmSession(t, d, 10, 1, "claude", 1, false)
	wmSession(t, d, 11, 1, "shell", nil, false)
	wmSession(t, d, 12, 1, "codex", nil, true)
	wmSession(t, d, 13, 1, "codex", nil, false)
	got, err := d.WatchmanLiveSessions()
	require.NoError(t, err)
	require.Len(t, got, 2)
	require.Equal(t, int64(10), got[0].SessionID)
	require.Equal(t, int64(1), got[0].TargetID)
	require.Equal(t, int64(13), got[1].SessionID)

	wb, err := d.WatchmanTargetWorkbench(1)
	require.NoError(t, err)
	require.Equal(t, int64(1), wb)
	wb, err = d.WatchmanTargetWorkbench(2)
	require.NoError(t, err)
	require.Zero(t, wb)
	_, err = d.WatchmanTargetWorkbench(99)
	require.ErrorIs(t, err, sql.ErrNoRows)
}

func TestPruneWatchmanArming_DropsWhatCannotBeDecided(t *testing.T) {
	d := openTestDB(t)
	wmTestWorkbench(t, d, 1)
	wmTarget(t, d, 1, nil)
	wmSession(t, d, 10, 1, "claude", nil, false) // live: stays
	wmSession(t, d, 11, 1, "claude", nil, true)  // finished: goes
	wmSession(t, d, 12, 1, "claude", nil, false) // deleting: goes
	_, err := d.Exec(`UPDATE terminal_sessions SET delete_requested_at = '2026-11-01T10:00:00Z' WHERE id = 12`)
	require.NoError(t, err)
	now := time.Date(2026, 11, 1, 10, 0, 0, 0, time.UTC)
	for _, a := range []WatchmanArming{
		{Scope: "session", RefID: 10}, {Scope: "session", RefID: 11}, {Scope: "session", RefID: 12},
		{Scope: "session", RefID: 99}, // gone
		{Scope: "target", RefID: 1},   // exists, no live session: stays
		{Scope: "target", RefID: 98},  // gone
	} {
		a.ArmedAt, a.ArmedBy = now, "cli"
		require.NoError(t, d.UpsertWatchmanArming(a))
	}
	n, err := d.PruneWatchmanArming()
	require.NoError(t, err)
	require.Equal(t, int64(4), n)
	got, err := d.ListWatchmanArming()
	require.NoError(t, err)
	require.Len(t, got, 2)
	require.Equal(t, [2]string{"session", "target"}, [2]string{got[0].Scope, got[1].Scope})
	require.Equal(t, [2]int64{10, 1}, [2]int64{got[0].RefID, got[1].RefID})
}
