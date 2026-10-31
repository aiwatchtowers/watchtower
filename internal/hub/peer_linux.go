//go:build linux

package hub

import (
	"fmt"
	"net"

	"golang.org/x/sys/unix"
)

// socketPeerUID is the uid of the process at the other end of c
// (SO_PEERCRED).
func socketPeerUID(c *net.UnixConn) (int, error) {
	raw, err := c.SyscallConn()
	if err != nil {
		return 0, fmt.Errorf("hub: control socket peer: %w", err)
	}
	var (
		cred *unix.Ucred
		cerr error
	)
	if err := raw.Control(func(fd uintptr) {
		cred, cerr = unix.GetsockoptUcred(int(fd), unix.SOL_SOCKET, unix.SO_PEERCRED)
	}); err != nil {
		return 0, fmt.Errorf("hub: control socket peer: %w", err)
	}
	if cerr != nil {
		return 0, fmt.Errorf("hub: control socket peer: %w", cerr)
	}
	return int(cred.Uid), nil
}
