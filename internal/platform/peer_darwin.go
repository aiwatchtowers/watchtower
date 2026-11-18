//go:build darwin

package platform

import (
	"fmt"
	"net"

	"golang.org/x/sys/unix"
)

// PeerUID is the uid of the process at the other end of c
// (LOCAL_PEERCRED).
func PeerUID(c *net.UnixConn) (int, error) {
	raw, err := c.SyscallConn()
	if err != nil {
		return 0, fmt.Errorf("platform: socket peer: %w", err)
	}
	var (
		cred *unix.Xucred
		cerr error
	)
	if err := raw.Control(func(fd uintptr) {
		cred, cerr = unix.GetsockoptXucred(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERCRED)
	}); err != nil {
		return 0, fmt.Errorf("platform: socket peer: %w", err)
	}
	if cerr != nil {
		return 0, fmt.Errorf("platform: socket peer: %w", cerr)
	}
	return int(cred.Uid), nil
}

// PeerPID is the pid of the process at the other end of c (LOCAL_PEERPID).
func PeerPID(c *net.UnixConn) (int, error) {
	raw, err := c.SyscallConn()
	if err != nil {
		return 0, fmt.Errorf("platform: socket peer: %w", err)
	}
	var (
		pid  int
		perr error
	)
	if err := raw.Control(func(fd uintptr) {
		pid, perr = unix.GetsockoptInt(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERPID)
	}); err != nil {
		return 0, fmt.Errorf("platform: socket peer: %w", err)
	}
	if perr != nil {
		return 0, fmt.Errorf("platform: socket peer: %w", perr)
	}
	if pid <= 0 {
		return 0, errNoPeerPID
	}
	return pid, nil
}

// MaxSocketPath is the longest socket path sockaddr_un takes here (104
// bytes, the terminating NUL included).
const MaxSocketPath = 103
