package extract

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// StaleTempAge is the age past which a spooled file is a crash leftover. A
// live extraction touches its file within minutes (the download is bounded
// at 5 minutes and every write moves the mtime; the PDF parse and OCR that
// follow are bounded at 60 s each), so ten minutes never catches a file in
// use — even one belonging to a concurrent `confluence sync`.
const StaleTempAge = 10 * time.Minute

// spoolPrefix names every file spool creates.
const spoolPrefix = "att-"

// SweepStale removes spooled files older than StaleTempAge: Extract
// removes its file on every path, but a process killed mid-extraction
// (SIGKILL, power loss) runs no deferred cleanup (EXT-03). The engine
// calls it at the start of each run. A missing dir is a no-op.
func (x *Extractor) SweepStale(now time.Time) (int, error) {
	if x.TempDir == "" {
		return 0, nil
	}
	entries, err := os.ReadDir(x.TempDir)
	if errors.Is(err, fs.ErrNotExist) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("extract: listing temp dir: %w", err)
	}
	removed := 0
	var errs []error
	for _, e := range entries {
		if !e.Type().IsRegular() || !strings.HasPrefix(e.Name(), spoolPrefix) {
			continue
		}
		info, err := e.Info()
		if err != nil || now.Sub(info.ModTime()) < StaleTempAge {
			continue
		}
		if err := os.Remove(filepath.Join(x.TempDir, e.Name())); err != nil && !errors.Is(err, fs.ErrNotExist) {
			errs = append(errs, err)
			continue
		}
		removed++
	}
	return removed, errors.Join(errs...)
}
