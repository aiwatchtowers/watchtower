// Package fsutil holds the small file helpers that secrets and private
// payloads share: owner-only temp files and (see atomic.go, lock.go) atomic
// rewrites and cross-process locks.
package fsutil

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

// SystemPromptTempPrefix names the 0600 temp files that hand a codex child
// its system prompt (WritePrivateTemp(SystemPromptTempPrefix+"*.txt")); the
// caller holds each (HoldTempFile) while codex runs — codex re-reads it for
// every model request — and removes it once codex has exited.
const SystemPromptTempPrefix = "wt-system-prompt-"

// HoldTempFile keeps path, a temp file a running child still reads, from
// the stale-temp sweep: it takes a shared advisory flock on the file, and
// SweepStaleTemp skips a file it cannot lock exclusively. The returned
// release removes the file and drops the lock; it is safe to call more
// than once, so defer it. "" gives a no-op. The kernel drops the lock when
// the holder dies, so a killed process's file is swept as a leftover once
// it is stale. The descriptor is close-on-exec, so the child never inherits
// the lock. If the file cannot be opened or locked, release still removes
// it, and err (never naming the file) says it is not shielded from the
// sweep, for the caller to log.
func HoldTempFile(path string) (release func(), err error) {
	if path == "" {
		return func() {}, nil
	}
	var held *os.File
	f, err := openNoBlock(path)
	if err == nil {
		if err = flockNB(int(f.Fd()), syscall.LOCK_SH); err == nil {
			held = f
		} else {
			_ = f.Close()
			err = fmt.Errorf("locking a held temp file: %w", err)
		}
	} else {
		err = fmt.Errorf("opening a held temp file: %w", unwrapPath(err))
	}
	var once sync.Once
	return func() {
		once.Do(func() {
			_ = os.Remove(path)
			if held != nil {
				_ = held.Close() // closing drops the flock
			}
		})
	}, err
}

// unwrapPath strips the *fs.PathError around err, so an error that reaches
// a log carries the errno, never the temp file's name.
func unwrapPath(err error) error {
	var pe *fs.PathError
	if errors.As(err, &pe) {
		return pe.Err
	}
	return err
}

// mayBeHeld reports whether a live process may still use path: true when
// another holder has a flock on it (HoldTempFile) and, failing closed, when
// the probe cannot tell — the file cannot be opened or locked for any
// reason but its being gone. err is that probe failure (nil for a plain
// hold), for the sweep to report: the file is kept, and a later sweep
// retries it.
func mayBeHeld(path string) (held bool, err error) {
	f, err := openNoBlock(path)
	if errors.Is(err, fs.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return true, unwrapPath(err)
	}
	defer func() { _ = f.Close() }()
	switch err := flockNB(int(f.Fd()), syscall.LOCK_EX); {
	case errors.Is(err, syscall.EWOULDBLOCK):
		return true, nil
	case err != nil:
		return true, err
	}
	_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
	return false, nil
}

// openNoBlock opens path read-only without blocking: a FIFO swapped in
// under a temp file's name cannot hang the caller waiting for a writer.
func openNoBlock(path string) (*os.File, error) {
	return os.OpenFile(path, os.O_RDONLY|syscall.O_NONBLOCK, 0)
}

// StaleTempPatterns are the temp files that held a prompt or an MCP config,
// this version's and older versions' (wt-chat-prompt-, wt-chat-mcp- and
// wt-mcp-*.json came before the pipes of #604), as filepath.Match patterns.
// A live call removes its own within ten minutes or holds it with a flock
// (HoldTempFile, which the sweep skips), so SweepStaleTemp may remove every
// older unheld one. staleTempKept are never swept: wt-chat-turn- files hold
// ids and live for a whole session, and wt-mcp-status- is the same family's
// session-long name, which the broad wt-mcp- pattern would otherwise catch.
var (
	StaleTempPatterns = []string{SystemPromptTempPrefix + "*", "wt-chat-prompt-*", "wt-chat-mcp-*", "wt-mcp-*.json"}
	staleTempKept     = []string{"wt-chat-turn-", "wt-mcp-status-"}
)

// SweepStaleTemp removes regular files in the system temp directory whose
// name matches one of StaleTempPatterns (and none of staleTempKept), whose last change is
// olderThan before now and that no live process holds (HoldTempFile):
// leftovers of a killed process. It returns how many
// it removed; a file that vanished meanwhile is not an error.
func SweepStaleTemp(olderThan time.Duration, now time.Time) (int, error) {
	n, err := sweepDir(os.TempDir(), isStaleTempName, true, olderThan, now)
	homes, homesErr := sweepStaleTempHomes(os.TempDir(), olderThan, now)
	return n + homes, errors.Join(err, homesErr)
}

// StaleTempHomePatterns are the private temp CODEX_HOMEs of one codex run
// (the automation agent()'s and the spec reviewer's): each holds the run's
// rollout — prompts, tool results, answers — and its owner removes it after
// the run. A live run holds the home (HoldTempHome), so SweepStaleTemp
// removes only a killed process's leftovers.
var StaleTempHomePatterns = []string{"wt-agent-codex-home-*", "wt-review-codex-home-*"}

