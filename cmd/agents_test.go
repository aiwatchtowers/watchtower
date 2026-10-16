package cmd

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/agentlog"
)

func runAgentsCmd(t *testing.T, args ...string) string {
	t.Helper()
	t.Cleanup(func() {
		flagAgentsWorkbench, flagAgentsJSON = 0, false
		rootCmd.SetArgs(nil)
	})
	var out, errOut bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&errOut)
	rootCmd.SetArgs(append([]string{"agents"}, args...))
	require.NoError(t, rootCmd.Execute(), errOut.String())
	return out.String()
}

func agentsFixture(t *testing.T) (wb int64) {
	t.Helper()
	database := writeActionsConfig(t)
	folder, _ := filepath.EvalSymlinks(t.TempDir())
	wb, err := database.CreateWorkbench("app", folder)
	require.NoError(t, err)
	claude := t.TempDir()
	prev := agentsClaudeDir
	agentsClaudeDir = func() string { return claude }
	t.Cleanup(func() { agentsClaudeDir = prev })
	dir := filepath.Join(claude, "projects", agentlog.Slug(folder))
	require.NoError(t, os.MkdirAll(dir, 0o755))
	rec := `{"type":"assistant","sessionId":"s1","uuid":"u1","timestamp":"2026-10-01T10:00:00Z","cwd":"` + folder +
		`","requestId":"r1","message":{"id":"m1","model":"claude-opus-5-5","role":"assistant","content":[],"usage":{"input_tokens":10,"output_tokens":5}}}` + "\n"
	require.NoError(t, os.WriteFile(filepath.Join(dir, "s1.jsonl"), []byte(rec), 0o600))
	return wb
}

func TestAgentsEnable_BackfillsAtOnce(t *testing.T) {
	wb := agentsFixture(t)
	out := runAgentsCmd(t, "enable", "--workbench", strconv.FormatInt(wb, 10), "--json")
	var r map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &r))
	assert.EqualValues(t, 1, r["sessions"])
}

func TestAgentsStatsJSON_PinnedKeys(t *testing.T) {
	wb := agentsFixture(t)
	runAgentsCmd(t, "enable", "--workbench", strconv.FormatInt(wb, 10))
	out := runAgentsCmd(t, "stats", "--workbench", strconv.FormatInt(wb, 10), "--json")
	var m map[string]json.RawMessage
	require.NoError(t, json.Unmarshal([]byte(out), &m))
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	assert.Equal(t, []string{"cost_estimated_calls", "cost_usd", "enabled", "outcomes", "owner_turns", "per_session",
		"reported_cost_usd", "sessions", "skills", "tokens", "tools", "workbench_id"}, keys)
}

func TestAgentsScan_RefusesWhenDisabled(t *testing.T) {
	wb := agentsFixture(t)
	rootCmd.SetArgs([]string{"agents", "scan", "--workbench", strconv.FormatInt(wb, 10)})
	t.Cleanup(func() { flagAgentsWorkbench = 0; rootCmd.SetArgs(nil) })
	assert.ErrorContains(t, rootCmd.Execute(), "analytics is off")
}

func TestAgentsDisable_KeepsRows(t *testing.T) {
	wb := agentsFixture(t)
	id := strconv.FormatInt(wb, 10)
	runAgentsCmd(t, "enable", "--workbench", id)
	runAgentsCmd(t, "disable", "--workbench", id)
	out := runAgentsCmd(t, "stats", "--workbench", id, "--json")
	assert.Contains(t, out, `"sessions": 1`)
	assert.Contains(t, out, `"enabled": false`)
}
