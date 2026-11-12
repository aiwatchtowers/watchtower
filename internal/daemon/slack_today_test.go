package daemon

import (
	"context"
	"fmt"
	"go/parser"
	"go/token"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/automations"
	"watchtower/internal/automations/builtin"
	"watchtower/internal/db"
	"watchtower/internal/policy/policytest"
)

// stFixture is the Morning brief fixture (an owner on Slack account 1) with
// Slack today's row, a member channel and the gate under test; now is the
// fixture's 10:00 local.
type stFixture struct {
	*mbFixture
	id    int64
	entry builtin.Entry
	now   time.Time
	seq   int
}

func newSTFixture(t *testing.T) *stFixture {
	t.Helper()
	f := newMBFixture(t, nil)
	a, err := f.db.GetBuiltinAutomation(slackTodayID)
	require.NoError(t, err)
	e, ok := builtin.Lookup(slackTodayID)
	require.True(t, ok)
	_, err = f.db.Exec(`INSERT INTO channels (id, name, type, is_member) VALUES ('1:C1', 'release', 'public', 1)`)
	require.NoError(t, err)
	return &stFixture{mbFixture: f, id: a.ID, entry: e, now: mbAt(10, 0)}
}

func (f *stFixture) due(t *testing.T) bool {
	t.Helper()
	return f.d.SlackTodayGate().Due(context.Background(), f.entry, f.now)
}

// message inserts a channel message at.
func (f *stFixture) message(t *testing.T, at time.Time) {
	t.Helper()
	f.seq++
	_, err := f.db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:C1', ?, 'U002', 'hello')`,
		fmt.Sprintf("%d.%06d", at.Unix(), f.seq))
	require.NoError(t, err)
}

// state commits the recipe's state: today's day and the window cursor.
func (f *stFixture) state(t *testing.T, day string, after int64, behind bool) {
	t.Helper()
	f.rawState(t, fmt.Sprintf(`{"today":{"v":1,"day":%q},"__window:slack":{"v":1,"after_rowid":%d,"behind":%t}}`,
		day, after, behind))
}

func (f *stFixture) rawState(t *testing.T, s string) {
	t.Helper()
	_, err := f.db.Exec(`INSERT INTO automation_state (automation_id, state_json) VALUES (?, ?)
		ON CONFLICT(automation_id) DO UPDATE SET state_json = excluded.state_json`, f.id, s)
	require.NoError(t, err)
}

// today commits today's state with the cursor past every message so far.
func (f *stFixture) today(t *testing.T) {
	t.Helper()
	var last int64
	require.NoError(t, f.db.QueryRow(`SELECT COALESCE(MAX(rowid), 0) FROM messages`).Scan(&last))
	f.state(t, f.now.Format("2006-01-02"), last, false)
}

// run records a sync run of status queued ago.
func (f *stFixture) run(t *testing.T, status string, ago time.Duration) {
	t.Helper()
	_, err := f.db.Exec(`INSERT INTO automation_runs (automation_id, trigger, status, queued_at) VALUES (?, 'sync', ?, ?)`,
		f.id, status, f.now.Add(-ago).UTC().Format("2006-01-02T15:04:05Z"))
	require.NoError(t, err)
}

func (f *stFixture) clearRuns(t *testing.T) {
	t.Helper()
	_, err := f.db.Exec(`DELETE FROM automation_runs WHERE automation_id = ?`, f.id)
	require.NoError(t, err)
}

// dueSetup is a state from earlier today, a new message past its cursor and
// a succeeded run two hours ago: everything the gate needs to be due.
func (f *stFixture) dueSetup(t *testing.T) {
	t.Helper()
	f.message(t, f.now.Add(-3*time.Hour))
	f.today(t)
	f.message(t, f.now.Add(-time.Hour))
	f.run(t, db.RunSucceeded, 2*time.Hour)
}

