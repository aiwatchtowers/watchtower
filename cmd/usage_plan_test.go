package cmd

import (
	"bytes"
	"encoding/json"
	"os"
	"sort"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func runUsagePlanCmd(t *testing.T, args ...string) string {
	t.Helper()
	t.Cleanup(func() {
		flagUsagePlanJSON, flagUsagePlanNow = false, false
		rootCmd.SetArgs(nil)
	})
	var out, errOut bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&errOut)
	rootCmd.SetArgs(append([]string{"usage", "plan"}, args...))
	require.NoError(t, rootCmd.Execute(), errOut.String())
	return out.String()
}

func TestUsagePlanJSON_PinnedKeys(t *testing.T) {
	database := writeActionsConfig(t)
	now := time.Date(2026, 10, 15, 8, 0, 0, 0, time.UTC)
	require.NoError(t, database.UpsertPlanUsageStatus(db.PlanUsageStatus{
		State: "ok", Plan: "max", FetchedAt: &now, UpdatedAt: now,
		LimitsJSON:    `[{"key":"session","label":"5-hour","group":"session","percent":4,"resets_at":"2026-10-15T10:59:59Z","severity":"normal","projection":{"state":"safe","hit_at":null,"rate_per_hour":0}}]`,
		BreakdownJSON: `[{"key":"chat","label":"Chats","percent":10}]`,
	}))
	out := runUsagePlanCmd(t, "--json")
	var m map[string]json.RawMessage
	require.NoError(t, json.Unmarshal([]byte(out), &m))
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	assert.Equal(t, []string{"breakdown", "fetched_at", "last_error", "limits", "plan", "reason", "state"}, keys)
}

func TestUsagePlanText_NoRowYet(t *testing.T) {
	writeActionsConfig(t)
	out := runUsagePlanCmd(t)
	assert.Contains(t, out, "No Claude plan usage yet")
}

func TestUsagePlanNow_RefusesWhenFeatureOff(t *testing.T) {
	database := writeActionsConfig(t)
	require.NoError(t, os.WriteFile(flagConfig, []byte("active_workspace: test\nplan_usage:\n  enabled: false\n"), 0o600))
	at := time.Date(2026, 10, 15, 8, 0, 0, 0, time.UTC)
	require.NoError(t, database.UpsertPlanUsageStatus(db.PlanUsageStatus{
		State: "disabled", Plan: "max", UpdatedAt: at, LimitsJSON: "[]", BreakdownJSON: "[]",
	}))
	t.Cleanup(func() {
		flagUsagePlanJSON, flagUsagePlanNow = false, false
		rootCmd.SetArgs(nil)
	})
	var out, errOut bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&errOut)
	rootCmd.SetArgs([]string{"usage", "plan", "--now"})
	err := rootCmd.Execute()
	require.Error(t, err)
	assert.Contains(t, err.Error(), "turned off")
	st, err := database.GetPlanUsageStatus()
	require.NoError(t, err)
	assert.Equal(t, "disabled", st.State, "the disabled row is left alone")
	assert.Equal(t, at, st.UpdatedAt)
}
