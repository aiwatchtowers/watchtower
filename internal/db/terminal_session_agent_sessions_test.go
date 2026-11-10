package db

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func agentSessionIDs(t *testing.T, d *DB, sid int64) []string {
	t.Helper()
	list, err := d.ListTerminalAgentSessions(sid)
	require.NoError(t, err)
	ids := make([]string, 0, len(list))
	for _, s := range list {
		ids = append(ids, s.AgentSessionID)
	}
	return ids
}

func TestTerminalAgentSessions_RecordsEachID(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	res, err := d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id)
		VALUES (?, 'claude', 'T', '/tmp/acme', 's-1')`, wb)
	require.NoError(t, err)
	sid, err := res.LastInsertId()
	require.NoError(t, err)

	for _, id := range []string{"s-2", "s-2", "s-3"} {
		_, err := d.SetTerminalClaudeSessionID(sid, wb, id)
		require.NoError(t, err)
	}
	assert.Equal(t, []string{"s-1", "s-2", "s-3"}, agentSessionIDs(t, d, sid))

	list, err := d.ListTerminalAgentSessions(sid)
	require.NoError(t, err)
	assert.False(t, list[0].FirstSeenAt.IsZero())
}

func TestTerminalAgentSessions_CodexIDRecorded(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	res, err := d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path)
		VALUES (?, 'codex', 'T', '/tmp/acme')`, wb)
	require.NoError(t, err)
	sid, err := res.LastInsertId()
	require.NoError(t, err)
	assert.Empty(t, agentSessionIDs(t, d, sid))

	ok, err := d.SetTerminalAgentSessionID(sid, wb, "c-1", "")
	require.NoError(t, err)
	require.True(t, ok)
	assert.Equal(t, []string{"c-1"}, agentSessionIDs(t, d, sid))
}

func TestTerminalAgentSessions_CascadeOnDelete(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	sid := newTestSession(t, d, wb)
	_, err := d.SetTerminalClaudeSessionID(sid, wb, "s-2")
	require.NoError(t, err)
	require.Len(t, agentSessionIDs(t, d, sid), 2)

	require.NoError(t, d.DeleteWorkbench(wb))
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM terminal_session_agent_sessions`).Scan(&n))
	assert.Zero(t, n, "a deleted workbench leaves no ledger rows (PROJ-02)")
}

func TestMigration00127_Backfill(t *testing.T) {
	d, err := Open(filepath.Join(t.TempDir(), "ledger.db"))
	require.NoError(t, err)
	defer d.Close()
	wb := newTestWorkbench(t, d)

	require.NoError(t, gooseDownTo(d.DB, "migrations", 126))
	_, err = d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id, created_at)
		VALUES (?, 'claude', 'T', '/tmp/acme', 's-old', '2026-10-01T10:00:00Z')`, wb)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path) VALUES (?, 'shell', 'S', '/tmp/acme')`, wb)
	require.NoError(t, err)
	require.NoError(t, gooseUp(d.DB, "migrations"))

	var n int
	var id, at string
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM terminal_session_agent_sessions`).Scan(&n))
	assert.Equal(t, 1, n)
	require.NoError(t, d.QueryRow(`SELECT agent_session_id, first_seen_at FROM terminal_session_agent_sessions`).Scan(&id, &at))
	assert.Equal(t, "s-old", id)
	assert.Equal(t, "2026-10-01T10:00:00Z", at)
}

