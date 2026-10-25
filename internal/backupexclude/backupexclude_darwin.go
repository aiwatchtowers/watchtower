//go:build darwin

package backupexclude

import (
	"bytes"
	_ "embed"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"golang.org/x/sys/unix"
)

// fixture is the value `tmutil addexclusion` writes (a binary plist holding
// the string "com.apple.backupd"), captured once with `xattr -px`. The test
// fixture is also the production value.
//
//go:embed testdata/excludeitem.bin
var fixture []byte

// setxattr is the write seam; tests replace it to fail one folder.
var setxattr = unix.Setxattr

// Apply sets the Time Machine item exclusion on each folder. Symlinks are
// resolved first, so a linked folder's target gets the attribute. A folder
// that does not exist is skipped silently and never created. The attribute is
// written only when it is missing or differs from the fixture bytes. Each
// failing folder yields one error naming it; the other folders still run.
func Apply(dirs []string) []error {
	var errs []error
	for _, dir := range dirs {
		if err := applyOne(dir); err != nil {
			errs = append(errs, fmt.Errorf("%s: %w", dir, err))
		}
	}
	return errs
}

func applyOne(dir string) error {
	resolved, err := filepath.EvalSymlinks(dir)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	buf := make([]byte, len(fixture)+1)
	n, err := unix.Getxattr(resolved, Attr, buf)
	switch {
	case err == nil:
		if bytes.Equal(buf[:n], fixture) {
			return nil
		}
	case errors.Is(err, unix.ENOATTR), errors.Is(err, unix.ERANGE):
		// Missing, or a value longer than ours: write it.
	default:
		return err
	}
	return setxattr(resolved, Attr, fixture, 0)
}