func TestSlackTodayGate_NoSlackAccountNotDue(t *testing.T) {
	f := newSTFixture(t)
	f.dueSetup(t)
	require.True(t, f.due(t), "precondition: due with an enabled account")

	_, err := f.db.Exec(`UPDATE slack_accounts SET status = 'removed'`)
	require.NoError(t, err)
	assert.False(t, f.due(t), "a removed account is no account")
	_, err = f.db.Exec(`UPDATE slack_accounts SET status = 'purged'`)
	require.NoError(t, err)
	assert.False(t, f.due(t), "a purged account is no account")
	_, err = f.db.Exec(`UPDATE slack_accounts SET status = 'ok', enabled = 0`)
	require.NoError(t, err)
	assert.False(t, f.due(t), "a disabled account is no account")
	_, err = f.db.Exec(`DELETE FROM slack_accounts`)
	require.NoError(t, err)
	assert.False(t, f.due(t))
}

func TestSlackTodayGate_PolicyOffNotDue(t *testing.T) {
	f := newSTFixture(t)
	f.dueSetup(t)
	require.True(t, f.due(t))
	policytest.Set(t, map[string]any{"AllowedSources": []any{"jira"}})
	assert.False(t, f.due(t), "Slack off by policy")
}

func TestSlackTodayGate_DayChangeIsDueWithoutMaterial(t *testing.T) {
	f := newSTFixture(t)
	f.message(t, f.now.Add(-time.Hour))
	f.today(t)
	f.run(t, db.RunSucceeded, 2*time.Minute)
	require.False(t, f.due(t), "precondition: today's state, nothing new, a run just now")

	f.state(t, f.now.AddDate(0, 0, -1).Format("2006-01-02"), 1, false)
	assert.True(t, f.due(t), "yesterday's state resets after midnight, no new message needed")

	f.rawState(t, `{}`)
	assert.True(t, f.due(t), "no day yet: the first run makes the card")
}

func TestSlackTodayGate_WithinTheHourNotDue(t *testing.T) {
	f := newSTFixture(t)
	f.message(t, f.now.Add(-3*time.Hour))
	f.today(t)
	f.message(t, f.now.Add(-time.Hour))
	f.run(t, db.RunSucceeded, 59*time.Minute)
	assert.False(t, f.due(t), "59 minutes after a succeeded run")
	f.clearRuns(t)
	f.run(t, db.RunSucceeded, 60*time.Minute)
	assert.True(t, f.due(t), "60 minutes after it")
	f.clearRuns(t)
	assert.True(t, f.due(t), "no run yet")
}

func TestSlackTodayGate_TruncatedWindowIsDueAtOnce(t *testing.T) {
	f := newSTFixture(t)
	f.message(t, f.now.Add(-time.Hour))
	f.state(t, f.now.Format("2006-01-02"), 0, true)
	f.run(t, db.RunSucceeded, 2*time.Minute)
	assert.True(t, f.due(t), "a window cut by a cap continues the next cycle")
}

func TestSlackTodayGate_FailedRunRetriedAfter15Minutes(t *testing.T) {
	f := newSTFixture(t)
	f.message(t, f.now.Add(-3*time.Hour))
	f.today(t)
	f.message(t, f.now.Add(-time.Hour))
	f.run(t, db.RunSucceeded, 30*time.Minute)
	f.run(t, db.RunFailed, 14*time.Minute)
	assert.False(t, f.due(t), "14 minutes after a failed run")

	f.clearRuns(t)
	f.run(t, db.RunSucceeded, 30*time.Minute)
	f.run(t, db.RunFailed, 15*time.Minute)
	assert.True(t, f.due(t), "15 minutes after a failed run, within the hour of the success")

	f.clearRuns(t)
	f.run(t, db.RunTimedOut, 20*time.Minute)
	assert.True(t, f.due(t), "a timed-out run with no success is retried too")

	f.clearRuns(t)
	f.run(t, db.RunFailed, 50*time.Minute)
	f.run(t, db.RunSucceeded, 30*time.Minute)
	assert.False(t, f.due(t), "a failure older than the success is the hour's rule")
}

