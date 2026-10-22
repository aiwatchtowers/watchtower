package db

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func seedBuiltinRow(t *testing.T, d *DB, builtinID, slug, content, approval string) int64 {
	t.Helper()
	id, err := d.UpsertBuiltinAutomation(Automation{
		BuiltinID: builtinID, Slug: slug, Name: "Acme " + slug,
		TriggerKind: TriggerKindSync, TriggerSpec: `{"sync":true}`,
		PermissionsJSON: `["llm"]`, OutputsJSON: `["inbox"]`,
		RecipeText: "---\nname: x\n---\n", ContentHash: content, ApprovalHash: approval,
	})
	require.NoError(t, err)
	return id
}

func TestBuiltinAutomation_UpsertNeverSetsOwnerColumns(t *testing.T) {
	d := openTestDB(t)
	id := seedBuiltinRow(t, d, "morning-brief", "morning-brief", "c1", "a1")
	again := seedBuiltinRow(t, d, "morning-brief", "morning-brief", "c2", "a2")
	require.Equal(t, id, again, "the upsert is keyed by the built-in's path")

	a := mustGetAutomation(t, d, id)
	assert.Equal(t, "", a.ConfirmedHash)
	assert.False(t, a.Enabled)
	assert.Equal(t, "builtin:morning-brief", a.Path)
	assert.Equal(t, OriginBuiltin, a.Origin)
	assert.Equal(t, "morning-brief", a.BuiltinID)
	assert.Equal(t, "personal", a.Scope)
	assert.Equal(t, "a2", a.ApprovalHash)
	assert.True(t, a.IsBuiltin())

	_, err := d.UpsertBuiltinAutomation(Automation{Slug: "x"})
	require.Error(t, err, "an empty builtin id is refused")

	// Confirmed and enabled survive a re-upsert with the same hash.
	require.NoError(t, d.ConfirmShippedBuiltin(id, "c2", "a2", time.Now()))
	require.NoError(t, d.SetBuiltinEnabled("morning-brief", true, time.Now()))
	seedBuiltinRow(t, d, "morning-brief", "morning-brief", "c2", "a2")
	a = mustGetAutomation(t, d, id)
	assert.Equal(t, "a2", a.ConfirmedHash)
	assert.True(t, a.Enabled)
	assert.True(t, a.Runnable())
}

func TestAuto06_ConfirmShippedBuiltinRefusesOtherBytes(t *testing.T) {
	now := time.Date(2026, 10, 22, 9, 0, 0, 0, time.UTC)
	cases := []struct {
		name          string
		owner         bool
		content, appr string
		want          error
		confirmed     string
	}{
		{name: "owner row", owner: true, content: "c-a1", appr: "a1", want: ErrNotBuiltin, confirmed: ""},
		{name: "other content", content: "c-other", appr: "a1", want: ErrHashMismatch, confirmed: ""},
		{name: "other approval", content: "c1", appr: "a-other", want: ErrHashMismatch, confirmed: ""},
		{name: "empty hashes", content: "", appr: "", want: ErrHashMismatch, confirmed: ""},
		{name: "matching", content: "c1", appr: "a1", want: nil, confirmed: "a1"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			d := openTestDB(t)
			var id int64
			if tc.owner {
				id = seedAutomationRow(t, d, "digest", "/acme/automations/digest.md", "a1")
			} else {
				id = seedBuiltinRow(t, d, "morning-brief", "morning-brief", "c1", "a1")
			}
			err := d.ConfirmShippedBuiltin(id, tc.content, tc.appr, now)
			if tc.want == nil {
				require.NoError(t, err)
			} else {
				require.ErrorIs(t, err, tc.want)
			}
			assert.Equal(t, tc.confirmed, mustGetAutomation(t, d, id).ConfirmedHash)
		})
	}
	d := openTestDB(t)
	require.ErrorIs(t, d.ConfirmShippedBuiltin(99, "c", "a", now), ErrAutomationNotFound)
}

func TestMarkAutomationsRemovedExcept_LeavesBuiltinRows(t *testing.T) {
	d := openTestDB(t)
	b := seedBuiltinRow(t, d, "morning-brief", "morning-brief", "c1", "a1")
	p := seedAutomationRow(t, d, "digest", "/acme/automations/digest.md", "a1")
	n, err := d.MarkAutomationsRemovedExcept("personal", 0, nil, time.Now())
	require.NoError(t, err)
	assert.Equal(t, 1, n)
	assert.Nil(t, mustGetAutomation(t, d, b).RemovedAt)
	assert.NotNil(t, mustGetAutomation(t, d, p).RemovedAt)
}

