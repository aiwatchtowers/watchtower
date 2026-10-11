package db

import (
	"errors"
	"fmt"
	"path/filepath"
	"testing"
	"time"
)

func TestIsBusy(t *testing.T) {
	path := filepath.Join(t.TempDir(), "watchtower.db")
	holder, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = holder.Close() })
	if _, err := holder.CreateWorkbench("acme", t.TempDir()); err != nil {
		t.Fatal(err)
	}
	lockExclusively(t, holder)
	rw, err := OpenExistingRW(path, 50*time.Millisecond)
	if err == nil {
		t.Cleanup(func() { _ = rw.Close() })
		_, err = rw.Exec(`UPDATE projects SET name = 'x'`)
	}
	if !IsBusy(err) || !IsBusy(fmt.Errorf("wrapped: %w", err)) {
		t.Fatalf("IsBusy(%v) = false", err)
	}
	if IsBusy(nil) || IsBusy(errors.New("SQLITE_BUSY in a plain message")) || IsBusy(ErrWorkbenchNotFound) {
		t.Fatal("IsBusy is true for a non-SQLite error")
	}
}
