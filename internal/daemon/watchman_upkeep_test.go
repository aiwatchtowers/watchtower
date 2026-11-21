package daemon

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/watchmanact"
)

// fakeAwake records keep-awake holds and releases.
type fakeAwake struct {
	holds    []string
	releases int
	err      error
}

func (f *fakeAwake) hold(reason string) (func(), error) {
	f.holds = append(f.holds, reason)
	if f.err != nil {
		return nil, f.err
	}
	return func() { f.releases++ }, nil
}

// upkeepClock drives the upkeep's wall clock and the loop's monotonic one.
type upkeepClock struct {
	wall time.Time
	mono time.Duration
}

func (c *upkeepClock) advance(wall, mono time.Duration) {
	c.wall = c.wall.Add(wall)
	c.mono += mono
}

func newUpkeepDaemon(t *testing.T) (*Daemon, *db.DB, *bytes.Buffer, *upkeepClock) {
	t.Helper()
	d, database, logs := newBackfillDaemon(t)
	clk := &upkeepClock{wall: time.Date(2026, 11, 18, 2, 10, 0, 0, time.Local)}
	d.watchmanUpkeep.now = func() time.Time { return clk.wall }
	d.loopMono = func() time.Duration { return clk.mono }
	return d, database, logs, clk
}

// upkeepSession inserts workbench wb's live claude session in folder.
func upkeepSession(t *testing.T, database *db.DB, wb int64, folder string) int64 {
	t.Helper()
	res, err := database.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id)
		VALUES (?, 'claude', 'acme', ?, ?)`, wb, folder, "sid-"+filepath.Base(folder))
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

func armUpkeepSession(t *testing.T, database *db.DB, id int64) {
	t.Helper()
	require.NoError(t, database.UpsertWatchmanArming(db.WatchmanArming{Scope: "session", RefID: id, ArmedAt: time.Now(), ArmedBy: "cli"}))
}

func gapRows(t *testing.T, database *db.DB) [][2]string {
	t.Helper()
	rows, err := database.Query(`SELECT started_at, ended_at FROM watchman_gaps ORDER BY id`)
	require.NoError(t, err)
	defer rows.Close()
	var out [][2]string
	for rows.Next() {
		var g [2]string
		require.NoError(t, rows.Scan(&g[0], &g[1]))
		out = append(out, g)
	}
	require.NoError(t, rows.Err())
	return out
}

func TestWatchmanUpkeep_HoldsAwakeWhileArmed(t *testing.T) {
	d, database, _, clk := newUpkeepDaemon(t)
	awake := &fakeAwake{}
	d.SetWatchmanAwake(awake.hold)
	ctx := context.Background()

	d.phaseWatchmanUpkeep(ctx)
	assert.Empty(t, awake.holds, "nothing armed: no hold")

	wb, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	folder := t.TempDir()
	s := upkeepSession(t, database, wb, folder)
	armUpkeepSession(t, database, s)
	d.phaseWatchmanUpkeep(ctx)
	clk.advance(15*time.Minute, 15*time.Minute)
	d.phaseWatchmanUpkeep(ctx)
	assert.Equal(t, []string{WatchmanAwakeReason}, awake.holds, "one hold across two cycles")
	assert.Zero(t, awake.releases)
	// The upkeep rewrites the sidecar from the database each cycle.
	sc, err := watchmanact.ReadSidecar(watchmanact.SidecarPath(d.config.WorkspaceDir()))
	require.NoError(t, err)
	assert.Equal(t, watchmanact.Sidecar{Sessions: []int64{s}, Worktrees: []string{folder}}, sc)

	_, err = database.DeleteWatchmanArming("session", s)
	require.NoError(t, err)
	clk.advance(15*time.Minute, 15*time.Minute)
	d.phaseWatchmanUpkeep(ctx)
	assert.Equal(t, 1, awake.releases, "released when the last row goes")
	sc, err = watchmanact.ReadSidecar(watchmanact.SidecarPath(d.config.WorkspaceDir()))
	require.NoError(t, err)
	assert.Equal(t, watchmanact.Sidecar{}, sc)

	// Armed again: a fresh hold.
	armUpkeepSession(t, database, s)
	d.phaseWatchmanUpkeep(ctx)
	assert.Len(t, awake.holds, 2)
}

func TestWatchmanUpkeep_RecordsGapAfterSleep(t *testing.T) {
	d, database, _, clk := newUpkeepDaemon(t)
	d.SetWatchmanAwake((&fakeAwake{}).hold)
	ctx := context.Background()
	wb, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	armUpkeepSession(t, database, upkeepSession(t, database, wb, t.TempDir()))

	d.phaseWatchmanUpkeep(ctx) // 02:10
	// The Mac slept: the wall clock jumped to 07:30, the monotonic one stood still.
	start := clk.wall
	clk.advance(5*time.Hour+20*time.Minute, 0)
	d.phaseWatchmanUpkeep(ctx)
	gaps := gapRows(t, database)
	require.Len(t, gaps, 1)
	assert.Equal(t, [2]string{start.UTC().Format(time.RFC3339), clk.wall.UTC().Format(time.RFC3339)}, gaps[0])
	assert.Equal(t, "02:10", start.Format("15:04"))
	assert.Equal(t, "07:30", clk.wall.Format("15:04"))

	// A normal interval: the monotonic clock ran along with the wall clock.
	clk.advance(15*time.Minute, 15*time.Minute)
	d.phaseWatchmanUpkeep(ctx)
	assert.Len(t, gapRows(t, database), 1)

	// Nothing armed while the Mac slept: no gap.
	_, err = database.Exec(`DELETE FROM watchman_arming`)
	require.NoError(t, err)
	d.phaseWatchmanUpkeep(ctx)
	clk.advance(6*time.Hour, 0)
	d.phaseWatchmanUpkeep(ctx)
	assert.Len(t, gapRows(t, database), 1)
}

func TestWatchmanUpkeep_HoldFailureLogsAndContinues(t *testing.T) {
	d, database, logs, clk := newUpkeepDaemon(t)
	awake := &fakeAwake{err: errors.New("IOReturn -536870199")}
	d.SetWatchmanAwake(awake.hold)
	ctx := context.Background()
	wb, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	s := upkeepSession(t, database, wb, t.TempDir())
	armUpkeepSession(t, database, s)

	d.phaseWatchmanUpkeep(ctx)
	assert.Contains(t, logs.String(), WatchmanAwakeReason)
	// The cycle went on: the sidecar was still written.
	sc, err := watchmanact.ReadSidecar(watchmanact.SidecarPath(d.config.WorkspaceDir()))
	require.NoError(t, err)
	assert.Equal(t, []int64{s}, sc.Sessions)

	// Retried next cycle.
	awake.err = nil
	clk.advance(15*time.Minute, 15*time.Minute)
	d.phaseWatchmanUpkeep(ctx)
	assert.Len(t, awake.holds, 2)
	clk.advance(15*time.Minute, 15*time.Minute)
	d.phaseWatchmanUpkeep(ctx)
	assert.Len(t, awake.holds, 2, "held: not taken again")
}

func TestWatchmanUpkeep_EnsuresHooksPerArmedWorktree(t *testing.T) {
	d, database, logs, _ := newUpkeepDaemon(t)
	wb, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	folder := t.TempDir()
	s := upkeepSession(t, database, wb, folder)
	armUpkeepSession(t, database, s)
	var got []string
	d.SetWatchmanHooks(func(_ context.Context, worktree string) error {
		got = append(got, worktree)
		return errors.New("git config failed")
	})
	d.phaseWatchmanUpkeep(context.Background())
	assert.Equal(t, []string{folder}, got)
	assert.Contains(t, logs.String(), "session")
}

// Rows nothing can be decided for are pruned before the hold: an ended
// session's row goes and holds nothing awake; an armed target with no live
// session stays and holds.
func TestWatchmanUpkeep_PrunesStaleArmingBeforeHold(t *testing.T) {
	d, database, _, _ := newUpkeepDaemon(t)
	awake := &fakeAwake{}
	d.SetWatchmanAwake(awake.hold)
	ctx := context.Background()
	wb, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	s := upkeepSession(t, database, wb, t.TempDir())
	armUpkeepSession(t, database, s)
	require.NoError(t, database.UpsertWatchmanArming(db.WatchmanArming{Scope: "session", RefID: 999, ArmedAt: time.Now(), ArmedBy: "cli"}))
	_, err = database.Exec(`UPDATE terminal_sessions SET finished_at = '2026-11-18T01:00:00.000Z' WHERE id = ?`, s)
	require.NoError(t, err)

	d.phaseWatchmanUpkeep(ctx)
	rows, err := database.ListWatchmanArming()
	require.NoError(t, err)
	assert.Empty(t, rows)
	assert.Empty(t, awake.holds, "nothing left to decide for: no hold")

	res, err := database.Exec(`INSERT INTO targets (text, period_start, period_end, project_id) VALUES ('acme', '2026-11-01', '2026-11-30', ?)`, wb)
	require.NoError(t, err)
	target, err := res.LastInsertId()
	require.NoError(t, err)
	require.NoError(t, database.UpsertWatchmanArming(db.WatchmanArming{Scope: "target", RefID: target, ArmedAt: time.Now(), ArmedBy: "cli"}))
	d.phaseWatchmanUpkeep(ctx)
	rows, err = database.ListWatchmanArming()
	require.NoError(t, err)
	assert.Len(t, rows, 1)
	assert.Equal(t, []string{WatchmanAwakeReason}, awake.holds)
}

// A sidecar refresh that fails before reading (its lock cannot be taken)
// still leaves the hold and the gap recording to run from the database.
func TestWatchmanUpkeep_SidecarFailureStillHolds(t *testing.T) {
	d, database, logs, clk := newUpkeepDaemon(t)
	awake := &fakeAwake{}
	d.SetWatchmanAwake(awake.hold)
	ctx := context.Background()
	wb, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	armUpkeepSession(t, database, upkeepSession(t, database, wb, t.TempDir()))
	require.NoError(t, os.MkdirAll(watchmanact.SidecarPath(d.config.WorkspaceDir())+".lock", 0o755))

	d.phaseWatchmanUpkeep(ctx)
	assert.Contains(t, logs.String(), "watchman sidecar")
	assert.Equal(t, []string{WatchmanAwakeReason}, awake.holds)
	clk.advance(5*time.Hour, 0)
	d.phaseWatchmanUpkeep(ctx)
	assert.Len(t, gapRows(t, database), 1)
}

// The upkeep drops the instructions of a deleted session and a removed
// target; a live session's text stays, armed or not (D7).
func TestWatchmanUpkeep_PrunesInstructionRows(t *testing.T) {
	d, database, logs, _ := newUpkeepDaemon(t)
	d.SetWatchmanAwake((&fakeAwake{}).hold)
	wb, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	live := upkeepSession(t, database, wb, t.TempDir())
	require.NoError(t, database.SetWatchmanInstruction("session", live, "keep"))
	require.NoError(t, database.SetWatchmanInstruction("session", 999, "gone"))
	require.NoError(t, database.SetWatchmanInstruction("target", 998, "gone"))

	d.phaseWatchmanUpkeep(context.Background())
	var n int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM watchman_instructions`).Scan(&n))
	assert.Equal(t, 1, n)
	text, err := database.WatchmanInstruction("session", live)
	require.NoError(t, err)
	assert.Equal(t, "keep", text)
	assert.Contains(t, logs.String(), "2 instruction(s)")
}

