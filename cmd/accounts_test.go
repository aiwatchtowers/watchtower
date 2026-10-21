package cmd

import (
	"bytes"
	"encoding/json"
	"os"
	"sort"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func runAccountsPurgesCmd(t *testing.T, args ...string) string {
	t.Helper()
	t.Cleanup(func() {
		flagAccountsPurgesJSON = false
		rootCmd.SetArgs(nil)
	})
	var out, errOut bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&errOut)
	rootCmd.SetArgs(append([]string{"accounts", "purges"}, args...))
	require.NoError(t, rootCmd.Execute(), errOut.String())
	return out.String()
}

func purgeJSONKeys(m map[string]any) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func TestAccountsPurgesJSONKeys(t *testing.T) {
	database := writeActionsConfig(t)
	f, err := os.OpenFile(flagConfig, os.O_APPEND|os.O_WRONLY, 0o600)
	require.NoError(t, err)
	_, err = f.WriteString("privacy:\n  purge_revoked_data: true\n")
	require.NoError(t, err)
	require.NoError(t, f.Close())
	_, err = database.Exec(`INSERT INTO linear_accounts (id, org_id, label) VALUES (1, 'o1', 'Acme')`)
	require.NoError(t, err)
	_, err = database.ScheduleAccountPurge("linear", 1, "revoked", "2026-10-24T12:00:00Z")
	require.NoError(t, err)

	var top map[string]any
	require.NoError(t, json.Unmarshal([]byte(runAccountsPurgesCmd(t, "--json")), &top))
	assert.Equal(t, []string{"enabled", "enabled_by", "grace_hours", "lease_days", "purges"}, purgeJSONKeys(top))
	assert.Equal(t, true, top["enabled"])
	assert.Equal(t, "setting", top["enabled_by"])
	assert.EqualValues(t, 72, top["grace_hours"])
	assert.EqualValues(t, 30, top["lease_days"])
	purges, ok := top["purges"].([]any)
	require.True(t, ok)
	require.Len(t, purges, 1)
	row, ok := purges[0].(map[string]any)
	require.True(t, ok)
	assert.Equal(t, []string{"account_id", "account_label", "due_at", "error", "finished_at", "id", "reason",
		"rows_deleted", "scheduled_at", "source", "started_at", "state"}, purgeJSONKeys(row))
	assert.Equal(t, "Acme", row["account_label"])
	assert.Equal(t, "scheduled", row["state"])
	assert.Equal(t, "2026-10-24T12:00:00Z", row["due_at"])
}

func TestAccountsPurgesTextEmpty(t *testing.T) {
	writeActionsConfig(t)
	out := runAccountsPurgesCmd(t)
	assert.Equal(t, "Purge on revoked access: off (default)\nNo purges.\n", out)

	var top map[string]any
	require.NoError(t, json.Unmarshal([]byte(runAccountsPurgesCmd(t, "--json")), &top))
	assert.Equal(t, false, top["enabled"])
	assert.Equal(t, "default", top["enabled_by"])
	assert.Equal(t, []any{}, top["purges"], "an empty ledger is an empty array, not null")
}
