package daemon

import (
	"bytes"
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

// The gate reads the people fingerprint: a new mail item (Mail waiting's)
// leaves Waiting for me quiet.
func TestPhaseWaitingForMe_NewMailIsQuiet(t *testing.T) {
	f := newMBFixture(t, nil)
	f.d.builtinActive[waitingForMeID] = true
	f.d.phaseWaitingForMe(context.Background())
	require.Len(t, f.waitingRuns(t), 1)
	_, err := f.db.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, snippet, created_at)
		VALUES ('gmail', '2000.0001', 'a@example.com', 'email_received', 'Hello — body', ?)`, time.Now().UTC().Format(time.RFC3339))
	require.NoError(t, err)
	f.d.phaseWaitingForMe(context.Background())
	assert.Len(t, f.waitingRuns(t), 1, "a mail item does not run Waiting for me")
}

// wireWaitingRunner points the daemon's slot runner at an executor whose
// attention.waiting fails while fail is set (the gates still read), with
// Waiting for me active.
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
	gates := map[string]builtin.Gate{waitingForMeID: f.d.WaitingForMeGate(), mailWaitingID: f.d.MailWaitingGate()}
	r := builtin.NewRunner(f.db, exec, gates, f.cfg, f.clock, f.d.logger)
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
	var logBuf bytes.Buffer
	f.d.SetLogger(log.New(&logBuf, "", 0))
	f.d.phaseWaitingForMe(context.Background())
	runs := f.waitingRuns(t)
	require.Len(t, runs, 1)
	assert.Equal(t, db.RunCancelled, runs[0].Status)
	// It has no legacy phase: the log line says it is not active.
	assert.Contains(t, logBuf.String(), "1 queued run(s) cancelled: it is not active")
	assert.NotContains(t, logBuf.String(), "legacy phases")
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

// mailRuns is Mail waiting's runs.
func (f *mbFixture) mailRuns(t *testing.T) []db.AutomationRun {
	t.Helper()
	a, err := f.db.GetBuiltinAutomation(mailWaitingID)
	require.NoError(t, err)
	runs, err := f.db.ListAutomationRuns(a.ID, 0)
	require.NoError(t, err)
	return runs
}

// insertMail adds one open mail item from sender at now.
func (f *mbFixture) insertMail(t *testing.T, ts, sender string) {
	t.Helper()
	_, err := f.db.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, snippet, created_at)
		VALUES ('gmail', ?, ?, 'email_received', 'Hello — body', ?)`, ts, sender, time.Now().UTC().Format(time.RFC3339))
	require.NoError(t, err)
}

