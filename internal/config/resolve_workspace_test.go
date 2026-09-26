package config

import (
	"io/fs"
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
	seedWorkspace(t, "zenith", true)
	seedWorkspace(t, "scratch", false)

	cfg, err := Load(writeConfigFile(t, "sync:\n  workers: 2\n"))
	require.NoError(t, err)
	require.Equal(t, "zenith", cfg.ActiveWorkspace)
	require.NoError(t, cfg.ValidateWorkspace())
	require.Equal(t, filepath.Join(dataRoot(t), "zenith", "watchtower.db"), cfg.DBPath())
}

func TestLoad_ConfiguredActiveWorkspaceWinsOverDirectories(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	seedWorkspace(t, "zenith", true)

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
	seedWorkspace(t, "zenith", true)

	cfg, err := Load(writeConfigFile(t, "sync:\n  workers: 2\n"))
	require.NoError(t, err)
	require.Empty(t, cfg.ActiveWorkspace)
	err = cfg.ValidateWorkspace()
	require.Error(t, err)
	require.Contains(t, err.Error(), "several workspaces hold a database (alpha, zenith)")
	require.Contains(t, err.Error(), "config set active_workspace")
	require.NotContains(t, err.Error(), "no workspace with a database was found")
}

// The env-token binding keys on ActiveWorkspace, so the resolver must run
// first: a workspace recovered from disk honours WATCHTOWER_SLACK_TOKEN
// exactly like one named in the config.
func TestLoad_EnvTokenBindsToResolvedWorkspace(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	seedWorkspace(t, "zenith", true)
	t.Setenv("WATCHTOWER_SLACK_TOKEN", "xoxp-from-env")

	cfg, err := Load(writeConfigFile(t, "sync:\n  workers: 2\n"))
	require.NoError(t, err)
	require.Equal(t, "zenith", cfg.ActiveWorkspace)
	require.NotNil(t, cfg.Workspaces["zenith"])
	require.Equal(t, "xoxp-from-env", cfg.Workspaces["zenith"].SlackToken)
}

func TestLoad_LeavesActiveWorkspaceEmptyWithoutAnyDatabase(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	seedWorkspace(t, "empty", false)

	cfg, err := Load(writeConfigFile(t, "sync:\n  workers: 2\n"))
	require.NoError(t, err)
	require.Empty(t, cfg.ActiveWorkspace)

	// No workspace holds a database yet, so the hint offers both ways to create
	// one: Slack via auth login, or a named workspace for a Google/Jira-only
	// start. Never config init — it rewrites the config.yaml that was just read.
	err = cfg.ValidateWorkspace()
	require.Error(t, err)
	require.Contains(t, err.Error(), "no workspace with a database was found")
	require.Contains(t, err.Error(), "'watchtower auth login'")
	require.Contains(t, err.Error(), "'watchtower config set active_workspace <name>'")
	require.NotContains(t, err.Error(), "config init")
	require.NotContains(t, err.Error(), "several workspaces")
}

func TestWorkspaceDirsWithDatabase_SkipsFilesInvalidNamesAndMissingRoot(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	names, err := workspaceDirsWithDatabase(dataRoot(t))
	require.NoError(t, err, "missing root is a fresh install, not an error")
	require.Nil(t, names, "missing root")

	seedWorkspace(t, "zenith", true)
	seedWorkspace(t, "alpha", true)
	seedWorkspace(t, "no-db", false)
	seedWorkspace(t, ".hidden", true)
	seedWorkspace(t, "bad name", true)
	require.NoError(t, os.WriteFile(filepath.Join(dataRoot(t), "watchtower.db"), nil, 0o600))

	names, err = workspaceDirsWithDatabase(dataRoot(t))
	require.NoError(t, err)
	require.Equal(t, []string{"alpha", "zenith"}, names)
}

// A workspace directory reached through a symlink is a candidate, exactly as
// on the Desktop (FileManager.fileExists follows symlinks): otherwise the two
// halves would resolve different workspaces. A dangling symlink, a symlink
// to a plain file and a symlink loop hold no database and are skipped without
// an error.
func TestWorkspaceDirsWithDatabase_FollowsSymlinks(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	root := dataRoot(t)
	require.NoError(t, os.MkdirAll(root, 0o755))

	target := filepath.Join(t.TempDir(), "elsewhere")
	require.NoError(t, os.MkdirAll(target, 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(target, "watchtower.db"), nil, 0o600))
	require.NoError(t, os.Symlink(target, filepath.Join(root, "linked")))

	require.NoError(t, os.Symlink(filepath.Join(t.TempDir(), "gone"), filepath.Join(root, "dangling")))
	plain := filepath.Join(t.TempDir(), "plain")
	require.NoError(t, os.WriteFile(plain, nil, 0o600))
	require.NoError(t, os.Symlink(plain, filepath.Join(root, "to-file")))
	// A symlink loop fails the stat with ELOOP instead of hanging.
	require.NoError(t, os.Symlink(filepath.Join(root, "loop-b"), filepath.Join(root, "loop-a")))
	require.NoError(t, os.Symlink(filepath.Join(root, "loop-a"), filepath.Join(root, "loop-b")))

	names, err := workspaceDirsWithDatabase(root)
	require.NoError(t, err)
	require.Equal(t, []string{"linked"}, names)

	cfg, err := Load(writeConfigFile(t, "sync:\n  workers: 2\n"))
	require.NoError(t, err)
	require.Equal(t, "linked", cfg.ActiveWorkspace)
}

