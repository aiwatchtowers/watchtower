package builtin

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/automations"
	"watchtower/internal/db"
)

// seedNeedsApproval indexes a needs-approval built-in row (event trigger
// approval) and makes it runnable unless off; it returns its id. Task 8 ships
// the recipe; until then the row stands in for it.
func seedNeedsApproval(t *testing.T, d *db.DB, runnable bool) int64 {
	t.Helper()
	id, err := d.UpsertBuiltinAutomation(db.Automation{
		BuiltinID: NeedsApprovalID, Slug: NeedsApprovalID, Name: "Needs approval",
		TriggerKind: "event", TriggerSpec: `{"type":"approval"}`,
		PermissionsJSON: `["builtin:approvals.list"]`, OutputsJSON: `["inbox"]`,
		RecipeText: "---\nname: Needs approval\n---\n", ContentHash: "c-na", ApprovalHash: "h-na",
	})
	require.NoError(t, err)
	if runnable {
		require.NoError(t, d.ConfirmShippedBuiltin(id, "c-na", "h-na", testStart))
		require.NoError(t, d.SetBuiltinEnabled(NeedsApprovalID, true, testStart))
	}
	return id
}

func approvalRuns(t *testing.T, d *db.DB, id int64) []db.AutomationRun {
	t.Helper()
	runs, err := d.ListAutomationRuns(id, 0)
	require.NoError(t, err)
	return runs
}

func payloadOf(t *testing.T, run db.AutomationRun) db.AutomationEventPayload {
	t.Helper()
	var p db.AutomationEventPayload
	require.NoError(t, json.Unmarshal([]byte(run.EventJSON), &p))
	return p
}

func eventRefs(t *testing.T, p db.AutomationEventPayload) []string {
	t.Helper()
	var refs []string
	for _, raw := range p.Events {
		var e map[string]any
		require.NoError(t, json.Unmarshal(raw, &e))
		assert.Equal(t, automations.ApprovalEvent, e["type"])
		refs = append(refs, e["ref"].(string))
	}
	return refs
}

func TestApprovalFire_QueuesOneEventRunAndWakes(t *testing.T) {
	d := db.OpenTestDB(t)
	id := seedNeedsApproval(t, d, true)
	act, err := d.InsertAgentAction(db.AgentAction{Tool: "create_target", ArgsJSON: `{}`})
	require.NoError(t, err)
	wakes := 0
	require.NoError(t, Fire(d, db.ActionRef(act), func() { wakes++ }))

	runs := approvalRuns(t, d, id)
	require.Len(t, runs, 1)
	assert.Equal(t, db.TriggerEvent, runs[0].Trigger)
	assert.Equal(t, db.RunQueued, runs[0].Status)
	p := payloadOf(t, runs[0])
	assert.Equal(t, []string{db.ActionRef(act)}, eventRefs(t, p))
	assert.Equal(t, 1, p.Count)
	assert.False(t, p.Truncated)
	assert.Equal(t, 1, wakes)
}

// AUTO-05 / AUTO-09: a burst is one queued run; a ref already in it merges as
// a no-op.
func TestApprovalFire_SecondFireMergesIntoTheQueuedRun(t *testing.T) {
	d := db.OpenTestDB(t)
	id := seedNeedsApproval(t, d, true)
	for _, ref := range []string{"reminder:7", "reminder:3", "reminder:7"} {
		require.NoError(t, Fire(d, ref, nil))
	}
	runs := approvalRuns(t, d, id)
	require.Len(t, runs, 1, "one queued run takes every ref")
	p := payloadOf(t, runs[0])
	assert.Equal(t, []string{"reminder:7", "reminder:3"}, eventRefs(t, p))
	assert.Equal(t, 2, p.Count)
}