func TestGetAutomationBySlug_IgnoresBuiltinTwin(t *testing.T) {
	d := openTestDB(t)
	b := seedBuiltinRow(t, d, "morning-brief", "morning-brief", "c1", "a1")
	p := seedAutomationRow(t, d, "morning-brief", "/acme/automations/morning-brief.md", "a1")
	require.NotEqual(t, b, p)
	a, err := d.GetAutomationBySlug("personal", 0, "morning-brief")
	require.NoError(t, err)
	assert.Equal(t, p, a.ID)

	got, err := d.GetBuiltinAutomation("morning-brief")
	require.NoError(t, err)
	assert.Equal(t, b, got.ID)
	_, err = d.GetBuiltinAutomation("nope")
	require.ErrorIs(t, err, ErrAutomationNotFound)

	_, err = d.Exec(`UPDATE automations SET slug = 'other', builtin_id = 'other' WHERE id = ?`, b)
	require.NoError(t, err)
	seedBuiltinRow(t, d, "third", "third", "c", "a")
	_, err = d.Exec(`UPDATE automations SET builtin_id = 'other' WHERE builtin_id = 'third'`)
	require.Error(t, err, "a built-in id is unique")
	_, err = d.Exec(`UPDATE automations SET origin = 'builtin' WHERE id = ?`, p)
	require.Error(t, err, "a built-in row carries its id")
	_, err = d.Exec(`UPDATE automations SET builtin_id = 'x' WHERE id = ?`, p)
	require.Error(t, err, "an owner row carries no built-in id")
}

func TestAutomation_RunsAtSlotEqualsIsBuiltin(t *testing.T) {
	d := openTestDB(t)
	owner := mustGetAutomation(t, d, seedAutomationRow(t, d, "digest", "/acme/automations/digest.md", "a1"))
	builtin := mustGetAutomation(t, d, seedBuiltinRow(t, d, "morning-brief", "morning-brief", "c1", "a1"))
	assert.False(t, owner.IsBuiltin())
	assert.Equal(t, OriginOwner, owner.Origin)
	assert.True(t, builtin.IsBuiltin())
	for _, a := range []*Automation{owner, builtin} {
		assert.Equal(t, a.IsBuiltin(), a.RunsAtSlot(), a.Path)
	}
}

func TestAutomationRuns_SyncTriggerAccepted(t *testing.T) {
	d := openTestDB(t)
	id := seedBuiltinRow(t, d, "morning-brief", "morning-brief", "c1", "a1")
	runID, coalesced, err := d.EnqueueAutomationRun(EnqueueRequest{AutomationID: id, Trigger: TriggerSync, Now: time.Now()})
	require.NoError(t, err)
	assert.False(t, coalesced)
	r, err := d.GetAutomationRun(runID)
	require.NoError(t, err)
	assert.Equal(t, TriggerSync, r.Trigger)
	_, _, err = d.EnqueueAutomationRun(EnqueueRequest{AutomationID: id, Trigger: "bogus", Now: time.Now()})
	require.Error(t, err, "the CHECK still refuses an unknown trigger")
}

func TestBuiltin_TakeQueuedRunReturnsOldestManual(t *testing.T) {
	d := openTestDB(t)
	id := seedBuiltinRow(t, d, "morning-brief", "morning-brief", "c1", "a1")
	got, err := d.TakeQueuedBuiltinRun(id)
	require.NoError(t, err)
	assert.Nil(t, got)
	_, err = d.Exec(`INSERT INTO automation_runs (id, automation_id, trigger, status, queued_at) VALUES
		(1, ?, 'sync', 'queued', '2026-10-22T08:00:00Z'),
		(2, ?, 'manual', 'succeeded', '2026-10-22T08:00:00Z'),
		(3, ?, 'manual', 'queued', '2026-10-22T09:00:00Z')`, id, id, id)
	require.NoError(t, err)
	got, err = d.TakeQueuedBuiltinRun(id)
	require.NoError(t, err)
	require.NotNil(t, got)
	assert.Equal(t, int64(3), got.ID)
}

