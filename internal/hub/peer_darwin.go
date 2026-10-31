//go:build darwin

package hub

import (
	"fmt"
	"net"

	"golang.org/x/sys/unix"
)

// socketPeerUID is the uid of the process at the other end of c
// (LOCAL_PEERCRED).
func socketPeerUID(c *net.UnixConn) (int, error) {
	raw, err := c.SyscallConn()
	if err != nil {
		return 0, fmt.Errorf("hub: control socket peer: %w", err)
	}
	var (
		cred *unix.Xucred
		cerr error
	)
	if err := raw.Control(func(fd uintptr) {
		cred, cerr = unix.GetsockoptXucred(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERCRED)
	}); err != nil {
		return 0, fmt.Errorf("hub: control socket peer: %w", err)
	}
	if cerr != nil {
		return 0, fmt.Errorf("hub: control socket peer: %w", cerr)
	}
	return int(cred.Uid), nil
}
