package agentlogdb

import (
	"path/filepath"
	"testing"
	"testing/fstest"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
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
		Events: []AgentLogEvent{{SessionUUID: "cx-1", Key: "api_call:codex:1.0.1.0.2/1.0.1.0.2", Kind: "api_call",
			TS: "2026-11-01T10:00:30Z", SrcPath: "/c/rollout-a.jsonl"}},
	})
	require.NoError(t, err)
	require.True(t, applied)
	model, cwd, err := d.CodexResumeState("cx-1")
	require.NoError(t, err)
	assert.Equal(t, "gpt-test", model)
	assert.Equal(t, "/w", cwd)
	model, cwd, err = d.CodexResumeState("absent")
	require.NoError(t, err)
	assert.Empty(t, model)
	assert.Empty(t, cwd)
	_, err = d.Exec(`DELETE FROM agent_log_sessions WHERE session_uuid = 'cx-1'`)
	require.NoError(t, err)
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM agent_log_events`).Scan(&n))
	assert.Zero(t, n, "the cascade from sessions to events survives the rebuild")
}

// Migration 00003 on a populated version-2 file: every row and child row
// stays, foreign keys check clean, the cascade and the totals view still work.
func TestMigration00003_UpgradeKeepsRowsAndCascade(t *testing.T) {
	path := filepath.Join(t.TempDir(), "agentlog.db")
	v2 := fstest.MapFS{}
	for _, name := range []string{"00001_init.sql", "00002_v2_facts.sql"} {
		b, err := migrationsFS.ReadFile("migrations/" + name)
		require.NoError(t, err)
		v2[name] = &fstest.MapFile{Data: b}
	}
	raw, err := db.OpenSidecar(path, v2)
	require.NoError(t, err)
	old := &DB{raw}
	pid := int64(7)
	_, err = old.ApplyAgentLogBatch(AgentLogBatch{
		File: AgentLogFile{Path: "/t/s1.jsonl", Agent: "claude", ReadOffset: 10, ParserVersion: 4}, ExpectOffset: -1,
		Sessions: []AgentLogSession{{SessionUUID: "s1", Agent: "claude", ProjectID: &pid, FolderPath: "/w", HomeCWD: "/w",
			SourcePath: "/t/s1.jsonl", StartedAt: "2026-11-01T10:00:00Z", EndedAt: "2026-11-01T10:01:00Z", Model: "m"}},
		Events: []AgentLogEvent{{SessionUUID: "s1", Key: "m1:r1", Kind: "api_call", TS: "2026-11-01T10:00:30Z",
			OutputTokens: 5, SrcPath: "/t/s1.jsonl"}},
		ContextParts: []AgentContextPart{{SessionUUID: "s1", Part: "system", Bytes: 100}},
		SkillListing: []AgentSkillListed{{SessionUUID: "s1", Skill: "x", Bytes: 10}},
		Subagents:    []AgentSubagent{{SessionUUID: "s1", AgentID: "a1", AgentType: "general-purpose", Depth: 1}},
	})
	require.NoError(t, err)
	require.NoError(t, old.Close())

	d, err := Open(path)
	require.NoError(t, err)
	t.Cleanup(func() { _ = d.Close() })
	count := func(table string) int {
		t.Helper()
		var n int
		require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM `+table).Scan(&n))
		return n
	}
	children := []string{"agent_log_events", "agent_log_context_parts", "agent_log_skill_listing", "agent_log_subagents"}
	for _, table := range append([]string{"agent_log_files", "agent_log_sessions"}, children...) {
		assert.Equal(t, 1, count(table), table)
	}
	var out int64
	require.NoError(t, d.QueryRow(`SELECT output_tokens FROM agent_log_session_totals WHERE session_uuid = 's1'`).Scan(&out))
	assert.Equal(t, int64(5), out)
	var dangling int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM pragma_foreign_key_check`).Scan(&dangling))
	assert.Zero(t, dangling, "no dangling child row")
	_, err = d.Exec(`DELETE FROM agent_log_sessions WHERE session_uuid = 's1'`)
	require.NoError(t, err)
	for _, table := range children {
		assert.Zero(t, count(table), "%s cascades from the rebuilt sessions table", table)
	}
}
