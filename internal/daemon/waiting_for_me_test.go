package daemon

import (
	"context"
	"errors"
	"go/parser"
	"go/token"
	"io"
	"log"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/automations"
	"watchtower/internal/automations/builtin"
	"watchtower/internal/db"
)

// Waiting for me runs right after the attention detector in runSync, so its
// list follows the pass that just ran.
func TestDaemon_WaitingForMeRunsRightAfterInbox(t *testing.T) {
	file, err := parser.ParseFile(token.NewFileSet(), "daemon.go", nil, 0)
	require.NoError(t, err)
	order := topLevelCallOrder(daemonFunc(t, file, "runSync", true))
	inbox, ok := order["phaseInbox"]
	require.True(t, ok, "runSync must run phaseInbox")
	waiting, ok := order["phaseWaitingForMe"]
	require.True(t, ok, "runSync must run phaseWaitingForMe")
	assert.Equal(t, inbox+1, waiting, "phaseWaitingForMe must be the statement right after phaseInbox")
}

// waitingRuns is Waiting for me's runs.
func (f *mbFixture) waitingRuns(t *testing.T) []db.AutomationRun {
	t.Helper()
	a, err := f.db.GetBuiltinAutomation(waitingForMeID)
	require.NoError(t, err)
	runs, err := f.db.ListAutomationRuns(a.ID, 0)
	require.NoError(t, err)
	return runs
}

