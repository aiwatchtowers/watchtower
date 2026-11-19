package sqlcipher

import (
	"crypto/sha256"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// fileFacts is a file's size and sha256.
type fileFacts struct {
	size int64
	sum  [sha256.Size]byte
}

func factsOf(t *testing.T, p string) fileFacts {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return fileFacts{size: int64(len(b)), sum: sha256.Sum256(b)}
}

func copyFile(t *testing.T, from, to string) {
	t.Helper()
	b, err := os.ReadFile(from)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(to, b, 0o600); err != nil {
		t.Fatal(err)
	}
}

// leftOverWAL builds a WAL database whose rows live only in the -wal file
// and copies the three files, while the writer is still open, into n fresh
// directories. It returns the copied main-file paths.
func leftOverWAL(t *testing.T, n int) []string {
	t.Helper()
	src := filepath.Join(t.TempDir(), "w.db")
	w := sql.OpenDB(&Connector{Path: "file:" + src, Params: "mode=rwc&_busy_timeout=500"})
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
	out := make([]string, 0, n)
	for range n {
		dst := filepath.Join(t.TempDir(), "w.db")
		for _, suffix := range []string{"", "-wal", "-shm"} {
			copyFile(t, src+suffix, dst+suffix)
		}
		out = append(out, dst)
	}
	return out
}

// readCopy opens p read-only, checks the three rows and closes the handle.
func readCopy(t *testing.T, p string, noCkpt bool) {
	t.Helper()
	d := sql.OpenDB(&Connector{
		Path:                "file:" + p,
		Params:              "mode=rw&_busy_timeout=500&_query_only=1",
		NoCheckpointOnClose: noCkpt,
	})
	var n int
	if err := d.QueryRow("SELECT count(*) FROM t").Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 3 {
		t.Fatalf("count = %d, want 3", n)
	}
	if noCkpt {
		var ac int
		if err := d.QueryRow("PRAGMA wal_autocheckpoint").Scan(&ac); err != nil {
			t.Fatal(err)
		}
		if ac != 0 {
			t.Fatalf("wal_autocheckpoint = %d, want 0", ac)
		}
	}
	if err := d.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestConnector_NoCheckpointOnClose(t *testing.T) {
	copies := leftOverWAL(t, 2)

	guarded := copies[0]
	mainBefore := factsOf(t, guarded)
	walBefore := factsOf(t, guarded+"-wal")
	readCopy(t, guarded, true)
	if got := factsOf(t, guarded); got != mainBefore {
		t.Fatalf("main file changed with NoCheckpointOnClose: size %d → %d", mainBefore.size, got.size)
	}
	if got := factsOf(t, guarded+"-wal"); got.sum != walBefore.sum {
		t.Fatal("-wal file changed with NoCheckpointOnClose")
	}

	// Control: without the flag the last close checkpoints the WAL into the
	// main file, so the assertions above can fail.
	control := copies[1]
	controlBefore := factsOf(t, control)
	readCopy(t, control, false)
	if factsOf(t, control) == controlBefore {
		t.Fatal("control: main file unchanged without NoCheckpointOnClose; the test cannot tell")
	}
}

func TestConnector_NoCheckpointGuardRequired(t *testing.T) {
	prev := confirmNoCkpt
	confirmNoCkpt = func(int) bool { return false }
	t.Cleanup(func() { confirmNoCkpt = prev })

	p := filepath.Join(t.TempDir(), "g.db")
	d := sql.OpenDB(&Connector{Path: "file:" + p, Params: "mode=rwc", NoCheckpointOnClose: true})
	t.Cleanup(func() { _ = d.Close() })
	err := d.Ping()
	if !errors.Is(err, ErrNoCheckpointGuard) {
		t.Fatalf("Ping error = %v, want ErrNoCheckpointGuard", err)
	}
}
