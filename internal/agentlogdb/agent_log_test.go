package agentlogdb

import (
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// testWorkbenchID stands for a workbench id; agentlog.db has no projects table.
const testWorkbenchID int64 = 1

func openTestDB(t *testing.T) *DB {
	t.Helper()
	d, err := Open(filepath.Join(t.TempDir(), "agentlog.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = d.Close() })
	return d
}

func explainDetails(t *testing.T, d querier, query string, args ...any) string {
	t.Helper()
	rows, err := d.Query("EXPLAIN QUERY PLAN "+query, args...)
	require.NoError(t, err)
	defer rows.Close()
	var lines []string
	for rows.Next() {
		var id, parent, notused int
		var detail string
		require.NoError(t, rows.Scan(&id, &parent, &notused, &detail))
		lines = append(lines, detail)
	}
	require.NoError(t, rows.Err())
	return strings.Join(lines, "\n")
}

func agentSession(uuid, started string, pid int64) AgentLogSession {
	return AgentLogSession{SessionUUID: uuid, Agent: "claude", ProjectID: &pid, FolderPath: "/w",
		HomeCWD: "/w", SourcePath: "/x/" + uuid + ".jsonl", StartedAt: started, EndedAt: started}
}

func apiCall(session, key string, out int64) AgentLogEvent {
	return AgentLogEvent{SessionUUID: session, Key: key, Kind: "api_call", TS: "2026-10-01T10:00:00Z",
		Name: "claude-opus-5-5", InputTokens: 10, OutputTokens: out, SrcPath: "/x/a.jsonl"}
}

func TestApplyAgentLogBatch_APICallCountsOnceLaterWins(t *testing.T) {
	d := openTestDB(t)
	pid := testWorkbenchID
	b := AgentLogBatch{File: AgentLogFile{Path: "/x/a.jsonl", Agent: "claude", ReadOffset: 100}, ExpectOffset: -1,
		Sessions: []AgentLogSession{agentSession("s1", "2026-10-01T10:00:00Z", pid)},
		Events:   []AgentLogEvent{apiCall("s1", "m1:r1", 5), apiCall("s1", "m1:r1", 40)}}
	ok, err := d.ApplyAgentLogBatch(b)
	require.NoError(t, err)
	require.True(t, ok)
	var n, out int64
	require.NoError(t, d.QueryRow(`SELECT COUNT(*), SUM(output_tokens) FROM agent_log_events`).Scan(&n, &out))
	assert.Equal(t, int64(1), n)
	assert.Equal(t, int64(40), out)
}

func TestApplyAgentLogBatch_CompareAndSetOffset(t *testing.T) {
	d := openTestDB(t)
	pid := testWorkbenchID
	b := AgentLogBatch{File: AgentLogFile{Path: "/x/a.jsonl", Agent: "claude", ReadOffset: 100}, ExpectOffset: -1,
		Sessions: []AgentLogSession{agentSession("s1", "2026-10-01T10:00:00Z", pid)}}
	ok, err := d.ApplyAgentLogBatch(b)
	require.NoError(t, err)
	require.True(t, ok)
	ok, err = d.ApplyAgentLogBatch(b) // stale: the row now exists at 100
	require.NoError(t, err)
	assert.False(t, ok)
	b.ExpectOffset, b.File.ReadOffset = 100, 250
	ok, err = d.ApplyAgentLogBatch(b)
	require.NoError(t, err)
	assert.True(t, ok)
	f, err := d.GetAgentLogFile("/x/a.jsonl")
	require.NoError(t, err)
	assert.Equal(t, int64(250), f.ReadOffset)
}

func TestApplyAgentLogBatch_ReplayOwnedByEarliestSession(t *testing.T) {
	d := openTestDB(t)
	pid := testWorkbenchID
	// The fork (later session) is scanned first, then the original.
	_, err := d.ApplyAgentLogBatch(AgentLogBatch{File: AgentLogFile{Path: "/x/fork.jsonl", Agent: "claude", ReadOffset: 1}, ExpectOffset: -1,
		Sessions: []AgentLogSession{agentSession("fork", "2026-10-02T00:00:00Z", pid)},
		Events:   []AgentLogEvent{apiCall("fork", "m1:r1", 7)}})
	require.NoError(t, err)
	_, err = d.ApplyAgentLogBatch(AgentLogBatch{File: AgentLogFile{Path: "/x/orig.jsonl", Agent: "claude", ReadOffset: 1}, ExpectOffset: -1,
		Sessions: []AgentLogSession{agentSession("orig", "2026-10-01T00:00:00Z", pid)},
		Events:   []AgentLogEvent{apiCall("orig", "m1:r1", 7)}})
	require.NoError(t, err)
	var owner string
	require.NoError(t, d.QueryRow(`SELECT session_uuid FROM agent_log_events WHERE key='m1:r1'`).Scan(&owner))
	assert.Equal(t, "orig", owner)
}

func TestApplyAgentLogBatch_SubagentReplaySkipped(t *testing.T) {
	d := openTestDB(t)
	pid := testWorkbenchID
	_, err := d.ApplyAgentLogBatch(AgentLogBatch{File: AgentLogFile{Path: "/x/p.jsonl", Agent: "claude", ReadOffset: 1}, ExpectOffset: -1,
		Sessions: []AgentLogSession{agentSession("p", "2026-10-01T00:00:00Z", pid)},
		Events:   []AgentLogEvent{func() AgentLogEvent { e := apiCall("p", "m1:r1", 7); e.MessageID = "m1"; return e }()}})
	require.NoError(t, err)
	replay := apiCall("p", "m1:r2", 7)
	replay.MessageID, replay.SubagentReplayCheck = "m1", true
	_, err = d.ApplyAgentLogBatch(AgentLogBatch{File: AgentLogFile{Path: "/x/p/subagents/agent-a.jsonl", Agent: "claude", ReadOffset: 1}, ExpectOffset: -1,
		Events: []AgentLogEvent{replay}})
	require.NoError(t, err)
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM agent_log_events WHERE kind='api_call'`).Scan(&n))
	assert.Equal(t, 1, n)
}

// The replay check runs once per subagent api_call inside the import's write
// transaction: it must seek the unique key range, never walk every api_call
// through idx_agent_log_events_kind (that held the lock for seconds per batch).
func TestApplyAgentLogBatch_ReplayCheckSeeksKey(t *testing.T) {
	d := openTestDB(t)
	plan := explainDetails(t, d, agentLogReplayCheckQuery, "s1", "m1:", "m1:￿", "m1:r2")
	assert.Contains(t, plan, "USING INDEX sqlite_autoindex_agent_log_events_1 (key>? AND key<?)")
	assert.NotContains(t, plan, "idx_agent_log_events_kind")
	assert.NotContains(t, plan, "idx_agent_log_events_session")
}

func TestApplyAgentLogBatch_ToolResultPairsLater(t *testing.T) {
	d := openTestDB(t)
	pid := testWorkbenchID
	use := AgentLogEvent{SessionUUID: "s1", Key: "tool:t1", Kind: "tool", TS: "2026-10-01T10:00:00Z", Name: "Bash", Target: "go test", Outcome: "pending", SrcPath: "/x/a.jsonl"}
	_, err := d.ApplyAgentLogBatch(AgentLogBatch{File: AgentLogFile{Path: "/x/a.jsonl", Agent: "claude", ReadOffset: 10}, ExpectOffset: -1,
		Sessions: []AgentLogSession{agentSession("s1", "2026-10-01T10:00:00Z", pid)}, Events: []AgentLogEvent{use}})
	require.NoError(t, err)
	_, err = d.ApplyAgentLogBatch(AgentLogBatch{File: AgentLogFile{Path: "/x/a.jsonl", Agent: "claude", ReadOffset: 20}, ExpectOffset: 10,
		ToolResults: []AgentToolResult{{ToolUseID: "t1", TS: "2026-10-01T10:00:02Z", Outcome: "error", ErrorClass: "exit_code"}}})
	require.NoError(t, err)
	var outcome, class string
	var dur int64
	require.NoError(t, d.QueryRow(`SELECT outcome, error_class, duration_ms FROM agent_log_events WHERE key='tool:t1'`).Scan(&outcome, &class, &dur))
	assert.Equal(t, "error", outcome)
	assert.Equal(t, "exit_code", class)
	assert.Equal(t, int64(2000), dur)
}

// PROJ-02 exception (spec D3): a deleted workbench's sessions keep their
// stale project_id (no foreign key reaches watchtower.db) and a workbench
// later bound to the same folder adopts them; another folder's sessions and
// a live workbench's sessions stay where they are.
func TestAgentLog_SurvivesWorkbenchDeleteAndIsAdopted(t *testing.T) {
	d := openTestDB(t)
	deleted, other, live := int64(7), int64(8), int64(10)
	otherFolder := agentSession("s2", "2026-10-01T00:00:00Z", other)
	otherFolder.FolderPath = "/elsewhere"
	_, err := d.ApplyAgentLogBatch(AgentLogBatch{File: AgentLogFile{Path: "/x/a.jsonl", Agent: "claude", ReadOffset: 1}, ExpectOffset: -1,
		Sessions: []AgentLogSession{agentSession("s1", "2026-10-01T00:00:00Z", deleted), otherFolder,
			agentSession("s3", "2026-10-01T00:00:00Z", live)},
		Events: []AgentLogEvent{apiCall("s1", "m1:r1", 3)}})
	require.NoError(t, err)

	adopted, err := d.AdoptAgentLogSessions(9, "/w", []int64{8, 9, 10})
	require.NoError(t, err)
	assert.Equal(t, int64(1), adopted)
	owner := func(uuid string) int64 {
		t.Helper()
		var pid int64
		require.NoError(t, d.QueryRow(`SELECT project_id FROM agent_log_sessions WHERE session_uuid = ?`, uuid).Scan(&pid))
		return pid
	}
	assert.Equal(t, int64(9), owner("s1"), "7 is no longer live: adopted")
	assert.Equal(t, other, owner("s2"), "another folder's session stays")
	assert.Equal(t, live, owner("s3"), "a live workbench's session is not stolen")
	var events int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM agent_log_events WHERE session_uuid = 's1'`).Scan(&events))
	assert.Equal(t, 1, events, "the events survive with their session")

	_, err = d.Exec(`UPDATE agent_log_sessions SET project_id = NULL WHERE session_uuid = 's1'`)
	require.NoError(t, err)
	adopted, err = d.AdoptAgentLogSessions(9, "/w", []int64{9, 10})
	require.NoError(t, err)
	assert.Equal(t, int64(1), adopted, "a NULL project_id is adopted too")
}

func TestAgentLogStats_OwnerTurnsSkipNotifications(t *testing.T) {
	d := openTestDB(t)
	pid := testWorkbenchID
	var evs []AgentLogEvent
	for i, trig := range []string{"owner", "notification", "hook"} {
		evs = append(evs, AgentLogEvent{SessionUUID: "s1", Key: "owner_turn:" + trig, Kind: "owner_turn", Trigger: trig,
			TS: "2026-10-01T10:00:0" + string(rune('0'+i)) + "Z", SrcPath: "/x/a.jsonl"})
	}
	_, err := d.ApplyAgentLogBatch(AgentLogBatch{File: AgentLogFile{Path: "/x/a.jsonl", Agent: "claude", ReadOffset: 10}, ExpectOffset: -1,
		Sessions: []AgentLogSession{agentSession("s1", "2026-10-01T10:00:00Z", pid)}, Events: evs})
	require.NoError(t, err)
	st, err := d.AgentLogStats(pid)
	require.NoError(t, err)
	assert.Equal(t, 1, st.OwnerTurns)
}

func TestApplyAgentLogBatch_ToolResultSetsSpawnedAgent(t *testing.T) {
	d := openTestDB(t)
	pid := testWorkbenchID
	use := AgentLogEvent{SessionUUID: "s1", Key: "tool:t1", Kind: "tool", TS: "2026-10-01T10:00:00Z", Name: "Agent", Outcome: "pending", SrcPath: "/x/a.jsonl"}
	_, err := d.ApplyAgentLogBatch(AgentLogBatch{File: AgentLogFile{Path: "/x/a.jsonl", Agent: "claude", ReadOffset: 10}, ExpectOffset: -1,
		Sessions: []AgentLogSession{agentSession("s1", "2026-10-01T10:00:00Z", pid)}, Events: []AgentLogEvent{use}})
	require.NoError(t, err)
	_, err = d.ApplyAgentLogBatch(AgentLogBatch{File: AgentLogFile{Path: "/x/a.jsonl", Agent: "claude", ReadOffset: 20}, ExpectOffset: 10,
		ToolResults: []AgentToolResult{{ToolUseID: "t1", TS: "2026-10-01T10:00:02Z", Outcome: "ok", SpawnedAgentID: "a1", Background: true}}})
	require.NoError(t, err)
	var id string
	var bg bool
	require.NoError(t, d.QueryRow(`SELECT spawned_agent_id, background FROM agent_log_events WHERE key='tool:t1'`).Scan(&id, &bg))
	assert.Equal(t, "a1", id)
	assert.True(t, bg)
}

func TestApplyAgentLogBatch_AsyncResultWithoutAgentIDSetsBackground(t *testing.T) {
	d := openTestDB(t)
	pid := testWorkbenchID
	use := AgentLogEvent{SessionUUID: "s1", Key: "tool:t1", Kind: "tool", TS: "2026-10-01T10:00:00Z", Name: "Agent", Outcome: "pending", SrcPath: "/x/a.jsonl"}
	_, err := d.ApplyAgentLogBatch(AgentLogBatch{File: AgentLogFile{Path: "/x/a.jsonl", Agent: "claude", ReadOffset: 10}, ExpectOffset: -1,
		Sessions: []AgentLogSession{agentSession("s1", "2026-10-01T10:00:00Z", pid)}, Events: []AgentLogEvent{use}})
	require.NoError(t, err)
	_, err = d.ApplyAgentLogBatch(AgentLogBatch{File: AgentLogFile{Path: "/x/a.jsonl", Agent: "claude", ReadOffset: 20}, ExpectOffset: 10,
		ToolResults: []AgentToolResult{{ToolUseID: "t1", TS: "2026-10-01T10:00:02Z", Outcome: "ok", Background: true}}})
	require.NoError(t, err)
	var id string
	var bg bool
	require.NoError(t, d.QueryRow(`SELECT spawned_agent_id, background FROM agent_log_events WHERE key='tool:t1'`).Scan(&id, &bg))
	assert.Equal(t, "", id)
	assert.True(t, bg)
}

// #571 review: a slice whose records carry no timestamp never blanks a
// session's stored start, and a blank start is filled by a later slice.
func TestApplyAgentLogBatch_EmptyStartNeverOverwritesSessionStart(t *testing.T) {
	d := openTestDB(t)
	pid := testWorkbenchID
	apply := func(off, expect int64, s AgentLogSession) {
		t.Helper()
		ok, err := d.ApplyAgentLogBatch(AgentLogBatch{File: AgentLogFile{Path: "/x/a.jsonl", Agent: "claude", ReadOffset: off},
			ExpectOffset: expect, Sessions: []AgentLogSession{s}})
		require.NoError(t, err)
		require.True(t, ok)
	}
	read := func(uuid string) (started, ended string) {
		t.Helper()
		require.NoError(t, d.QueryRow(`SELECT started_at, ended_at FROM agent_log_sessions WHERE session_uuid = ?`, uuid).Scan(&started, &ended))
		return
	}
	apply(1, -1, agentSession("s1", "2026-10-01T10:00:00Z", pid))
	apply(2, 1, agentSession("s1", "", pid))
	started, ended := read("s1")
	assert.Equal(t, "2026-10-01T10:00:00Z", started)
	assert.Equal(t, "2026-10-01T10:00:00Z", ended)

	apply(3, 2, agentSession("s2", "", pid))
	apply(4, 3, agentSession("s2", "2026-10-01T11:00:00Z", pid))
	started, ended = read("s2")
	assert.Equal(t, "2026-10-01T11:00:00Z", started)
	assert.Equal(t, "2026-10-01T11:00:00Z", ended)
}

// #571: reprice commits slice by slice; a failed slice leaves its rows (and
// the rest) at the old version for the next scan, earlier slices stay done.
func TestRepriceAgentLogEvents_SlicesAndPartialFailure(t *testing.T) {
	old := agentLogRepriceSlice
	agentLogRepriceSlice = 2
	t.Cleanup(func() { agentLogRepriceSlice = old })
	d := openTestDB(t)
	pid := testWorkbenchID
	var evs []AgentLogEvent
	for i := range 5 {
		evs = append(evs, apiCall("s1", "m"+string(rune('a'+i))+":r", 3))
	}
	_, err := d.ApplyAgentLogBatch(AgentLogBatch{File: AgentLogFile{Path: "/x/a.jsonl", Agent: "claude", ReadOffset: 1}, ExpectOffset: -1,
		Sessions: []AgentLogSession{agentSession("s1", "2026-10-01T10:00:00Z", pid)}, Events: evs})
	require.NoError(t, err)
	price := func(string, string, int64, int64, int64, int64, int64) (float64, bool) { return 1, true }
	_, err = d.Exec(`CREATE TRIGGER test_fail_reprice BEFORE UPDATE OF price_version ON agent_log_events
		WHEN NEW.key = 'md:r' BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END`)
	require.NoError(t, err)
	n, err := d.RepriceAgentLogEvents(9, price)
	require.Error(t, err)
	assert.Equal(t, 2, n)
	var done int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM agent_log_events WHERE price_version = 9`).Scan(&done))
	assert.Equal(t, 2, done, "the first slice is committed, the failing one rolled back")

	_, err = d.Exec(`DROP TRIGGER test_fail_reprice`)
	require.NoError(t, err)
	n, err = d.RepriceAgentLogEvents(9, price)
	require.NoError(t, err)
	assert.Equal(t, 3, n)
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM agent_log_events WHERE price_version = 9`).Scan(&done))
	assert.Equal(t, 5, done)
}
