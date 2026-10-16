package db

import (
	"path/filepath"
	"testing"

	"github.com/pressly/goose/v3"
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

func TestMigration00125_Backfill(t *testing.T) {
	d, err := Open(filepath.Join(t.TempDir(), "ledger.db"))
	require.NoError(t, err)
	defer d.Close()
	wb := newTestWorkbench(t, d)

	require.NoError(t, goose.DownTo(d.DB, "migrations", 124))
	_, err = d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id, created_at)
		VALUES (?, 'claude', 'T', '/tmp/acme', 's-old', '2026-10-01T10:00:00Z')`, wb)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path) VALUES (?, 'shell', 'S', '/tmp/acme')`, wb)
	require.NoError(t, err)
	require.NoError(t, goose.Up(d.DB, "migrations"))

	var n int
	var id, at string
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM terminal_session_agent_sessions`).Scan(&n))
	assert.Equal(t, 1, n)
	require.NoError(t, d.QueryRow(`SELECT agent_session_id, first_seen_at FROM terminal_session_agent_sessions`).Scan(&id, &at))
	assert.Equal(t, "s-old", id)
	assert.Equal(t, "2026-10-01T10:00:00Z", at)
}
