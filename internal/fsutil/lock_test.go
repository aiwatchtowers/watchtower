package fsutil

import (
	"context"
	"errors"
	"path/filepath"
	"testing"
	"time"
)

func TestLockFile_ExcludesUntilUnlock(t *testing.T) {
	path := filepath.Join(t.TempDir(), "x.lock")
	unlock, err := LockFile(context.Background(), path)
	if err != nil {
		t.Fatalf("first lock: %v", err)
	}

	acquired := make(chan func(), 1)
	go func() {
		u, err := LockFile(context.Background(), path)
		if err != nil {
			t.Errorf("second lock: %v", err)
			close(acquired)
			return
		}
		acquired <- u
	}()

	select {
	case <-acquired:
		t.Fatal("second lock acquired while the first is held")
	case <-time.After(150 * time.Millisecond):
	}
	unlock()
	select {
	case u, ok := <-acquired:
		if ok {
			u()
		}
	case <-time.After(5 * time.Second):
		t.Fatal("second lock not acquired after unlock")
	}
}

func TestLockFile_ContextCancelStopsWaiting(t *testing.T) {
	path := filepath.Join(t.TempDir(), "x.lock")
	unlock, err := LockFile(context.Background(), path)
	if err != nil {
		t.Fatalf("first lock: %v", err)
	}
	defer unlock()

	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	if _, err := LockFile(ctx, path); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("err = %v, want context.DeadlineExceeded", err)
	}
}

func TestTryLockFile_SecondHolderGetsFalse(t *testing.T) {
	path := filepath.Join(t.TempDir(), "x.lock")
	unlock, ok, err := TryLockFile(path)
	if err != nil || !ok {
		t.Fatalf("first: ok=%v err=%v", ok, err)
	}
	if _, ok2, err := TryLockFile(path); err != nil || ok2 {
		t.Fatalf("second: ok=%v err=%v, want false, nil", ok2, err)
	}
	unlock()
	unlock2, ok3, err := TryLockFile(path)
	if err != nil || !ok3 {
		t.Fatalf("after unlock: ok=%v err=%v", ok3, err)
	}
	unlock2()
}
