package daemon

import (
	"context"
	"log"
	"os"
	"path/filepath"
	"testing"

	"watchtower/internal/agentlog"
	"watchtower/internal/agentlogdb"
	"watchtower/internal/db"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func newAgentAnalyticsTestDaemon(t *testing.T) (*Daemon, *db.DB) {
	t.Helper()
	orch, cfg, _ := testDaemonWithTempHome(t)
	database := db.OpenTestDB(t)
	d := newDaemon(orch, cfg)
	d.SetLogger(log.New(os.Stderr, "[test-agent-analytics] ", 0))
	d.SetDB(database)
	al, err := agentlogdb.Open(filepath.Join(t.TempDir(), "agentlog.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = al.Close() })
	d.SetAgentLogDB(al)
	return d, database
}

// enableAgentAnalyticsWorkbench binds an analytics-on workbench to a temp
// folder holding one transcript with one api_call.
func enableAgentAnalyticsWorkbench(t *testing.T, database *db.DB) {
	t.Helper()
	folder, _ := filepath.EvalSymlinks(t.TempDir())
	wb, err := database.CreateWorkbench("app", folder)
	require.NoError(t, err)
	require.NoError(t, database.SetWorkbenchAgentAnalytics(wb, true))
	claude := t.TempDir()
	prev := agentAnalyticsClaudeDir
	agentAnalyticsClaudeDir = func() string { return claude }
	t.Cleanup(func() { agentAnalyticsClaudeDir = prev })
	dir := filepath.Join(claude, "projects", agentlog.Slug(folder))
	require.NoError(t, os.MkdirAll(dir, 0o755))
	rec := `{"type":"assistant","sessionId":"s1","uuid":"u1","timestamp":"2026-10-01T10:00:00Z","cwd":"` + folder +
		`","requestId":"r1","message":{"id":"m1","model":"claude-opus-5-5","role":"assistant","content":[],"usage":{"input_tokens":1,"output_tokens":1}}}` + "\n"
	require.NoError(t, os.WriteFile(filepath.Join(dir, "s1.jsonl"), []byte(rec), 0o600))
}

func TestPhaseAgentAnalytics_InertWithoutEnabledWorkbench(t *testing.T) {
	d, database := newAgentAnalyticsTestDaemon(t)
	d.phaseAgentAnalytics(context.Background())
	assert.Equal(t, 0, countPipelineRuns(t, database, "agent-analytics"))
}

func TestPhaseAgentAnalytics_ScansEnabledWorkbench(t *testing.T) {
	d, database := newAgentAnalyticsTestDaemon(t)
	enableAgentAnalyticsWorkbench(t, database)

	d.phaseAgentAnalytics(context.Background())

	var n int
	require.NoError(t, d.agentLog.QueryRow(`SELECT COUNT(*) FROM agent_log_events`).Scan(&n))
	assert.Equal(t, 1, n)
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM agent_log_events`).Scan(&n))
	assert.Zero(t, n, "nothing lands in watchtower.db")
	assert.Equal(t, 1, countPipelineRuns(t, database, "agent-analytics"))
}

// Spec "Error handling": agentlog.db failed to open → the phase skips with
// no pipeline_runs row and never falls back to watchtower.db.
func TestPhaseAgentAnalytics_NilAgentlogSkips(t *testing.T) {
	d, database := newAgentAnalyticsTestDaemon(t)
	d.SetAgentLogDB(nil)
	enableAgentAnalyticsWorkbench(t, database)

	d.phaseAgentAnalytics(context.Background())

	assert.Equal(t, 0, countPipelineRuns(t, database, "agent-analytics"))
	var n int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM agent_log_events`).Scan(&n))
	assert.Zero(t, n)
}
