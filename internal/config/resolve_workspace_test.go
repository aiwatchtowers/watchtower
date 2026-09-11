package config

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
)

// seedWorkspace creates ~/.local/share/watchtower/<name>/ under the test HOME,
// with a watchtower.db when withDB is set.
func seedWorkspace(t *testing.T, name string, withDB bool) {
	t.Helper()
	dir := filepath.Join(dataRoot(t), name)
	require.NoError(t, os.MkdirAll(dir, 0o755))
	if withDB {
		require.NoError(t, os.WriteFile(filepath.Join(dir, "watchtower.db"), nil, 0o600))
	}
}

func dataRoot(t *testing.T) string {
	t.Helper()
	root, err := DataRoot()
	require.NoError(t, err)
	return root
}

func writeConfigFile(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, os.WriteFile(path, []byte(body), 0o600))
	return path
}

// The incident shape: settings present, active_workspace gone, one workspace
// directory holding a database. Every CLI command and the daemon must resolve
// the same workspace the Desktop already opens.
func TestLoad_ResolvesActiveWorkspaceFromTheOnlyDatabase(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	seedWorkspace(t, "whitebit", true)
	seedWorkspace(t, "scratch", false)

	cfg, err := Load(writeConfigFile(t, "sync:\n  workers: 2\n"))
	require.NoError(t, err)
	require.Equal(t, "whitebit", cfg.ActiveWorkspace)
	require.NoError(t, cfg.ValidateWorkspace())
	require.Equal(t, filepath.Join(dataRoot(t), "whitebit", "watchtower.db"), cfg.DBPath())
}

func TestLoad_ConfiguredActiveWorkspaceWinsOverDirectories(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	seedWorkspace(t, "whitebit", true)

	cfg, err := Load(writeConfigFile(t, "active_workspace: dev\n"))
	require.NoError(t, err)
	require.Equal(t, "dev", cfg.ActiveWorkspace)
}

// Several databases: no guess. The daemon fails loudly with the existing
// "active_workspace is required" error instead of writing into an arbitrary
// workspace.
func TestLoad_LeavesActiveWorkspaceEmptyWhenAmbiguous(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	seedWorkspace(t, "alpha", true)
	seedWorkspace(t, "whitebit", true)

	cfg, err := Load(writeConfigFile(t, "sync:\n  workers: 2\n"))
	require.NoError(t, err)
	require.Empty(t, cfg.ActiveWorkspace)
	err = cfg.ValidateWorkspace()
	require.Error(t, err)
	require.Contains(t, err.Error(), "several workspaces hold a database (alpha, whitebit)")
	require.Contains(t, err.Error(), "config set active_workspace")
}

// The env-token binding keys on ActiveWorkspace, so the resolver must run
// first: a workspace recovered from disk honours WATCHTOWER_SLACK_TOKEN
// exactly like one named in the config.
func TestLoad_EnvTokenBindsToResolvedWorkspace(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	seedWorkspace(t, "whitebit", true)
	t.Setenv("WATCHTOWER_SLACK_TOKEN", "xoxp-from-env")

	cfg, err := Load(writeConfigFile(t, "sync:\n  workers: 2\n"))
	require.NoError(t, err)
	require.Equal(t, "whitebit", cfg.ActiveWorkspace)
	require.NotNil(t, cfg.Workspaces["whitebit"])
	require.Equal(t, "xoxp-from-env", cfg.Workspaces["whitebit"].SlackToken)
}

func TestLoad_LeavesActiveWorkspaceEmptyWithoutAnyDatabase(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	seedWorkspace(t, "empty", false)

	cfg, err := Load(writeConfigFile(t, "sync:\n  workers: 2\n"))
	require.NoError(t, err)
	require.Empty(t, cfg.ActiveWorkspace)
}

func TestWorkspaceDirsWithDatabase_SkipsFilesInvalidNamesAndMissingRoot(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	require.Nil(t, workspaceDirsWithDatabase(dataRoot(t)), "missing root")

	seedWorkspace(t, "whitebit", true)
	seedWorkspace(t, "alpha", true)
	seedWorkspace(t, "no-db", false)
	seedWorkspace(t, ".hidden", true)
	seedWorkspace(t, "bad name", true)
	require.NoError(t, os.WriteFile(filepath.Join(dataRoot(t), "watchtower.db"), nil, 0o600))

	require.Equal(t, []string{"alpha", "whitebit"}, workspaceDirsWithDatabase(dataRoot(t)))
}
