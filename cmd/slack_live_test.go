package cmd

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/spf13/cobra"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/chat"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/policy/policytest"
	"watchtower/internal/slacklive"
)

func setupSlackLiveCLI(t *testing.T, scenario string) (configPath string) {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	configPath = writeLegacyConfig(t, "xoxp-test")
	stub, err := filepath.Abs(filepath.Join("..", "internal", "slacklive", "testdata", "fake_claude.sh"))
	require.NoError(t, err)
	standInSandbox(t)
	origBin, origEnv := slackLiveBinary, slackLiveEnv
	slackLiveBinary = func(*slackLiveWiring, *config.Config) string { return stub }
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

// standInSandbox makes aiSessionSandbox a stand-in sandbox-exec that logs
// its argv and runs the CLI after "--" unconfined (the CI is Linux;
// internal/chat tests the real one). It returns the log's path.
func standInSandbox(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	log := filepath.Join(dir, "argv")
	bin := filepath.Join(dir, "sandbox-exec")
	script := "#!/bin/sh\nprintf '%s\\n' \"$@\" >> '" + log + "'\nwhile [ \"$1\" != -- ]; do shift; done\nshift\nexec \"$@\"\n"
	require.NoError(t, os.WriteFile(bin, []byte(script), 0o700))
	home := t.TempDir()
	prev := aiSessionSandbox
	aiSessionSandbox = func() (*chat.ChildSandbox, error) { return chat.NewChildSandboxAt(bin, []string{home}) }
	t.Cleanup(func() { aiSessionSandbox = prev })
	return log
}

// The Claude probe's child runs inside the chat's file sandbox (CHAT-05):
// the stand-in sandbox-exec saw the profile and the CLI after "--".
func TestSlackLiveProbe_ClaudeRunsInTheFileSandbox(t *testing.T) {
	setupSlackLiveCLI(t, "ok")
	log := standInSandbox(t)
	stdout, _, err := runRootCmd(t, []*cobra.Command{slackLiveProbeCmd}, "slack", "live", "probe", "--provider", "claude", "--json")
	require.NoError(t, err)
	assert.Contains(t, stdout, `"status":"ok"`)
	argv, err := os.ReadFile(log)
	require.NoError(t, err)
	lines := strings.Split(strings.TrimSpace(string(argv)), "\n")
	require.Contains(t, lines, "-p")
	sep := -1 // the last run: the first is the sandbox's own /usr/bin/true check
	for i, l := range lines {
		if l == "--" {
			sep = i
		}
	}
	require.GreaterOrEqual(t, sep, 0, string(argv))
	assert.True(t, strings.HasSuffix(lines[sep+1], "fake_claude.sh"), lines[sep+1])
	assert.Contains(t, lines[sep+2:], "--permission-prompt-tool")
}

// probeVerdict runs `slack live probe --json` for provider and returns the
// verdict; the stub records its pid in a file, so started reports whether a
// child ran.
func probeVerdict(t *testing.T, provider string) (out map[string]any, started bool) {
	t.Helper()
	pidfile := filepath.Join(t.TempDir(), "pid")
	slackLiveEnv = func(*slackLiveWiring) []string { return append(os.Environ(), "SCENARIO=ok", "PIDFILE="+pidfile) }
	stdout, _, err := runRootCmd(t, []*cobra.Command{slackLiveProbeCmd}, "slack", "live", "probe", "--provider", provider, "--json")
	require.NoError(t, err)
	require.NoError(t, json.Unmarshal([]byte(stdout), &out))
	_, statErr := os.Stat(pidfile)
	return out, statErr == nil
}

// AllowClaudeAITools=false (MDM) keeps the claude.ai Slack connector off for
// the probe too: not_connected/policy, no child.
func TestSlackLiveProbe_PolicyOffStartsNothing(t *testing.T) {
	setupSlackLiveCLI(t, "ok")
	policytest.Set(t, map[string]any{"AllowClaudeAITools": false})
	out, started := probeVerdict(t, "claude")
	assert.Equal(t, "not_connected", out["status"])
	assert.Equal(t, slackLiveClassPolicy, out["error_class"])
	assert.False(t, started, "no child under a policy that forbids the connectors")
}

// AllowedAIProviders without codex: the Codex probe starts nothing.
func TestSlackLiveProbe_ProviderPolicyStartsNothing(t *testing.T) {
	setupSlackLiveCLI(t, "ok")
	policytest.Set(t, map[string]any{"AllowedAIProviders": []any{"claude"}})
	out, started := probeVerdict(t, "codex")
	assert.Equal(t, "not_connected", out["status"])
	assert.Equal(t, slackLiveClassPolicy, out["error_class"])
	assert.False(t, started)
}

// No file sandbox: the Claude probe fails closed, no child.
func TestSlackLiveProbe_NoSandboxStartsNothing(t *testing.T) {
	setupSlackLiveCLI(t, "ok")
	prev := aiSessionSandbox
	aiSessionSandbox = func() (*chat.ChildSandbox, error) { return nil, errors.New("no sandbox-exec") }
	t.Cleanup(func() { aiSessionSandbox = prev })
	out, started := probeVerdict(t, "claude")
	assert.Equal(t, "unavailable", out["status"])
	assert.Equal(t, slacklive.ErrorClassSandbox, out["error_class"])
	assert.False(t, started)
}

// The owner's switches: connectors off, or the Slack connector off one by
// one, keep the probe from starting the connector.
func TestSlackLiveProbe_OwnerSwitches(t *testing.T) {
	policytest.Set(t, nil)
	cfg := &config.Config{}
	cfg.AI.ClaudeAI.Connectors = true
	class, _ := claudeSlackLiveOff(cfg)
	assert.Empty(t, class)
	cfg.AI.ClaudeAI.DisabledConnectors = []string{"Slack"}
	class, _ = claudeSlackLiveOff(cfg)
	assert.Equal(t, slackLiveClassDisabled, class)
	cfg.AI.ClaudeAI.Connectors = false
	class, _ = claudeSlackLiveOff(cfg)
	assert.Equal(t, slackLiveClassConnectorsOff, class)
	r := claudeSlackLiveProbe(cfg)(t.Context(), "/nonexistent/claude", nil)
	assert.Equal(t, slacklive.Result{Provider: "claude", Status: slacklive.StatusNotConnected, ErrorClass: slackLiveClassConnectorsOff}, r)
}

// A skipped verdict names only the workspaces the newest check found ok,
// not the ones it recorded as absent, nor an older check's.
func TestSlackLiveProbe_FreshTeamsOnlyOK(t *testing.T) {
	now := time.Now()
	at := now.Add(-time.Minute)
	rows := []db.SlackLiveStatus{
		{TeamID: "", Provider: "claude", Status: "ok", CheckedAt: at},
		{TeamID: "T1", Provider: "claude", Status: "ok", CheckedAt: at},
		{TeamID: "T2", Provider: "claude", Status: "not_connected", ErrorClass: "workspace_not_connected", CheckedAt: at},
		{TeamID: "T3", Provider: "claude", Status: "ok", CheckedAt: at.Add(-time.Hour)},
	}
	got, ok := freshSlackLive(rows, "claude", now, time.Hour)
	require.True(t, ok)
	assert.Equal(t, "ok", got.Status)
	assert.Equal(t, []string{"T1"}, got.Teams)
}

// The chat's watcher never starts a probe for a provider without a Slack
// Live wiring (a routed turn on Ollama).
func TestSlackLiveWatcher_NoProbeWithoutWiring(t *testing.T) {
	d := db.OpenTestDB(t)
	w, probes := slackWatcher(t, d, time.Now())
	w.provider = "ollama"
	toolCall(w, "1", "list_messages", true, "")
	assert.Empty(t, *probes)
}
