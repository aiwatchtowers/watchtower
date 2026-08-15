package cmd

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
)

// TestJiraCommentSyncEnabled pins wireJiraSyncers' comment-sync gate (Task
// 6): bounded Jira comment sync now rides streams.enabled — the stream
// digests own the comment feed, not the ideas registry consolidator —
// so ideas.enabled alone must no longer turn it on or off.
func TestJiraCommentSyncEnabled(t *testing.T) {
	tests := []struct {
		name           string
		ideasEnabled   bool
		streamsEnabled bool
		want           bool
	}{
		{"streams enabled, ideas disabled", false, true, true},
		{"both enabled", true, true, true},
		{"both disabled", false, false, false},
		{"only ideas enabled is no longer sufficient", true, false, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg := &config.Config{
				Ideas:   config.IdeasConfig{Enabled: tt.ideasEnabled},
				Streams: config.StreamsConfig{Enabled: tt.streamsEnabled},
			}
			assert.Equal(t, tt.want, jiraCommentSyncEnabled(cfg))
		})
	}
}

func TestPidFilePath(t *testing.T) {
	cfg := &config.Config{ActiveWorkspace: "test"}
	t.Setenv("HOME", "/tmp/test-home")
	path := pidFilePath(cfg)
	assert.Contains(t, path, "test")
	assert.Contains(t, path, "daemon.pid")
}

func TestLogFilePath(t *testing.T) {
	cfg := &config.Config{ActiveWorkspace: "test"}
	t.Setenv("HOME", "/tmp/test-home")
	path := logFilePath(cfg)
	assert.Contains(t, path, "test")
	assert.Contains(t, path, "daemon.log")
}

func TestSyncLogFilePath(t *testing.T) {
	cfg := &config.Config{ActiveWorkspace: "test"}
	t.Setenv("HOME", "/tmp/test-home")
	path := syncLogFilePath(cfg)
	assert.Contains(t, path, "test")
	assert.Contains(t, path, "watchtower.log")
}

func TestSyncResultPath(t *testing.T) {
	cfg := &config.Config{ActiveWorkspace: "test"}
	t.Setenv("HOME", "/tmp/test-home")
	path := syncResultPath(cfg)
	assert.Contains(t, path, "test")
	assert.Contains(t, path, "last_sync.json")
}

func TestRotateLogIfOversized(t *testing.T) {
	// makeOversized creates a file whose header identifies the generation,
	// then extends it past maxLogSize sparsely (instant, no real disk on APFS).
	makeOversized := func(t *testing.T, path, header string) {
		t.Helper()
		require.NoError(t, os.WriteFile(path, []byte(header), 0o600))
		require.NoError(t, os.Truncate(path, maxLogSize+1))
	}

	t.Run("oversized file is renamed to .1 and fresh appends go to a new file", func(t *testing.T) {
		dir := t.TempDir()
		path := filepath.Join(dir, "watchtower.log")
		makeOversized(t, path, "old generation")

		rotateLogIfOversized(path)

		_, err := os.Stat(path)
		assert.True(t, os.IsNotExist(err), "original path should be gone after rotation")
		rotated, err := os.Stat(path + ".1")
		require.NoError(t, err)
		assert.Equal(t, int64(maxLogSize+1), rotated.Size())

		// The caller's O_CREATE|O_APPEND open starts a fresh file.
		f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
		require.NoError(t, err)
		_, err = f.WriteString("fresh line\n")
		require.NoError(t, err)
		require.NoError(t, f.Close())
		content, err := os.ReadFile(path)
		require.NoError(t, err)
		assert.Equal(t, "fresh line\n", string(content))
	})

	t.Run("existing .1 is replaced", func(t *testing.T) {
		dir := t.TempDir()
		path := filepath.Join(dir, "watchtower.log")
		require.NoError(t, os.WriteFile(path+".1", []byte("older generation"), 0o600))
		makeOversized(t, path, "newer generation")

		rotateLogIfOversized(path)

		content, err := os.ReadFile(path + ".1")
		require.NoError(t, err)
		assert.Equal(t, "newer generation", string(content[:len("newer generation")]))
	})

	t.Run("under-cap file is untouched", func(t *testing.T) {
		dir := t.TempDir()
		path := filepath.Join(dir, "watchtower.log")
		require.NoError(t, os.WriteFile(path, []byte("small"), 0o600))

		rotateLogIfOversized(path)

		content, err := os.ReadFile(path)
		require.NoError(t, err)
		assert.Equal(t, "small", string(content))
		_, err = os.Stat(path + ".1")
		assert.True(t, os.IsNotExist(err), "no .1 should appear for an under-cap file")
	})

	t.Run("missing file is a no-op", func(t *testing.T) {
		dir := t.TempDir()
		path := filepath.Join(dir, "watchtower.log")

		rotateLogIfOversized(path)

		_, err := os.Stat(path)
		assert.True(t, os.IsNotExist(err))
		_, err = os.Stat(path + ".1")
		assert.True(t, os.IsNotExist(err))
	})
}

