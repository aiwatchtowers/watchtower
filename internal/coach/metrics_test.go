package coach

import (
	"context"
	"database/sql"
	"fmt"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/agentlogdb"
	"watchtower/internal/agentreport"
	"watchtower/internal/db"
)

var t0 = time.Date(2026, 10, 1, 10, 0, 0, 0, time.UTC)

const tsLayout = "2006-01-02T15:04:05Z"

type dbs struct {
	*db.DB
	al *agentlogdb.DB
}

func openDBs(t *testing.T) dbs {
	t.Helper()
	dir := t.TempDir()
	d, err := db.Open(filepath.Join(dir, "w.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = d.Close() })
	al, err := agentlogdb.Open(filepath.Join(dir, "agentlog.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = al.Close() })
	_, err = agentlogdb.MoveFromMain(context.Background(), d, al, agentlogdb.MoveLockPath(filepath.Join(dir, "agentlog.db")))
	require.NoError(t, err)
	return dbs{DB: d, al: al}
}

// workbench creates a workbench with analytics on and `tasks` open targets.
func (d dbs) workbench(t *testing.T, name string, tasks int) (int64, []int64) {
	t.Helper()
	wb, err := d.CreateWorkbench(name, t.TempDir())
	require.NoError(t, err)
	require.NoError(t, d.SetWorkbenchAgentAnalytics(wb, true))
	var ids []int64
	for i := range tasks {
		res, err := d.Exec(`INSERT INTO targets (text, period_start, period_end, project_id, status)
			VALUES (?, '2026-01-01', '2026-12-31', ?, 'in_progress')`, fmt.Sprintf("goal %d", i), wb)
		require.NoError(t, err)
		id, err := res.LastInsertId()
		require.NoError(t, err)
		_, err = d.Exec(`UPDATE target_status_history SET changed_at = ? WHERE target_id = ?`, t0.Add(-time.Hour).Format(tsLayout), id)
		require.NoError(t, err)
		ids = append(ids, id)
	}
	return wb, ids
}

// session stores one session of the workbench: a minute of work that touches
// every target, `interrupts` interrupts and `cost` of model spend.
func (d dbs) session(t *testing.T, wb int64, uuid string, targets []int64, interrupts int, cost float64) {
	t.Helper()
	d.sessionOf(t, "claude", wb, uuid, targets, interrupts, cost)
}

// sessionOf is session for one agent's session ("claude" or "codex").
func (d dbs) sessionOf(t *testing.T, agent string, wb int64, uuid string, targets []int64, interrupts int, cost float64) {
	t.Helper()
	path := "/tmp/x/" + uuid + ".jsonl"
	at := func(s int) string { return t0.Add(time.Duration(s) * time.Second).Format(tsLayout) }
	var evs []agentlogdb.AgentLogEvent
	add := func(e agentlogdb.AgentLogEvent, s int) {
		e.SessionUUID, e.TS, e.SrcPath, e.SrcOffset = uuid, at(s), path, int64(len(evs))
		e.Key = fmt.Sprintf("%s:%d", uuid, len(evs))
		evs = append(evs, e)
	}
	add(agentlogdb.AgentLogEvent{Kind: "owner_turn", Trigger: "owner"}, 0)
	add(agentlogdb.AgentLogEvent{Kind: "api_call", Name: "claude-opus-5-5", InputTokens: 10, OutputTokens: 5, CostUSD: cost}, 10)
	for i, id := range targets {
		add(agentlogdb.AgentLogEvent{Kind: "tool", Name: "mcp__watchtower-workbench__update_target", Target: fmt.Sprintf("#%d", id), Outcome: "ok"}, 20+i)
	}
	for i := range interrupts {
		add(agentlogdb.AgentLogEvent{Kind: "owner_turn", Trigger: "interrupt"}, 30+i)
	}
	add(agentlogdb.AgentLogEvent{Kind: "api_call", Name: "claude-opus-5-5", InputTokens: 10, OutputTokens: 5}, 60)
	_, err := d.al.ApplyAgentLogBatch(agentlogdb.AgentLogBatch{
		File: agentlogdb.AgentLogFile{Path: path, Agent: agent, ReadOffset: 10, ParserVersion: 4}, ExpectOffset: -1,
		Sessions: []agentlogdb.AgentLogSession{{SessionUUID: uuid, Agent: agent, ProjectID: &wb, FolderPath: "/w", HomeCWD: "/w",
			SourcePath: path, StartedAt: at(0), EndedAt: at(60), Model: "claude-opus-5-5"}},
		Events: evs,
	})
	require.NoError(t, err)
}

func (d dbs) specReview(t *testing.T, wb int64, findings int, at time.Time, previous int64) int64 {
	t.Helper()
	a := db.OwnerAsk{WorkbenchID: wb, Kind: "review", Title: "s", DocPath: "a.md", DocType: "spec"}
	if previous != 0 {
		a.PreviousAskID = sql.NullInt64{Int64: previous, Valid: true}
	}
	var id int64
	require.NoError(t, d.WithTx(func(tx *sql.Tx) error {
		var err error
		id, _, err = d.InsertOwnerAsk(tx, a)
		if err != nil {
			return err
		}
		return d.QueueSpecReview(tx, id, at, nil)
	}))
	ok, err := d.ClaimSpecReview(id, 1, at)
	require.NoError(t, err)
	require.True(t, ok)
	require.NoError(t, d.FinishSpecReview(id, 1, db.SpecReview{Result: "{}", Findings: findings}, at))
	return id
}

// twoWorkbenches: A has 1 task and 2 interrupts, B has 2 tasks and 1 interrupt.
func twoWorkbenches(t *testing.T) (dbs, int64, int64) {
	d := openDBs(t)
	a, at := d.workbench(t, "a", 1)
	b, bt := d.workbench(t, "b", 2)
	d.session(t, a, "sa", at, 2, 1.0)
	d.session(t, b, "sb", bt, 1, 3.0)
	return d, a, b
}

func measure(t *testing.T, d dbs, wb int64) Metrics {
	t.Helper()
	m, err := Measure(d.DB, d.al, wb, time.Time{}, t0.Add(time.Hour), agentreport.AgentAll)
	require.NoError(t, err)
	return m
}

func TestMeasure_PerTask(t *testing.T) {
	d, a, b := twoWorkbenches(t)

	ma := measure(t, d, a)
	assert.Equal(t, 1, ma.Sessions)
	assert.Equal(t, Value{V: 2, N: 1, Known: true}, ma.Corrections)
	assert.True(t, ma.TaskHours.Known)
	assert.Greater(t, ma.TaskHours.V, 0.0)
	assert.InDelta(t, 1.0, ma.TaskCostUSD.V, 0.01)

	mb := measure(t, d, b)
	assert.Equal(t, Value{V: 0.5, N: 2, Known: true}, mb.Corrections)
	assert.InDelta(t, 1.5, mb.TaskCostUSD.V, 0.01, "3.0 across two tasks")

	ov, err := agentreport.BuildOverview(d.DB, d.al, a, time.Time{}, t0.Add(time.Hour), agentreport.English, agentreport.AgentAll)
	require.NoError(t, err)
	assert.InDelta(t, float64(ov.Time.OwnerMS)/float64(ov.Time.ActiveMS), ma.OwnerLoop.V, 1e-9)
	assert.True(t, ma.OwnerLoop.Known)
	assert.Equal(t, ma.OwnerLoop, ma.Of("owner_loop"))
	assert.Equal(t, ma.Corrections, ma.Of("corrections"))
	assert.Equal(t, ma.TaskCostUSD, ma.Of("task_cost"))
	assert.False(t, ma.Of("nonsense").Known)
}

func TestMeasure_AllWorkbenchesSumsBeforeDividing(t *testing.T) {
	d, _, _ := twoWorkbenches(t)
	m := measure(t, d, 0)
	assert.Equal(t, 2, m.Sessions)
	// 3 corrections over 3 tasks; averaging the two workbenches' rates would give 1.25.
	assert.Equal(t, Value{V: 1, N: 3, Known: true}, m.Corrections)
	// 4.0 over 3 tasks; the mean of 1.0 and 1.5 would be 1.25.
	assert.InDelta(t, 4.0/3, m.TaskCostUSD.V, 0.01)
}

func TestMeasure_AllWorkbenchesSkipsAnalyticsOff(t *testing.T) {
	d, a, b := twoWorkbenches(t)
	require.NoError(t, d.SetWorkbenchAgentAnalytics(b, false))
	m := measure(t, d, 0)
	assert.Equal(t, measure(t, d, a).Corrections, m.Corrections)
}

func TestMeasure_NoTasksIsUnknown(t *testing.T) {
	d := openDBs(t)
	wb, _ := d.workbench(t, "empty", 0)
	d.session(t, wb, "s", nil, 1, 1.0)
	m := measure(t, d, wb)
	assert.Equal(t, 1, m.Sessions)
	assert.False(t, m.Corrections.Known)
	assert.False(t, m.TaskHours.Known)
	assert.False(t, m.TaskCostUSD.Known)
	assert.False(t, m.SpecFindings.Known)
	assert.False(t, m.ReviewComments.Known)

	none := measure(t, openDBs(t), 0)
	assert.Zero(t, none.Sessions)
	assert.False(t, none.OwnerLoop.Known)
}

func TestMeasure_SpecFindingsFirstRoundOnly(t *testing.T) {
	d := openDBs(t)
	wb, _ := d.workbench(t, "a", 0)
	at := t0.Add(time.Minute)
	first := d.specReview(t, wb, 4, at, 0)
	d.specReview(t, wb, 8, at, first)
	d.specReview(t, wb, 2, at, 0)
	d.specReview(t, wb, -1, at, 0)

	m := measure(t, d, wb)
	assert.Equal(t, Value{V: 3, N: 2, Known: true}, m.SpecFindings)
	assert.Equal(t, m.SpecFindings, m.Of("review_findings"))
	assert.Equal(t, m.SpecFindings, measure(t, d, 0).SpecFindings)

	late, err := Measure(d.DB, d.al, wb, t0.Add(time.Hour), t0.Add(2*time.Hour), agentreport.AgentAll)
	require.NoError(t, err)
	assert.False(t, late.SpecFindings.Known, "outside the period")
}

func TestMeasure_UntilBoundsSessions(t *testing.T) {
	d := openDBs(t)
	wb, ids := d.workbench(t, "a", 1)
	d.session(t, wb, "s", ids, 1, 1.0)
	before, err := Measure(d.DB, d.al, wb, time.Time{}, t0.Add(-time.Minute), agentreport.AgentAll)
	require.NoError(t, err)
	assert.Zero(t, before.Sessions, "the session starts after until")
	assert.False(t, before.OwnerLoop.Known)
	assert.Equal(t, 1, measure(t, d, wb).Sessions)
}

func TestMeasure_MoreThanTasksMaxTasks(t *testing.T) {
	d := openDBs(t)
	n := agentreport.TasksMax + 10
	wb, ids := d.workbench(t, "a", n)
	d.session(t, wb, "s", ids, 0, 6.0)
	m := measure(t, d, wb)
	assert.Equal(t, n, m.TaskCostUSD.N)
	assert.InDelta(t, 6.0/float64(n), m.TaskCostUSD.V, 0.01, "numerator covers every task, not the listed 50")
}

// Decision D (ask #507): codex sessions are agent sessions of the workbench;
// the coach's metrics count them like Claude Code ones.
func TestCoachMetrics_IncludeCodexSessions(t *testing.T) {
	d := openDBs(t)
	wb, tasks := d.workbench(t, "a", 1)
	d.session(t, wb, "claude-1", tasks, 0, 1.0)
	before := measure(t, d, wb)
	path := "/tmp/x/rollout-codex-1.jsonl"
	at := func(s int) string { return t0.Add(time.Duration(s) * time.Second).Format(tsLayout) }
	_, err := d.al.ApplyAgentLogBatch(agentlogdb.AgentLogBatch{
		File: agentlogdb.AgentLogFile{Path: path, Agent: "codex", ReadOffset: 10, ParserVersion: 4}, ExpectOffset: -1,
		Sessions: []agentlogdb.AgentLogSession{{SessionUUID: "codex-1", Agent: "codex", ProjectID: &wb, FolderPath: "/w", HomeCWD: "/w",
			SourcePath: path, StartedAt: at(0), EndedAt: at(60), Model: "gpt-test"}},
		Events: []agentlogdb.AgentLogEvent{
			{SessionUUID: "codex-1", Key: "codex-1:0", Kind: "owner_turn", Trigger: "owner", TS: at(0), SrcPath: path},
			{SessionUUID: "codex-1", Key: "codex-1:1", Kind: "owner_turn", Trigger: "interrupt", TS: at(30), SrcPath: path, SrcOffset: 1},
			{SessionUUID: "codex-1", Key: "codex-1:2", Kind: "api_call", Name: "gpt-test", OutputTokens: 5, CostEstimated: true, TS: at(60), SrcPath: path, SrcOffset: 2},
		},
	})
	require.NoError(t, err)
	after := measure(t, d, wb)
	assert.Equal(t, before.Sessions+1, after.Sessions)
	assert.InDelta(t, before.Corrections.V+1, after.Corrections.V, 1e-9, "the codex interrupt is a correction of the one task")
}

func TestAgentFor(t *testing.T) {
	for dest, want := range map[string]string{
		DestClaudeMDUser: "claude", "claude_skill_user": "claude", DestSettingsAllow: "claude",
		DestPromptAdd: "claude", "repo_claude_md": "claude", "repo_claude_skill": "claude",
		DestChat: "claude", DestSession: agentreport.AgentAll, DestProcedure: agentreport.AgentAll,
		"codex_skill_user": "codex", "codex_agents_md_user": "codex", "codex_rules_allow": "codex",
		"repo_agents_md": "codex", "repo_codex_skill": "codex",
		"pack_overlay": agentreport.AgentAll, "repo_workflow": agentreport.AgentAll,
	} {
		assert.Equal(t, want, AgentFor(dest), dest)
	}
}

// TestMeasure_AgentFilter: a Claude session with 2 interrupts and a Codex one
// with none, both on the one task of a workbench.
func TestMeasure_AgentFilter(t *testing.T) {
	d := openDBs(t)
	wb, ids := d.workbench(t, "a", 1)
	d.sessionOf(t, "claude", wb, "sc", ids, 2, 1.0)
	d.sessionOf(t, "codex", wb, "sx", ids, 0, 3.0)
	of := func(agent string) Metrics {
		m, err := Measure(d.DB, d.al, wb, time.Time{}, t0.Add(time.Hour), agent)
		require.NoError(t, err)
		return m
	}
	claude, codex, all := of("claude"), of("codex"), of(agentreport.AgentAll)
	assert.Equal(t, 1, claude.Sessions)
	assert.Equal(t, Value{V: 2, N: 1, Known: true}, claude.Corrections)
	assert.InDelta(t, 1.0, claude.TaskCostUSD.V, 0.01)
	assert.Equal(t, 1, codex.Sessions)
	assert.Equal(t, Value{V: 0, N: 1, Known: true}, codex.Corrections)
	assert.InDelta(t, 3.0, codex.TaskCostUSD.V, 0.01)
	assert.Equal(t, 2, all.Sessions)
	assert.Equal(t, Value{V: 2, N: 1, Known: true}, all.Corrections)
	assert.InDelta(t, 4.0, all.TaskCostUSD.V, 0.01)

	_, err := Measure(d.DB, d.al, wb, time.Time{}, t0.Add(time.Hour), "gemini")
	assert.ErrorIs(t, err, agentreport.ErrUnknownAgent)
}
