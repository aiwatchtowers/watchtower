package chat

import (
	"errors"
	"os"
	"path/filepath"
	"strconv"
)

// errOtherExecutable: the client runs another program than this session.
var errOtherExecutable = errors.New("the client runs another executable")

// sameExecutable checks that pid (read from procRoot, the proc file
// system) runs the executable own, both with their symlinks resolved.
func sameExecutable(procRoot string, pid int, own string) error {
	if pid <= 1 {
		return errOtherExecutable
	}
	peer, err := filepath.EvalSymlinks(filepath.Join(procRoot, strconv.Itoa(pid), "exe"))
	if err != nil {
		return errOtherExecutable
	}
	mine, err := filepath.EvalSymlinks(own)
	if err != nil || mine != peer {
		return errOtherExecutable
	}
	if _, err := os.Stat(peer); err != nil {
		return errOtherExecutable
	}
	return nil
}
