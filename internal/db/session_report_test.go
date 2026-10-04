package db

import (
	"database/sql"
	"path/filepath"
	"testing"
	"time"

	"github.com/pressly/goose/v3"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func linkRow(t *testing.T, d *DB, sessionID, targetID int64) (firstAt, lastAt string) {
	t.Helper()
	require.NoError(t, d.QueryRow(`SELECT first_at, last_at FROM terminal_session_targets
		WHERE session_id = ? AND target_id = ?`, sessionID, targetID).Scan(&firstAt, &lastAt))
	return firstAt, lastAt
}

func countRows(t *testing.T, d *DB, q string, args ...any) int {
	t.Helper()
	var n int
	require.NoError(t, d.QueryRow(q, args...).Scan(&n))
	return n
}

func TestMigration00101_DownUpKeepsOtherRows(t *testing.T) {
	d, err := Open(filepath.Join(t.TempDir(), "session-report-cycle.db"))
	require.NoError(t, err)
	defer d.Close()
	pid := newTestWorkbench(t, d)
	target := insertWorkbenchTargetRow(t, d, pid, "feature")
	sid := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
	require.NoError(t, d.LinkSessionTarget(sid, target))
	require.NoError(t, d.UpsertPRState(PRState{WorkbenchID: pid, Ref: "pr:7", State: "open", CheckedAt: "2026-10-03T10:00:00Z"}))

	// DownTo(100), not a bare Down: a later migration can move the tip past 00101.
	require.NoError(t, goose.DownTo(d.DB, "migrations", 100))
	cols := columnNames(t, d.DB, "terminal_sessions")
	for _, c := range []string{"finished_at", "finish_summary", "agent_failed_at", "agent_error"} {
		assert.False(t, cols[c], "Down kept %s", c)
	}
	for _, table := range []string{"terminal_session_targets", "workbench_pr_states"} {
		assert.Zero(t, countRows(t, d, `SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?`, table),
			"Down kept %s", table)
	}
	assert.Equal(t, 1, countRows(t, d, `SELECT COUNT(*) FROM terminal_sessions WHERE id = ?`, sid))
	assert.Equal(t, 1, countRows(t, d, `SELECT COUNT(*) FROM targets WHERE id = ?`, target))

	require.NoError(t, goose.Up(d.DB, "migrations"))
	cols = columnNames(t, d.DB, "terminal_sessions")
	for _, c := range []string{"finished_at", "finish_summary", "agent_failed_at", "agent_error"} {
		assert.True(t, cols[c], "re-Up did not restore %s", c)
	}
	assert.Equal(t, 1, countRows(t, d, `SELECT COUNT(*) FROM terminal_sessions WHERE id = ?`, sid))
	assert.Equal(t, 1, countRows(t, d, `SELECT COUNT(*) FROM projects WHERE id = ?`, pid))
	require.NoError(t, d.LinkSessionTarget(sid, target))
}

func TestLinkSessionTarget_KeepsFirstAtMovesLastAt(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	target := insertWorkbenchTargetRow(t, d, pid, "feature")
	sid := newAgentStateRow(t, d, pid, "claude", agentStateUUID)

	require.NoError(t, d.LinkSessionTarget(sid, target))
	// Backdate the row so the second link's now is visibly later.
	_, err := d.Exec(`UPDATE terminal_session_targets SET first_at = '2026-01-01T00:00:00Z', last_at = '2026-01-01T00:00:00Z'`)
	require.NoError(t, err)
	require.NoError(t, d.LinkSessionTarget(sid, target))

	first, last := linkRow(t, d, sid, target)
	assert.Equal(t, "2026-01-01T00:00:00Z", first, "a second link keeps first_at")
	assert.Greater(t, last, first, "a second link moves last_at")
	_, err = time.Parse(time.RFC3339, last)
	assert.NoError(t, err, "last_at is UTC ISO-8601 seconds")
	assert.Equal(t, 1, countRows(t, d, `SELECT COUNT(*) FROM terminal_session_targets`))

	ids, err := d.SessionLinkedTargets(sid)
	require.NoError(t, err)
	assert.Equal(t, []int64{target}, ids)
	ids, err = d.SessionLinkedTargets(sid + 100)
	require.NoError(t, err)
	assert.Empty(t, ids)
}

func TestSessionTargetLinks_Cascades(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	t1 := insertWorkbenchTargetRow(t, d, pid, "one")
	t2 := insertWorkbenchTargetRow(t, d, pid, "two")
	s1 := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
	s2 := newAgentStateRow(t, d, pid, "claude", "1b6c1f7e-3c2a-4d5e-9f10-2a3b4c5d6e7f")
	for _, s := range []int64{s1, s2} {
		for _, tg := range []int64{t1, t2} {
			require.NoError(t, d.LinkSessionTarget(s, tg))
		}
	}

	_, err := d.Exec(`DELETE FROM terminal_sessions WHERE id = ?`, s1)
	require.NoError(t, err)
	assert.Zero(t, countRows(t, d, `SELECT COUNT(*) FROM terminal_session_targets WHERE session_id = ?`, s1))
	_, err = d.Exec(`DELETE FROM targets WHERE id = ?`, t1)
	require.NoError(t, err)
	assert.Zero(t, countRows(t, d, `SELECT COUNT(*) FROM terminal_session_targets WHERE target_id = ?`, t1))

	ids, err := d.SessionLinkedTargets(s2)
	require.NoError(t, err)
	assert.Equal(t, []int64{t2}, ids)
}

func TestPRStates_UpsertAndRead(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	other := newTestWorkbench(t, d)
	open := PRState{WorkbenchID: pid, Ref: "pr:7", State: "open", PRNumber: sql.NullInt64{Int64: 7, Valid: true},
		Title: "Add login", Additions: sql.NullInt64{Int64: 12, Valid: true}, Deletions: sql.NullInt64{Int64: 3, Valid: true},
		CheckedAt: "2026-10-03T10:00:00Z"}
	require.NoError(t, d.UpsertPRState(open))
	require.NoError(t, d.UpsertPRState(PRState{WorkbenchID: pid, Ref: "branch:feature/x", State: "none", CheckedAt: "2026-10-03T10:00:00Z"}))
	require.NoError(t, d.UpsertPRState(PRState{WorkbenchID: other, Ref: "pr:7", State: "closed", CheckedAt: "2026-10-03T10:00:00Z"}))

	merged := open
	merged.State, merged.MergedAt, merged.CheckedAt = "merged", "2026-10-03T11:00:00Z", "2026-10-03T11:05:00Z"
	require.NoError(t, d.UpsertPRState(merged))

	got, err := d.PRStates(pid)
	require.NoError(t, err)
	require.Len(t, got, 2)
	assert.Equal(t, merged, got["pr:7"], "an upsert replaces the row")
	assert.Equal(t, "none", got["branch:feature/x"].State)
	assert.False(t, got["branch:feature/x"].PRNumber.Valid)

	none, err := d.PRStates(pid + 100)
	require.NoError(t, err)
	assert.Empty(t, none)
}

func TestPRStates_CheckRejectsUnknownState(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	assert.Error(t, d.UpsertPRState(PRState{WorkbenchID: pid, Ref: "pr:1", State: "draft", CheckedAt: "2026-10-03T10:00:00Z"}))
	for _, s := range []string{"merged", "open", "closed", "none", "unknown"} {
		assert.NoError(t, d.UpsertPRState(PRState{WorkbenchID: pid, Ref: "pr:1", State: s, CheckedAt: "2026-10-03T10:00:00Z"}), s)
	}
}

func TestFinishTerminalSession_StoresBoth(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	sid := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
	at := time.Date(2026, 10, 3, 12, 34, 56, 789_000_000, time.FixedZone("UTC+3", 3*3600))

	require.NoError(t, d.FinishTerminalSession(sid, "first", at))
	require.NoError(t, d.FinishTerminalSession(sid, "Shipped the login fix.", at.Add(time.Second)))
	finished, summary := finishColumns(t, d, sid)
	assert.Equal(t, "2026-10-03T09:34:57.789Z", finished.String, "agent_state_at format, UTC")
	assert.Equal(t, "Shipped the login fix.", summary, "the newest summary wins")

	assert.ErrorIs(t, d.FinishTerminalSession(sid+100, "x", at), ErrTerminalSessionNotFound)
}

func finishColumns(t *testing.T, d *DB, sid int64) (sql.NullString, string) {
	t.Helper()
	var finished sql.NullString
	var summary string
	require.NoError(t, d.QueryRow(`SELECT finished_at, finish_summary FROM terminal_sessions WHERE id = ?`, sid).
		Scan(&finished, &summary))
	return finished, summary
}

func failureColumns(t *testing.T, d *DB, sid int64) (failedAt sql.NullString, agentError, stateAt string) {
	t.Helper()
	require.NoError(t, d.QueryRow(`SELECT agent_failed_at, agent_error, agent_state_at FROM terminal_sessions WHERE id = ?`, sid).
		Scan(&failedAt, &agentError, &stateAt))
	return failedAt, agentError, stateAt
}

// PROJ-11 (amended 2026-10-03): a `working` write clears finished_at and the
// error in the same statement and keeps the summary; waiting and approval
// keep finished_at.
func TestProj11_WorkingClearsFinishedAndError(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	sid := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
	t0 := time.Now().UTC().Truncate(time.Millisecond)

	require.NoError(t, d.FinishTerminalSession(sid, "Done.", t0))
	for i, state := range []string{"waiting", "approval"} {
		ok, err := d.SetTerminalAgentState(sid, pid, agentStateUUID, state, t0.Add(time.Duration(i+1)*time.Second), "", nil, false, AgentOrder{})
		require.NoError(t, err)
		require.True(t, ok, state)
		finished, _ := finishColumns(t, d, sid)
		assert.True(t, finished.Valid, "%s cleared finished_at", state)
	}
	ok, err := d.SetTerminalAgentState(sid, pid, agentStateUUID, "waiting", t0.Add(3*time.Second), "",
		&AgentFailure{Error: "rate_limit"}, false, AgentOrder{})
	require.NoError(t, err)
	require.True(t, ok)

	ok, err = d.SetTerminalAgentState(sid, pid, agentStateUUID, "working", t0.Add(4*time.Second), "", nil, false, AgentOrder{})
	require.NoError(t, err)
	require.True(t, ok)
	finished, summary := finishColumns(t, d, sid)
	assert.False(t, finished.Valid, "working kept finished_at")
	assert.Equal(t, "Done.", summary, "working kept the previous summary")
	failedAt, agentError, _ := failureColumns(t, d, sid)
	assert.False(t, failedAt.Valid, "working kept agent_failed_at")
	assert.Empty(t, agentError)

	// A subagent's PostToolUse (working only out of approval) clears it too.
	require.NoError(t, d.FinishTerminalSession(sid, "Again.", t0.Add(5*time.Second)))
	_, err = d.SetTerminalAgentState(sid, pid, agentStateUUID, "approval", t0.Add(6*time.Second), "", nil, false, AgentOrder{})
	require.NoError(t, err)
	ok, err = d.SetTerminalAgentState(sid, pid, agentStateUUID, "working", t0.Add(7*time.Second), "approval", nil, false, AgentOrder{})
	require.NoError(t, err)
	require.True(t, ok)
	finished, _ = finishColumns(t, d, sid)
	assert.False(t, finished.Valid, "working out of approval kept finished_at")
}

// PROJ-11: a prompt's `working` over a stored `working` still clears
// finished_at — after an Esc interrupt (no hook) the turn that called
// finish_session never reported its end, and the new prompt must not leave
// the new work Finished. With finished_at NULL it stays a repeat, and an
// older event still clears nothing.
func TestProj11_WorkingOverWorkingClearsFinished(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	sid := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
	t0 := time.Now().UTC().Truncate(time.Millisecond)
	ok, err := d.SetTerminalAgentState(sid, pid, agentStateUUID, "working", t0, "", nil, false, AgentOrder{})
	require.NoError(t, err)
	require.True(t, ok)
	require.NoError(t, d.FinishTerminalSession(sid, "Done.", t0.Add(time.Second)))

	ok, err = d.SetTerminalAgentState(sid, pid, agentStateUUID, "working", t0.Add(-time.Second), "", nil, true, AgentOrder{})
	require.NoError(t, err)
	assert.False(t, ok, "an older working wrote")
	finished, _ := finishColumns(t, d, sid)
	assert.True(t, finished.Valid, "an older working cleared finished_at")

	ok, err = d.SetTerminalAgentState(sid, pid, agentStateUUID, "working", t0.Add(2*time.Second), "", nil, true, AgentOrder{})
	require.NoError(t, err)
	require.True(t, ok, "a prompt's working over a finished working did not land")
	finished, summary := finishColumns(t, d, sid)
	assert.False(t, finished.Valid, "working over working kept finished_at")
	assert.Equal(t, "Done.", summary, "working over working dropped the summary")
	_, _, stateAt := failureColumns(t, d, sid)
	assert.Equal(t, t0.Add(2*time.Second).Format(agentStateAtLayout), stateAt)

	ok, err = d.SetTerminalAgentState(sid, pid, agentStateUUID, "working", t0.Add(3*time.Second), "", nil, true, AgentOrder{})
	require.NoError(t, err)
	assert.False(t, ok, "a plain working repeat wrote")
	_, _, afterAt := failureColumns(t, d, sid)
	assert.Equal(t, stateAt, afterAt, "a plain working repeat moved the time")
}

// PROJ-11: a tool run's `working` over a stored `working` never clears
// finished_at — it is the finish_session turn itself (its own PostToolUse).
func TestProj11_ToolRunWorkingOverWorkingKeepsFinished(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	sid := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
	t0 := time.Now().UTC().Truncate(time.Millisecond)
	ok, err := d.SetTerminalAgentState(sid, pid, agentStateUUID, "working", t0, "", nil, true, AgentOrder{})
	require.NoError(t, err)
	require.True(t, ok)
	require.NoError(t, d.FinishTerminalSession(sid, "Done.", t0.Add(time.Second)))

	ok, err = d.SetTerminalAgentState(sid, pid, agentStateUUID, "working", t0.Add(2*time.Second), "", nil, false, AgentOrder{})
	require.NoError(t, err)
	assert.False(t, ok, "a tool run's working over working wrote")
	finished, summary := finishColumns(t, d, sid)
	assert.True(t, finished.Valid, "a tool run's working over working cleared finished_at")
	assert.Equal(t, "Done.", summary)
}

// PROJ-11: a tool run's `working` that changes the state — out of waiting
// (a turn the agent started itself after Stop) or out of approval — is a new
// turn and clears finished_at.
func TestProj11_ToolRunOutOfWaitingClearsFinished(t *testing.T) {
	for _, from := range []string{"waiting", "approval"} {
		d := openTestDB(t)
		pid := newTestWorkbench(t, d)
		sid := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
		t0 := time.Now().UTC().Truncate(time.Millisecond)
		ok, err := d.SetTerminalAgentState(sid, pid, agentStateUUID, "working", t0, "", nil, true, AgentOrder{})
		require.NoError(t, err)
		require.True(t, ok)
		require.NoError(t, d.FinishTerminalSession(sid, "Done.", t0.Add(time.Second)))
		ok, err = d.SetTerminalAgentState(sid, pid, agentStateUUID, from, t0.Add(2*time.Second), "", nil, false, AgentOrder{})
		require.NoError(t, err)
		require.True(t, ok, from)

		ok, err = d.SetTerminalAgentState(sid, pid, agentStateUUID, "working", t0.Add(3*time.Second), "", nil, false, AgentOrder{})
		require.NoError(t, err)
		require.True(t, ok, "a tool run out of %s did not land", from)
		finished, summary := finishColumns(t, d, sid)
		assert.False(t, finished.Valid, "a tool run out of %s kept finished_at", from)
		assert.Equal(t, "Done.", summary, from)
	}
}

// An older working event, refused by the time guard, clears nothing.
func TestSetTerminalAgentState_RefusedWorkingKeepsFinished(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	sid := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
	t0 := time.Now().UTC().Truncate(time.Millisecond)
	ok, err := d.SetTerminalAgentState(sid, pid, agentStateUUID, "waiting", t0, "", &AgentFailure{Error: "rate_limit"}, false, AgentOrder{})
	require.NoError(t, err)
	require.True(t, ok)
	require.NoError(t, d.FinishTerminalSession(sid, "Done.", t0))

	ok, err = d.SetTerminalAgentState(sid, pid, agentStateUUID, "working", t0.Add(-time.Second), "", nil, false, AgentOrder{})
	require.NoError(t, err)
	assert.False(t, ok)
	finished, _ := finishColumns(t, d, sid)
	assert.True(t, finished.Valid, "a refused working write cleared finished_at")
	failedAt, agentError, _ := failureColumns(t, d, sid)
	assert.True(t, failedAt.Valid, "a refused working write cleared the error")
	assert.Equal(t, "rate_limit", agentError)
}

// PROJ-11 (amended 2026-10-03), db half: a StopFailure stores waiting plus
// agent_failed_at = agent_state_at and the error, whether the stored state
// was working or a plain waiting. A later plain waiting (idle_prompt, the
// Stop hook) keeps the error; a StopFailure with another error replaces it
// at its own time; a real state change (working, approval) clears it. The
// hook half (payload field, clipping) is in cmd.
func TestProj11_StopFailureRecordsErrorOtherWritesClearIt(t *testing.T) {
	for _, tc := range []struct {
		from, next string
		kept       bool
	}{
		{"working", "waiting", true},
		{"waiting", "waiting", true},
		{"working", "approval", false},
		{"waiting", "approval", false},
		{"waiting", "working", false},
	} {
		d := openTestDB(t)
		pid := newTestWorkbench(t, d)
		sid := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
		t0 := time.Now().UTC().Truncate(time.Millisecond)
		ok, err := d.SetTerminalAgentState(sid, pid, agentStateUUID, tc.from, t0, "", nil, false, AgentOrder{})
		require.NoError(t, err)
		require.True(t, ok)

		ok, err = d.SetTerminalAgentState(sid, pid, agentStateUUID, "waiting", t0.Add(time.Second), "",
			&AgentFailure{Error: "rate_limit"}, false, AgentOrder{})
		require.NoError(t, err)
		require.True(t, ok, "StopFailure from %s did not land", tc.from)
		failedAt, agentError, stateAt := failureColumns(t, d, sid)
		assert.Equal(t, stateAt, failedAt.String, "from %s: agent_failed_at = agent_state_at", tc.from)
		assert.Equal(t, "rate_limit", agentError)
		s, err := d.GetTerminalSession(sid)
		require.NoError(t, err)
		require.NotNil(t, s.AgentFailure)
		assert.Equal(t, AgentFailure{At: stateAt, Error: "rate_limit"}, *s.AgentFailure)

		// A repeated StopFailure is a repeat: the transition time is kept.
		ok, err = d.SetTerminalAgentState(sid, pid, agentStateUUID, "waiting", t0.Add(2*time.Second), "",
			&AgentFailure{Error: "rate_limit"}, false, AgentOrder{})
		require.NoError(t, err)
		assert.False(t, ok, "a repeated StopFailure wrote")

		// A StopFailure with another error replaces it and stamps its own
		// time, unless it is older than the stored state.
		ok, err = d.SetTerminalAgentState(sid, pid, agentStateUUID, "waiting", t0.Add(500*time.Millisecond), "",
			&AgentFailure{Error: "overloaded"}, false, AgentOrder{})
		require.NoError(t, err)
		assert.False(t, ok, "an older StopFailure with another error wrote")
		_, agentError, _ = failureColumns(t, d, sid)
		assert.Equal(t, "rate_limit", agentError, "an older StopFailure replaced the error")
		ok, err = d.SetTerminalAgentState(sid, pid, agentStateUUID, "waiting", t0.Add(2500*time.Millisecond), "",
			&AgentFailure{Error: "overloaded"}, false, AgentOrder{})
		require.NoError(t, err)
		require.True(t, ok, "a StopFailure with another error did not land")
		failedAt, agentError, newAt := failureColumns(t, d, sid)
		assert.Equal(t, t0.Add(2500*time.Millisecond).Format(agentStateAtLayout), newAt,
			"another error kept the first failure's time")
		assert.Equal(t, newAt, failedAt.String, "another error: agent_failed_at = agent_state_at")
		assert.Equal(t, "overloaded", agentError)
		stateAt = newAt

		ok, err = d.SetTerminalAgentState(sid, pid, agentStateUUID, tc.next, t0.Add(3*time.Second), "", nil, false, AgentOrder{})
		require.NoError(t, err)
		assert.Equal(t, !tc.kept, ok, "%s after a StopFailure: written", tc.next)
		failedAt, agentError, afterAt := failureColumns(t, d, sid)
		s, err = d.GetTerminalSession(sid)
		require.NoError(t, err)
		if tc.kept {
			assert.Equal(t, stateAt, afterAt, "a plain %s moved the failed state's time", tc.next)
			assert.Equal(t, stateAt, failedAt.String, "a plain %s cleared agent_failed_at", tc.next)
			assert.Equal(t, "overloaded", agentError, "a plain %s cleared agent_error", tc.next)
			assert.NotNil(t, s.AgentFailure)
			continue
		}
		assert.False(t, failedAt.Valid, "%s kept agent_failed_at", tc.next)
		assert.Empty(t, agentError, "%s kept agent_error", tc.next)
		assert.Nil(t, s.AgentFailure)
	}
}

// A new run (SessionStart) starts with no error either.
func TestClearTerminalAgentState_ClearsTheError(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	sid := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
	t0 := time.Now().UTC().Truncate(time.Millisecond)
	_, err := d.SetTerminalAgentState(sid, pid, agentStateUUID, "waiting", t0, "", &AgentFailure{Error: "rate_limit"}, false, AgentOrder{})
	require.NoError(t, err)
	ok, err := d.ClearTerminalAgentState(sid, pid, agentStateUUID, t0.Add(time.Second))
	require.NoError(t, err)
	require.True(t, ok)
	failedAt, agentError, _ := failureColumns(t, d, sid)
	assert.False(t, failedAt.Valid)
	assert.Empty(t, agentError)
}
