package cmd

import (
	"encoding/json"
	"strconv"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/watchman"
)

func resetWatchmanLimitsFlags() {
	watchmanLimitsListFlagJSON = false
	watchmanLimitsAddFlagKind, watchmanLimitsAddFlagPat = "", ""
	watchmanLimitsRemoveFlagID = 0
}

func limitsCLI(t *testing.T, args ...string) (string, error) {
	t.Helper()
	t.Cleanup(resetWatchmanLimitsFlags)
	out, err := runWatchman(t, append([]string{"limits"}, args...)...)
	resetWatchmanLimitsFlags()
	return out, err
}

func ownerLimits(t *testing.T) []db.WatchmanExtraLimit {
	t.Helper()
	var path string
	d := openAgentsTestMain(t, &path)
	rows, err := d.WatchmanExtraLimits()
	require.NoError(t, err)
	return rows
}

func TestWatchmanLimits_JSONKeysPinned(t *testing.T) {
	agentsFixture(t)
	_, err := limitsCLI(t, "add", "--kind", "command", "--pattern", "terraform apply")
	require.NoError(t, err)
	out, err := limitsCLI(t, "list", "--json")
	require.NoError(t, err, out)
	assert.Equal(t, []string{"builtin", "ok", "owner"}, jsonKeys(t, out))
	var raw struct {
		OK      bool                         `json:"ok"`
		Builtin []string                     `json:"builtin"`
		Owner   []map[string]json.RawMessage `json:"owner"`
	}
	require.NoError(t, json.Unmarshal([]byte(out), &raw))
	assert.True(t, raw.OK)
	require.Len(t, raw.Builtin, len(watchman.BuiltinLimits()))
	assert.Equal(t, string(watchman.LimitUnreadable), raw.Builtin[0])
	require.Len(t, raw.Owner, 1)
	assert.Equal(t, []string{"id", "kind", "pattern"}, mapKeys(raw.Owner[0]))
	assert.JSONEq(t, `"terraform apply"`, string(raw.Owner[0]["pattern"]))
}

func TestWatchmanLimits_AddListRemove(t *testing.T) {
	agentsFixture(t)
	_, err := limitsCLI(t, "add", "--kind", "tool", "--pattern", "create_jira_issue")
	require.NoError(t, err)
	_, err = limitsCLI(t, "add", "--kind", "tool", "--pattern", "create_jira_issue") // the same again: one row
	require.NoError(t, err)
	rows := ownerLimits(t)
	require.Len(t, rows, 1)
	out, err := limitsCLI(t, "list")
	require.NoError(t, err)
	assert.Contains(t, out, "create_jira_issue")
	assert.Contains(t, out, "main_ref")
	for _, bad := range [][]string{
		{"add", "--kind", "url", "--pattern", "x"},
		{"add", "--kind", "command", "--pattern", "  "},
		{"add", "--kind", "command", "--pattern", `echo "open`},
		{"add", "--kind", "tool", "--pattern", "two words"},
	} {
		_, err := limitsCLI(t, bad...)
		require.Error(t, err, bad)
	}
	_, err = limitsCLI(t, "remove", "--id", strconv.FormatInt(rows[0].ID, 10))
	require.NoError(t, err)
	assert.Empty(t, ownerLimits(t))
}

func TestWatchmanLimits_RemoveUnknownIDFails(t *testing.T) {
	agentsFixture(t)
	_, err := limitsCLI(t, "remove", "--id", "999")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "999")
	_, err = limitsCLI(t, "remove") // a built-in has no id
	require.Error(t, err)
}

func TestWatchmanLimits_RefusedUnderAgent(t *testing.T) {
	agentsFixture(t)
	var path string
	d := openAgentsTestMain(t, &path)
	id, err := d.AddWatchmanExtraLimit("command", "terraform apply")
	require.NoError(t, err)
	t.Setenv(agentEnvMarkers[0], "1")
	for _, args := range [][]string{
		{"add", "--kind", "command", "--pattern", "make deploy"},
		{"remove", "--id", strconv.FormatInt(id, 10)},
	} {
		_, err := limitsCLI(t, args...)
		require.Error(t, err, args)
		assert.Contains(t, err.Error(), agentEnvMarkers[0])
	}
	rows := ownerLimits(t)
	require.Len(t, rows, 1)
	assert.Equal(t, "terraform apply", rows[0].Pattern)
	// list only reads: it stays open under an agent.
	out, err := limitsCLI(t, "list", "--json")
	require.NoError(t, err, out)
}