// A failing run is not retried every cycle: within 15 minutes of a failed
// sync run newer than the last success, neither a stale day nor a cut
// window makes the gate due; at 15 minutes both do.
func TestSlackTodayGate_FailedRunHoldsDayChangeAndBehind(t *testing.T) {
	f := newSTFixture(t)
	f.message(t, f.now.Add(-time.Hour))
	yesterday := f.now.AddDate(0, 0, -1).Format("2006-01-02")
	today := f.now.Format("2006-01-02")
	for _, tc := range []struct {
		name   string
		day    string
		behind bool
	}{{"stale day", yesterday, false}, {"behind", today, true}} {
		f.state(t, tc.day, 0, tc.behind)
		f.clearRuns(t)
		f.run(t, db.RunSucceeded, 3*time.Hour)
		f.run(t, db.RunFailed, 5*time.Minute)
		assert.False(t, f.due(t), "%s: failed 5 minutes ago", tc.name)
		f.clearRuns(t)
		f.run(t, db.RunFailed, 5*time.Minute)
		assert.False(t, f.due(t), "%s: failed 5 minutes ago, no success yet", tc.name)
		f.clearRuns(t)
		f.run(t, db.RunSucceeded, 3*time.Hour)
		f.run(t, db.RunFailed, 15*time.Minute)
		assert.True(t, f.due(t), "%s: failed 15 minutes ago", tc.name)
	}
}

func TestSlackTodayGate_NoMaterialNotDue(t *testing.T) {
	f := newSTFixture(t)
	f.message(t, f.now.Add(-time.Hour))
	f.today(t)
	f.run(t, db.RunSucceeded, 2*time.Hour)
	assert.False(t, f.due(t), "nothing past the cursor")

	f.message(t, f.now.Add(-11*time.Hour))
	assert.False(t, f.due(t), "a message from before local midnight is below the floor")
}

func TestSlackTodayGate_ReadErrorIsDue(t *testing.T) {
	f := newSTFixture(t)
	f.message(t, f.now.Add(-time.Hour))
	f.today(t)
	f.run(t, db.RunSucceeded, 2*time.Minute)
	require.False(t, f.due(t))

	f.rawState(t, `[1]`)
	assert.True(t, f.due(t), "an unreadable state counts as due")
	assert.Contains(t, f.log.String(), "slack-today: ")

	f.rawState(t, fmt.Sprintf(`{"today":{"v":1,"day":%q},"__window:slack":{"v":9}}`, f.now.Format("2006-01-02")))
	assert.True(t, f.due(t), "an unreadable cursor counts as due")
}

// Slack today runs right after Waiting for me in runSync.
func TestPhaseSlackToday_RunsAfterWaitingForMe(t *testing.T) {
	file, err := parser.ParseFile(token.NewFileSet(), "daemon.go", nil, 0)
	require.NoError(t, err)
	order := topLevelCallOrder(daemonFunc(t, file, "runSync", true))
	waiting, ok := order["phaseWaitingForMe"]
	require.True(t, ok, "runSync must run phaseWaitingForMe")
	today, ok := order["phaseSlackToday"]
	require.True(t, ok, "runSync must run phaseSlackToday")
	assert.Equal(t, waiting+1, today, "phaseSlackToday must be the statement right after phaseWaitingForMe")
}

func (f *stFixture) runs(t *testing.T) []db.AutomationRun {
	t.Helper()
	runs, err := f.db.ListAutomationRuns(f.id, 0)
	require.NoError(t, err)
	return runs
}

// Not active (its row did not sync or move), the slot runs nothing and
// cancels a queued Run Now, which only the slot would take.
func TestPhaseSlackToday_NotActiveCancelsQueuedRun(t *testing.T) {
	f := newSTFixture(t)
	_, _, err := builtin.EnqueueManual(f.db, f.id, automations.BuiltinInput{}, f.clock.Now())
	require.NoError(t, err)
	f.d.phaseSlackToday(context.Background())
	runs := f.runs(t)
	require.Len(t, runs, 1)
	assert.Equal(t, db.RunCancelled, runs[0].Status)
}

// Slack today off: the slot writes no run and cancels a queued Run Now
// (FEAT-01).
func TestPhaseSlackToday_OffWritesNoRun(t *testing.T) {
	f := newSTFixture(t)
	f.cfg.SlackToday.Enabled = false
	f.d.builtinActive[slackTodayID] = true
	f.dueSetup(t)
	f.clearRuns(t)
	f.d.phaseSlackToday(context.Background())
	assert.Empty(t, f.runs(t))

	_, _, err := builtin.EnqueueManual(f.db, f.id, automations.BuiltinInput{}, f.clock.Now())
	require.NoError(t, err)
	f.d.phaseSlackToday(context.Background())
	runs := f.runs(t)
	require.Len(t, runs, 1)
	assert.Equal(t, db.RunCancelled, runs[0].Status)
}
