package media

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"

	"watchtower/internal/fsutil"
)

// tempPrefix starts every temp file and directory the pass (and the image
// call's per-call work directory, "media-call-") creates.
const tempPrefix = "media-"

// staleTempAge is how old a temp entry must be before a pass start removes
// it: every live one is removed by its own item or call well within this.
const staleTempAge = 10 * time.Minute

// tempDir is <workspace>/tmp/media, the only place bytes ever land.
func tempDir(workspace string) string { return filepath.Join(workspace, "tmp", "media") }

// makeTempDir creates the 0700 temp directory.
func makeTempDir(dir string) error {
	if err := fsutil.MakePrivateDir(dir); err != nil {
		return fmt.Errorf("media: creating the temp dir: %w", err)
	}
	return nil
}

// sweepTempDir removes the media-* entries a killed pass or call left
// behind (older than staleTempAge).
func sweepTempDir(dir string, now time.Time) error {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return fmt.Errorf("media: listing the temp dir: %w", err)
	}
	var errs []error
	for _, e := range entries {
		if !strings.HasPrefix(e.Name(), tempPrefix) {
			continue
		}
		info, err := e.Info() // lstat: a symlink is judged, never followed
		if errors.Is(err, fs.ErrNotExist) {
			continue
		}
		if err != nil {
			errs = append(errs, err)
			continue
		}
		if now.Sub(info.ModTime()) < staleTempAge {
			continue
		}
		if err := os.RemoveAll(filepath.Join(dir, e.Name())); err != nil {
			errs = append(errs, err)
		}
	}
	if err := errors.Join(errs...); err != nil {
		return fmt.Errorf("media: sweeping the temp dir: %w", err)
	}
	return nil
}

// newTempFile creates a fresh 0600 media-* file in dir.
func newTempFile(dir, pattern string) (*os.File, error) {
	f, err := os.CreateTemp(dir, tempPrefix+pattern)
	if err != nil {
		return nil, openError{err}
	}
	return f, nil
}
