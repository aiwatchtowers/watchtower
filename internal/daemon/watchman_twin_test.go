package daemon

import (
	"context"
	"database/sql"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"

	"github.com/stretchr/testify/require"

	"watchtower/internal/asks"
	"watchtower/internal/db"
)

// fakeTwin counts the worker's passes.
type fakeTwin struct {
	runs, held atomic.Int32
	waited     atomic.Bool
}

func (f *fakeTwin) RunOnce(context.Context) int { f.runs.Add(1); return 0 }
func (f *fakeTwin) Wait()                       { f.waited.Store(true) }
func (f *fakeTwin) DeliverHeld(context.Context) { f.held.Add(1) }

// A wait point's wake runs a pass at once — the scan queues what no writer
// queued, then the lease — with no sync cycle; stopping waits for the items.
func TestWatchmanTwinPhase_WakeRunsWithoutWaitingForCycle(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		d, database, _ := newBackfillDaemon(t)
		twin := &fakeTwin{}
		d.watchmanTwin = twin
		stop := d.startWatchmanTwin(context.Background())
		synctest.Wait()
		require.Equal(t, int32(1), twin.runs.Load(), "a pass at start")

		// An armed session's open ask that no writer queued.
		wb, err := database.CreateWorkbench("acme", t.TempDir())
		require.NoError(t, err)
		res, err := database.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id)
			VALUES (?, 'claude', 'New session', '/tmp/acme', 'uuid')`, wb)
		require.NoError(t, err)
		session, _ := res.LastInsertId()
		require.NoError(t, database.UpsertWatchmanArming(db.WatchmanArming{Scope: "session", RefID: session, ArmedAt: time.Now(), ArmedBy: "cli"}))
		var askID int64
		require.NoError(t, database.WithTx(func(tx *sql.Tx) error {
			askID, _, err = database.InsertOwnerAsk(tx, db.OwnerAsk{WorkbenchID: wb, SessionID: sql.NullInt64{Int64: session, Valid: true},
				Kind: asks.KindQuestion, Title: "Which store?", Payload: `{"questions":[]}`})
			return err
		}))

		d.watchmanWakeCh <- struct{}{}
		synctest.Wait()
		require.Equal(t, int32(2), twin.runs.Load(), "the wake ran a pass without a cycle")
		require.Equal(t, int32(2), twin.held.Load())
		it, err := database.WatchmanItemByRef("ask", askID, "ask")
		require.NoError(t, err)
		require.NotNil(t, it, "the pass scanned the wait points first")

		d.nudgeWatchmanTwin() // a cycle's nudge
		synctest.Wait()
		require.Equal(t, int32(3), twin.runs.Load())

		stop()
		require.True(t, twin.waited.Load(), "stop waits for the deciding items")
	})
}

func TestWatchmanTwinPhase_NotWiredIsOff(t *testing.T) {
	d, _, _ := newBackfillDaemon(t)
	stop := d.startWatchmanTwin(context.Background())
	d.nudgeWatchmanTwin() // no channel: a no-op
	stop()
}