func TestBuiltin_SetEnabledMirrorsOnly(t *testing.T) {
	d := openTestDB(t)
	id := seedBuiltinRow(t, d, "morning-brief", "morning-brief", "c1", "a1")
	require.NoError(t, d.SetBuiltinEnabled("morning-brief", true, time.Now()))
	a := mustGetAutomation(t, d, id)
	assert.True(t, a.Enabled)
	assert.Nil(t, a.LastScheduledFor)
	// A stopped row (disabled_reason) is never turned on by the mirror:
	// TestSetBuiltinEnabled_NeverTurnsOnARunawayStop.
	require.ErrorIs(t, d.SetBuiltinEnabled("nope", true, time.Now()), ErrAutomationNotFound)
	require.ErrorIs(t, d.SetBuiltinEnabled("nope", false, time.Now()), ErrAutomationNotFound)

	// An unchanged value writes nothing (updated_at stays) and is no error.
	_, err := d.Exec(`UPDATE automations SET updated_at = '2026-01-01T00:00:00Z' WHERE id = ?`, id)
	require.NoError(t, err)
	require.NoError(t, d.SetBuiltinEnabled("morning-brief", true, time.Now()))
	a = mustGetAutomation(t, d, id)
	assert.True(t, a.Enabled)
	assert.Equal(t, "2026-01-01T00:00:00Z", formatAutomationTime(a.UpdatedAt))
	require.NoError(t, d.SetBuiltinEnabled("morning-brief", false, time.Now()))
	a = mustGetAutomation(t, d, id)
	assert.False(t, a.Enabled)
	assert.NotEqual(t, "2026-01-01T00:00:00Z", formatAutomationTime(a.UpdatedAt))
}

func TestBuiltinMigration_RecordCountsAttempts(t *testing.T) {
	d := openTestDB(t)
	m, err := d.GetBuiltinMigration("morning-brief")
	require.NoError(t, err)
	assert.Nil(t, m)
	t0 := time.Date(2026, 10, 22, 9, 0, 0, 0, time.UTC)
	require.NoError(t, d.RecordBuiltinMigration("morning-brief", BuiltinMigrationFailed, "boom", t0))
	require.NoError(t, d.RecordBuiltinMigration("morning-brief", BuiltinMigrationFailed, "boom again", t0.Add(time.Hour)))
	m, err = d.GetBuiltinMigration("morning-brief")
	require.NoError(t, err)
	require.NotNil(t, m)
	assert.Equal(t, 2, m.Attempts)
	assert.Equal(t, BuiltinMigrationFailed, m.Status)
	assert.Equal(t, "boom again", m.Error)
	require.NoError(t, d.RecordBuiltinMigration("morning-brief", BuiltinMigrationDone, "", t0.Add(2*time.Hour)))
	m, err = d.GetBuiltinMigration("morning-brief")
	require.NoError(t, err)
	assert.Equal(t, BuiltinMigrationDone, m.Status)
	assert.Equal(t, "", m.Error)
	assert.Equal(t, 3, m.Attempts)
	assert.True(t, m.UpdatedAt.Equal(t0.Add(2*time.Hour)))
	require.Error(t, d.RecordBuiltinMigration("morning-brief", "bogus", "", t0), "the CHECK refuses an unknown status")
}

