package cmd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/spf13/cobra"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func setupSlackLiveCLI(t *testing.T, scenario string) (configPath string) {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	configPath = writeLegacyConfig(t, "xoxp-test")
	stub, err := filepath.Abs(filepath.Join("..", "internal", "slacklive", "testdata", "fake_claude.sh"))
	require.NoError(t, err)
	origBin, origEnv := slackLiveBinary, slackLiveEnv
	slackLiveBinary = func(*slackLiveWiring) string { return stub }
	slackLiveEnv = func(*slackLiveWiring) []string { return append(os.Environ(), "SCENARIO="+scenario) }
	t.Cleanup(func() { slackLiveBinary, slackLiveEnv = origBin, origEnv })
	return configPath
}

func TestSlackLiveProbe_JSONKeysPinnedAndIfOlderSkips(t *testing.T) {
	configPath := setupSlackLiveCLI(t, "ok")
	cmds := []*cobra.Command{slackLiveProbeCmd}
	stdout, _, err := runRootCmd(t, cmds, "slack", "live", "probe", "--provider", "claude", "--json")
	require.NoError(t, err)
	var raw map[string]any
	require.NoError(t, json.Unmarshal([]byte(stdout), &raw))
	keys := make([]string, 0, len(raw))
	for k := range raw {
		keys = append(keys, k)
	}
	assert.ElementsMatch(t, []string{"provider", "status", "teams", "error_class", "connector_id", "checked_at", "skipped"}, keys)
	assert.Equal(t, "ok", raw["status"])
	assert.Equal(t, false, raw["skipped"])

	// The stub would now report no connector; a fresh verdict must be reused.
	// runRootCmd resets a --config an earlier test's run left set back to
	// its default: point this run at the test's config again.
	flagConfig = configPath
	slackLiveEnv = func(*slackLiveWiring) []string { return append(os.Environ(), "SCENARIO=absent") }
	stdout, _, err = runRootCmd(t, cmds, "slack", "live", "probe", "--provider", "claude", "--json", "--if-older", "10m")
	require.NoError(t, err)
	require.NoError(t, json.Unmarshal([]byte(stdout), &raw))
	assert.Equal(t, true, raw["skipped"])
	assert.Equal(t, "ok", raw["status"])
}

func TestSlackLiveProbe_FreshSlackLiveAge(t *testing.T) {
	now := time.Now()
	rows := []db.SlackLiveStatus{{TeamID: "", Provider: "claude", Status: "ok", CheckedAt: now.Add(-time.Hour)}}
	_, ok := freshSlackLive(rows, "claude", now, 30*time.Minute)
	assert.False(t, ok)
	got, ok := freshSlackLive(rows, "claude", now, 2*time.Hour)
	assert.True(t, ok)
	assert.True(t, got.Skipped)
	_, ok = freshSlackLive(rows, "codex", now, 2*time.Hour)
	assert.False(t, ok)
}

func TestSlackLiveProbe_RefusesAProviderWithoutAConnector(t *testing.T) {
	setupSlackLiveCLI(t, "ok")
	_, _, err := runRootCmd(t, []*cobra.Command{slackLiveProbeCmd}, "slack", "live", "probe", "--provider", "ollama")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "--provider must be one of claude, codex")
}
