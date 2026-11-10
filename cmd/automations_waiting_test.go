package cmd

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/automations"
	"watchtower/internal/automations/builtin"
	"watchtower/internal/db"
)

// The preview (draft_automation's evaluation) of the shipped Waiting for me
// calls its read primitive: the dry run succeeds with one tool step.
func TestAutomationsCLI_PreviewShippedWaitingForMe(t *testing.T) {
	newAutoCLI(t)
	e, ok := builtin.Lookup("waiting-for-me")
	require.True(t, ok)
	out, err := runAutomationsWithStdin(t, string(e.Recipe), "preview", "--stdin", "--json", "--builtin", e.ID)
	require.NoError(t, err, out)
	var res struct {
		DryRun struct {
			Status, Error string
			Steps         []struct{ Kind, Name, Status string } `json:"steps"`
		} `json:"dry_run"`
	}
	require.NoError(t, json.Unmarshal([]byte(out), &res), out)
	assert.Equal(t, db.RunSucceeded, res.DryRun.Status, res.DryRun.Error)
	require.NotEmpty(t, res.DryRun.Steps)
	assert.Equal(t, "tool", res.DryRun.Steps[0].Kind)
	assert.Equal(t, automations.PrimitiveAttentionWaiting, res.DryRun.Steps[0].Name)
	assert.Equal(t, "ok", res.DryRun.Steps[0].Status)
}

// `automations dry-run` of the shipped Waiting for me succeeds with one tool
// step for its read.
func TestAutomationsCLI_DryRunShippedWaitingForMe(t *testing.T) {
	c := newAutoCLI(t)
	cfg, err := loadAutomationsConfig()
	require.NoError(t, err)
	a, err := builtin.SyncOne(context.Background(), c.d, cfg.WorkspaceDir(), cfg, "waiting-for-me", time.Now())
	require.NoError(t, err)
	out, err := runAutomations(t, "dry-run", idArg(a.ID), "--json")
	require.NoError(t, err, out)
	var res dryRunJSON
	require.NoError(t, json.Unmarshal([]byte(out), &res), out)
	assert.Equal(t, db.RunSucceeded, res.Status, res.Error)
	steps, err := c.d.ListAutomationRunSteps(res.RunID)
	require.NoError(t, err)
	var tools int
	for _, s := range steps {
		if s.Kind == "tool" && s.Name == automations.PrimitiveAttentionWaiting {
			tools++
		}
	}
	assert.Equal(t, 1, tools, "steps = %+v", steps)
}
