package automations_test

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/automations"
	"watchtower/internal/db"
	"watchtower/internal/tools"
)

// seedAgentRun is a personal automation's run, claimed (running) unless
// trigger is queued-only; it returns the database and the run id.
func seedAgentRun(t *testing.T, trigger string) (*db.DB, int64) {
	t.Helper()
	d := db.OpenTestDB(t)
	id, err := d.UpsertAutomationIndex(db.Automation{Slug: "agent", Scope: "personal", Path: "/automations/agent.md",
		Name: "Agent", TriggerKind: "manual", Concurrency: 1})
	require.NoError(t, err)
	now := time.Now()
	run, _, err := d.EnqueueAutomationRun(db.EnqueueRequest{AutomationID: id, Trigger: trigger, Now: now})
	require.NoError(t, err)
	ok, err := d.ClaimAutomationRun(run, "h", "", 1000, 5, now)
	require.NoError(t, err)
	require.True(t, ok)
	return d, run
}

func agentManifest(t *testing.T, outputs []string, entries ...string) *automations.Manifest {
	t.Helper()
	m, err := automations.ParseManifest(entries, outputs, automations.Scope{Kind: automations.ScopePersonal})
	require.NoError(t, err)
	return m
}

func TestGateAgentCall_ManifestDecidesEachCall(t *testing.T) {
	d, run := seedAgentRun(t, db.TriggerManual)
	ctx := context.Background()
	list := tools.NewListJiraIssues()
	create := tools.NewCreateTarget()
	m := agentManifest(t, []string{"target"}, "jira:read@PAY")

	args, err := automations.GateAgentCall(ctx, d, m, run, list, json.RawMessage(`{"project":"PAY"}`))
	require.NoError(t, err)
	assert.JSONEq(t, fmt.Sprintf(`{"project":"PAY","limit":%d}`, automations.DefaultListLimit), string(args), "the list limit is injected")

	_, err = automations.GateAgentCall(ctx, d, m, run, list, json.RawMessage(`{"project":"OPS"}`))
	require.Error(t, err)
	assert.Equal(t, "PermissionDenied: needs jira:read@OPS", err.Error())

	_, err = automations.GateAgentCall(ctx, d, m, run, create, json.RawMessage(`{"text":"x"}`))
	require.NoError(t, err, "outputs:[target] admits create_target, as EffectiveAgentTools offers it")

	_, err = automations.GateAgentCall(ctx, d, agentManifest(t, nil, "jira:read@PAY"), run, create, json.RawMessage(`{"text":"x"}`))
	require.Error(t, err)
	assert.True(t, strings.HasPrefix(err.Error(), "PermissionDenied: needs "), err.Error())
}

func TestGateAgentCall_RefusesAnEndedRun(t *testing.T) {
	d, run := seedAgentRun(t, db.TriggerManual)
	ctx := context.Background()
	m := agentManifest(t, nil, "jira:read@PAY")
	list := tools.NewListJiraIssues()
	require.NoError(t, d.FinishAutomationRun(run, db.RunFinish{Status: db.RunSucceeded, Now: time.Now()}, nil))

	_, err := automations.GateAgentCall(ctx, d, m, run, list, json.RawMessage(`{"project":"PAY"}`))
	require.EqualError(t, err, "the automation run has ended")
	_, err = automations.GateAgentCall(ctx, d, m, run+100, list, json.RawMessage(`{"project":"PAY"}`))
	require.EqualError(t, err, "the automation run has ended", "a missing run has ended too")
}

func TestGateAgentCall_DryRunRefusesWrites(t *testing.T) {
	d, run := seedAgentRun(t, db.TriggerDryRun)
	_, err := automations.GateAgentCall(context.Background(), d, agentManifest(t, []string{"target"}), run,
		tools.NewCreateTarget(), json.RawMessage(`{"text":"x"}`))
	require.Error(t, err)
	assert.Contains(t, err.Error(), "NotAvailable")
}

func TestCheckAgentResult_RefusesOverLimit(t *testing.T) {
	require.NoError(t, automations.CheckAgentResult(make([]byte, automations.MaxSDKResultBytes)))
	err := automations.CheckAgentResult(make([]byte, automations.MaxSDKResultBytes+1))
	require.Error(t, err)
	assert.True(t, strings.HasPrefix(err.Error(), "ResultTooLarge: "), err.Error())
}
