package cmd

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
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
	actionsFlagForce = false
	return out.String(), err
}

func TestActions_ApproveExecutesCreateTarget(t *testing.T) {
	database := writeActionsConfig(t)
	id, err := database.InsertAgentAction(db.AgentAction{Tool: "create_target",
		ArgsJSON: `{"text":"Call Vasya","reason":"r","due":"2026-09-05T16:00"}`, Reason: "r", Surface: "main"})
	require.NoError(t, err)

	out, err := runActions(t, "approve", strconv.FormatInt(id, 10), "--json")
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
}

// blockExecutingClaim makes Apply's claim UPDATE fail, which is the only way
// to reach "the decision persisted but Apply errored" from the CLI.
func blockExecutingClaim(t *testing.T, database *db.DB) {
	t.Helper()
	_, err := database.Exec(`CREATE TRIGGER block_executing BEFORE UPDATE OF status ON agent_actions
		WHEN NEW.status = 'executing' BEGIN SELECT RAISE(ABORT, 'claim blocked'); END`)
	require.NoError(t, err)
}

// Spec §8: exit 0 whenever the status change persisted, exit 1 only when
// nothing did. An approve whose Apply then errors HAS persisted — reporting a
// failed process for it would tell the Desktop the approval never happened.
func TestActions_ApproveEnvelopeSurvivesAnApplyError(t *testing.T) {
	database := writeActionsConfig(t)
	id, err := database.InsertAgentAction(db.AgentAction{Tool: "create_target",
		ArgsJSON: `{"text":"x","reason":"r"}`, Reason: "r"})
	require.NoError(t, err)
	blockExecutingClaim(t, database)

	out, err := runActions(t, "approve", strconv.FormatInt(id, 10), "--json")
	require.NoError(t, err, "the pending → approved flip committed → exit 0")
	assert.Contains(t, out, `"applied_ok": false`)
	assert.Contains(t, out, `"status": "approved"`)
	assert.Contains(t, out, "claim blocked")

	// The bare `apply` path persists nothing of its own, so its failure IS the
	// outcome and must exit non-zero.
	_, err = runActions(t, "apply", strconv.FormatInt(id, 10), "--json")
	assert.Error(t, err)
}

// A row stranded in `executing` by an apply whose process died is refused, so
// an external write is never re-sent on a guess; --force reclaims it.
func TestActions_ApplyForceReclaimsAnInterruptedApply(t *testing.T) {
	database := writeActionsConfig(t)
	id, err := database.InsertAgentAction(db.AgentAction{Tool: "create_target",
		ArgsJSON: `{"text":"Call Vasya","reason":"r"}`, Reason: "r", Status: "executing"})
	require.NoError(t, err)

	_, err = runActions(t, "apply", strconv.FormatInt(id, 10), "--json")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "--force")

	out, err := runActions(t, "apply", strconv.FormatInt(id, 10), "--force", "--json")
	require.NoError(t, err)
	assert.Contains(t, out, `"applied_ok": true`)
	assert.Contains(t, out, `"status": "applied"`)

	targets, err := database.GetTargets(db.TargetFilter{})
	require.NoError(t, err)
	require.Len(t, targets, 1)
}

// Spec §5 promises the CLI warns as the card does before an external retry.
func TestActions_ApplyWarnsBeforeRetryingAnExternalAction(t *testing.T) {
	database := writeActionsConfig(t)
	id, err := database.InsertAgentAction(db.AgentAction{Tool: "create_jira_issue", External: true,
		ArgsJSON: `{"project_key":"ABC","issue_type":"Task","summary":"s","reason":"r"}`,
		Status:   "failed", Error: "boom"})
	require.NoError(t, err)

	out, err := runActions(t, "apply", strconv.FormatInt(id, 10), "--json")
	require.NoError(t, err)
	assert.Contains(t, out, `"warning"`)
	assert.Contains(t, out, "check Jira for a duplicate")

	// The retry failed the same way (no Jira account), so the row is `failed`
	// again — and the human face carries the same warning.
	out, err = runActions(t, "apply", strconv.FormatInt(id, 10))
	require.NoError(t, err)
	assert.Contains(t, out, "check Jira for a duplicate")

	// A local action's retry says nothing of the sort.
	localID, err := database.InsertAgentAction(db.AgentAction{Tool: "create_target",
		ArgsJSON: `{"text":"x","reason":"r"}`, Status: "failed"})
	require.NoError(t, err)
	out, err = runActions(t, "apply", strconv.FormatInt(localID, 10), "--json")
	require.NoError(t, err)
	assert.NotContains(t, out, "check Jira")
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