// Active, the first cycle writes one succeeded run and the `waiting`
// artifact (an empty list with nothing open); a quiet cycle after it writes
// no run; a new open item makes the next cycle run.
func TestPhaseWaitingForMe_RunsOnlyWhenWhatItShowsChanged(t *testing.T) {
	f := newMBFixture(t, nil)
	f.d.builtinActive[waitingForMeID] = true
	f.d.phaseWaitingForMe(context.Background())
	f.d.phaseWaitingForMe(context.Background())
	runs := f.waitingRuns(t)
	require.Len(t, runs, 1, "a quiet cycle writes no run")
	assert.Equal(t, db.RunSucceeded, runs[0].Status, runs[0].Error)
	var n int
	require.NoError(t, f.db.QueryRow(`SELECT COUNT(*) FROM automation_outputs WHERE output_key = 'waiting'`).Scan(&n))
	assert.Equal(t, 1, n, "one living artifact")

	_, err := f.db.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, created_at)
		VALUES ('C001', '1000.0001', 'U001', 'mention', ?)`, time.Now().UTC().Format(time.RFC3339))
	require.NoError(t, err)
	f.d.phaseWaitingForMe(context.Background())
	assert.Len(t, f.waitingRuns(t), 2, "a new item runs")
	f.d.phaseWaitingForMe(context.Background())
	assert.Len(t, f.waitingRuns(t), 2, "and the cycle after it is quiet again")
}

// wireWaitingRunner points the daemon's slot runner at an executor whose
// attention.waiting fails while fail is set (the gate still reads).
func (f *mbFixture) wireWaitingRunner(t *testing.T, fail *atomic.Bool) {
	t.Helper()
	prims := f.d.BuiltinPrimitives()
	read := prims[automations.PrimitiveAttentionWaiting]
	prims[automations.PrimitiveAttentionWaiting] = func(ctx context.Context, c automations.PrimitiveCall) (automations.PrimitiveResult, error) {
		if fail.Load() {
			return automations.PrimitiveResult{}, errors.New("read failed")
		}
		return read(ctx, c)
	}
	b := automations.Backends{DB: f.db, Clock: f.clock, Primitives: prims, DefaultPrompt: builtin.DefaultPromptFunc}
	exec := automations.NewExecutor(f.db, b, automations.ExecutorOptions{Logger: log.New(io.Discard, "", 0)})
	r := builtin.NewRunner(f.db, exec, map[string]builtin.Gate{waitingForMeID: f.d.WaitingForMeGate()}, f.cfg, f.clock, f.d.logger)
	f.d.SetBuiltins(r, map[string]bool{waitingForMeID: true})
}

// A failed run records nothing as shown: the next cycle runs again, and a
// success then makes the cycle after it quiet.
func TestPhaseWaitingForMe_FailedRunIsRetriedNextCycle(t *testing.T) {
	f := newMBFixture(t, nil)
	var fail atomic.Bool
	fail.Store(true)
	f.wireWaitingRunner(t, &fail)
	f.d.phaseWaitingForMe(context.Background())
	runs := f.waitingRuns(t)
	require.Len(t, runs, 1)
	assert.Equal(t, db.RunFailed, runs[0].Status)
	fail.Store(false)
	f.d.phaseWaitingForMe(context.Background())
	runs = f.waitingRuns(t)
	require.Len(t, runs, 2, "the failure is retried the next cycle")
	assert.Equal(t, db.RunSucceeded, runs[0].Status, runs[0].Error)
	f.d.phaseWaitingForMe(context.Background())
	assert.Len(t, f.waitingRuns(t), 2, "quiet after the success")
}

// Run Now runs whatever the gate would say: a queued manual run is taken
// at the slot even on a quiet cycle.
func TestPhaseWaitingForMe_RunNowBypassesTheGate(t *testing.T) {
	f := newMBFixture(t, nil)
	f.d.builtinActive[waitingForMeID] = true
	f.d.phaseWaitingForMe(context.Background())
	require.Len(t, f.waitingRuns(t), 1)
	a, err := f.db.GetBuiltinAutomation(waitingForMeID)
	require.NoError(t, err)
	_, _, err = builtin.EnqueueManual(f.db, a.ID, automations.BuiltinInput{}, f.clock.Now())
	require.NoError(t, err)
	f.d.phaseWaitingForMe(context.Background())
	runs := f.waitingRuns(t)
	require.Len(t, runs, 2, "Run Now ran on a quiet cycle")
	assert.Equal(t, db.RunSucceeded, runs[0].Status, runs[0].Error)
	assert.Equal(t, db.TriggerManual, runs[0].Trigger)
}

// Not active (its row did not sync or move), the slot runs nothing and
// cancels a queued Run Now, which only the slot would take.
func TestPhaseWaitingForMe_NotActiveCancelsQueuedRun(t *testing.T) {
	f := newMBFixture(t, nil)
	a, err := f.db.GetBuiltinAutomation(waitingForMeID)
	require.NoError(t, err)
	_, _, err = builtin.EnqueueManual(f.db, a.ID, automations.BuiltinInput{}, f.clock.Now())
	require.NoError(t, err)
	f.d.phaseWaitingForMe(context.Background())
	runs := f.waitingRuns(t)
	require.Len(t, runs, 1)
	assert.Equal(t, db.RunCancelled, runs[0].Status)
}

// Attention detection off: the slot skips it and writes no run (FEAT-01).
func TestPhaseWaitingForMe_DetectionOffWritesNoRun(t *testing.T) {
	f := newMBFixture(t, nil)
	f.cfg.Inbox.Enabled = false
	f.d.builtinActive[waitingForMeID] = true
	f.d.phaseWaitingForMe(context.Background())
	assert.Empty(t, f.waitingRuns(t))
}

// An owner's copy (overridden) runs every cycle: the fingerprint covers
// only what the shipped recipe shows.
func TestPhaseWaitingForMe_OwnerCopyRunsEveryCycle(t *testing.T) {
	f := newMBFixture(t, nil)
	f.d.builtinActive[waitingForMeID] = true
	_, err := f.db.Exec(`UPDATE automations SET overridden = 1 WHERE builtin_id = ?`, waitingForMeID)
	require.NoError(t, err)
	f.d.phaseWaitingForMe(context.Background())
	f.d.phaseWaitingForMe(context.Background())
	runs := f.waitingRuns(t)
	require.Len(t, runs, 2, "no quiet-cycle skip for an owner's copy")
	for _, r := range runs {
		assert.Equal(t, db.RunSucceeded, r.Status, r.Error)
	}
}

// A Run Now that fails after a succeeded run is retried at the next cycle
// even though the open items did not change.
func TestPhaseWaitingForMe_FailedRunNowIsRetriedNextCycle(t *testing.T) {
	f := newMBFixture(t, nil)
	var fail atomic.Bool
	f.wireWaitingRunner(t, &fail)
	f.d.phaseWaitingForMe(context.Background())
	require.Len(t, f.waitingRuns(t), 1)

	fail.Store(true)
	a, err := f.db.GetBuiltinAutomation(waitingForMeID)
	require.NoError(t, err)
	_, _, err = builtin.EnqueueManual(f.db, a.ID, automations.BuiltinInput{}, f.clock.Now())
	require.NoError(t, err)
	f.d.phaseWaitingForMe(context.Background())
	runs := f.waitingRuns(t)
	require.Len(t, runs, 2)
	assert.Equal(t, db.RunFailed, runs[0].Status)
	assert.Equal(t, db.TriggerManual, runs[0].Trigger)

	fail.Store(false)
	f.d.phaseWaitingForMe(context.Background())
	runs = f.waitingRuns(t)
	require.Len(t, runs, 3, "the failed Run Now is retried by the next cycle")
	assert.Equal(t, db.RunSucceeded, runs[0].Status, runs[0].Error)
	f.d.phaseWaitingForMe(context.Background())
	assert.Len(t, f.waitingRuns(t), 3, "quiet after the success")
}
