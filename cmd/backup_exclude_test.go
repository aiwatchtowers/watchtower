package cmd

import (
	"bytes"
	"context"
	"errors"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
)

// recordBackupExclude replaces the Apply seam with a recorder that returns
// errs, and gives the once-per-process log a fresh state and a buffer.
func recordBackupExclude(t *testing.T, errs []error) (calls *[][]string, stderr *bytes.Buffer) {
	t.Helper()
	var got [][]string
	origApply, origOut, origLogged := backupExcludeApply, backupExclusionStderr, backupExclusionLogged
	backupExcludeApply = func(dirs []string) []error {
		got = append(got, append([]string(nil), dirs...))
		return errs
	}
	buf := &bytes.Buffer{}
	backupExclusionStderr = buf
	backupExclusionLogged = map[string]bool{}
	t.Cleanup(func() {
		backupExcludeApply, backupExclusionStderr, backupExclusionLogged = origApply, origOut, origLogged
	})
	return &got, buf
}

func backupRootAndAS(t *testing.T) (root, as string) {
	t.Helper()
	root, err := config.DataRoot()
	require.NoError(t, err)
	as, err = config.AppSupportDir()
	require.NoError(t, err)
	return root, as
}

func TestBackupDirs_DefaultRecordingsNotDuplicated(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	root, as := backupRootAndAS(t)
	assert.Equal(t, []string{root, as}, backupDirs(&config.Config{}))
}

func TestBackupDirs_CustomRecordingsOutside(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	root, as := backupRootAndAS(t)
	rec := filepath.Join(t.TempDir(), "rec")
	cfg := &config.Config{}
	cfg.Transcripts.RecordingsDir = rec
	assert.Equal(t, []string{root, as, rec}, backupDirs(cfg))
}

func TestBackupDirs_CustomRecordingsInsideAS(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	root, as := backupRootAndAS(t)
	cfg := &config.Config{}
	cfg.Transcripts.RecordingsDir = filepath.Join(as, "sub") + "/"
	assert.Equal(t, []string{root, as}, backupDirs(cfg))

	// A sibling whose name only starts like <as> is outside it.
	cfg.Transcripts.RecordingsDir = as + "-other"
	assert.Equal(t, []string{root, as, as + "-other"}, backupDirs(cfg))
}

func TestBackup01_WorkspaceInitApplies(t *testing.T) {
	_, configPath := workspaceInitHome(t)
	var workspaceExisted bool
	calls, _ := recordBackupExclude(t, nil)
	inner := backupExcludeApply
	backupExcludeApply = func(dirs []string) []error {
		cfg, err := config.Load(configPath)
		if err == nil {
			cfg.ActiveWorkspace = "default"
			_, statErr := os.Stat(cfg.WorkspaceDir())
			workspaceExisted = statErr == nil
		}
		return inner(dirs)
	}

	_, err := initWorkspace(configPath, "", "default")
	require.NoError(t, err)
	require.Len(t, *calls, 1)
	assert.Equal(t, backupDirs(&config.Config{}), (*calls)[0])
	assert.True(t, workspaceExisted, "the workspace folder must exist when the exclusion runs")
}

func TestBackup01_DBMigrateApplies(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	calls, _ := recordBackupExclude(t, nil)
	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)

	require.NoError(t, dbMigrateCmd.RunE(dbMigrateCmd, nil))
	require.Len(t, *calls, 1)
	assert.Equal(t, backupDirs(cfg), (*calls)[0])
}

func TestBackup01_DaemonStartApplies(t *testing.T) {
	_, configPath := workspaceInitHome(t)
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
	assert.Equal(t, backupDirs(cfg), (*calls)[0])
}

func TestApplyBackupExclusion_FailureKeepsExitCode(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	_, stderr := recordBackupExclude(t, []error{errors.New("/x/root: operation not supported")})

	require.NoError(t, dbMigrateCmd.RunE(dbMigrateCmd, nil))
	require.NoError(t, dbMigrateCmd.RunE(dbMigrateCmd, nil))
	assert.Equal(t, "backup exclusion: /x/root: operation not supported\n", stderr.String())
	assert.Equal(t, 1, strings.Count(stderr.String(), "backup exclusion:"))
}

func TestApplyBackupExclusion_CreatesAS0700(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	recordBackupExclude(t, nil)
	_, as := backupRootAndAS(t)

	applyBackupExclusion(&config.Config{})
	info, err := os.Stat(as)
	require.NoError(t, err)
	assert.True(t, info.IsDir())
	assert.Equal(t, os.FileMode(0o700), info.Mode().Perm())
}
