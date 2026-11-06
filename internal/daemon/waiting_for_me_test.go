package daemon

import (
	"context"
	"go/parser"
	"go/token"
	"testing"

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

// Active, the slot writes one succeeded run and the `waiting` artifact
// (an empty list with nothing open), every cycle.
func TestPhaseWaitingForMe_ActiveRunsEachCycle(t *testing.T) {
	f := newMBFixture(t, nil)
	f.d.builtinActive[waitingForMeID] = true
	f.d.phaseWaitingForMe(context.Background())
	f.d.phaseWaitingForMe(context.Background())
	runs := f.waitingRuns(t)
	require.Len(t, runs, 2)
	for _, r := range runs {
		assert.Equal(t, db.RunSucceeded, r.Status, r.Error)
	}
	var n int
	require.NoError(t, f.db.QueryRow(`SELECT COUNT(*) FROM automation_outputs WHERE output_key = 'waiting'`).Scan(&n))
	assert.Equal(t, 1, n, "one living artifact")
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