// Both active, Mail waiting runs once and writes its `mail` artifact; a
// quiet cycle writes no run, a new people item leaves it quiet, a new
// sender makes the next cycle run.
func TestPhaseWaitingForMe_MailRunsOnlyWhenSendersChanged(t *testing.T) {
	f := newMBFixture(t, nil)
	f.d.builtinActive[waitingForMeID] = true
	f.d.builtinActive[mailWaitingID] = true
	f.d.phaseWaitingForMe(context.Background())
	f.d.phaseWaitingForMe(context.Background())
	runs := f.mailRuns(t)
	require.Len(t, runs, 1, "a quiet cycle writes no run")
	assert.Equal(t, db.RunSucceeded, runs[0].Status, runs[0].Error)
	assert.Equal(t, 1, countRows(t, f.db, `SELECT COUNT(*) FROM automation_outputs WHERE output_key = 'mail'`), "one living artifact")

	_, err := f.db.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, created_at)
		VALUES ('C001', '1000.0001', 'U001', 'mention', ?)`, time.Now().UTC().Format(time.RFC3339))
	require.NoError(t, err)
	f.d.phaseWaitingForMe(context.Background())
	assert.Len(t, f.mailRuns(t), 1, "a people item does not run Mail waiting")
	assert.Len(t, f.waitingRuns(t), 2, "it runs Waiting for me")

	f.insertMail(t, "2000.0001", "a@example.com")
	f.d.phaseWaitingForMe(context.Background())
	assert.Len(t, f.mailRuns(t), 2, "a new sender runs")
	f.d.phaseWaitingForMe(context.Background())
	assert.Len(t, f.mailRuns(t), 2, "and the cycle after it is quiet again")
}

// A failed Mail waiting run records nothing as shown: the next cycle runs
// it again, and a success then makes the cycle after it quiet.
func TestPhaseWaitingForMe_MailFailedRunRetriedNextCycle(t *testing.T) {
	f := newMBFixture(t, nil)
	var fail atomic.Bool
	fail.Store(true)
	f.wireWaitingRunner(t, &fail)
	f.d.builtinActive[mailWaitingID] = true
	f.d.phaseWaitingForMe(context.Background())
	runs := f.mailRuns(t)
	require.Len(t, runs, 1)
	assert.Equal(t, db.RunFailed, runs[0].Status)
	fail.Store(false)
	f.d.phaseWaitingForMe(context.Background())
	runs = f.mailRuns(t)
	require.Len(t, runs, 2, "the failure is retried the next cycle")
	assert.Equal(t, db.RunSucceeded, runs[0].Status, runs[0].Error)
	f.d.phaseWaitingForMe(context.Background())
	assert.Len(t, f.mailRuns(t), 2, "quiet after the success")
}

// Muting a sender changes what Mail waiting shows: the next cycle runs it,
// and Waiting for me stays quiet.
func TestPhaseWaitingForMe_MuteChangesMailFingerprint(t *testing.T) {
	f := newMBFixture(t, nil)
	f.d.builtinActive[waitingForMeID] = true
	f.d.builtinActive[mailWaitingID] = true
	f.insertMail(t, "2000.0001", "news@example.com")
	f.insertMail(t, "2000.0002", "a@example.com")
	f.d.phaseWaitingForMe(context.Background())
	require.Len(t, f.mailRuns(t), 1)
	_, err := f.db.Exec(`INSERT INTO inbox_learned_rules (rule_type, scope_key, weight, source, last_updated)
		VALUES ('source_mute', 'email:news@example.com', -1, 'user_rule', ?)`, time.Now().UTC().Format(time.RFC3339))
	require.NoError(t, err)
	f.d.phaseWaitingForMe(context.Background())
	assert.Len(t, f.mailRuns(t), 2, "a mute runs Mail waiting")
	assert.Len(t, f.waitingRuns(t), 1, "and leaves Waiting for me quiet")
	f.d.phaseWaitingForMe(context.Background())
	assert.Len(t, f.mailRuns(t), 2, "quiet after it")
}

// Waiting for me active, Mail waiting not (its row did not sync or move):
// the slot cancels Mail waiting's queued Run Now and never runs it.
func TestPhaseWaitingForMe_MailNotActiveCancelsQueuedRun(t *testing.T) {
	f := newMBFixture(t, nil)
	f.d.builtinActive[waitingForMeID] = true
	a, err := f.db.GetBuiltinAutomation(mailWaitingID)
	require.NoError(t, err)
	_, _, err = builtin.EnqueueManual(f.db, a.ID, automations.BuiltinInput{}, f.clock.Now())
	require.NoError(t, err)
	f.d.phaseWaitingForMe(context.Background())
	runs := f.mailRuns(t)
	require.Len(t, runs, 1)
	assert.Equal(t, db.RunCancelled, runs[0].Status)
	require.Len(t, f.waitingRuns(t), 1, "Waiting for me still runs")
	f.d.phaseWaitingForMe(context.Background())
	assert.Len(t, f.mailRuns(t), 1, "no sync run while it is not active")
}

// Neither active: the slot runs nothing and cancels both queued Run Nows.
func TestPhaseWaitingForMe_NeitherActiveCancelsBoth(t *testing.T) {
	f := newMBFixture(t, nil)
	for _, id := range []string{waitingForMeID, mailWaitingID} {
		a, err := f.db.GetBuiltinAutomation(id)
		require.NoError(t, err)
		_, _, err = builtin.EnqueueManual(f.db, a.ID, automations.BuiltinInput{}, f.clock.Now())
		require.NoError(t, err)
	}
	f.d.phaseWaitingForMe(context.Background())
	for _, runs := range [][]db.AutomationRun{f.waitingRuns(t), f.mailRuns(t)} {
		require.Len(t, runs, 1)
		assert.Equal(t, db.RunCancelled, runs[0].Status)
	}
}
