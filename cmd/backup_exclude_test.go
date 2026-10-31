package cmd

import (
	"bytes"
	"context"
	"errors"
	"io"
	"log"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
)

// recordBackupExclude replaces the Apply seam with a recorder that returns
// errs, runs as darwin, and captures the failure lines in a buffer.
func recordBackupExclude(t *testing.T, errs []error) (calls *[][]string, stderr *bytes.Buffer) {
	t.Helper()
	var got [][]string
	origApply, origOut, origGOOS := backupExcludeApply, backupExclusionStderr, backupExclusionGOOS
	backupExcludeApply = func(dirs []string) []error {
		got = append(got, append([]string(nil), dirs...))
		return errs
	}
	buf := &bytes.Buffer{}
	backupExclusionStderr = buf
	backupExclusionGOOS = "darwin"
	t.Cleanup(func() {
		backupExcludeApply, backupExclusionStderr, backupExclusionGOOS = origApply, origOut, origGOOS
	})
	return &got, buf
}

// backupRootAndAS returns the two BACKUP-01 folders under the current HOME,
// spelled out literally (not through backupDirs). The support folder is the
// macOS one on darwin; on another OS running these tests (the Linux CI job,
// with the GOOS seam set to darwin) it is that OS's AppSupportDir,
// <data root>/.support.
func backupRootAndAS(t *testing.T) (root, as string) {
	t.Helper()
	home, err := os.UserHomeDir()
	require.NoError(t, err)
	root = filepath.Join(home, ".local", "share", "watchtower")
	if runtime.GOOS == "darwin" {
		return root, filepath.Join(home, "Library", "Application Support", "Watchtower")
	}
	return root, filepath.Join(root, ".support")
}

func TestBackupDirs_DataRootAndAppSupport(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	root, as := backupRootAndAS(t)
	assert.Equal(t, []string{root, as}, backupDirs())
}

func TestBackup01_WorkspaceInitApplies(t *testing.T) {
	_, configPath := workspaceInitHome(t)
	root, as := backupRootAndAS(t)
	var workspaceExisted bool
	calls, _ := recordBackupExclude(t, nil)
	inner := backupExcludeApply
	backupExcludeApply = func(dirs []string) []error {
		cfg, err := config.Load(configPath)
		require.NoError(t, err)
		cfg.ActiveWorkspace = "default"
		_, statErr := os.Stat(cfg.WorkspaceDir())
		workspaceExisted = statErr == nil
		return inner(dirs)
	}

	_, err := initWorkspace(configPath, "", "default")
	require.NoError(t, err)
	require.Len(t, *calls, 1)
	assert.Equal(t, []string{root, as}, (*calls)[0])
	assert.True(t, workspaceExisted, "the workspace folder must exist when the exclusion runs")
}

func TestBackup01_DBMigrateApplies(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	root, as := backupRootAndAS(t)
	calls, _ := recordBackupExclude(t, nil)

	require.NoError(t, dbMigrateCmd.RunE(dbMigrateCmd, nil))
	require.Len(t, *calls, 1)
	assert.Equal(t, []string{root, as}, (*calls)[0])
}

func TestBackup01_DaemonStartApplies(t *testing.T) {
	_, configPath := workspaceInitHome(t)
	root, as := backupRootAndAS(t)
	_, err := initWorkspace(configPath, "", "default")
	require.NoError(t, err)
	cfg, err := config.Load(configPath)
	require.NoError(t, err)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	defer database.Close()
	calls, _ := recordBackupExclude(t, nil)

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	done := make(chan error, 1)
	go func() { done <- runSyncDaemon(ctx, cfg, database, log.New(io.Discard, "", 0), nil) }()
	select {
	case err := <-done:
		require.NoError(t, err)
	case <-time.After(60 * time.Second):
		t.Fatal("the daemon did not stop on a cancelled context")
	}
	require.Len(t, *calls, 1)
	assert.Equal(t, []string{root, as}, (*calls)[0])
}

func TestApplyBackupExclusion_FailureKeepsExitCode(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	_, stderr := recordBackupExclude(t, []error{errors.New("/x/root: operation not supported")})

	require.NoError(t, dbMigrateCmd.RunE(dbMigrateCmd, nil))
	assert.Equal(t, "backup exclusion: /x/root: operation not supported\n", stderr.String())
}

func TestApplyBackupExclusion_MakeDirFailureLoggedExitZero(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	calls, stderr := recordBackupExclude(t, nil)
	home, err := os.UserHomeDir()
	require.NoError(t, err)
	_, as := backupRootAndAS(t)
	// A file where the Library folder belongs makes MakePrivateDir fail; off
	// darwin, a file where the support folder belongs.
	blocker := filepath.Join(home, "Library")
	if runtime.GOOS != "darwin" {
		blocker = as
	}
	require.NoError(t, os.MkdirAll(filepath.Dir(blocker), 0o700))
	require.NoError(t, os.WriteFile(blocker, []byte("x"), 0o600))

	require.NoError(t, dbMigrateCmd.RunE(dbMigrateCmd, nil))
	assert.Equal(t, 1, strings.Count(stderr.String(), "backup exclusion: "+as+": "), stderr.String())
	assert.Len(t, *calls, 1, "Apply still runs for the other folder")
}

func TestApplyBackupExclusion_CreatesAS0700(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	recordBackupExclude(t, nil)
	_, as := backupRootAndAS(t)

	applyBackupExclusion()
	info, err := os.Stat(as)
	require.NoError(t, err)
	assert.True(t, info.IsDir())
	assert.Equal(t, os.FileMode(0o700), info.Mode().Perm())
}

func TestApplyBackupExclusion_NoOpOffDarwin(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	calls, stderr := recordBackupExclude(t, nil)
	backupExclusionGOOS = "linux"
	_, as := backupRootAndAS(t)

	applyBackupExclusion()
	_, err := os.Stat(as)
	assert.True(t, os.IsNotExist(err), "Application Support must not be created off macOS: %v", err)
	assert.Empty(t, *calls)
	assert.Empty(t, stderr.String())
}
