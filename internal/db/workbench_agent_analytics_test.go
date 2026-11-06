package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Decision D (ask #507): codex rollouts attach to the workbench's codex rows.
func TestDB_CodexSessionsResolveTerminalIDs(t *testing.T) {
	d := openTestDB(t)
	wb, err := d.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	other, err := d.CreateWorkbench("other", t.TempDir())
	require.NoError(t, err)
	insert := func(project int64, kind string, sid, path any) int64 {
		t.Helper()
		res, err := d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id, agent_transcript_path)
			VALUES (?, ?, 't', '/w', ?, ?)`, project, kind, sid, path)
		require.NoError(t, err)
		id, err := res.LastInsertId()
		require.NoError(t, err)
		return id
	}
	cx := insert(wb, "codex", "cx-1", "/r/rollout-x-cx-1.jsonl")
	cx2 := insert(wb, "codex", "cx-2", nil)
	insert(wb, "codex", "cx-1", nil)  // a second row resuming cx-1: listed once
	insert(wb, "codex", nil, nil)     // never started: no session id
	insert(wb, "claude", "cl-1", nil) // a Claude row
	insert(other, "codex", "cx-9", nil)

	ids, err := d.CodexTerminalSessionIDs([]string{"cx-1", "cl-1", "cx-9", "nope"})
	require.NoError(t, err)
	assert.Equal(t, map[string]int64{"cx-1": cx, "cx-9": ids["cx-9"]}, ids, "a Claude row never resolves as codex")
	assert.NotZero(t, ids["cx-9"])

	rows, err := d.WorkbenchCodexSessions(wb)
	require.NoError(t, err)
	assert.Equal(t, []CodexAnalyticsRow{
		{ID: cx, SessionID: "cx-1", TranscriptPath: "/r/rollout-x-cx-1.jsonl"},
		{ID: cx2, SessionID: "cx-2"},
	}, rows)
}
