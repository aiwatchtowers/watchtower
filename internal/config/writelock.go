package config

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"syscall"
)

// ErrWriteLockHeld is returned by WithWriteLock when this process already
// holds the write lock on the same config path. The lock is not re-entrant:
// a nested call fails at once instead of deadlocking on its own flock.
var ErrWriteLockHeld = errors.New("config.yaml write lock already held by this process")

// ErrWriteNotLocked is a low-level writer's refusal of a path its token does
// not cover.
var ErrWriteNotLocked = errors.New("config write lock not held for this path")

// WriteLock is the token WithWriteLock hands its callback. It has no exported
// constructor, and every low-level config.yaml writer (cmd's
// writeConfigAtomic and writeConfigFile, this package's
// writeFeatureMigrationConfigBytes) takes it as its first parameter, so a
// write outside the lock does not compile. The token, and every copy of it
// (they share held), stops covering its path once the callback returns.
type WriteLock struct {
	path string
	held *atomic.Bool
}

// Covers reports whether lk is a live lock on path.
func (lk *WriteLock) Covers(path string) bool {
	return lk != nil && lk.held != nil && lk.held.Load() && lk.path == writeLockKey(path)
}

var (
	writeLocksMu sync.Mutex
	writeLocks   = map[string]bool{}
)

// WithWriteLock runs fn under an exclusive flock(2) on <configPath>.lock
// (created 0600, its directory 0700), the lock every config.yaml writer
// shares — the CLI, the daemon and the Desktop (ConfigFileLock.swift locks
// the same file). fn re-reads the file inside the lock and changes only its
// own keys, so a concurrent writer of another key is never overwritten from
// a stale snapshot. Readers take no lock: writers replace the file with an
// atomic rename.
//
// A second call for the same path while this process holds it — nested, or
// from another goroutine — returns ErrWriteLockHeld without waiting: the lock
// is not re-entrant and does not queue in-process callers, so a future
// in-process writer that can run concurrently with another must serialize
// its own callers or retry on ErrWriteLockHeld.
func WithWriteLock(configPath string, fn func(lk *WriteLock) error) error {
	key := writeLockKey(configPath)
	writeLocksMu.Lock()
	if writeLocks[key] {
		writeLocksMu.Unlock()
		return ErrWriteLockHeld
	}
	writeLocks[key] = true
	writeLocksMu.Unlock()
	defer func() {
		writeLocksMu.Lock()
		delete(writeLocks, key)
		writeLocksMu.Unlock()
	}()

	if err := os.MkdirAll(filepath.Dir(configPath), 0o700); err != nil {
		return fmt.Errorf("creating config directory: %w", err)
	}
	f, err := os.OpenFile(configPath+".lock", os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return fmt.Errorf("opening config lock file: %w", err)
	}
	defer f.Close()
	if err := flockRetry(int(f.Fd()), syscall.LOCK_EX); err != nil {
		return fmt.Errorf("locking config file: %w", err)
	}
	defer func() { _ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN) }()

	lk := &WriteLock{path: key, held: new(atomic.Bool)}
	lk.held.Store(true)
	defer lk.held.Store(false)
	return fn(lk)
}

// writeLockKey names a config path the same way however it was spelled.
func writeLockKey(configPath string) string {
	if abs, err := filepath.Abs(configPath); err == nil {
		return abs
	}
	return filepath.Clean(configPath)
}

// flockRetry takes flock(how) on fd, retrying a call a signal interrupted.
func flockRetry(fd, how int) error {
	for {
		err := syscall.Flock(fd, how)
		if !errors.Is(err, syscall.EINTR) {
			return err
		}
	}
}