// An unreadable data directory is not a fresh install: the hint must surface
// the read failure instead of the "no workspace found" advice.
func TestLoad_UnreadableDataRootReportsLookupError(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads a 0o000 directory")
	}
	t.Setenv("HOME", t.TempDir())
	seedWorkspace(t, "zenith", true)
	root := dataRoot(t)
	require.NoError(t, os.Chmod(root, 0o000))
	t.Cleanup(func() { _ = os.Chmod(root, 0o755) })

	cfg, err := Load(writeConfigFile(t, "sync:\n  workers: 2\n"))
	require.NoError(t, err)
	require.Empty(t, cfg.ActiveWorkspace)
	err = cfg.ValidateWorkspace()
	require.Error(t, err)
	require.ErrorIs(t, err, fs.ErrPermission)
	require.Contains(t, err.Error(), "config set active_workspace")
	require.NotContains(t, err.Error(), "no workspace with a database was found")
}

func TestWorkspaceDatabaseWarning_NamedWorkspaceHasDatabase(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	seedWorkspace(t, "zenith", true)
	seedWorkspace(t, "other", true)

	require.Empty(t, WorkspaceDatabaseWarning("zenith"))
}

// A brand-new workspace legitimately has no database yet: with nothing else on
// disk the warning says so without suggesting a typo.
func TestWorkspaceDatabaseWarning_NoDataRootAtAll(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	w := WorkspaceDatabaseWarning("fresh")
	require.Contains(t, w, `"fresh"`)
	require.Contains(t, w, filepath.Join(dataRoot(t), "fresh", "watchtower.db"))
	require.Contains(t, w, "no workspace holds a database yet")
	require.NotContains(t, w, "typo")
}

func TestWorkspaceDatabaseWarning_ZeroCandidates(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	seedWorkspace(t, "fresh", false)
	seedWorkspace(t, "empty", false)

	w := WorkspaceDatabaseWarning("fresh")
	require.Contains(t, w, "no workspace holds a database yet")
	require.NotContains(t, w, "typo")
}

// The typo shape the backlog item names: the misspelled name has no database
// while the real one does — list every directory that holds one.
func TestWorkspaceDatabaseWarning_ListsCandidatesOnTypo(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	seedWorkspace(t, "zenith", true)
	seedWorkspace(t, "alpha", true)
	seedWorkspace(t, "no-db", false)

	w := WorkspaceDatabaseWarning("zentih")
	require.Contains(t, w, `"zentih"`)
	require.Contains(t, w, "alpha, zenith")
	require.Contains(t, w, "typo")
	require.NotContains(t, w, "no-db")
}

func TestWorkspaceDatabaseWarning_InvalidName(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	seedWorkspace(t, "zenith", true)

	w := WorkspaceDatabaseWarning("../zenith")
	require.Contains(t, w, "not a valid workspace name")
}

// An unreadable data directory must surface the read failure rather than
// claim there is no database anywhere.
func TestWorkspaceDatabaseWarning_UnreadableDataRoot(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root ignores directory permissions")
	}
	t.Setenv("HOME", t.TempDir())
	seedWorkspace(t, "zenith", true)
	require.NoError(t, os.Chmod(dataRoot(t), 0o000))
	t.Cleanup(func() { _ = os.Chmod(dataRoot(t), 0o755) })

	w := WorkspaceDatabaseWarning("zentih")
	require.Contains(t, w, "could not")
	require.NotContains(t, w, "no workspace holds a database yet")
}

// Execute-only root: the target's own stat cleanly reports not-exist, but the
// listing fails — the warning must say the list is unknown, not that none exist.
func TestWorkspaceDatabaseWarning_UnlistableDataRoot(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root ignores directory permissions")
	}
	t.Setenv("HOME", t.TempDir())
	seedWorkspace(t, "zenith", true)
	require.NoError(t, os.Chmod(dataRoot(t), 0o111))
	t.Cleanup(func() { _ = os.Chmod(dataRoot(t), 0o755) })

	w := WorkspaceDatabaseWarning("zentih")
	require.Contains(t, w, "existing workspaces could not be listed")
	require.NotContains(t, w, "no workspace holds a database yet")
}

func TestWorkspaceDatabaseWarning_EmptyNameIsSilent(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	seedWorkspace(t, "zenith", true)

	require.Empty(t, WorkspaceDatabaseWarning(""))
}
