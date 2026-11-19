package chat

import (
	"errors"
	"syscall"
	"testing"

	"github.com/stretchr/testify/require"
)

// waitProcessExit blocks until pid has exited (kqueue NOTE_EXIT): a process
// event, never a poll. A pid already gone returns at once.
func waitProcessExit(t *testing.T, pid int) {
	t.Helper()
	kq, err := syscall.Kqueue()
	require.NoError(t, err)
	defer func() { _ = syscall.Close(kq) }()
	ev := syscall.Kevent_t{Ident: uint64(pid), Filter: syscall.EVFILT_PROC,
		Flags: syscall.EV_ADD | syscall.EV_ONESHOT, Fflags: syscall.NOTE_EXIT}
	if _, err := syscall.Kevent(kq, []syscall.Kevent_t{ev}, nil, nil); errors.Is(err, syscall.ESRCH) {
		return // already gone
	} else {
		require.NoError(t, err)
	}
	out := make([]syscall.Kevent_t, 1)
	for {
		n, err := syscall.Kevent(kq, nil, out, nil)
		if errors.Is(err, syscall.EINTR) {
			continue
		}
		require.NoError(t, err)
		if n > 0 {
			return
		}
	}
}
