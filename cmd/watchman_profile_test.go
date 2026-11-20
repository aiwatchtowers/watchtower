package cmd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func runWatchmanProfileCmd(t *testing.T, args ...string) (string, error) {
	t.Helper()
	reset := func() {
		watchmanProfileFlagWorkbench, watchmanProfileFlagJSON = 0, false
		watchmanProfileFlagKey, watchmanProfileFlagTextFile = "", ""
	}
	t.Cleanup(reset)
	out, err := runWatchman(t, append([]string{"profile"}, args...)...)
	reset()
	return out, err
}

func writeProfileFile(t *testing.T, text string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "profile.txt")
	require.NoError(t, os.WriteFile(path, []byte(text), 0o600))
	return path
}

func TestWatchmanProfile_JSONKeysPinned(t *testing.T) {
	wb, _ := watchmanFixture(t)
	var path string
	d := openAgentsTestMain(t, &path)
	_, err := d.SaveLearnedWatchmanProfile(wb, "design", "Prefers small steps", time.Date(2026, 11, 9, 3, 0, 0, 0, time.UTC))
	require.NoError(t, err)
	_, err = d.SaveLearnedWatchmanProfile(wb, "sleep_window", "00:30-07:45", time.Date(2026, 11, 9, 3, 0, 0, 0, time.UTC))
	require.NoError(t, err)

	id := strconv.FormatInt(wb, 10)
	out, err := runWatchmanProfileCmd(t, "--workbench", id, "--json")
	require.NoError(t, err)
	assert.Equal(t, []string{"ok", "profiles", "sleep_window", "workbench"}, jsonKeys(t, out))
	var raw struct {
		Profiles []map[string]any `json:"profiles"`
	}
	require.NoError(t, json.Unmarshal([]byte(out), &raw))
	require.Len(t, raw.Profiles, 2)
	keys := make([]string, 0, len(raw.Profiles[0]))
	for k := range raw.Profiles[0] {
		keys = append(keys, k)
	}
	assert.ElementsMatch(t, []string{"key", "text", "pinned", "version", "updated_at"}, keys)
	var r watchmanProfileJSON
	require.NoError(t, json.Unmarshal([]byte(out), &r))
	assert.Equal(t, watchmanProfileJSON{OK: true, Workbench: wb, SleepWindow: "00:30-07:45", Profiles: []watchmanProfileEntryJSON{
		{Key: "design", Text: "Prefers small steps", Version: 1, UpdatedAt: "2026-11-09T03:00:00Z"},
		{Key: "sleep_window", Text: "00:30-07:45", Version: 1, UpdatedAt: "2026-11-09T03:00:00Z"},
	}}, r)

	// set pins (version bumped), unpin keeps the text.
	_, err = runWatchmanProfileCmd(t, "set", "--workbench", id, "--key", "design", "--text-file", writeProfileFile(t, "Mine\n\nAlso mine\n"))
	require.NoError(t, err)
	_, err = runWatchmanProfileCmd(t, "set", "--workbench", id, "--key", "sleep_window", "--text-file", writeProfileFile(t, "23:00-07:00\n"))
	require.NoError(t, err)
	out, err = runWatchmanProfileCmd(t, "--workbench", id, "--json")
	require.NoError(t, err)
	require.NoError(t, json.Unmarshal([]byte(out), &r))
	assert.Equal(t, "23:00-07:00", r.SleepWindow)
	assert.Equal(t, "Mine\nAlso mine", r.Profiles[0].Text)
	assert.True(t, r.Profiles[0].Pinned)
	assert.Equal(t, 2, r.Profiles[0].Version)

	_, err = runWatchmanProfileCmd(t, "unpin", "--workbench", id, "--key", "design")
	require.NoError(t, err)
	out, err = runWatchmanProfileCmd(t, "--workbench", id, "--json")
	require.NoError(t, err)
	require.NoError(t, json.Unmarshal([]byte(out), &r))
	assert.False(t, r.Profiles[0].Pinned)
	assert.Equal(t, "Mine\nAlso mine", r.Profiles[0].Text)
}

func TestWatchmanProfile_EmptyJSON(t *testing.T) {
	wb, _ := watchmanFixture(t)
	out, err := runWatchmanProfileCmd(t, "--workbench", strconv.FormatInt(wb, 10), "--json")
	require.NoError(t, err)
	assert.JSONEq(t, `{"ok":true,"workbench":`+strconv.FormatInt(wb, 10)+`,"profiles":[],"sleep_window":""}`, out)
}

func TestWatchmanProfileSet_Validates(t *testing.T) {
	wb, _ := watchmanFixture(t)
	id := strconv.FormatInt(wb, 10)
	for _, c := range []struct{ key, text string }{
		{"nope", "x"},
		{"sleep_window", "late"},
		{"design", "  \n"},
		{"design", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n21\n"},
	} {
		_, err := runWatchmanProfileCmd(t, "set", "--workbench", id, "--key", c.key, "--text-file", writeProfileFile(t, c.text))
		assert.Error(t, err, c.key)
	}
	_, err := runWatchmanProfileCmd(t, "unpin", "--workbench", id, "--key", "design")
	assert.Error(t, err, "nothing to unpin")
}

func TestWatchmanProfileSet_RefusedUnderAgent(t *testing.T) {
	wb, _ := watchmanFixture(t)
	id := strconv.FormatInt(wb, 10)
	t.Setenv(agentEnvMarkers[0], "1")
	_, err := runWatchmanProfileCmd(t, "set", "--workbench", id, "--key", "design", "--text-file", writeProfileFile(t, "Mine"))
	require.Error(t, err)
	assert.Contains(t, err.Error(), agentEnvMarkers[0])
	_, err = runWatchmanProfileCmd(t, "unpin", "--workbench", id, "--key", "design")
	require.Error(t, err)
	assert.Contains(t, err.Error(), agentEnvMarkers[0])

	var path string
	d := openAgentsTestMain(t, &path)
	ps, err := d.WatchmanProfiles(wb)
	require.NoError(t, err)
	assert.Empty(t, ps)

	// Showing only reads: it stays open.
	_, err = runWatchmanProfileCmd(t, "--workbench", id)
	require.NoError(t, err)
}
