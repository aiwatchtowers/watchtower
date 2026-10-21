package db

import (
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"watchtower/internal/db/lockmetrics"
)

// lockEvents reads the lock-metrics sink next to dbPath.
func lockEvents(t *testing.T, dbPath string) []lockmetrics.Event {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(filepath.Dir(dbPath), lockmetrics.FileName))
	if err != nil {
		t.Fatalf("reading the lock-metrics sink: %v", err)
	}
	var out []lockmetrics.Event
	for line := range strings.SplitSeq(strings.TrimSpace(string(raw)), "\n") {
		var e lockmetrics.Event
		if err := json.Unmarshal([]byte(line), &e); err != nil {
			t.Fatalf("bad sink line %q: %v", line, err)
		}
		out = append(out, e)
	}
	return out
}

// skipUnlessDefaultThreshold skips when the environment overrides the
// threshold ("off" disables the sink; these tests rely on the default),
// which this package cannot reset once the sink has read the environment.
func skipUnlessDefaultThreshold(t *testing.T) {
	t.Helper()
	if v := os.Getenv("WATCHTOWER_DBLOCK_THRESHOLD_MS"); v != "" {
		t.Skipf("WATCHTOWER_DBLOCK_THRESHOLD_MS=%q overrides the default threshold", v)
	}
}

// Open goes through the measuring driver: a slow WithTx is written next to
// the file, named by the helper and its caller, with the busy timeout
// SetBusyTimeout set.
func TestOpenMeasuresSlowTxThroughWithTx(t *testing.T) {
	skipUnlessDefaultThreshold(t)
	path := filepath.Join(t.TempDir(), "watchtower.db")
	d, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = d.Close() })
	if err := d.SetBusyTimeout(1500 * time.Millisecond); err != nil {
		t.Fatal(err)
	}

	hold := lockmetrics.DefaultThreshold + 50*time.Millisecond
	if err := d.WithTx(func(*sql.Tx) error { time.Sleep(hold); return nil }); err != nil {
		t.Fatal(err)
	}

	const site = "internal/db.(*DB).WithTx <- internal/db.TestOpenMeasuresSlowTxThroughWithTx"
	for _, e := range lockEvents(t, path) {
		if e.Kind == lockmetrics.KindTx && e.Site == site {
			if e.HoldMS < hold.Milliseconds() || e.BusyTimeoutMS != 1500 {
				t.Fatalf("tx event = %+v, want hold_ms >= %d and busy_timeout_ms 1500", e, hold.Milliseconds())
			}
			return
		}
	}
	t.Fatalf("no tx event with site %q in %+v", site, lockEvents(t, path))
}

// A hook opener's busy error is recorded with the hook's busy timeout, and
// the caller still sees the driver's error (IsBusy holds).
func TestOpenExistingRWRecordsBusyWithItsTimeout(t *testing.T) {
	skipUnlessDefaultThreshold(t)
	path := filepath.Join(t.TempDir(), "watchtower.db")
	holder, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = holder.Close() })
	held, err := holder.Begin() // BEGIN IMMEDIATE: holds the write lock
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = held.Rollback() })

	rw, err := OpenExistingRW(path, 50*time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = rw.Close() })
	_, err = rw.Exec(`UPDATE projects SET name = 'x'`)
	if !IsBusy(err) {
		t.Fatalf("update under a held write lock: want a busy error, got %v", err)
	}

	for _, e := range lockEvents(t, path) {
		if e.Kind == lockmetrics.KindBusy && e.Site == "internal/db.TestOpenExistingRWRecordsBusyWithItsTimeout" {
			if e.Err != "SQLITE_BUSY" || e.BusyTimeoutMS != 50 {
				t.Fatalf("busy event = %+v, want err SQLITE_BUSY, busy_timeout_ms 50", e)
			}
			return
		}
	}
	t.Fatalf("no busy event from this test in %+v", lockEvents(t, path))
}

// A failed open never re-points the process's lock-metrics sink: after
// OpenExisting of a missing file, a slow transaction on the open database
// still lands next to its own file, and nothing is written by the missing one.
func TestFailedOpenKeepsTheLockMetricsSink(t *testing.T) {
	skipUnlessDefaultThreshold(t)
	path := filepath.Join(t.TempDir(), "watchtower.db")
	d, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = d.Close() })

	missingDir := t.TempDir()
	if _, err := OpenExisting(filepath.Join(missingDir, "missing.db"), 50*time.Millisecond); err == nil {
		t.Fatal("OpenExisting of a missing file succeeded")
	}
	if _, err := OpenExistingRW(filepath.Join(missingDir, "missing.db"), 50*time.Millisecond); err == nil {
		t.Fatal("OpenExistingRW of a missing file succeeded")
	}

	hold := lockmetrics.DefaultThreshold + 50*time.Millisecond
	if err := d.WithTx(func(*sql.Tx) error { time.Sleep(hold); return nil }); err != nil {
		t.Fatal(err)
	}

	const site = "internal/db.(*DB).WithTx <- internal/db.TestFailedOpenKeepsTheLockMetricsSink"
	found := false
	for _, e := range lockEvents(t, path) {
		found = found || e.Kind == lockmetrics.KindTx && e.Site == site
	}
	if !found {
		t.Fatalf("no tx event with site %q next to the open database: %+v", site, lockEvents(t, path))
	}
	if _, err := os.Stat(filepath.Join(missingDir, lockmetrics.FileName)); !os.IsNotExist(err) {
		t.Fatalf("a sink was written next to the missing database (stat err %v)", err)
	}
}

// pingFresh opens a connection, so a busy error on the open names this
// helper as its caller.
func pingFresh(d *DB) error { return d.Ping() }

// A busy error while a pool connection opens (the engine reads the schema
// then) is recorded, and its site names the open's caller after
// pragmaConnector.Connect.
func TestPoolConnectionOpenRecordsBusy(t *testing.T) {
	skipUnlessDefaultThreshold(t)
	path := filepath.Join(t.TempDir(), "watchtower.db")
	d, err := Open(path) // creates the file and points the sink beside it
	if err != nil {
		t.Fatal(err)
	}
	if err := d.Close(); err != nil {
		t.Fatal(err)
	}

	// An exclusive-mode connection that has written keeps every other
	// connection out of the file, reads included.
	holder := sql.OpenDB(engineConnector(path))
	holder.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = holder.Close() })
	for _, q := range []string{`PRAGMA locking_mode=EXCLUSIVE`, `UPDATE projects SET name = name`} {
		if _, err := holder.Exec(q); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}

	fresh := openPoolWith(metricsConnector(path + "?_busy_timeout=50"))
	t.Cleanup(func() { _ = fresh.Close() })
	if err := pingFresh(fresh); !IsBusy(err) {
		t.Fatalf("open under an exclusive lock: want a busy error, got %v", err)
	}

	const site = "internal/db.(*pragmaConnector).Connect <- internal/db.pingFresh"
	for _, e := range lockEvents(t, path) {
		if e.Kind == lockmetrics.KindBusy && e.Site == site {
			if e.BusyTimeoutMS != 50 {
				t.Fatalf("busy event = %+v, want busy_timeout_ms 50", e)
			}
			return
		}
	}
	t.Fatalf("no busy event with site %q in %+v", site, lockEvents(t, path))
}
