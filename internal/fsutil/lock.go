package fsutil

import (
	"context"
	"errors"
	"fmt"
	"os"
	"syscall"
	"time"
)

// lockPollInterval is how often LockFile retries a held lock.
const lockPollInterval = 25 * time.Millisecond

// LockFile takes an exclusive advisory flock on path (created 0600 if
// missing), waiting until it is free or ctx is done, and returns the unlock
// func. It serializes a read-modify-write of a shared file across processes —
// the daemon and a concurrent CLI refreshing the same rotating OAuth token —
// where an in-process mutex cannot. The kernel drops the lock if the holder
// dies, so a crashed process never wedges the others. The lock file is left in
// place on unlock: deleting it would let a waiter lock an unlinked inode while
// a newcomer locks a fresh one.
func LockFile(ctx context.Context, path string) (func(), error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, fmt.Errorf("opening lock file: %w", err)
	}
	for {
		err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			return func() {
				_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
				_ = f.Close()
			}, nil
		}
		if !errors.Is(err, syscall.EWOULDBLOCK) && !errors.Is(err, syscall.EINTR) {
			_ = f.Close()
			return nil, fmt.Errorf("locking %s: %w", path, err)
		}
		select {
		case <-ctx.Done():
			_ = f.Close()
			return nil, fmt.Errorf("waiting for lock %s: %w", path, ctx.Err())
		case <-time.After(lockPollInterval):
		}
	}
}