func TestApprovalFire_101RefsCapAt100AndTruncated(t *testing.T) {
	d := db.OpenTestDB(t)
	id := seedNeedsApproval(t, d, true)
	for i := 1; i <= 101; i++ {
		require.NoError(t, Fire(d, fmt.Sprintf("reminder:%d", i), nil))
	}
	runs := approvalRuns(t, d, id)
	require.Len(t, runs, 1)
	p := payloadOf(t, runs[0])
	assert.Len(t, p.Events, automations.MaxEventsPerRun)
	assert.Len(t, p.Cycles, automations.MaxEventsPerRun, "the refs are capped with the events")
	assert.Equal(t, 101, p.Count)
	assert.True(t, p.Truncated)
}

func TestApprovalFire_ClaimedRunGetsANewOne(t *testing.T) {
	d := db.OpenTestDB(t)
	id := seedNeedsApproval(t, d, true)
	require.NoError(t, Fire(d, "reminder:1", nil))
	first := approvalRuns(t, d, id)[0]
	ok, err := d.ClaimAutomationRun(first.ID, "h-na", "", 0, 0, testStart)
	require.NoError(t, err)
	require.True(t, ok)

	require.NoError(t, Fire(d, "reminder:2", nil))
	runs := approvalRuns(t, d, id)
	require.Len(t, runs, 2)
	assert.Equal(t, db.RunQueued, runs[0].Status, "newest first")
	assert.Equal(t, []string{"reminder:2"}, eventRefs(t, payloadOf(t, runs[0])))
}

func TestApprovalFire_NotRunnableQueuesNothing(t *testing.T) {
	t.Run("not indexed", func(t *testing.T) {
		d := db.OpenTestDB(t)
		require.NoError(t, Fire(d, "reminder:1", func() { t.Error("woke") }))
	})
	t.Run("unconfirmed", func(t *testing.T) {
		d := db.OpenTestDB(t)
		id := seedNeedsApproval(t, d, false)
		require.NoError(t, d.SetBuiltinEnabled(NeedsApprovalID, true, testStart))
		require.NoError(t, Fire(d, "reminder:1", func() { t.Error("woke") }))
		assert.Empty(t, approvalRuns(t, d, id))
	})
	t.Run("off", func(t *testing.T) {
		d := db.OpenTestDB(t)
		id := seedNeedsApproval(t, d, true)
		require.NoError(t, d.SetBuiltinEnabled(NeedsApprovalID, false, testStart))
		require.NoError(t, Fire(d, "reminder:1", func() { t.Error("woke") }))
		assert.Empty(t, approvalRuns(t, d, id))
	})
	t.Run("stopped by the daemon", func(t *testing.T) {
		d := db.OpenTestDB(t)
		id := seedNeedsApproval(t, d, true)
		require.NoError(t, d.DisableRunawayAutomation(id, "a run would not end", testStart))
		require.NoError(t, Fire(d, "reminder:1", func() { t.Error("woke") }))
		assert.Empty(t, approvalRuns(t, d, id))
	})
}

func TestApprovalFire_EnqueueErrorLoggedAndSwallowed(t *testing.T) {
	d := db.OpenTestDB(t)
	seedNeedsApproval(t, d, true)
	// A trigger on automation_runs makes every insert fail.
	_, err := d.Exec(`CREATE TRIGGER fail_runs BEFORE INSERT ON automation_runs BEGIN SELECT RAISE(ABORT, 'no runs'); END`)
	require.NoError(t, err)
	require.Error(t, Fire(d, "reminder:9", nil), "Fire returns the enqueue error")

	var lines []string
	d.SetApprovalHook(ApprovalHook(d, func() { t.Error("woke after a failed enqueue") },
		func(format string, args ...any) { lines = append(lines, fmt.Sprintf(format, args...)) }))
	id, err := d.InsertReminder(db.Reminder{Note: "ping acme", RemindAt: "2000-01-01T00:00:00Z"})
	require.NoError(t, err, "the writer's result is unchanged")
	require.NotZero(t, id)
	require.Len(t, lines, 1)
	assert.True(t, strings.HasPrefix(lines[0], "approval hook: "+db.ReminderRef(id)+": "), lines[0])
	assert.NotContains(t, lines[0], "ping acme", "ids only (FILES-01)")
}

