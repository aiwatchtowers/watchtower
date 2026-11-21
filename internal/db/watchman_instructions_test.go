package db

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestWatchmanInstruction_SetGetClear(t *testing.T) {
	d := openTestDB(t)
	got, err := d.WatchmanInstruction("session", 7)
	require.NoError(t, err)
	require.Empty(t, got)

	require.NoError(t, d.SetWatchmanInstruction("session", 7, "  ship task 3 only\n"))
	require.NoError(t, d.SetWatchmanInstruction("target", 7, "ask me before the schema"))
	got, err = d.WatchmanInstruction("session", 7)
	require.NoError(t, err)
	require.Equal(t, "ship task 3 only", got)
	got, err = d.WatchmanInstruction("target", 7)
	require.NoError(t, err)
	require.Equal(t, "ask me before the schema", got)

	require.NoError(t, d.SetWatchmanInstruction("session", 7, "replaced"))
	got, err = d.WatchmanInstruction("session", 7)
	require.NoError(t, err)
	require.Equal(t, "replaced", got)

	// Empty (or blank) deletes the row.
	require.NoError(t, d.SetWatchmanInstruction("session", 7, " \n "))
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM watchman_instructions WHERE scope = 'session'`).Scan(&n))
	require.Zero(t, n)
	got, err = d.WatchmanInstruction("target", 7)
	require.NoError(t, err)
	require.Equal(t, "ask me before the schema", got, "the target's row is its own")

	// The scope CHECK holds.
	require.Error(t, d.SetWatchmanInstruction("workbench", 7, "x"))
}

func TestWatchmanInstruction_ClippedTo2000Runes(t *testing.T) {
	d := openTestDB(t)
	in := "  " + strings.Repeat("я", 2500) + "  "
	require.NoError(t, d.SetWatchmanInstruction("session", 1, in))
	got, err := d.WatchmanInstruction("session", 1)
	require.NoError(t, err)
	require.Equal(t, strings.Repeat("я", 2000), got)

	// A clip that ends on a space is trimmed again.
	in = strings.Repeat("a", 1999) + "   tail"
	require.NoError(t, d.SetWatchmanInstruction("session", 2, in))
	got, err = d.WatchmanInstruction("session", 2)
	require.NoError(t, err)
	require.Equal(t, strings.Repeat("a", 1999), got)
}

func TestWatchmanSessionInstructions_TargetThenSession(t *testing.T) {
	d := openTestDB(t)
	wmTestWorkbench(t, d, 1)
	wmTarget(t, d, 1, nil)
	wmTarget(t, d, 2, 1)
	wmTarget(t, d, 3, nil)
	wmSession(t, d, 10, 1, "claude", 2, false) // under target 1 (through 2)
	wmSession(t, d, 11, 1, "claude", 3, false) // its target is not armed

	require.NoError(t, d.SetWatchmanInstruction("target", 1, "group text"))
	require.NoError(t, d.SetWatchmanInstruction("target", 2, "sub-task text"))
	require.NoError(t, d.SetWatchmanInstruction("target", 3, "unarmed target text"))
	require.NoError(t, d.SetWatchmanInstruction("session", 10, "session text"))
	require.NoError(t, d.SetWatchmanInstruction("session", 11, "other session"))

	// Nothing armed: no target text, the session's own stays.
	tgt, ses, err := d.WatchmanSessionInstructions(10)
	require.NoError(t, err)
	require.Empty(t, tgt)
	require.Equal(t, "session text", ses)

	t0 := time.Date(2026, 11, 1, 10, 0, 0, 0, time.UTC)
	require.NoError(t, d.UpsertWatchmanArming(WatchmanArming{Scope: "target", RefID: 1, ArmedAt: t0, ArmedBy: "cli"}))
	tgt, ses, err = d.WatchmanSessionInstructions(10)
	require.NoError(t, err)
	require.Equal(t, "group text", tgt, "the armed target covering the session")
	require.Equal(t, "session text", ses)

	// Two armed targets cover it: the oldest-armed one's text.
	require.NoError(t, d.UpsertWatchmanArming(WatchmanArming{Scope: "target", RefID: 2, ArmedAt: t0.Add(-time.Hour), ArmedBy: "cli"}))
	tgt, _, err = d.WatchmanSessionInstructions(10)
	require.NoError(t, err)
	require.Equal(t, "sub-task text", tgt)

	// A session whose target is not armed reads no target text.
	tgt, ses, err = d.WatchmanSessionInstructions(11)
	require.NoError(t, err)
	require.Empty(t, tgt)
	require.Equal(t, "other session", ses)

	// Unknown session: both empty.
	tgt, ses, err = d.WatchmanSessionInstructions(99)
	require.NoError(t, err)
	require.Empty(t, tgt)
	require.Empty(t, ses)
}

func TestWatchmanUpkeep_PrunesInstructions(t *testing.T) {
	d := openTestDB(t)
	wmTestWorkbench(t, d, 1)
	wmTarget(t, d, 1, nil)
	wmTarget(t, d, 2, nil)
	wmSession(t, d, 10, 1, "claude", nil, false) // live
	wmSession(t, d, 11, 1, "claude", nil, true)  // finished, its row still there
	wmSession(t, d, 12, 1, "claude", nil, false) // being deleted
	for _, id := range []int64{10, 11, 12, 13} { // 13: no such session
		require.NoError(t, d.SetWatchmanInstruction("session", id, "s"))
	}
	for _, id := range []int64{1, 2} {
		require.NoError(t, d.SetWatchmanInstruction("target", id, "t"))
	}
	_, err := d.Exec(`UPDATE terminal_sessions SET delete_requested_at = '2026-11-01T10:00:00Z' WHERE id = 12`)
	require.NoError(t, err)
	_, err = d.Exec(`DELETE FROM targets WHERE id = 2`)
	require.NoError(t, err)

	n, err := d.PruneWatchmanInstructions()
	require.NoError(t, err)
	require.Equal(t, int64(3), n)
	rows, err := d.Query(`SELECT scope, ref_id FROM watchman_instructions ORDER BY scope, ref_id`)
	require.NoError(t, err)
	defer rows.Close()
	var left []string
	for rows.Next() {
		var scope string
		var id int64
		require.NoError(t, rows.Scan(&scope, &id))
		left = append(left, fmt.Sprintf("%s/%d", scope, id))
	}
	require.NoError(t, rows.Err())
	require.Equal(t, []string{"session/10", "session/11", "target/1"}, left)
}

func TestArmWatchmanInstructed_OneTransaction(t *testing.T) {
	d := openTestDB(t)
	t0 := time.Date(2026, 11, 1, 10, 0, 0, 0, time.UTC)
	inserted, err := d.ArmWatchmanInstructed(WatchmanArming{Scope: "session", RefID: 7, ArmedAt: t0, ArmedBy: "cli"}, "first")
	require.NoError(t, err)
	require.True(t, inserted)
	inserted, err = d.ArmWatchmanInstructed(WatchmanArming{Scope: "session", RefID: 7, ArmedAt: t0.Add(time.Hour), ArmedBy: "cli"}, "second")
	require.NoError(t, err)
	require.False(t, inserted, "a re-arm keeps the row")
	got, err := d.WatchmanInstruction("session", 7)
	require.NoError(t, err)
	require.Equal(t, "second", got)
	arming, err := d.ListWatchmanArming()
	require.NoError(t, err)
	require.Len(t, arming, 1)
	require.True(t, arming[0].ArmedAt.Equal(t0))

	// A bad scope fails, and leaves no row of either kind.
	_, err = d.ArmWatchmanInstructed(WatchmanArming{Scope: "bogus", RefID: 8, ArmedAt: t0, ArmedBy: "cli"}, "x")
	require.Error(t, err)
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM watchman_instructions WHERE ref_id = 8`).Scan(&n))
	require.Zero(t, n)
}
