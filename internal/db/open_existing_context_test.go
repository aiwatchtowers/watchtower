package db

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"watchtower/internal/db/lockmetrics"
	"watchtower/internal/sqlcipher"
)

// sha256File is the sha256 of the file at p.
func sha256File(t *testing.T, p string) [sha256.Size]byte {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return sha256.Sum256(b)
}

// leftOverWALCopy builds a WAL database whose rows live only in the -wal
// file and copies its three files, while the writer is still open, into a
// fresh directory. It returns the copy's main-file path.
func leftOverWALCopy(t *testing.T) string {
	t.Helper()
	src := filepath.Join(t.TempDir(), "w.db")
	w := sql.OpenDB(&sqlcipher.Connector{Path: "file:" + src, Params: "mode=rwc&_busy_timeout=500"})
	defer func() { _ = w.Close() }()
	w.SetMaxOpenConns(1)
	for _, q := range []string{
		"PRAGMA journal_mode=WAL",
		"PRAGMA wal_autocheckpoint=0",
		"CREATE TABLE t(x)",
		"INSERT INTO t(x) VALUES (1), (2), (3)",
	} {
		if _, err := w.Exec(q); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	dst := filepath.Join(t.TempDir(), "w.db")
	for _, suffix := range []string{"", "-wal", "-shm"} {
		b, err := os.ReadFile(src + suffix)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(dst+suffix, b, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return dst
}

func TestOpenExistingContext_CancelledContext(t *testing.T) {
	p := filepath.Join(t.TempDir(), "missing.db")
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	d, err := OpenExistingContext(ctx, p, 500*time.Millisecond)
	if err == nil {
		_ = d.Close()
		t.Fatal("open with a cancelled context succeeded")
	}
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("err = %v, want context.Canceled", err)
	}
	if _, statErr := os.Stat(p); !errors.Is(statErr, os.ErrNotExist) {
		t.Fatalf("a file was created at the missing path: %v", statErr)
	}
}

func TestOpenExistingContext_LeftOverWALMainFileUntouched(t *testing.T) {
	p := leftOverWALCopy(t)
	mainBefore := sha256File(t, p)
	walBefore := sha256File(t, p+"-wal")

	d, err := OpenExistingContext(context.Background(), p, 500*time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	var n int
	if err := d.QueryRow("SELECT count(*) FROM t").Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 3 {
		t.Fatalf("count = %d, want 3", n)
	}
	if err := d.Close(); err != nil {
		t.Fatal(err)
	}
	if sha256File(t, p) != mainBefore {
		t.Fatal("main database file changed")
	}
	if sha256File(t, p+"-wal") != walBefore {
		t.Fatal("-wal file changed")
	}
}

func TestOpenExistingContext_QueryOnly(t *testing.T) {
	p := leftOverWALCopy(t)
	d, err := OpenExistingContext(context.Background(), p, 500*time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = d.Close() })
	if _, err := d.Exec("INSERT INTO t(x) VALUES (4)"); err == nil {
		t.Fatal("INSERT succeeded on a query_only handle")
	}
}

func TestOpenExistingContext_NoDblockSink(t *testing.T) {
	p := leftOverWALCopy(t)
	lockmetrics.Configure(p)
	t.Cleanup(func() { lockmetrics.Configure("") })
	if !lockmetrics.Enabled() {
		t.Skip("lock metrics are off in this environment")
	}
	d, err := OpenExistingContext(context.Background(), p, 500*time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = d.Close() })
	if lockmetrics.Enabled() {
		t.Fatal("lock-metrics sink still on after OpenExistingContext")
	}
}
