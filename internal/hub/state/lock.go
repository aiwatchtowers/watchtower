package state

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"syscall"
)

// ErrLocked is AcquireLock's answer while another hub (or a CLI writing
// directly) holds the state dir.
var ErrLocked = errors.New("hub: another hub holds this state dir")

// LockFileName is the hub lock's file name inside the state dir.
const LockFileName = "hub.lock"

// Lock is the held hub lock: one hub per state dir.
type Lock struct {
	mu sync.Mutex
	f  *os.File
}

// AcquireLock takes <dir>/hub.lock (flock LOCK_EX|LOCK_NB, created 0600 in
// a 0700 dir) without waiting, and writes this process's pid into it for
// diagnostics. A held lock returns ErrLocked; the kernel frees it when the
// holder dies. The file stays on Release: deleting it would let a newcomer
// lock a fresh inode while another still holds the old one.
func AcquireLock(dir string) (*Lock, error) {
	if err := ensurePrivateDir(dir); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(filepath.Join(dir, LockFileName), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, fmt.Errorf("opening the hub lock: %w", err)
	}
	for {
		err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if !errors.Is(err, syscall.EINTR) {
			break
		}
	}
	if err != nil {
		_ = f.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, ErrLocked
		}
		return nil, fmt.Errorf("taking the hub lock: %w", err)
	}
	if err := writePID(f); err != nil {
		_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		_ = f.Close()
		return nil, err
	}
	return &Lock{f: f}, nil
}

func writePID(f *os.File) error {
	if err := f.Chmod(0o600); err != nil {
		return fmt.Errorf("tightening the hub lock: %w", err)
	}
	if err := f.Truncate(0); err != nil {
		return fmt.Errorf("writing the hub lock: %w", err)
	}
	if _, err := f.WriteAt([]byte(strconv.Itoa(os.Getpid())+"\n"), 0); err != nil {
		return fmt.Errorf("writing the hub lock: %w", err)
	}
	return nil
}

// Release frees the lock; a second call does nothing.
func (l *Lock) Release() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.f == nil {
		return nil
	}
	f := l.f
	l.f = nil
	unlockErr := syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
	closeErr := f.Close()
	if unlockErr != nil {
		return fmt.Errorf("releasing the hub lock: %w", unlockErr)
	}
	return closeErr
}
