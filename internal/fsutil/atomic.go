package fsutil

import (
	"fmt"
	"os"
	"path/filepath"
)

// WriteFileAtomic replaces path with data so that a reader — or a crash —
// sees either the old file or the new one, never a truncated mix: it writes
// a fresh temp file in the same directory (so the rename stays on one
// filesystem), syncs it, then renames it over path. The result has exactly
// mode perm, whatever an existing file's mode was (os.WriteFile keeps an
// existing file's mode). Token stores use it: a torn write of a rotating
// refresh token forces a re-login.
func WriteFileAtomic(path string, data []byte, perm os.FileMode) (err error) {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, filepath.Base(path)+".tmp-*") // created 0600
	if err != nil {
		return fmt.Errorf("creating temp file for %s: %w", filepath.Base(path), err)
	}
	defer func() {
		if err != nil {
			_ = os.Remove(tmp.Name())
		}
	}()
	if err := tmp.Chmod(perm); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("setting mode on temp file for %s: %w", filepath.Base(path), err)
	}
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("writing temp file for %s: %w", filepath.Base(path), err)
	}
	// Durable before visible: without the sync a crash right after the
	// rename can still surface an empty file under the new name.
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("syncing temp file for %s: %w", filepath.Base(path), err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("closing temp file for %s: %w", filepath.Base(path), err)
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		return fmt.Errorf("renaming temp file over %s: %w", filepath.Base(path), err)
	}
	return nil
}
