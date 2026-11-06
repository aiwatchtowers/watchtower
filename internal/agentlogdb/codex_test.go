package agentlogdb

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Migration 00003: a codex file and session are accepted; their events keep
// the session cascade.
func TestAgentlog04_CodexRowsAccepted(t *testing.T) {
	d := openTestDB(t)
	pid := int64(1)
	applied, err := d.ApplyAgentLogBatch(AgentLogBatch{
		File: AgentLogFile{Path: "/c/rollout-a.jsonl", Agent: "codex", ReadOffset: 10, ParserVersion: 4}, ExpectOffset: -1,
		Sessions: []AgentLogSession{{SessionUUID: "cx-1", Agent: "codex", ProjectID: &pid, FolderPath: "/w", HomeCWD: "/w",
			SourcePath: "/c/rollout-a.jsonl", StartedAt: "2026-11-01T10:00:00Z", EndedAt: "2026-11-01T10:01:00Z", Model: "gpt-test"}},
		Events: []AgentLogEvent{{SessionUUID: "cx-1", Key: "api_call:codex:2026-11-01T10:00:30Z:1500", Kind: "api_call",
			TS: "2026-11-01T10:00:30Z", SrcPath: "/c/rollout-a.jsonl"}},
	})
	require.NoError(t, err)
	require.True(t, applied)
	model, total, err := d.CodexResumeState("cx-1")
	require.NoError(t, err)
	assert.Equal(t, "gpt-test", model)
	assert.Equal(t, int64(1500), total)
	model, total, err = d.CodexResumeState("absent")
	require.NoError(t, err)
	assert.Empty(t, model)
	assert.Zero(t, total)
	_, err = d.Exec(`DELETE FROM agent_log_sessions WHERE session_uuid = 'cx-1'`)
	require.NoError(t, err)
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM agent_log_events`).Scan(&n))
	assert.Zero(t, n, "the cascade from sessions to events survives the rebuild")
}
