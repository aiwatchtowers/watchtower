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
	"time"
)

// SystemPromptTempPrefix names the 0600 temp files that hand a claude/codex
// child its system prompt (WritePrivateTemp(SystemPromptTempPrefix+"*.txt")).
// The caller removes each after the call; SweepStalePrivateTemp clears the
// ones a killed process left behind.
const SystemPromptTempPrefix = "wt-system-prompt-"

// SweepStalePrivateTemp removes regular files in the system temp directory
// whose name starts with prefix and whose last change is olderThan before
// now: crash leftovers of WritePrivateTemp, which a live call never keeps
// that long. It returns how many it removed; a file that vanished meanwhile
// is not an error.
func SweepStalePrivateTemp(prefix string, olderThan time.Duration, now time.Time) (int, error) {
	dir := os.TempDir()
	entries, err := os.ReadDir(dir)
	if err != nil {
		return 0, fmt.Errorf("listing temp dir: %w", err)
	}
	removed := 0
	var errs []error
	for _, e := range entries {
		if !e.Type().IsRegular() || !strings.HasPrefix(e.Name(), prefix) {
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
		if err := os.Remove(filepath.Join(dir, e.Name())); err != nil && !errors.Is(err, fs.ErrNotExist) {
			errs = append(errs, err)
			continue
		}
		removed++
	}
	return removed, errors.Join(errs...)
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
