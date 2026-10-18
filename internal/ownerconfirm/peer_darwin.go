package ownerconfirm

import (
	"errors"
	"net"

	"golang.org/x/sys/unix"
)

// peerPID is the pid of the process serving the socket (LOCAL_PEERPID).
func peerPID(conn net.Conn) (int, error) {
	uc, ok := conn.(*net.UnixConn)
	if !ok {
		return 0, errors.New("not a unix socket")
	}
	raw, err := uc.SyscallConn()
	if err != nil {
		return 0, err
	}
	var pid int
	var sockErr error
	if err := raw.Control(func(fd uintptr) {
		pid, sockErr = unix.GetsockoptInt(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERPID)
	}); err != nil {
		return 0, err
	}
	if sockErr != nil {
		return 0, sockErr
	}
	if pid <= 0 {
		return 0, errors.New("no peer pid")
	}
	return pid, nil
}
