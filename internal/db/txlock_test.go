package db

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"
)

// openTwoWriters opens two independent handles (two processes, in effect) on
// one file-backed WAL database with a scratch table. A file is required: every
// :memory: connection is its own database.
func openTwoWriters(t *testing.T) (a, b *DB) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "txlock.db")
	a, err := Open(path)
	if err != nil {
		t.Fatalf("open A: %v", err)
	}
	t.Cleanup(func() { a.Close() })
	b, err = Open(path)
	if err != nil {
		t.Fatalf("open B: %v", err)
	}
	t.Cleanup(func() { b.Close() })
	if _, err := a.Exec(`CREATE TABLE txlock_probe (n INTEGER NOT NULL)`); err != nil {
		t.Fatalf("create table: %v", err)
	}
	if _, err := a.Exec(`INSERT INTO txlock_probe (n) VALUES (0)`); err != nil {
		t.Fatalf("seed: %v", err)
	}
	return a, b
}

// A write transaction that reads before it writes must not fail when another
// connection commits in between. Under a DEFERRED begin the read pins a WAL
// snapshot and the later upgrade to a write lock fails at once with
// SQLITE_BUSY_SNAPSHOT — busy_timeout never applies to it (the 2026-09-30
// Approve failure class). Begin must therefore take the write lock up front
// (BEGIN IMMEDIATE), so the other writer waits instead.
func TestTxLock_BeginTakesWriteLockUpFront(t *testing.T) {
	a, b := openTwoWriters(t)

	tx, err := a.Begin()
	if err != nil {
		t.Fatalf("begin A: %v", err)
	}
	defer func() { _ = tx.Rollback() }()
	var n int
	if err := tx.QueryRow(`SELECT n FROM txlock_probe`).Scan(&n); err != nil {
		t.Fatalf("read in A: %v", err)
	}

	// With the write lock held by A, B cannot write until A commits: not
	// waiting at all, B's write is refused busy (the wait itself is
	// busy_timeout's).
	if err := b.SetBusyTimeout(0); err != nil {
		t.Fatal(err)
	}
	if _, err := b.Exec(`UPDATE txlock_probe SET n = n + 100`); !IsBusy(err) {
		t.Fatalf("B's write while A's write transaction was open: want busy, got %v: Begin did not take the write lock", err)
	}

	if _, err := tx.Exec(`UPDATE txlock_probe SET n = ?`, n+1); err != nil {
		t.Fatalf("write in A after a concurrent writer: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit A: %v", err)
	}
	if _, err := b.Exec(`UPDATE txlock_probe SET n = n + 100`); err != nil {
		t.Fatalf("B's write after A committed: %v", err)
	}

	if err := a.QueryRow(`SELECT n FROM txlock_probe`).Scan(&n); err != nil {
		t.Fatalf("final read: %v", err)
	}
	if n != 101 {
		t.Fatalf("n = %d, want 101 (A's +1 then B's +100, serialized)", n)
	}
}

// A transaction explicitly opened read-only stays DEFERRED: it must never take
// the write lock and block a writer in another process.
func TestTxLock_ReadOnlyTxDoesNotTakeWriteLock(t *testing.T) {
	a, b := openTwoWriters(t)

	tx, err := a.BeginTx(context.Background(), &sql.TxOptions{ReadOnly: true})
	if err != nil {
		t.Fatalf("begin read-only A: %v", err)
	}
	defer func() { _ = tx.Rollback() }()
	var n int
	if err := tx.QueryRow(`SELECT n FROM txlock_probe`).Scan(&n); err != nil {
		t.Fatalf("read in A: %v", err)
	}

	// Not waiting at all, B's write still goes through.
	if err := b.SetBusyTimeout(0); err != nil {
		t.Fatal(err)
	}
	if _, err := b.Exec(`UPDATE txlock_probe SET n = n + 1`); err != nil {
		t.Fatalf("B's write during A's read-only tx (blocked behind it?): %v", err)
	}
}

// A query_only handle (the dev-mode `watchtower mcp`, DEV-01) runs a read-only
// transaction normally, while a write transaction is refused at BEGIN — the
// immediate begin asks for the write lock query_only forbids, so the fence
// fails closed before any statement runs.
func TestTxLock_ReadOnlyHandleTransactions(t *testing.T) {
	a, _ := openTwoWriters(t)
	if err := a.SetReadOnly(); err != nil {
		t.Fatalf("SetReadOnly: %v", err)
	}
	tx, err := a.BeginTx(context.Background(), &sql.TxOptions{ReadOnly: true})
	if err != nil {
		t.Fatalf("read-only begin on read-only handle: %v", err)
	}
	var n int
	if err := tx.QueryRow(`SELECT n FROM txlock_probe`).Scan(&n); err != nil {
		t.Fatalf("read on read-only handle: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit read-only tx: %v", err)
	}

	wtx, err := a.Begin()
	if err == nil {
		_ = wtx.Rollback()
		t.Fatal("write transaction began on a query_only handle")
	}
}