func TestSyncAdditionalFlags(t *testing.T) {
	assert.NotNil(t, syncCmd.Flags().Lookup("detach"))
	assert.NotNil(t, syncCmd.Flags().Lookup("stop"))
	assert.NotNil(t, syncCmd.Flags().Lookup("skip-dms"))
	assert.NotNil(t, syncCmd.Flags().Lookup("progress-json"))
	assert.NotNil(t, syncCmd.Flags().Lookup("days"))
}

func TestSyncStopSubcommandRegistered(t *testing.T) {
	found := false
	for _, cmd := range syncCmd.Commands() {
		if cmd.Name() == "stop" {
			found = true
			break
		}
	}
	assert.True(t, found, "sync stop subcommand should be registered")
}

func TestSyncDetachRequiresDaemon(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	// Create a minimal config with a real token to pass Validate()
	tmpDir := os.Getenv("HOME")
	configPath := filepath.Join(tmpDir, "config-detach.yaml")
	configYAML := `active_workspace: test-ws
workspaces:
  test-ws:
    slack_token: "xoxp-test-token"
`
	require.NoError(t, os.WriteFile(configPath, []byte(configYAML), 0o600))

	oldFlagConfig := flagConfig
	flagConfig = configPath
	defer func() { flagConfig = oldFlagConfig }()

	syncFlagFull = false
	syncFlagDaemon = false
	syncFlagDetach = true
	syncFlagStop = false
	defer func() { syncFlagDetach = false }()

	// Ensure we're not the detached child
	t.Setenv("WATCHTOWER_DETACH", "")

	err := syncCmd.RunE(syncCmd, nil)
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "--detach requires --daemon")
}

func TestOpenDBFromConfig(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	database, err := openDBFromConfig()
	require.NoError(t, err)
	require.NotNil(t, database)
	database.Close()
}

func TestOpenDBFromConfig_InvalidConfig(t *testing.T) {
	oldFlagConfig := flagConfig
	flagConfig = "/nonexistent/config.yaml"
	defer func() { flagConfig = oldFlagConfig }()

	database, err := openDBFromConfig()
	assert.Error(t, err)
	assert.Nil(t, database)
}

func TestOpenTracksDB(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	database, err := openTracksDB()
	require.NoError(t, err)
	require.NotNil(t, database)
	database.Close()
}

func TestOpenTracksDB_InvalidConfig(t *testing.T) {
	oldFlagConfig := flagConfig
	flagConfig = "/nonexistent/config.yaml"
	defer func() { flagConfig = oldFlagConfig }()

	database, err := openTracksDB()
	assert.Error(t, err)
	assert.Nil(t, database)
}

func TestOpenPromptStore(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	cfg, store, closer, err := openPromptStore()
	require.NoError(t, err)
	require.NotNil(t, cfg)
	require.NotNil(t, store)
	require.NotNil(t, closer)
	closer()
}

func TestOpenPromptStore_InvalidConfig(t *testing.T) {
	oldFlagConfig := flagConfig
	flagConfig = "/nonexistent/config.yaml"
	defer func() { flagConfig = oldFlagConfig }()

	_, _, _, err := openPromptStore()
	assert.Error(t, err)
}
