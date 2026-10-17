package db

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"testing"
	"time"
)

// interruptQuery runs a query that cannot finish before its context
// deadline, so SQLite interrupts it. modernc then reports the connection as
// bad and database/sql replaces it with a fresh one on the next call —
// which interruptQuery checks with a per-connection marker (cache_size, a
// pragma no opener sets and query_only does not refuse), so the callers'
// assertions never run against the old connection.
func interruptQuery(t *testing.T, d *DB) {
	t.Helper()
	const marker = -1234
	if _, err := d.Exec(fmt.Sprintf("PRAGMA cache_size=%d", marker)); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if got := pragmaInt(t, d, "cache_size"); got == marker {
			t.Fatal("the interrupted connection was not replaced; the test proves nothing")
		}
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	var n int64
	err := d.QueryRowContext(ctx,
		`WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c) SELECT count(*) FROM c`).Scan(&n)
	if err == nil {
		t.Fatal("endless query finished")
	}
	if !errors.Is(err, context.DeadlineExceeded) && ctx.Err() == nil {
		t.Fatalf("query failed for another reason: %v", err)
	}
}

func pragmaInt(t *testing.T, d *DB, name string) int64 {
	t.Helper()
	var v int64
	if err := d.QueryRow("PRAGMA " + name).Scan(&v); err != nil {
		t.Fatalf("reading %s: %v", name, err)
	}
	return v
}

// TestPragmasSurviveInterruptedQuery: a context-cancelled query makes the
// pool drop its connection; the replacement must carry the same pragmas —
// Open's busy_timeout, foreign_keys and synchronous, and whatever
// SetBusyTimeout and SetReadOnly set on the handle afterwards.
func TestPragmasSurviveInterruptedQuery(t *testing.T) {
	t.Run("Open", func(t *testing.T) {
		d, err := Open(filepath.Join(t.TempDir(), "watchtower.db"))
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = d.Close() })
		interruptQuery(t, d)
		if got := pragmaInt(t, d, "busy_timeout"); got != busyTimeoutMS {
			t.Errorf("busy_timeout = %d, want %d", got, busyTimeoutMS)
		}
		if got := pragmaInt(t, d, "foreign_keys"); got != 1 {
			t.Errorf("foreign_keys = %d, want 1", got)
		}
		if got := pragmaInt(t, d, "synchronous"); got != 1 { // NORMAL
			t.Errorf("synchronous = %d, want 1 (NORMAL)", got)
		}
	})

	t.Run("SetBusyTimeout and SetReadOnly", func(t *testing.T) {
		d, err := Open(filepath.Join(t.TempDir(), "watchtower.db"))
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = d.Close() })
		if err := d.SetBusyTimeout(1500 * time.Millisecond); err != nil {
			t.Fatal(err)
		}
		if err := d.SetReadOnly(); err != nil {
			t.Fatal(err)
		}
		interruptQuery(t, d)
		if got := pragmaInt(t, d, "busy_timeout"); got != 1500 {
			t.Errorf("busy_timeout = %d, want 1500", got)
		}
		if got := pragmaInt(t, d, "query_only"); got != 1 {
			t.Errorf("query_only = %d, want 1", got)
		}
		if _, err := d.Exec(`CREATE TABLE fence_probe (x INTEGER)`); err == nil {
			t.Error("a write went through on a read-only handle after a reconnect")
		}
	})

	t.Run("SetBusyTimeout zero", func(t *testing.T) {
		d, err := Open(filepath.Join(t.TempDir(), "watchtower.db"))
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = d.Close() })
		if err := d.SetBusyTimeout(0); err != nil {
			t.Fatal(err)
		}
		interruptQuery(t, d)
		if got := pragmaInt(t, d, "busy_timeout"); got != 0 {
			t.Errorf("busy_timeout = %d, want 0 (the explicit value, not the DSN's)", got)
		}
	})

	t.Run("OpenExistingRW", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), "watchtower.db")
		seed, err := Open(path)
		if err != nil {
			t.Fatal(err)
		}
		_ = seed.Close()
		d, err := OpenExistingRW(path, 500*time.Millisecond)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = d.Close() })
		if err := d.SetBusyTimeout(800 * time.Millisecond); err != nil {
			t.Fatal(err)
		}
		interruptQuery(t, d)
		if got := pragmaInt(t, d, "busy_timeout"); got != 800 {
			t.Errorf("busy_timeout = %d, want 800", got)
		}
		if got := pragmaInt(t, d, "foreign_keys"); got != 1 {
			t.Errorf("foreign_keys = %d, want 1", got)
		}
	})
}