func TestAgentSessionIDs_HistoryAndCurrent(t *testing.T) {
	d := openTestDB(t)
	ctx := context.Background()
	wb := newTestWorkbench(t, d)
	res, err := d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id, created_at)
		VALUES (?, 'claude', 'T', '/tmp/acme', 'u-1', '2026-10-12T09:30:00Z')`, wb)
	require.NoError(t, err)
	sid, err := res.LastInsertId()
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE terminal_session_agent_sessions SET first_seen_at = '2026-10-12T09:30:00Z' WHERE agent_session_id = 'u-1'`)
	require.NoError(t, err)
	_, err = d.SetTerminalClaudeSessionID(sid, wb, "u-2")
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE terminal_session_agent_sessions SET first_seen_at = '2026-10-12T10:00:00Z' WHERE agent_session_id = 'u-2'`)
	require.NoError(t, err)

	got, err := d.AgentSessionIDs(ctx, sid)
	require.NoError(t, err)
	assert.Equal(t, []AgentSessionID{{ID: "u-1", Since: "2026-10-12T09:30:00Z"}, {ID: "u-2", Since: "2026-10-12T10:00:00Z"}}, got)

	// The current id with no history row (a pre-00127 gap) is acquired at
	// the row's created_at.
	_, err = d.Exec(`DELETE FROM terminal_session_agent_sessions WHERE agent_session_id = 'u-2'`)
	require.NoError(t, err)
	got, err = d.AgentSessionIDs(ctx, sid)
	require.NoError(t, err)
	assert.Equal(t, []AgentSessionID{{ID: "u-1", Since: "2026-10-12T09:30:00Z"}, {ID: "u-2", Since: "2026-10-12T09:30:00Z"}}, got)

	none, err := d.AgentSessionIDs(ctx, sid+100)
	require.NoError(t, err)
	assert.Empty(t, none)
}

func TestAgentSessionIDOwners_HistoryAndCurrent(t *testing.T) {
	d := openTestDB(t)
	ctx := context.Background()
	wb := newTestWorkbench(t, d)
	a := newTestSession(t, d, wb)
	b := newTestSession(t, d, wb)
	c := newTestSession(t, d, wb)
	_, err := d.SetTerminalClaudeSessionID(a, wb, "shared")
	require.NoError(t, err)
	_, err = d.SetTerminalClaudeSessionID(a, wb, "a-later") // "shared" stays in a's history only
	require.NoError(t, err)
	_, err = d.SetTerminalClaudeSessionID(b, wb, "shared") // b's current id
	require.NoError(t, err)
	_, err = d.Exec(`DELETE FROM terminal_session_agent_sessions WHERE terminal_session_id = ? AND agent_session_id = 'shared'`, b)
	require.NoError(t, err)
	_, err = d.SetTerminalClaudeSessionID(c, wb, "c-own")
	require.NoError(t, err)

	owners, err := d.AgentSessionIDOwners(ctx, []string{"shared", "c-own", "nobody"})
	require.NoError(t, err)
	assert.Equal(t, map[string][]int64{"shared": {a, b}, "c-own": {c}}, owners)

	empty, err := d.AgentSessionIDOwners(ctx, nil)
	require.NoError(t, err)
	assert.Empty(t, empty)
}

func tombstones(t *testing.T, d *DB) []string {
	t.Helper()
	rows, err := d.Query(`SELECT agent_session_id FROM agent_session_tombstones ORDER BY 1`)
	require.NoError(t, err)
	defer rows.Close()
	out := []string{}
	for rows.Next() {
		var id string
		require.NoError(t, rows.Scan(&id))
		out = append(out, id)
	}
	require.NoError(t, rows.Err())
	return out
}

// Deleting a terminal session tombstones every agent session id it had,
// its history and its current id, also through a workbench delete's
// cascade (auto cleanup spec 2026-11-10 §2b: a uuid of a deleted row stays
// shared).
func TestAgentSessionTombstones_DeleteAndCascade(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	sid := newTestSession(t, d, wb) // current "uuid"
	_, err := d.SetTerminalClaudeSessionID(sid, wb, "u-2")
	require.NoError(t, err)
	// A current id missing from the history is tombstoned too.
	_, err = d.Exec(`DELETE FROM terminal_session_agent_sessions WHERE agent_session_id = 'u-2'`)
	require.NoError(t, err)
	_, err = d.Exec(`DELETE FROM terminal_sessions WHERE id = ?`, sid)
	require.NoError(t, err)
	assert.Equal(t, []string{"u-2", "uuid"}, tombstones(t, d))

	other := newTestWorkbench(t, d)
	cs := newTestSession(t, d, other)
	_, err = d.SetTerminalClaudeSessionID(cs, other, "c-1")
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path) VALUES (?, 'shell', 'S', '/tmp/acme')`, other)
	require.NoError(t, err) // a shell row has no id and tombstones nothing
	require.NoError(t, d.DeleteWorkbench(other))
	assert.Equal(t, []string{"c-1", "u-2", "uuid"}, tombstones(t, d))
}

func TestAgentSessionIDOwners_TombstoneIsADeletedOwner(t *testing.T) {
	d := openTestDB(t)
	ctx := context.Background()
	wb := newTestWorkbench(t, d)
	a := newTestSession(t, d, wb)
	b := newTestSession(t, d, wb)
	_, err := d.SetTerminalClaudeSessionID(a, wb, "shared")
	require.NoError(t, err)
	_, err = d.SetTerminalClaudeSessionID(b, wb, "shared")
	require.NoError(t, err)
	_, err = d.Exec(`DELETE FROM terminal_sessions WHERE id = ?`, b)
	require.NoError(t, err)

	owners, err := d.AgentSessionIDOwners(ctx, []string{"shared"})
	require.NoError(t, err)
	assert.Equal(t, map[string][]int64{"shared": {0, a}}, owners)
}
