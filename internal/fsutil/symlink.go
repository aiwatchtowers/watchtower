package fsutil

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// NoSymlinkComponents reports whether no component of the absolute path —
// from the root down to path itself — is a symbolic link. It lstats each
// component top-down and stops at the first link, so no link is ever
// followed: a stored folder whose folder or ancestor was later replaced by a
// link (one into a privacy-protected folder, say) answers false. An lstat
// failure, a missing component included, is returned as the error.
func NoSymlinkComponents(path string) (bool, error) {
	if !filepath.IsAbs(path) {
		return false, fmt.Errorf("%q is not an absolute path", path)
	}
	cur := string(filepath.Separator)
	for part := range strings.SplitSeq(filepath.Clean(path), string(filepath.Separator)) {
		if part == "" {
			continue
		}
		cur = filepath.Join(cur, part)
		fi, err := os.Lstat(cur)
		if err != nil {
			return false, err
		}
		if fi.Mode()&fs.ModeSymlink != 0 {
			return false, nil
		}
	}
	return true, nil
}
