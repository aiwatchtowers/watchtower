package platform

import (
	"errors"
	"fmt"
	"io/fs"
	"net"
	"os"
	"sync"
	"time"

	"golang.org/x/sys/unix"
)

// ErrSocketBusy is ListenLocked's error when another process serves the
// socket.
var ErrSocketBusy = errors.New("platform: another process serves this socket")

// ListenLocked binds the unix socket at socketPath (0600) for the one
// process holding <socketPath>.lock (an exclusive, non-blocking flock kept
// until the listener closes). A held lock, or a live listener answering on
// the path, is ErrSocketBusy; a stale socket file is replaced; any other
// file there is refused. The folder must exist.
func ListenLocked(socketPath string) (net.Listener, error) {
	lock, err := os.OpenFile(socketPath+".lock", os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, fmt.Errorf("platform: open socket lock: %w", err)
	}
	if err := unix.Flock(int(lock.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		_ = lock.Close()
		if errors.Is(err, unix.EWOULDBLOCK) {
			return nil, ErrSocketBusy
		}
		return nil, fmt.Errorf("platform: lock socket: %w", err)
	}
	if c, err := net.DialTimeout("unix", socketPath, time.Second); err == nil {
		_ = c.Close()
		_ = lock.Close()
		return nil, ErrSocketBusy
	}
	if fi, err := os.Lstat(socketPath); err == nil {
		if fi.Mode().Type() != fs.ModeSocket {
			_ = lock.Close()
			return nil, fmt.Errorf("platform: socket path %s is not a socket", socketPath)
		}
		if err := os.Remove(socketPath); err != nil {
			_ = lock.Close()
			return nil, fmt.Errorf("platform: remove stale socket: %w", err)
		}
	}
	l, err := net.Listen("unix", socketPath)
	if err != nil {
		_ = lock.Close()
		return nil, fmt.Errorf("platform: listen on socket: %w", err)
	}
	if err := os.Chmod(socketPath, 0o600); err != nil {
		_ = l.Close()
		_ = lock.Close()
		return nil, fmt.Errorf("platform: chmod socket: %w", err)
	}
	return &lockedListener{Listener: l, lock: lock}, nil
}

// lockedListener releases the lock when the listener closes.
type lockedListener struct {
	net.Listener
	lock *os.File
	once sync.Once
}

func (l *lockedListener) Close() error {
	err := l.Listener.Close()
	l.once.Do(func() { _ = l.lock.Close() })
	return err //nolint:wrapcheck // passes the listener's own close error through
}
