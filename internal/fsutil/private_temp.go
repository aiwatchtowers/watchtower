// Package fsutil holds the small file helpers that secrets and private
// payloads share: owner-only temp files and (see atomic.go, lock.go) atomic
// rewrites and cross-process locks.
package fsutil

import (
	"fmt"
	"os"
)

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