// The sweep's four cases, and that it never writes reminders or agent_actions.
func TestSweepApprovals(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC()
	at := func(d time.Duration) string { return now.Add(d).Format("2006-01-02T15:04:05Z") }
	artifact := func(t *testing.T, d *db.DB, a int64, key, written string) {
		t.Helper()
		var run int64
		require.NoError(t, d.QueryRow(`INSERT INTO automation_runs (automation_id, trigger, status) VALUES (?, 'event', 'succeeded') RETURNING id`, a).Scan(&run))
		_, err := d.Exec(`INSERT INTO automation_outputs (automation_id, run_id, kind, title, body, output_key, written_at, changed_at)
			VALUES (?, ?, 'inbox', 't', 'b', ?, ?, ?)`, a, run, key, written, written)
		require.NoError(t, err)
	}
	queued := func(t *testing.T, d *db.DB, a int64) []db.AutomationRun {
		t.Helper()
		var out []db.AutomationRun
		for _, r := range approvalRuns(t, d, a) {
			if r.Status == db.RunQueued {
				out = append(out, r)
			}
		}
		return out
	}
	snapshot := func(t *testing.T, d *db.DB) string {
		t.Helper()
		var s string
		require.NoError(t, d.QueryRow(`SELECT
			(SELECT COALESCE(group_concat(id||status||decided_at||applied_at||dismissed_at||args_json, ','), '') FROM agent_actions) || '|' ||
			(SELECT COALESCE(group_concat(id||status||remind_at||done_at, ','), '') FROM reminders)`).Scan(&s))
		return s
	}

	cases := []struct {
		name  string
		setup func(t *testing.T, d *db.DB, a int64)
		fire  bool
	}{
		{"a newly due reminder", func(t *testing.T, d *db.DB, a int64) {
			rem, err := d.InsertReminder(db.Reminder{RemindAt: at(-time.Minute)})
			require.NoError(t, err)
			artifact(t, d, a, db.ReminderRef(rem), at(-time.Hour)) // drawn before it was snoozed to now
		}, true},
		{"an open approval without a current artifact", func(t *testing.T, d *db.DB, _ int64) {
			_, err := d.InsertAgentAction(db.AgentAction{Tool: "create_target", ArgsJSON: `{}`})
			require.NoError(t, err)
		}, true},
		{"an artifact of a closed record", func(t *testing.T, d *db.DB, a int64) {
			id, err := d.InsertAgentAction(db.AgentAction{Tool: "create_target", ArgsJSON: `{}`, Status: "applied"})
			require.NoError(t, err)
			artifact(t, d, a, db.ActionRef(id), at(time.Minute))
		}, true},
		{"everything matches", func(t *testing.T, d *db.DB, a int64) {
			id, err := d.InsertAgentAction(db.AgentAction{Tool: "create_target", ArgsJSON: `{}`})
			require.NoError(t, err)
			artifact(t, d, a, db.ActionRef(id), at(time.Minute))
			_, err = d.InsertReminder(db.Reminder{RemindAt: at(time.Hour)}) // not due yet
			require.NoError(t, err)
		}, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			d := db.OpenTestDB(t)
			a := seedNeedsApproval(t, d, true)
			c.setup(t, d, a)
			before := snapshot(t, d)
			wakes := 0
			fired, err := SweepApprovals(ctx, d, now, func() { wakes++ })
			require.NoError(t, err)
			assert.Equal(t, c.fire, fired)
			assert.Equal(t, before, snapshot(t, d), "the sweep never writes reminders or agent_actions")
			q := queued(t, d, a)
			if !c.fire {
				assert.Empty(t, q)
				assert.Zero(t, wakes)
				return
			}
			require.Len(t, q, 1)
			assert.Equal(t, []string{SweepRef}, eventRefs(t, payloadOf(t, q[0])))
			assert.Equal(t, 1, wakes)
		})
	}
}

