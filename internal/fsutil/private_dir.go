package fsutil

import "os"

// MakePrivateDir creates dir 0700, and narrows one an older install left
// 0755 (MkdirAll never changes an existing directory's mode): the workspace
// and ~/.config/watchtower hold the database, logs and tokens.
func MakePrivateDir(dir string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	return os.Chmod(dir, 0o700)
}