// tempHomeHold is the file inside a temp home its live run holds.
const tempHomeHold = ".wt-hold"

// HoldTempHome shields dir, a temp home of StaleTempHomePatterns, from the
// stale-temp sweep while the run lives: it creates a hold file in dir and
// holds it (HoldTempFile). release drops the hold; the caller still removes
// dir. On an error (never naming the path) dir is not shielded, for the
// caller to log.
func HoldTempHome(dir string) (release func(), err error) {
	path := filepath.Join(dir, tempHomeHold)
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		return func() {}, fmt.Errorf("creating a temp home's hold file: %w", unwrapPath(err))
	}
	return HoldTempFile(path)
}

// sweepStaleTempHomes removes the directories in dir that match
// StaleTempHomePatterns, were last changed olderThan before now and whose
// hold file no live process holds (a home with no hold file is unheld).
func sweepStaleTempHomes(dir string, olderThan time.Duration, now time.Time) (int, error) {
	entries, err := os.ReadDir(dir)
	if errors.Is(err, fs.ErrNotExist) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("listing the temp directory: %w", unwrapPath(err))
	}
	removed := 0
	var errs []error
	for _, e := range entries {
		if !e.IsDir() || !matchesAny(StaleTempHomePatterns, e.Name()) {
			continue
		}
		info, err := e.Info()
		if errors.Is(err, fs.ErrNotExist) {
			continue
		}
		if err != nil {
			errs = append(errs, unwrapPath(err))
			continue
		}
		if now.Sub(info.ModTime()) < olderThan {
			continue
		}
		home := filepath.Join(dir, e.Name())
		held, err := mayBeHeld(filepath.Join(home, tempHomeHold))
		if err != nil {
			errs = append(errs, fmt.Errorf("probing a stale temp home, kept: %w", err))
		}
		if held {
			continue
		}
		if err := os.RemoveAll(home); err != nil {
			errs = append(errs, fmt.Errorf("removing a stale temp home: %w", unwrapPath(err)))
			continue
		}
		removed++
	}
	return removed, errors.Join(errs...)
}

func matchesAny(patterns []string, name string) bool {
	for _, pattern := range patterns {
		if ok, _ := filepath.Match(pattern, name); ok {
			return true
		}
	}
	return false
}

// SweepStaleDir removes every regular file in dir older than olderThan (a
// spool whose live files are always younger). A missing dir is a no-op.
func SweepStaleDir(dir string, olderThan time.Duration, now time.Time) (int, error) {
	return sweepDir(dir, func(string) bool { return true }, false, olderThan, now)
}

// sweepDir removes dir's regular files older than olderThan whose name
// match accepts; with skipHeld, it keeps any a live process may hold
// (mayBeHeld).
func sweepDir(dir string, match func(name string) bool, skipHeld bool, olderThan time.Duration, now time.Time) (int, error) {
	entries, err := os.ReadDir(dir)
	if errors.Is(err, fs.ErrNotExist) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("listing %s: %w", dir, err)
	}
	removed := 0
	var errs []error
	for _, e := range entries {
		if !e.Type().IsRegular() || !match(e.Name()) {
			continue
		}
		info, err := e.Info()
		if errors.Is(err, fs.ErrNotExist) {
			continue
		}
		if err != nil {
			errs = append(errs, err)
			continue
		}
		if now.Sub(info.ModTime()) < olderThan {
			continue
		}
		if skipHeld {
			held, err := mayBeHeld(filepath.Join(dir, e.Name()))
			if err != nil {
				errs = append(errs, fmt.Errorf("probing a stale temp file, kept: %w", err))
			}
			if held {
				continue
			}
		}
		if err := os.Remove(filepath.Join(dir, e.Name())); err != nil && !errors.Is(err, fs.ErrNotExist) {
			errs = append(errs, err)
			continue
		}
		removed++
	}
	return removed, errors.Join(errs...)
}

// isStaleTempName reports whether name is a prompt or MCP-config temp file.
func isStaleTempName(name string) bool {
	for _, kept := range staleTempKept {
		if strings.HasPrefix(name, kept) {
			return false
		}
	}
	return matchesAny(StaleTempPatterns, name)
}

// WritePrivateTemp writes content to a fresh 0600 file in the system temp
// directory (os.CreateTemp pattern) and returns its path. The caller removes
// the file once nothing reads it any more. Used to hand a subprocess data
// that must not sit on its argv — visible in `ps`, and bounded by ARG_MAX.
func WritePrivateTemp(pattern, content string) (string, error) {
	f, err := os.CreateTemp("", pattern)
	if err != nil {
		return "", fmt.Errorf("creating private temp file: %w", err)
	}
	path := f.Name()
	if err := f.Chmod(0o600); err != nil {
		f.Close()
		os.Remove(path)
		return "", fmt.Errorf("setting mode on %s: %w", path, err)
	}
	if _, err := f.WriteString(content); err != nil {
		f.Close()
		os.Remove(path)
		return "", fmt.Errorf("writing %s: %w", path, err)
	}
	if err := f.Close(); err != nil {
		os.Remove(path)
		return "", fmt.Errorf("closing %s: %w", path, err)
	}
	return path, nil
}
