package db

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestListWorkbenchTerminalSessionsSince(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	ins := func(project any, kind string, sid, transcript any, active string) int64 {
		t.Helper()
		res, err := d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id,
			agent_transcript_path, last_active_at) VALUES (?, ?, 't', '/tmp/acme', ?, ?, ?)`,
			project, kind, sid, transcript, active)
		require.NoError(t, err)
		id, err := res.LastInsertId()
		require.NoError(t, err)
		return id
	}
	recentClaude := ins(wb, "claude", "c-1", nil, "2026-10-10T08:00:00Z")
	recentCodex := ins(wb, "codex", "x-1", "/tmp/acme/rollout.jsonl", "2026-10-03T00:00:00Z")
	ins(wb, "claude", "c-old", nil, "2026-10-02T23:59:59Z")   // before the window
	ins(nil, "claude", "c-free", nil, "2026-10-10T08:00:00Z") // no workbench
	ins(wb, "shell", nil, nil, "2026-10-10T08:00:00Z")        // not an agent
	ins(wb, "codex", nil, nil, "2026-10-10T08:00:00Z")        // codex before its first SessionStart

	got, err := d.ListWorkbenchTerminalSessionsSince(time.Date(2026, 10, 3, 0, 0, 0, 0, time.UTC))
	require.NoError(t, err)
	require.Len(t, got, 3)
	assert.Equal(t, RecentWorkbenchSession{ID: recentClaude, WorkbenchID: wb, Kind: "claude", FolderPath: "/tmp/acme", AgentSessionID: "c-1"}, got[0])
	assert.Equal(t, RecentWorkbenchSession{ID: recentCodex, WorkbenchID: wb, Kind: "codex", FolderPath: "/tmp/acme",
		AgentSessionID: "x-1", TranscriptPath: "/tmp/acme/rollout.jsonl"}, got[1])
	assert.Equal(t, "codex", got[2].Kind)
	assert.Empty(t, got[2].AgentSessionID)
}

func TestListInstructionSuggestionTexts_ByStatus(t *testing.T) {
	d := openTestDB(t)
	now := time.Date(2026, 10, 1, 9, 0, 0, 0, time.UTC)
	a, b := sugg("a"), sugg("b")
	a.Text, b.Text = "keep a", "drop b"
	require.NoError(t, d.UpsertInstructionSuggestion(a, now))
	require.NoError(t, d.UpsertInstructionSuggestion(b, now))
	fps, err := d.ListOpenInstructionSuggestions()
	require.NoError(t, err)
	for _, s := range fps {
		if s.Fingerprint == "b" {
			require.NoError(t, d.DecideInstructionSuggestion(s.ID, "dismissed", now))
		}
	}
	got, err := d.ListInstructionSuggestionTexts("dismissed")
	require.NoError(t, err)
	assert.Equal(t, []string{"drop b"}, got)
}