func TestSweepApprovals_NotRunnableComparesNothing(t *testing.T) {
	d := db.OpenTestDB(t)
	a := seedNeedsApproval(t, d, false)
	_, err := d.InsertAgentAction(db.AgentAction{Tool: "create_target", ArgsJSON: `{}`})
	require.NoError(t, err)
	fired, err := SweepApprovals(context.Background(), d, time.Now(), nil)
	require.NoError(t, err)
	assert.False(t, fired)
	assert.Empty(t, approvalRuns(t, d, a))
}

// hookedNeedsApproval is a test database whose approval hook is Fire, with a
// runnable needs-approval row.
func hookedNeedsApproval(t *testing.T) (*db.DB, int64) {
	t.Helper()
	d := db.OpenTestDB(t)
	id := seedNeedsApproval(t, d, true)
	d.SetApprovalHook(ApprovalHook(d, nil, func(format string, args ...any) { t.Errorf(format, args...) }))
	return d, id
}

// A workbench session's DirectApply write and an execute-trust call insert
// approved and walk approved → executing → applied: never an approval, no run.
func TestApprovalHook_DirectApplyQueuesNoRun(t *testing.T) {
	d, id := hookedNeedsApproval(t)
	for _, row := range []db.AgentAction{
		{Tool: "update_target", ArgsJSON: `{}`, Status: "approved", TrustAtCreate: "execute", ContextType: "project", ContextID: "3"},
		{Tool: "create_track", ArgsJSON: `{}`, Status: "approved", TrustAtCreate: "execute"},
	} {
		act, err := d.InsertAgentAction(row)
		require.NoError(t, err)
		for _, step := range [][2]string{{"approved", "executing"}, {"executing", "applied"}} {
			ok, err := d.TransitionAgentAction(act, []string{step[0]}, step[1], "", "")
			require.NoError(t, err)
			require.True(t, ok)
		}
	}
	// A project row that fails is still an audit row, not an approval.
	act, err := d.InsertAgentAction(db.AgentAction{Tool: "update_target", ArgsJSON: `{}`, Status: "approved", ContextType: "project"})
	require.NoError(t, err)
	_, err = d.TransitionAgentAction(act, []string{"approved"}, "failed", "", "boom")
	require.NoError(t, err)
	assert.Empty(t, approvalRuns(t, d, id))
}

// An Inbox button press records a one-press row (surface inbox): no run.
func TestApprovalHook_InboxButtonPressQueuesNoRun(t *testing.T) {
	d, id := hookedNeedsApproval(t)
	act, err := d.InsertInboxButtonProposal(db.AgentAction{Tool: "create_target", ArgsJSON: `{}`, Surface: "inbox",
		ContextType: db.InboxButtonContextType, ContextID: "1:0:abc"})
	require.NoError(t, err)
	for _, step := range [][2]string{{"pending", "approved"}, {"approved", "executing"}, {"executing", "applied"}} {
		ok, err := d.TransitionAgentAction(act, []string{step[0]}, step[1], "", "")
		require.NoError(t, err)
		require.True(t, ok)
	}
	assert.Empty(t, approvalRuns(t, d, id))
}

// A real approval: its proposal and its pending → approved decision each
// queue (into one run).
func TestApprovalHook_RealApprovalQueuesARun(t *testing.T) {
	d, id := hookedNeedsApproval(t)
	act, err := d.InsertAgentAction(db.AgentAction{Tool: "create_target", ArgsJSON: `{}`, Surface: "chat"})
	require.NoError(t, err)
	require.Len(t, approvalRuns(t, d, id), 1, "the proposal queues a run")
	_, err = d.Exec(`DELETE FROM automation_runs WHERE automation_id = ?`, id)
	require.NoError(t, err)

	ok, err := d.TransitionAgentAction(act, []string{"pending"}, "approved", "", "")
	require.NoError(t, err)
	require.True(t, ok)
	runs := approvalRuns(t, d, id)
	require.Len(t, runs, 1, "the decision queues a run")
	assert.Equal(t, []string{db.ActionRef(act)}, eventRefs(t, payloadOf(t, runs[0])))
}