func TestBuiltinCost_PipelineRunsOnlyBeforeFirstRun(t *testing.T) {
	d := openTestDB(t)
	id := seedBuiltinRow(t, d, "morning-brief", "morning-brief", "c1", "a1")
	now := time.Now()
	day0 := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.Local)
	at := func(day, hour int) string {
		return formatAutomationTime(day0.AddDate(0, 0, day).Add(time.Duration(hour) * time.Hour))
	}

	sum, err := d.BuiltinCost(id, []string{"briefing"}, day0.AddDate(0, 0, -7))
	require.NoError(t, err)
	assert.Equal(t, BuiltinCostSum{}, sum, "nothing ran yet")

	_, err = d.Exec(`INSERT INTO pipeline_runs (pipeline, cost_usd, started_at) VALUES
		('briefing', 0.25, ?), ('briefing', 0.40, ?), ('tracks', 1.00, ?), ('briefing', 9.00, ?)`,
		at(-3, 7), at(0, 7), at(-3, 8), at(-10, 7))
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO automation_runs (automation_id, trigger, status, queued_at, started_at, reported_cost_usd)
		VALUES (?, 'sync', 'succeeded', ?, ?, 0.10), (?, 'dry_run', 'failed', ?, ?, 5.0),
		       (?, 'sync', 'failed', ?, ?, NULL)`,
		id, at(0, 8), at(0, 8), id, at(-5, 8), at(-5, 8), id, at(-4, 8), at(-4, 8))
	require.NoError(t, err)

	sum, err = d.BuiltinCost(id, []string{"briefing"}, day0.AddDate(0, 0, -7))
	require.NoError(t, err)
	assert.InDelta(t, 0.35, sum.USD, 1e-9,
		"day −3 pipeline cost plus the run's $0.10: the failed day −4 run cuts nothing off, the dry run costs nothing")
	assert.True(t, sum.Reported)
}

func TestBuiltinCost_ZeroCostPipelineRowsAreNotReported(t *testing.T) {
	d := openTestDB(t)
	id := seedBuiltinRow(t, d, "morning-brief", "morning-brief", "c1", "a1")
	since := time.Now().AddDate(0, 0, -7)
	_, err := d.Exec(`INSERT INTO pipeline_runs (pipeline, cost_usd, started_at) VALUES ('briefing', 0, ?), ('briefing', 0, ?)`,
		formatAutomationTime(time.Now().AddDate(0, 0, -2)), formatAutomationTime(time.Now().AddDate(0, 0, -1)))
	require.NoError(t, err)
	sum, err := d.BuiltinCost(id, []string{"briefing"}, since)
	require.NoError(t, err)
	assert.Equal(t, BuiltinCostSum{}, sum, "zero-cost rows and no runs: cost not reported")

	_, err = d.Exec(`INSERT INTO pipeline_runs (pipeline, cost_usd, started_at) VALUES ('briefing', 0.2, ?)`,
		formatAutomationTime(time.Now().AddDate(0, 0, -3)))
	require.NoError(t, err)
	sum, err = d.BuiltinCost(id, []string{"briefing"}, since)
	require.NoError(t, err)
	assert.InDelta(t, 0.2, sum.USD, 1e-9)
	assert.True(t, sum.Reported)
}

func TestMigration00150_KeepsRunsAndChildren(t *testing.T) {
	d := openTestDB(t)
	automationObjects := func() map[string]string {
		rows, err := d.Query(`SELECT type || ':' || name, sql FROM sqlite_master
			WHERE tbl_name IN ('automations','automation_runs') AND type IN ('index','trigger') AND sql IS NOT NULL`)
		require.NoError(t, err)
		defer rows.Close()
		out := map[string]string{}
		for rows.Next() {
			var name, sql string
			require.NoError(t, rows.Scan(&name, &sql))
			out[name] = sql
		}
		require.NoError(t, rows.Err())
		return out
	}
	seqOf := func(table string) int64 {
		var seq int64
		require.NoError(t, d.QueryRow(`SELECT seq FROM sqlite_sequence WHERE name = ?`, table).Scan(&seq))
		return seq
	}
	atHead := automationObjects()
	require.NoError(t, gooseDownTo(d.DB, "migrations", 149))
	before := automationObjects()

	wb := newTestWorkbench(t, d)
	a := seedAutomationRow(t, d, "digest", "/acme/automations/digest.md", "h1")
	gone := seedAutomationRow(t, d, "gone", "/acme/automations/gone.md", "h2")
	_, err := d.Exec(`DELETE FROM automations WHERE id = ?`, gone)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO automation_runs (id, automation_id, trigger, status, reported_cost_usd) VALUES
		(1, ?, 'manual', 'succeeded', 0.5), (2, ?, 'schedule', 'waiting', NULL), (3, ?, 'manual', 'queued', NULL)`, a, a, a)
	require.NoError(t, err)
	_, err = d.Exec(`DELETE FROM automation_runs WHERE id = 3`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO automation_run_steps (run_id, seq, kind, status) VALUES (1, 1, 'llm', 'ok')`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO automation_run_replay (run_id, seq, kind, name, args_hash, pending) VALUES (2, 1, 'ask', 'q', 'h', 1)`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO automation_outputs (id, automation_id, run_id, kind, title, body) VALUES (1, ?, 1, 'inbox', 't', 'b')`, a)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO automation_state (automation_id, state_json, run_id) VALUES (?, '{"n":1}', 1)`, a)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO automation_tool_grants (automation_id, tool, grant_hash) VALUES (?, 'create_target', 'h1')`, a)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO owner_asks (project_id, kind, title, automation_run_id) VALUES (?, 'question', 'Q', 2)`, wb)
	require.NoError(t, err)
	autoSeq, runSeq := seqOf("automations"), seqOf("automation_runs")
	require.Equal(t, gone, autoSeq)
	require.Equal(t, int64(3), runSeq)

	require.NoError(t, gooseUp(d.DB, "migrations"))

	assert.Equal(t, atHead, automationObjects(), "every index and the trigger are recreated")
	assert.Equal(t, autoSeq, seqOf("automations"))
	assert.Equal(t, runSeq, seqOf("automation_runs"))
	assert.Equal(t, 1, countWhere(t, d, `PRAGMA foreign_keys`))
	got := mustGetAutomation(t, d, a)
	assert.Equal(t, OriginOwner, got.Origin)
	assert.Equal(t, "", got.BuiltinID)
	assert.False(t, got.Overridden)
	assert.Equal(t, 2, countWhere(t, d, `SELECT COUNT(*) FROM automation_runs WHERE automation_id = ?`, a))
	assert.Equal(t, 1, countWhere(t, d, `SELECT COUNT(*) FROM automation_run_steps WHERE run_id = 1`))
	assert.Equal(t, 1, countWhere(t, d, `SELECT COUNT(*) FROM automation_run_replay WHERE run_id = 2`))
	assert.Equal(t, 1, countWhere(t, d, `SELECT COUNT(*) FROM automation_outputs WHERE id = 1 AND run_id = 1`))
	assert.Equal(t, 1, countWhere(t, d, `SELECT COUNT(*) FROM automation_state WHERE automation_id = ?`, a))
	assert.Equal(t, 1, countWhere(t, d, `SELECT COUNT(*) FROM automation_tool_grants WHERE automation_id = ?`, a))
	assert.Equal(t, 1, countWhere(t, d, `SELECT COUNT(*) FROM owner_asks WHERE automation_run_id = 2`))
	assert.Equal(t, 0, countWhere(t, d, `SELECT COUNT(*) FROM pragma_foreign_key_check`))

	// A built-in with a sync run and children, and a sync run of the owner row.
	b := seedBuiltinRow(t, d, "morning-brief", "morning-brief", "c1", "a1")
	_, err = d.Exec(`INSERT INTO automation_runs (id, automation_id, trigger, status) VALUES
		(10, ?, 'sync', 'succeeded'), (11, ?, 'manual', 'succeeded'), (12, ?, 'sync', 'succeeded')`, b, b, a)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO automation_run_steps (run_id, seq, kind, status) VALUES (10, 1, 'llm', 'ok'), (12, 1, 'llm', 'ok')`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO automation_outputs (automation_id, run_id, kind, title, body) VALUES (?, 11, 'inbox', 't', 'b')`, b)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO automation_state (automation_id, state_json) VALUES (?, '{}')`, b)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO automation_tool_grants (automation_id, tool, grant_hash) VALUES (?, 'x', 'a1')`, b)
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE automation_runs SET rerun_of = 12 WHERE id = 1`)
	require.NoError(t, err)

	require.NoError(t, gooseDownTo(d.DB, "migrations", 149))
	assert.Equal(t, before, automationObjects(), "the 00149 indexes and trigger come back verbatim")
	assert.Equal(t, 0, countWhere(t, d, `SELECT COUNT(*) FROM automations WHERE id = ?`, b))
	assert.Equal(t, 1, countWhere(t, d, `SELECT COUNT(*) FROM automations WHERE id = ?`, a))
	assert.Equal(t, 2, countWhere(t, d, `SELECT COUNT(*) FROM automation_runs`))
	assert.Equal(t, 0, countWhere(t, d, `SELECT COUNT(*) FROM automation_run_steps WHERE run_id IN (10, 12)`))
	assert.Equal(t, 1, countWhere(t, d, `SELECT COUNT(*) FROM automation_outputs`))
	assert.Equal(t, 1, countWhere(t, d, `SELECT COUNT(*) FROM automation_state`))
	assert.Equal(t, 1, countWhere(t, d, `SELECT COUNT(*) FROM automation_tool_grants`))
	assert.Equal(t, 1, countWhere(t, d, `SELECT COUNT(*) FROM automation_runs WHERE id = 1 AND rerun_of IS NULL`))
	assert.Equal(t, 0, countWhere(t, d, `SELECT COUNT(*) FROM sqlite_master WHERE name = 'builtin_migrations'`))
	assert.Equal(t, 0, countWhere(t, d, `SELECT COUNT(*) FROM pragma_foreign_key_check`))
	assert.Equal(t, 1, countWhere(t, d, `PRAGMA foreign_keys`))
	_, err = d.Exec(`INSERT INTO automation_runs (automation_id, trigger) VALUES (?, 'sync')`, a)
	require.Error(t, err, "the old CHECK refuses sync")

	require.NoError(t, gooseUp(d.DB, "migrations"))
	assert.Equal(t, atHead, automationObjects())
	_, err = d.Exec(`UPDATE automation_runs SET status = 'failed' WHERE id = 2`)
	require.NoError(t, err)
	assert.Equal(t, 0, countWhere(t, d, `SELECT COUNT(*) FROM automation_run_replay WHERE run_id = 2`),
		"automation_runs_replay_cleanup fires after the rebuild")
}

// The owner-recipe executor's start sweep never ends a built-in's run (the
// daemon sweeps those itself before its first slot, so a retried executor
// sweep cannot end a live slot run); MarkInterruptedBuiltinRuns ends only
// the built-ins' runs.
func TestMarkInterrupted_BuiltinRunsSweptApart(t *testing.T) {
	d := openTestDB(t)
	owner := seedRunAutomation(t, d, "digest", 4)
	builtin := seedBuiltinRow(t, d, "morning-brief", "morning-brief", "c1", "a1")
	ownerRun, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: owner, Trigger: TriggerManual})
	slotRun, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: builtin, Trigger: TriggerSync})
	mustClaimAutomationRun(t, d, ownerRun)
	mustClaimAutomationRun(t, d, slotRun)

	n, err := d.MarkInterruptedAutomationRuns(runTestNow)
	require.NoError(t, err)
	assert.Equal(t, 1, n)
	wantAutomationRun(t, d, ownerRun, RunFailed, ErrKindInterrupted)
	wantAutomationRun(t, d, slotRun, RunRunning, "")

	n, err = d.MarkInterruptedBuiltinRuns(runTestNow)
	require.NoError(t, err)
	assert.Equal(t, 1, n)
	wantAutomationRun(t, d, slotRun, RunFailed, ErrKindInterrupted)
}

// A built-in run past its deadline (a killed CLI's) is ended; a live one, an
// owner run and a queued run are not.
func TestMarkStaleBuiltinRuns_EndsOnlyBuiltinRunsPastDeadline(t *testing.T) {
	d := openTestDB(t)
	bi := seedBuiltinRow(t, d, "morning-brief", "morning-brief", "c1", "a1")
	claimAt := func(a int64, started time.Time) int64 {
		run, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerManual})
		ok, err := d.ClaimAutomationRun(run, "h", "s", 50000, 5, started)
		require.NoError(t, err)
		require.True(t, ok)
		return run
	}
	owner := claimAt(seedRunAutomation(t, d, "digest", 4), runTestNow.Add(-30*time.Minute))
	n, err := d.MarkStaleBuiltinRuns(runTestNow)
	require.NoError(t, err)
	assert.Equal(t, 0, n, "no built-in run is running")

	stale := claimAt(bi, runTestNow.Add(-7*time.Minute))
	queued, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: bi, Trigger: TriggerManual})
	n, err = d.MarkStaleBuiltinRuns(runTestNow)
	require.NoError(t, err)
	assert.Equal(t, 1, n)
	wantAutomationRun(t, d, stale, RunFailed, ErrKindInterrupted)
	wantAutomationRun(t, d, owner, RunRunning, "")
	wantAutomationRun(t, d, queued, RunQueued, "")

	_, err = d.CancelAutomationRun(queued, runTestNow)
	require.NoError(t, err)
	live := claimAt(bi, runTestNow.Add(-2*time.Minute))
	n, err = d.MarkStaleBuiltinRuns(runTestNow)
	require.NoError(t, err)
	assert.Equal(t, 0, n)
	wantAutomationRun(t, d, live, RunRunning, "")
	_, err = d.MarkStaleBuiltinRuns(time.Time{})
	require.Error(t, err)
}

// A built-in run that waited is never stale: a wait moves the meter's
// deadline by the pause, so started_at + budget says nothing about it. A
// waiting run, a run resumed after a wait, and a run that waited on a write
// and is running again are all left alone; a plain stale run is ended.
func TestMarkStaleBuiltinRuns_NeverEndsARunThatWaited(t *testing.T) {
	d := openTestDB(t)
	claimStale := func(builtinID string) int64 {
		a := seedBuiltinRow(t, d, builtinID, builtinID, "c1", "a1")
		run, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerManual})
		ok, err := d.ClaimAutomationRun(run, "h", "s", 50000, 5, runTestNow.Add(-30*time.Minute))
		require.NoError(t, err)
		require.True(t, ok)
		return run
	}
	step := func(run int64, s AutomationRunStep) {
		s.RunID, s.Seq, s.StartedAt = run, 1, runTestNow.Add(-29*time.Minute)
		_, err := d.AppendAutomationRunStep(s)
		require.NoError(t, err)
	}

	waiting := claimStale("acme-waiting")
	step(waiting, AutomationRunStep{Kind: "tool", Name: "create_target", Status: "waiting", ActionID: 7})
	require.NoError(t, d.SetAutomationRunWaiting(waiting, WaitApproval))

	resumedAsk := claimStale("acme-ask")
	step(resumedAsk, AutomationRunStep{Kind: "ask", Name: "ask", Status: "ok", AskID: 3})
	require.NoError(t, d.SetAutomationRunWaiting(resumedAsk, "ask"))
	require.NoError(t, d.ResumeAutomationRun(resumedAsk))

	resumedWrite := claimStale("acme-write")
	step(resumedWrite, AutomationRunStep{Kind: "tool", Name: "create_target", Status: "applied", ActionID: 8})

	plain := claimStale("acme-plain")
	step(plain, AutomationRunStep{Kind: "llm", Name: "brief.compose", Status: "ok"})

	n, err := d.MarkStaleBuiltinRuns(runTestNow)
	require.NoError(t, err)
	assert.Equal(t, 1, n)
	wantAutomationRun(t, d, plain, RunFailed, ErrKindInterrupted)
	wantAutomationRun(t, d, waiting, RunWaiting, "")
	wantAutomationRun(t, d, resumedAsk, RunRunning, "")
	wantAutomationRun(t, d, resumedWrite, RunRunning, "")
}

// The start sweep ends a CLI's inline manual run only past its deadline,
// like a dry run; a sync run, a waiting run and a manual run past its
// deadline are ended at once.
func TestMarkInterruptedBuiltinRuns_LiveManualRunSurvives(t *testing.T) {
	d := openTestDB(t)
	bi := seedBuiltinRow(t, d, "morning-brief", "morning-brief", "c1", "a1")
	claimAt := func(trigger string, started time.Time) int64 {
		run, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: bi, Trigger: trigger})
		ok, err := d.ClaimAutomationRun(run, "h", "s", 50000, 5, started)
		require.NoError(t, err)
		require.True(t, ok)
		return run
	}
	live := claimAt(TriggerManual, runTestNow.Add(-2*time.Minute))
	n, err := d.MarkInterruptedBuiltinRuns(runTestNow)
	require.NoError(t, err)
	assert.Equal(t, 0, n)
	wantAutomationRun(t, d, live, RunRunning, "")

	_, err = d.Exec(`UPDATE automations SET concurrency = 4 WHERE id = ?`, bi)
	require.NoError(t, err)
	stale := claimAt(TriggerManual, runTestNow.Add(-7*time.Minute))
	_, err = d.Exec(`UPDATE automation_runs SET trigger = 'sync' WHERE id = ?`, stale)
	require.NoError(t, err)
	slot := stale
	past := claimAt(TriggerManual, runTestNow.Add(-7*time.Minute))
	waiting := claimAt(TriggerManual, runTestNow.Add(-time.Minute))
	_, err = d.Exec(`UPDATE automation_runs SET trigger = 'manual' WHERE id = ?`, past)
	require.NoError(t, err)
	require.NoError(t, d.SetAutomationRunWaiting(waiting, WaitAsk))
	n, err = d.MarkInterruptedBuiltinRuns(runTestNow)
	require.NoError(t, err)
	assert.Equal(t, 3, n)
	wantAutomationRun(t, d, live, RunRunning, "")
	wantAutomationRun(t, d, slot, RunFailed, ErrKindInterrupted)
	wantAutomationRun(t, d, past, RunFailed, ErrKindInterrupted)
	wantAutomationRun(t, d, waiting, RunFailed, ErrKindInterrupted)
}

// A built-in the daemon stopped (a run that would not end) stays off through
// every sync's mirror; only ResumeBuiltin turns it on again.
func TestSetBuiltinEnabled_NeverTurnsOnARunawayStop(t *testing.T) {
	d := openTestDB(t)
	id := seedBuiltinRow(t, d, "morning-brief", "morning-brief", "c1", "a1")
	resumed, err := d.ResumeBuiltin("morning-brief", runTestNow)
	require.NoError(t, err)
	assert.False(t, resumed, "nothing to resume")
	require.NoError(t, d.SetBuiltinEnabled("morning-brief", true, runTestNow))
	require.NoError(t, d.DisableRunawayAutomation(id, "runaway", runTestNow))

	require.NoError(t, d.SetBuiltinEnabled("morning-brief", true, runTestNow))
	a, err := d.GetAutomation(id)
	require.NoError(t, err)
	assert.False(t, a.Enabled, "the sync's mirror never turns a stopped built-in on")
	assert.Equal(t, "runaway", a.DisabledReason)

	resumed, err = d.ResumeBuiltin("morning-brief", runTestNow)
	require.NoError(t, err)
	assert.True(t, resumed)
	a, err = d.GetAutomation(id)
	require.NoError(t, err)
	assert.True(t, a.Enabled)
	assert.Empty(t, a.DisabledReason)
	assert.Nil(t, a.DisabledAt)
	_, err = d.ResumeBuiltin("nope", runTestNow)
	require.ErrorIs(t, err, ErrAutomationNotFound)
}

func TestCancelQueuedBuiltinRuns_OnlyQueuedManualRunsOfThatBuiltin(t *testing.T) {
	d := openTestDB(t)
	bi := seedBuiltinRow(t, d, "morning-brief", "morning-brief", "c1", "a1")
	other := seedRunAutomation(t, d, "digest", 4)
	queued, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: bi, Trigger: TriggerManual})
	ownerRun, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: other, Trigger: TriggerManual})
	n, err := d.CancelQueuedBuiltinRuns("morning-brief", runTestNow)
	require.NoError(t, err)
	assert.Equal(t, 1, n)
	wantAutomationRun(t, d, queued, RunCancelled, ErrKindNotRunnable)
	wantAutomationRun(t, d, ownerRun, RunQueued, "")

	running, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: bi, Trigger: TriggerManual})
	mustClaimAutomationRun(t, d, running)
	n, err = d.CancelQueuedBuiltinRuns("morning-brief", runTestNow)
	require.NoError(t, err)
	assert.Equal(t, 0, n)
	wantAutomationRun(t, d, running, RunRunning, "")
}

func TestCancelQueuedAutomationRun_OnlyWhileQueued(t *testing.T) {
	d := openTestDB(t)
	a := seedRunAutomation(t, d, "digest", 4)
	queued, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerManual})
	ok, err := d.CancelQueuedAutomationRun(queued, runTestNow)
	require.NoError(t, err)
	assert.True(t, ok)
	wantAutomationRun(t, d, queued, RunCancelled, ErrKindCancelled)

	claimed, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerManual})
	mustClaimAutomationRun(t, d, claimed)
	ok, err = d.CancelQueuedAutomationRun(claimed, runTestNow)
	require.NoError(t, err)
	assert.False(t, ok, "a claimed run is left alone")
	wantAutomationRun(t, d, claimed, RunRunning, "")
	_, err = d.CancelQueuedAutomationRun(99999, runTestNow)
	require.ErrorIs(t, err, ErrAutomationRunNotFound)
}

func TestBuiltinCost_CountsTokens(t *testing.T) {
	d := openTestDB(t)
	id := seedBuiltinRow(t, d, "morning-brief", "morning-brief", "c1", "a1")
	since := time.Now().AddDate(0, 0, -7)
	_, err := d.Exec(`INSERT INTO pipeline_runs (pipeline, input_tokens, output_tokens, started_at) VALUES
		('briefing', 100, 20, ?), ('tracks', 1000, 1000, ?)`,
		formatAutomationTime(time.Now().AddDate(0, 0, -3)), formatAutomationTime(time.Now().AddDate(0, 0, -3)))
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO automation_runs (automation_id, trigger, status, queued_at, started_at, input_tokens, output_tokens)
		VALUES (?, 'sync', 'failed', ?, ?, 300, 40), (?, 'dry_run', 'failed', ?, ?, 5000, 5000)`,
		id, formatAutomationTime(time.Now().AddDate(0, 0, -1)), formatAutomationTime(time.Now().AddDate(0, 0, -1)),
		id, formatAutomationTime(time.Now().AddDate(0, 0, -1)), formatAutomationTime(time.Now().AddDate(0, 0, -1)))
	require.NoError(t, err)
	sum, err := d.BuiltinCost(id, []string{"briefing"}, since)
	require.NoError(t, err)
	assert.Equal(t, BuiltinCostSum{Tokens: 460}, sum, "the run's and the briefing row's tokens, no cost reported")
}
