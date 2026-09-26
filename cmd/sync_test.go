package cmd

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
)

func TestSyncCommandRegistered(t *testing.T) {
	found := false
	for _, cmd := range rootCmd.Commands() {
		if cmd.Name() == "sync" {
			found = true
			break
		}
	}
	assert.True(t, found, "sync command should be registered")
}

func TestSyncCommandFlags(t *testing.T) {
	f := syncCmd.Flags()

	fullFlag := f.Lookup("full")
	assert.NotNil(t, fullFlag)
	assert.Equal(t, "false", fullFlag.DefValue)

	daemonFlag := f.Lookup("daemon")
	assert.NotNil(t, daemonFlag)
	assert.Equal(t, "false", daemonFlag.DefValue)

	channelsFlag := f.Lookup("channels")
	assert.NotNil(t, channelsFlag)
	assert.Equal(t, "[]", channelsFlag.DefValue)

	workersFlag := f.Lookup("workers")
	assert.NotNil(t, workersFlag)
	assert.Equal(t, "0", workersFlag.DefValue)
}

func TestSyncCommandRequiresConfig(t *testing.T) {
	oldFlagConfig := flagConfig
	flagConfig = "/nonexistent/path/config.yaml"
	defer func() { flagConfig = oldFlagConfig }()

	err := syncCmd.RunE(syncCmd, nil)
	assert.Error(t, err)
}

// A fresh install connects Slack through the multi-account OAuth path, which
// writes active_workspace but no `workspaces.<name>` block — the token lives
// in slack_token_<id>.json. The daemon must still start against that config;
// before this guard a missing block failed `sync --daemon --detach` with
// "workspace not found in config" before daemon.log was even opened.
func TestValidateSyncConfig_NoWorkspacesEntry(t *testing.T) {
	cfg := &config.Config{ActiveWorkspace: "acme"}
	require.NoError(t, validateSyncConfig(cfg))
}

func TestValidateSyncConfig_RequiresActiveWorkspace(t *testing.T) {
	err := validateSyncConfig(&config.Config{})
	require.Error(t, err)
	require.Contains(t, err.Error(), "active_workspace is required")
}

// A legacy config-embedded token is still validated when present: a
// malformed one is a misconfiguration, not an optional Slack.
func TestValidateSyncConfig_LegacyTokenStillValidated(t *testing.T) {
	cfg := &config.Config{
		ActiveWorkspace: "acme",
		Workspaces:      map[string]*config.WorkspaceConfig{"acme": {SlackToken: "not-a-slack-token"}},
	}
	err := validateSyncConfig(cfg)
	require.Error(t, err)
	require.Contains(t, err.Error(), "invalid format")

	cfg.Workspaces["acme"].SlackToken = "xoxp-valid"
	require.NoError(t, validateSyncConfig(cfg))
}

// The incident shape driven through the real command: active_workspace set,
// no `workspaces:` block. runSync must get past config validation — the
// "--detach requires --daemon" error is only reachable after
// validateSyncConfig accepted the config. Before the fix this failed with
// "workspace \"acme\" not found in config".
func TestRunSync_AcceptsConfigWithoutWorkspacesBlock(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	configPath := filepath.Join(os.Getenv("HOME"), "config-no-block.yaml")
	require.NoError(t, os.WriteFile(configPath, []byte("active_workspace: acme\n"), 0o600))

	oldFlagConfig := flagConfig
	flagConfig = configPath
	defer func() { flagConfig = oldFlagConfig }()

	syncFlagFull = false
	syncFlagDaemon = false
	syncFlagDetach = true
	syncFlagStop = false
	defer func() { syncFlagDetach = false }()
	t.Setenv("WATCHTOWER_DETACH", "")

	err := syncCmd.RunE(syncCmd, nil)
	require.Error(t, err)
	require.Contains(t, err.Error(), "--detach requires --daemon")
}
