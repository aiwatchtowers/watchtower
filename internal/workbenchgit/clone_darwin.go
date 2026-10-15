//go:build darwin

package workbenchgit

import (
	"errors"

	"golang.org/x/sys/unix"
)

// clonefileNative is clonefile(2): a copy-on-write copy, recursive for a
// directory, never following a symlink at src.
func clonefileNative(src, dst string) error {
	err := unix.Clonefile(src, dst, unix.CLONE_NOFOLLOW)
	if errors.Is(err, unix.ENOTSUP) || errors.Is(err, unix.EXDEV) {
		return errCloneUnsupported
	}
	return err
}
