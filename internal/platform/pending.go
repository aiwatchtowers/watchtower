package platform

import (
	"errors"
	"net"

	"golang.org/x/sys/unix"
)

// Pending is whether bytes wait to be read on a unix connection: a
// non-blocking peek, 1 when any do, 0 when none (a closed peer is 0 too).
// A socket that speaks first uses it to refuse a client that wrote before
// the greeting (one that may have exec'd since it connected).
func Pending(c net.Conn) (int, error) {
	uc, ok := c.(*net.UnixConn)
	if !ok {
		return 0, errors.New("platform: not a unix connection")
	}
	raw, err := uc.SyscallConn()
	if err != nil {
		return 0, err //nolint:wrapcheck // the caller refuses the peer either way
	}
	var n int
	var perr error
	if err := raw.Control(func(fd uintptr) {
		n, _, perr = unix.Recvfrom(int(fd), make([]byte, 1), unix.MSG_PEEK|unix.MSG_DONTWAIT)
	}); err != nil {
		return 0, err //nolint:wrapcheck // as above
	}
	if errors.Is(perr, unix.EAGAIN) {
		return 0, nil // nothing sent yet
	}
	return n, perr //nolint:wrapcheck // as above
}