// The upkeep drops the stall counts of sessions no longer handed over; an
// armed live session keeps its count (spec 2026-11-21-watchman-tuning §4b).
func TestWatchmanUpkeep_PrunesStallRows(t *testing.T) {
	d, database, logs, _ := newUpkeepDaemon(t)
	d.SetWatchmanAwake((&fakeAwake{}).hold)
	wb, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	armed := upkeepSession(t, database, wb, t.TempDir())
	taken := upkeepSession(t, database, wb, t.TempDir())
	require.NoError(t, database.UpsertWatchmanArming(db.WatchmanArming{Scope: "session", RefID: armed, ArmedAt: time.Now(), ArmedBy: "cli"}))
	for _, s := range []int64{armed, taken} {
		require.NoError(t, database.UpsertWatchmanStall(db.WatchmanStallRow{SessionID: s, StoppedAt: time.Now(), Pings: 2}))
	}

	d.phaseWatchmanUpkeep(context.Background())
	st, err := database.WatchmanStall(armed)
	require.NoError(t, err)
	require.NotNil(t, st)
	assert.Equal(t, 2, st.Pings)
	st, err = database.WatchmanStall(taken)
	require.NoError(t, err)
	assert.Nil(t, st, "a session not handed over loses its count")
	assert.Contains(t, logs.String(), "1 stall count(s)")
}
