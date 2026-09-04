package cmd

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// writeActionsConfig points flagConfig at a temp workspace whose DB path
// lives under a temp HOME (the writeFeaturesConfig precedent).
func writeActionsConfig(t *testing.T) *db.DB {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	tmpDir := t.TempDir()
	configPath := filepath.Join(tmpDir, "config.yaml")
	require.NoError(t, os.WriteFile(configPath, []byte("active_workspace: test\n"), 0o600))
	original := flagConfig
	flagConfig = configPath
	t.Cleanup(func() { flagConfig = original })
	database, err := openDBFromConfig()
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	return database
}

func runActions(t *testing.T, args ...string) (string, error) {
	t.Helper()
	var out bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&out)
	rootCmd.SetArgs(append([]string{"actions"}, args...))
	err := rootCmd.Execute()
	rootCmd.SetArgs(nil)
	actionsFlagJSON = false
	actionsFlagStatus = ""
	actionsFlagConversation = 0
	actionsFlagSurface = ""
	return out.String(), err
}

func TestActions_ApproveExecutesCreateTarget(t *testing.T) {
	database := writeActionsConfig(t)
	id, err := database.InsertAgentAction(db.AgentAction{Tool: "create_target",
		ArgsJSON: `{"text":"Call Vasya","reason":"r","due":"2026-09-05T16:00"}`, Reason: "r", Surface: "main"})
	require.NoError(t, err)

	out, err := runActions(t, "approve", "1", "--json")
	require.NoError(t, err)
	var env struct {
		OK        bool `json:"ok"`
		AppliedOK bool `json:"applied_ok"`
		Action    struct {
			Status string          `json:"status"`
			Result json.RawMessage `json:"result"`
		} `json:"action"`
	}
	require.NoError(t, json.Unmarshal([]byte(out), &env), out)
	assert.True(t, env.OK)
	assert.True(t, env.AppliedOK)
	assert.Equal(t, "applied", env.Action.Status)
	assert.Contains(t, string(env.Action.Result), "target_id")

	targets, err := database.GetTargets(db.TargetFilter{})
	require.NoError(t, err)
	require.Len(t, targets, 1)
	assert.Equal(t, "Call Vasya", targets[0].Text)
	_ = id
}

func TestActions_RejectAndTerminalStates(t *testing.T) {
	database := writeActionsConfig(t)
	_, err := database.InsertAgentAction(db.AgentAction{Tool: "create_target", ArgsJSON: `{"text":"x","reason":"r"}`})
	require.NoError(t, err)

	out, err := runActions(t, "reject", "1", "--json")
	require.NoError(t, err)
	assert.Contains(t, out, `"status": "rejected"`)

	// AGENT-05: rejected is terminal — approve and apply both refuse.
	_, err = runActions(t, "approve", "1", "--json")
	assert.Error(t, err)
	_, err = runActions(t, "apply", "1", "--json")
	assert.Error(t, err)
}

func TestActions_ApproveWithFailingToolExitsZeroWithAppliedFalse(t *testing.T) {
	database := writeActionsConfig(t)
	// No Jira account connected → Execute fails at ResolveJiraAccount.
	_, err := database.InsertAgentAction(db.AgentAction{Tool: "create_jira_issue", External: true,
		ArgsJSON: `{"project_key":"ABC","issue_type":"Task","summary":"s","reason":"r"}`})
	require.NoError(t, err)

	out, err := runActions(t, "approve", "1", "--json")
	require.NoError(t, err, "status change persisted → exit 0 (the recap_ok precedent)")
	assert.Contains(t, out, `"applied_ok": false`)
	assert.Contains(t, out, `"status": "failed"`)

	// Retry from failed is allowed (and fails again the same way).
	out, err = runActions(t, "apply", "1", "--json")
	require.NoError(t, err)
	assert.Contains(t, out, `"status": "failed"`)
}

func TestActions_TrustAndTools(t *testing.T) {
	writeActionsConfig(t)
	_, err := runActions(t, "trust", "create_jira_issue", "execute")
	assert.Error(t, err, "AGENT-03: external tools can never execute without approval")

	_, err = runActions(t, "trust", "create_target", "execute")
	require.NoError(t, err)

	out, err := runActions(t, "tools", "--json")
	require.NoError(t, err)
	var listed []struct {
		Name     string   `json:"name"`
		External bool     `json:"external"`
		Trust    string   `json:"trust"`
		Surfaces []string `json:"surfaces"`
	}
	require.NoError(t, json.Unmarshal([]byte(out), &listed), out)
	byName := map[string]int{}
	for i, l := range listed {
		byName[l.Name] = i
	}
	assert.Equal(t, "execute", listed[byName["create_target"]].Trust)
	assert.True(t, listed[byName["create_jira_issue"]].External)
	assert.Equal(t, "ask", listed[byName["create_jira_issue"]].Trust)
	assert.ElementsMatch(t, []string{"main", "target"}, listed[byName["create_jira_issue"]].Surfaces)

	out, err = runActions(t, "tools", "--surface", "target", "--json")
	require.NoError(t, err)
	assert.NotContains(t, out, `"create_target"`)
}

func TestActions_ListAndShow(t *testing.T) {
	database := writeActionsConfig(t)
	_, _ = database.InsertAgentAction(db.AgentAction{Tool: "create_target", ArgsJSON: `{"text":"a","reason":"r"}`, ConversationID: 5})
	_, _ = database.InsertAgentAction(db.AgentAction{Tool: "create_target", ArgsJSON: `{"text":"b","reason":"r"}`, ConversationID: 6})

	out, err := runActions(t, "list", "--conversation", "5", "--json")
	require.NoError(t, err)
	assert.Contains(t, out, `"text": "a"`)
	assert.NotContains(t, out, `"text": "b"`)

	out, err = runActions(t, "show", "2", "--json")
	require.NoError(t, err)
	assert.Contains(t, out, `"conversation_id": 6`)

	_, err = runActions(t, "show", "99", "--json")
	assert.Error(t, err)
}
