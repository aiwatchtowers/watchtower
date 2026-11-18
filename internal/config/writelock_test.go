package config

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"testing/synctest"

	"github.com/stretchr/testify/require"
)

// tryLockOwnFD takes a non-blocking exclusive flock on path through its own
// file descriptor and reports whether it got it (releasing it at once).
func tryLockOwnFD(t *testing.T, path string) bool {
	t.Helper()
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	require.NoError(t, err)
	defer f.Close()
	err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
	if err == nil {
		require.NoError(t, syscall.Flock(int(f.Fd()), syscall.LOCK_UN))
		return true
	}
	require.ErrorIs(t, err, syscall.EWOULDBLOCK)
	return false
}

func TestWithWriteLock_ExcludesSecondHolder(t *testing.T) {
	cfgPath := filepath.Join(t.TempDir(), "config.yaml")
	lockPath := cfgPath + ".lock"

	err := WithWriteLock(cfgPath, func(lk *WriteLock) error {
		require.True(t, lk.Covers(cfgPath))
		require.False(t, tryLockOwnFD(t, lockPath), "a second holder must not get the lock while fn runs")
		return nil
	})
	require.NoError(t, err)
	require.True(t, tryLockOwnFD(t, lockPath), "the lock is free once WithWriteLock returns")

	info, err := os.Stat(lockPath)
	require.NoError(t, err)
	require.Equal(t, os.FileMode(0o600), info.Mode().Perm())
}

func TestWithWriteLock_NestedCallFailsFast(t *testing.T) {
	cfgPath := filepath.Join(t.TempDir(), "config.yaml")
	// In a synctest bubble so a nested call that queued on an in-process
	// mutex or channel (rather than failing) would be reported as a deadlock.
	// A nested call blocked in flock(2) itself would not be — that block is a
	// syscall outside the bubble's view — so the assertion is that the nested
	// call returns at all, with ErrWriteLockHeld.
	synctest.Test(t, func(t *testing.T) {
		var nested error
		err := WithWriteLock(cfgPath, func(*WriteLock) error {
			nested = WithWriteLock(cfgPath, func(*WriteLock) error {
				return errors.New("nested fn must not run")
			})
			return nil
		})
		require.NoError(t, err)
		require.ErrorIs(t, nested, ErrWriteLockHeld)
	})
	// The held mark is cleared: the next call takes the lock again.
	require.NoError(t, WithWriteLock(cfgPath, func(*WriteLock) error { return nil }))
}

func TestWithWriteLock_TokenCoversOnlyItsPathWhileHeld(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.yaml")
	var leaked *WriteLock
	require.NoError(t, WithWriteLock(cfgPath, func(lk *WriteLock) error {
		require.True(t, lk.Covers(filepath.Join(dir, ".", "config.yaml")))
		require.False(t, lk.Covers(filepath.Join(dir, "other.yaml")))
		leaked = lk
		return nil
	}))
	require.False(t, leaked.Covers(cfgPath), "a token kept past its callback covers nothing")
	var zero *WriteLock
	require.False(t, zero.Covers(cfgPath))
	require.False(t, (&WriteLock{}).Covers(cfgPath))
}

func TestWithWriteLock_CopiedTokenStopsCoveringAfterRelease(t *testing.T) {
	cfgPath := filepath.Join(t.TempDir(), "config.yaml")
	var copied WriteLock
	require.NoError(t, WithWriteLock(cfgPath, func(lk *WriteLock) error {
		copied = *lk
		require.True(t, copied.Covers(cfgPath))
		return nil
	}))
	require.False(t, copied.Covers(cfgPath), "a copy taken inside the callback covers nothing after it returns")
}

func TestWithWriteLock_CreatesMissingDirectory(t *testing.T) {
	cfgPath := filepath.Join(t.TempDir(), "nested", "config.yaml")
	require.NoError(t, WithWriteLock(cfgPath, func(*WriteLock) error { return nil }))
	_, err := os.Stat(cfgPath + ".lock")
	require.NoError(t, err)
}

func TestWithWriteLock_ReturnsFnError(t *testing.T) {
	cfgPath := filepath.Join(t.TempDir(), "config.yaml")
	boom := errors.New("boom")
	require.ErrorIs(t, WithWriteLock(cfgPath, func(*WriteLock) error { return boom }), boom)
}

func TestWriteFeatureMigrationConfigBytes_RefusesUncoveredPath(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.yaml")
	other := filepath.Join(dir, "other.yaml")
	err := WithWriteLock(cfgPath, func(lk *WriteLock) error {
		return writeFeatureMigrationConfigBytes(lk, []byte("a: 1\n"), other)
	})
	require.Error(t, err)
	_, statErr := os.Stat(other)
	require.True(t, os.IsNotExist(statErr), "nothing is written without the lock on that path")
}

// patchConfigYAMLLocked is patchConfigYAML under the write lock, for tests of
// the patch itself.
func patchConfigYAMLLocked(configPath string, sets map[string]bool, deletes []string) error {
	return WithWriteLock(configPath, func(lk *WriteLock) error {
		return patchConfigYAML(lk, configPath, sets, deletes)
	})
}

// TestWithWriteLock_SharedLockFileFixture pins the lock file's name to
// testdata/write_lock.json, which the Desktop's ConfigFileLockTests read too:
// Go and Swift writers must lock the same file.
func TestWithWriteLock_SharedLockFileFixture(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "write_lock.json"))
	require.NoError(t, err)
	var fx struct{ Config, Lock string }
	require.NoError(t, json.Unmarshal(raw, &fx))
	require.NotEmpty(t, fx.Config)

	dir := t.TempDir()
	cfgPath := filepath.Join(dir, fx.Config)
	require.NoError(t, WithWriteLock(cfgPath, func(*WriteLock) error {
		require.False(t, tryLockOwnFD(t, filepath.Join(dir, fx.Lock)), "the fixture's lock file is the one held")
		return nil
	}))
}
