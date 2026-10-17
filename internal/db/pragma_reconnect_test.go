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

func wantPragma(t *testing.T, d *DB, name string, want int64) {
	t.Helper()
	if got := pragmaInt(t, d, name); got != want {
		t.Errorf("%s = %d, want %d", name, got, want)
	}
}

func mustOK(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

// openTemp opens a fresh database file through Open.
func openTemp(t *testing.T) (*DB, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "watchtower.db")
	d, err := Open(path)
	mustOK(t, err)
	t.Cleanup(func() { _ = d.Close() })
	return d, path
}

// TestPragmasSurviveInterruptedQuery*: a context-cancelled query makes the
// pool drop its connection; the replacement must carry the same pragmas —
// Open's busy_timeout, foreign_keys and synchronous, and whatever
// SetBusyTimeout and SetReadOnly set on the handle afterwards.
func TestPragmasSurviveInterruptedQuery_Open(t *testing.T) {
	d, _ := openTemp(t)
	interruptQuery(t, d)
	wantPragma(t, d, "busy_timeout", busyTimeoutMS)
	wantPragma(t, d, "foreign_keys", 1)
	wantPragma(t, d, "synchronous", 1) // NORMAL
}

func TestPragmasSurviveInterruptedQuery_SetBusyTimeoutAndReadOnly(t *testing.T) {
	d, _ := openTemp(t)
	mustOK(t, d.SetBusyTimeout(1500*time.Millisecond))
	mustOK(t, d.SetReadOnly())
	interruptQuery(t, d)
	wantPragma(t, d, "busy_timeout", 1500)
	wantPragma(t, d, "query_only", 1)
	if _, err := d.Exec(`CREATE TABLE fence_probe (x INTEGER)`); err == nil {
		t.Error("a write went through on a read-only handle after a reconnect")
	}
}

// An explicit 0 is the handle's value, not "fall back to the DSN's".
func TestPragmasSurviveInterruptedQuery_SetBusyTimeoutZero(t *testing.T) {
	d, _ := openTemp(t)
	mustOK(t, d.SetBusyTimeout(0))
	interruptQuery(t, d)
	wantPragma(t, d, "busy_timeout", 0)
}

func TestPragmasSurviveInterruptedQuery_OpenExistingRW(t *testing.T) {
	seed, path := openTemp(t)
	_ = seed.Close()
	d, err := OpenExistingRW(path, 500*time.Millisecond)
	mustOK(t, err)
	t.Cleanup(func() { _ = d.Close() })
	mustOK(t, d.SetBusyTimeout(800*time.Millisecond))
	interruptQuery(t, d)
	wantPragma(t, d, "busy_timeout", 800)
	wantPragma(t, d, "foreign_keys", 1)
}
