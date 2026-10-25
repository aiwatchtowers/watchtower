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

// SystemPromptTempPrefix names the 0600 temp files that hand a codex child
// its system prompt (WritePrivateTemp(SystemPromptTempPrefix+"*.txt")); the
// caller removes each once codex has read it.
const SystemPromptTempPrefix = "wt-system-prompt-"

// StaleTempPrefixes are the temp files that held a prompt or an MCP config,
// this version's and older versions' (wt-chat-prompt-, wt-chat-mcp-, wt-mcp-
// came before the pipes of #604). A live call never keeps one ten minutes,
// so SweepStaleTemp may remove every older one. Not wt-chat-turn- or
// wt-mcp-status-: they hold ids and live for a whole session.
var StaleTempPrefixes = []string{SystemPromptTempPrefix, "wt-chat-prompt-", "wt-chat-mcp-", "wt-mcp-"}

// SweepStaleTemp removes regular files in the system temp directory whose
// name starts with one of StaleTempPrefixes and whose last change is
// olderThan before now: leftovers of a killed process. It returns how many
// it removed; a file that vanished meanwhile is not an error.
func SweepStaleTemp(olderThan time.Duration, now time.Time) (int, error) {
	return sweepDir(os.TempDir(), StaleTempPrefixes, olderThan, now)
}

// SweepStaleDir removes every regular file in dir older than olderThan (a
// spool whose live files are always younger). A missing dir is a no-op.
func SweepStaleDir(dir string, olderThan time.Duration, now time.Time) (int, error) {
	return sweepDir(dir, nil, olderThan, now)
}

// sweepDir removes dir's regular files older than olderThan whose name
// starts with one of prefixes (every file when prefixes is nil).
func sweepDir(dir string, prefixes []string, olderThan time.Duration, now time.Time) (int, error) {
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
		if !e.Type().IsRegular() || (prefixes != nil && !hasAnyPrefix(e.Name(), prefixes)) {
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

func hasAnyPrefix(name string, prefixes []string) bool {
	for _, p := range prefixes {
		if strings.HasPrefix(name, p) {
			return true
		}
	}
	return false
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
