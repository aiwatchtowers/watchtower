package cmd

import (
	"bytes"
	"encoding/json"
	"sort"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func runBackfillCmd(t *testing.T, args ...string) string {
	t.Helper()
	t.Cleanup(func() {
		flagBackfillJSON = false
		rootCmd.SetArgs(nil)
	})
	var out, errOut bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&errOut)
	rootCmd.SetArgs(append([]string{"backfill", "status"}, args...))
	require.NoError(t, rootCmd.Execute(), errOut.String())
	return out.String()
}

func TestBackfillStatusJSON_PinnedKeysAndDays(t *testing.T) {
	database := writeActionsConfig(t)
	now := time.Date(2026, 10, 15, 8, 0, 0, 0, time.UTC)
	upper := float64(now.Unix())
	floor := upper - 30*86400
	started, err := database.StartHistoryBackfill("slack", 1, floor, upper, now)
	require.NoError(t, err)
	require.True(t, started)
	rows, err := database.ListHistoryBackfills()
	require.NoError(t, err)
	require.NoError(t, database.AdvanceHistoryBackfill(rows[0].ID, upper-12*86400, now))

	out := runBackfillCmd(t, "--json")
	var top map[string][]map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &top))
	require.Len(t, top["backfills"], 1)
	row := top["backfills"][0]
	keys := make([]string, 0, len(row))
	for k := range row {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	assert.Equal(t, []string{"account_id", "days_done", "days_total", "done_at", "last_error", "source", "started_at", "status", "waiting"}, keys)
	assert.Equal(t, "slack", row["source"])
	assert.EqualValues(t, 1, row["account_id"])
	assert.EqualValues(t, 30, row["days_total"])
	assert.EqualValues(t, 12, row["days_done"])
	assert.Nil(t, row["done_at"])
	assert.Equal(t, "2026-10-15T08:00:00Z", row["started_at"])
}

func TestBackfillStatusText(t *testing.T) {
	database := writeActionsConfig(t)
	assert.Contains(t, runBackfillCmd(t), "No history backfill.")

	now := time.Date(2026, 10, 15, 8, 0, 0, 0, time.UTC)
	upper := float64(now.Unix())
	_, err := database.StartHistoryBackfill("slack", 1, upper-30*86400, upper, now)
	require.NoError(t, err)
	rows, err := database.ListHistoryBackfills()
	require.NoError(t, err)
	require.NoError(t, database.AdvanceHistoryBackfill(rows[0].ID, upper-12*86400, now))
	assert.Equal(t, "slack #1  running  12/30 days\n", runBackfillCmd(t))

	require.NoError(t, database.SetHistoryBackfillWaiting(rows[0].ID, "plan_limit", now))
	_, err = database.RecordHistoryBackfillFailure(rows[0].ID, "boom", now)
	require.NoError(t, err)
	assert.Equal(t, "slack #1  running  12/30 days  (waiting: plan_limit)  — boom\n", runBackfillCmd(t))

	// R29: a jira row is listed like any other kind.
	_, err = database.StartHistoryBackfill("jira", 2, upper-30*86400, upper, now)
	require.NoError(t, err)
	assert.Contains(t, runBackfillCmd(t), "jira #2  running  0/30 days\n")
}

// #580: a row held by a transient failure reads waiting = held, with the
// reason in last_error.
func TestBackfillStatus_HeldRow(t *testing.T) {
	database := writeActionsConfig(t)
	now := time.Date(2026, 10, 15, 8, 0, 0, 0, time.UTC)
	upper := float64(now.Unix())
	_, err := database.StartHistoryBackfill("imap", 1, upper-30*86400, upper, now)
	require.NoError(t, err)
	rows, err := database.ListHistoryBackfills()
	require.NoError(t, err)
	require.NoError(t, database.HoldHistoryBackfill(rows[0].ID, "held: fetch: offline", now))
	assert.Equal(t, "imap #1  running  0/30 days  (waiting: held)  — held: fetch: offline\n", runBackfillCmd(t))

	var top map[string][]map[string]any
	require.NoError(t, json.Unmarshal([]byte(runBackfillCmd(t, "--json")), &top))
	assert.Equal(t, "held", top["backfills"][0]["waiting"])
}
