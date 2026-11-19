package chat

import (
	"errors"
	"testing"

	"github.com/stretchr/testify/require"
	"golang.org/x/sys/unix"
)

// waitProcessExit blocks until pid has exited (a pidfd turns readable): a
// process event, never a poll. A pid already gone returns at once.
func waitProcessExit(t *testing.T, pid int) {
	t.Helper()
	fd, err := unix.PidfdOpen(pid, 0)
	if errors.Is(err, unix.ESRCH) {
		return // already gone
	}
	require.NoError(t, err)
	defer func() { _ = unix.Close(fd) }()
	for {
		_, err := unix.Poll([]unix.PollFd{{Fd: int32(fd), Events: unix.POLLIN}}, -1)
		if errors.Is(err, unix.EINTR) {
			continue
		}
		require.NoError(t, err)
		return
	}
}
