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
	for _, line := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
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
