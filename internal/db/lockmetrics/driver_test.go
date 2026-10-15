package lockmetrics_test

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"modernc.org/sqlite"
	sqlite3 "modernc.org/sqlite/lib"

	"watchtower/internal/db/lockmetrics"
)

// The site of an event raised from this file names this package's helpers.
const testPkg = "internal/db/lockmetrics_test."

// setupDriver starts from a fresh process state with the given threshold
// env and the sink next to a DB file in a temp dir. It returns both paths.
func setupDriver(t *testing.T, thresholdMS string) (dbPath, sinkPath string) {
	t.Helper()
	t.Setenv("WATCHTOWER_DBLOCK_THRESHOLD_MS", thresholdMS)
	lockmetrics.ResetForTest()
	t.Cleanup(lockmetrics.ResetForTest)
	dir := t.TempDir()
	dbPath = filepath.Join(dir, "watchtower.db")
	lockmetrics.Configure(dbPath)
	return dbPath, filepath.Join(dir, lockmetrics.FileName)
}

// openMetrics opens dsn through the wrapping driver on one connection, as
// internal/db does, and makes sure table t exists.
func openMetrics(t *testing.T, dsn string) *sql.DB {
	t.Helper()
	d, err := sql.Open(lockmetrics.DriverName, dsn)
	if err != nil {
		t.Fatalf("open %s: %v", dsn, err)
	}
	d.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = d.Close() })
	if _, err := d.Exec(`PRAGMA journal_mode=WAL`); err != nil {
		t.Fatalf("wal: %v", err)
	}
	if _, err := d.Exec(`CREATE TABLE IF NOT EXISTS t (v INTEGER)`); err != nil {
		t.Fatalf("create: %v", err)
	}
	return d
}

func readEvents(t *testing.T, path string) []lockmetrics.Event {
	t.Helper()
	raw, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		t.Fatalf("read sink: %v", err)
	}
	var out []lockmetrics.Event
	for _, line := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
		var e lockmetrics.Event
		if err := json.Unmarshal([]byte(line), &e); err != nil {
			t.Fatalf("bad line %q: %v", line, err)
		}
		out = append(out, e)
	}
	return out
}

func ofKind(events []lockmetrics.Event, kind string) []lockmetrics.Event {
	var out []lockmetrics.Event
	for _, e := range events {
		if e.Kind == kind {
			out = append(out, e)
		}
	}
	return out
}

// holdTx runs a write transaction that keeps the lock for d.
func holdTx(t *testing.T, d *sql.DB, hold time.Duration) {
	t.Helper()
	tx, err := d.Begin()
	if err != nil {
		t.Fatalf("begin: %v", err)
	}
	if _, err := tx.Exec(`INSERT INTO t (v) VALUES (1)`); err != nil {
		t.Fatalf("insert: %v", err)
	}
	time.Sleep(hold)
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit: %v", err)
	}
}

func beginWrite(d *sql.DB) error {
	tx, err := d.Begin()
	if err != nil {
		return err
	}
	return tx.Rollback()
}

func insertRow(d *sql.DB) error {
	_, err := d.Exec(`INSERT INTO t (v) VALUES (2)`)
	return err
}

func TestDriverSlowTxRecordedWithSiteAndBusyTimeout(t *testing.T) {
	dbPath, sink := setupDriver(t, "30")
	d := openMetrics(t, dbPath+"?_txlock=immediate&_pragma=busy_timeout(1234)")

	holdTx(t, d, 60*time.Millisecond)

	txs := ofKind(readEvents(t, sink), lockmetrics.KindTx)
	if len(txs) != 1 {
		t.Fatalf("want 1 tx event, got %+v", txs)
	}
	e := txs[0]
	if e.HoldMS < 60 {
		t.Errorf("hold_ms = %d, want >= 60", e.HoldMS)
	}
	if e.Site != testPkg+"holdTx" {
		t.Errorf("site = %q, want %q", e.Site, testPkg+"holdTx")
	}
	if e.BusyTimeoutMS != 1234 {
		t.Errorf("busy_timeout_ms = %d, want 1234", e.BusyTimeoutMS)
	}
	if e.Proc != "cli" || e.PID != os.Getpid() || e.Err != "" {
		t.Errorf("unexpected fields %+v", e)
	}
}

func TestDriverBelowThresholdWritesNothing(t *testing.T) {
	dbPath, sink := setupDriver(t, "10000")
	d := openMetrics(t, dbPath+"?_txlock=immediate")

	holdTx(t, d, 0)
	if err := insertRow(d); err != nil {
		t.Fatal(err)
	}

	if _, err := os.Stat(sink); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("sink written below the threshold (stat err %v): %+v", err, readEvents(t, sink))
	}
}

func TestDriverBusyIsRecordedAndErrorPassesThroughUnwrapped(t *testing.T) {
	dbPath, sink := setupDriver(t, "10000") // busy is written whatever the threshold
	holder := openMetrics(t, dbPath+"?_txlock=immediate")
	d := openMetrics(t, dbPath+"?_txlock=immediate&_pragma=busy_timeout(50)")

	held, err := holder.Begin()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = held.Rollback() })

	err = beginWrite(d)
	var se *sqlite.Error
	if !errors.As(err, &se) || se.Code()&0xff != sqlite3.SQLITE_BUSY {
		t.Fatalf("begin under a held lock: want *sqlite.Error SQLITE_BUSY, got %T %v", err, err)
	}

	if _, err := d.Exec(`PRAGMA busy_timeout=70`); err != nil {
		t.Fatal(err)
	}
	err = insertRow(d)
	if !errors.As(err, &se) || se.Code()&0xff != sqlite3.SQLITE_BUSY {
		t.Fatalf("insert under a held lock: want *sqlite.Error SQLITE_BUSY, got %T %v", err, err)
	}

	busy := ofKind(readEvents(t, sink), lockmetrics.KindBusy)
	if len(busy) != 2 {
		t.Fatalf("want 2 busy events, got %+v", busy)
	}
	for i, want := range []struct {
		site    string
		timeout int64
	}{{testPkg + "beginWrite", 50}, {testPkg + "insertRow", 70}} {
		e := busy[i]
		if e.Err != "SQLITE_BUSY" || e.Site != want.site || e.BusyTimeoutMS != want.timeout {
			t.Errorf("busy[%d] = %+v, want err SQLITE_BUSY site %s timeout %d", i, e, want.site, want.timeout)
		}
		if e.WaitMS < 40 {
			t.Errorf("busy[%d] wait_ms = %d, want about the busy timeout", i, e.WaitMS)
		}
	}
}

func TestDriverSlowAutocommitExecRecordedAsHold(t *testing.T) {
	dbPath, sink := setupDriver(t, "30")
	holder := openMetrics(t, dbPath+"?_txlock=immediate")
	d := openMetrics(t, dbPath+"?_txlock=immediate&_pragma=busy_timeout(5000)")

	held, err := holder.Begin()
	if err != nil {
		t.Fatal(err)
	}
	released := make(chan error, 1)
	go func() {
		time.Sleep(80 * time.Millisecond)
		released <- held.Commit()
	}()
	if err := insertRow(d); err != nil {
		t.Fatal(err)
	}
	if err := <-released; err != nil {
		t.Fatal(err)
	}

	var execs []lockmetrics.Event
	for _, e := range ofKind(readEvents(t, sink), lockmetrics.KindExec) {
		if e.Site == testPkg+"insertRow" {
			execs = append(execs, e)
		}
	}
	if len(execs) != 1 {
		t.Fatalf("want 1 exec event from insertRow, got %+v", readEvents(t, sink))
	}
	if execs[0].HoldMS < 30 || execs[0].WaitMS != 0 || execs[0].BusyTimeoutMS != 5000 {
		t.Errorf("exec event = %+v, want hold_ms >= 30, no wait_ms, busy_timeout_ms 5000", execs[0])
	}
}

func TestDriverReadOnlyTxAndReadsAreNotMeasured(t *testing.T) {
	dbPath, sink := setupDriver(t, "0") // 0 logs every measured tx/exec
	d := openMetrics(t, dbPath+"?_txlock=immediate")
	if err := os.Remove(sink); err != nil { // drop openMetrics' own DDL events
		t.Fatal(err)
	}

	tx, err := d.BeginTx(context.Background(), &sql.TxOptions{ReadOnly: true})
	if err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(`SELECT 1`); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(`PRAGMA user_version`); err != nil {
		t.Fatal(err)
	}
	if got := readEvents(t, sink); len(got) != 0 {
		t.Fatalf("read-only work was measured: %+v", got)
	}

	holdTx(t, d, 0)
	if got := ofKind(readEvents(t, sink), lockmetrics.KindTx); len(got) != 1 {
		t.Fatalf("a write tx at threshold 0: want 1 tx event, got %+v", got)
	}
}

func TestDriverMemoryDatabaseIsNotMeasured(t *testing.T) {
	_, sink := setupDriver(t, "0")
	d := openMetrics(t, ":memory:?_txlock=immediate")

	holdTx(t, d, 0)
	if err := insertRow(d); err != nil {
		t.Fatal(err)
	}

	if _, err := os.Stat(sink); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("an in-memory database was measured: %+v", readEvents(t, sink))
	}
}

func TestDriverKeepsTxLockMode(t *testing.T) {
	// BEGIN IMMEDIATE takes the write lock at Begin, so a second writer's
	// Begin is busy before either has written anything.
	dbPath, _ := setupDriver(t, "off")
	a := openMetrics(t, dbPath+"?_txlock=immediate")
	b := openMetrics(t, dbPath+"?_txlock=immediate&_pragma=busy_timeout(0)")
	tx, err := a.Begin()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = tx.Rollback() })
	if err := beginWrite(b); err == nil {
		t.Fatal("second immediate Begin succeeded while the first holds the write lock")
	}
}

func TestIsWrite(t *testing.T) {
	for q, want := range map[string]bool{
		"INSERT INTO t VALUES (1)":             true,
		"  update t set v = 1":                 true,
		"DELETE FROM t":                        true,
		"CREATE TABLE x (a)":                   true,
		"REPLACE INTO t VALUES (1)":            true,
		"PRAGMA busy_timeout=5000":             true,
		"pragma foreign_keys = ON":             true,
		"SELECT 1":                             false,
		"select * from t":                      false,
		"PRAGMA user_version":                  false,
		"PRAGMA wal_checkpoint(PASSIVE)":       false,
		"PRAGMA user_version; SELECT 1 = 1":    false,
		"EXPLAIN QUERY PLAN SELECT 1":          false,
		"WITH x AS (SELECT 1) SELECT * FROM x": false,
		"-- a comment\nSELECT 1":               false,
		"/* c */ INSERT INTO t VALUES (1)":     true,
		"/* c */ select 1":                     false,
		"":                                     true,
	} {
		if got := lockmetrics.IsWrite(q); got != want {
			t.Errorf("IsWrite(%q) = %v, want %v", q, got, want)
		}
	}
}

func TestPragmaBusyTimeoutMS(t *testing.T) {
	for q, want := range map[string]int64{
		"PRAGMA busy_timeout=5000":    5000,
		"pragma busy_timeout = 250;":  250,
		"PRAGMA busy_timeout(1000)":   1000,
		"PRAGMA main.busy_timeout=42": 42,
		"  PRAGMA  busy_timeout = 0 ": 0,
		"PRAGMA busy_timeout":         -1,
		"PRAGMA foreign_keys=ON":      -1,
		"SELECT busy_timeout=5":       -1,
		"PRAGMA busy_timeout=abc":     -1,
	} {
		got, ok := lockmetrics.PragmaBusyTimeoutMS(q)
		if want < 0 {
			if ok {
				t.Errorf("PragmaBusyTimeoutMS(%q) = %d, want no match", q, got)
			}
			continue
		}
		if !ok || got != want {
			t.Errorf("PragmaBusyTimeoutMS(%q) = %d, %v, want %d", q, got, ok, want)
		}
	}
}

func TestDSNBusyTimeoutMS(t *testing.T) {
	for dsn, want := range map[string]int64{
		"/x/watchtower.db?_txlock=immediate": 0,
		"/x/watchtower.db":                   0,
		"file:/x/w.db?mode=rw&_pragma=busy_timeout(500)&_pragma=query_only(1)":  500,
		"/x/w.db?_txlock=immediate&_pragma=busy_timeout(5000)":                  5000,
		"file:/x/w.db?mode=rw&_pragma=busy_timeout%281500%29&_txlock=immediate": 1500,
	} {
		if got := lockmetrics.DSNBusyTimeoutMS(dsn); got != want {
			t.Errorf("DSNBusyTimeoutMS(%q) = %d, want %d", dsn, got, want)
		}
	}
}

// The tx event is stamped when COMMIT is done, so [ts-hold_ms, ts] is the
// interval the lock was held (db lockstats overlaps busy events with it).
func TestDriverTxEventIsStampedAfterCommit(t *testing.T) {
	dbPath, sink := setupDriver(t, "30")
	d := openMetrics(t, dbPath+"?_txlock=immediate")

	beforeBegin := time.Now()
	tx, err := d.Begin()
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(60 * time.Millisecond)
	beforeCommit := time.Now()
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}

	txs := ofKind(readEvents(t, sink), lockmetrics.KindTx)
	if len(txs) != 1 {
		t.Fatalf("want 1 tx event, got %+v", txs)
	}
	e := txs[0]
	// ts is written with millisecond precision (truncated): allow 1 ms.
	ts := e.TS.Add(time.Millisecond)
	if ts.Before(beforeCommit) {
		t.Errorf("ts %v is before COMMIT was called (%v): stamped at begin?", e.TS, beforeCommit)
	}
	if start := ts.Add(-time.Duration(e.HoldMS) * time.Millisecond); start.Before(beforeBegin.Add(-time.Millisecond)) {
		t.Errorf("ts - hold_ms = %v starts before Begin was called (%v)", start, beforeBegin)
	}
}

// A query_only connection (OpenExisting) never takes the write lock: its
// transactions and statements are not timed even at threshold 0, but its
// busy errors are still recorded.
func TestDriverQueryOnlyConnectionRecordsOnlyBusy(t *testing.T) {
	dbPath, sink := setupDriver(t, "0")
	holder := openMetrics(t, dbPath+"?_txlock=immediate")
	ro := openQueryOnly(t, dbPath)
	if err := os.Remove(sink); err != nil { // drop openMetrics' own DDL events
		t.Fatal(err)
	}

	tx, err := ro.Begin() // deferred: no _txlock on this DSN
	if err != nil {
		t.Fatal(err)
	}
	var n int
	if err := tx.QueryRow(`SELECT count(*) FROM t`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	time.Sleep(20 * time.Millisecond)
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
	if got := readEvents(t, sink); len(got) != 0 {
		t.Fatalf("a query_only connection was timed: %+v", got)
	}

	// An exclusive-mode writer shuts readers out: the read fails busy. The
	// writer can enter that mode only while no other connection is open.
	if err := ro.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := holder.Exec(`PRAGMA locking_mode=EXCLUSIVE`); err != nil {
		t.Fatal(err)
	}
	held, err := holder.Begin()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = held.Rollback() })
	if _, err := held.Exec(`INSERT INTO t (v) VALUES (3)`); err != nil {
		t.Fatal(err)
	}
	if err := countRows(openQueryOnly(t, dbPath)); err == nil {
		t.Fatal("read under an exclusive lock succeeded")
	}
	busy := ofKind(readEvents(t, sink), lockmetrics.KindBusy)
	if len(busy) != 1 || busy[0].Site != testPkg+"countRows" || busy[0].BusyTimeoutMS != 50 {
		t.Fatalf("want 1 busy event from countRows with busy_timeout_ms 50, got %+v", readEvents(t, sink))
	}
	if txs := ofKind(readEvents(t, sink), lockmetrics.KindTx); len(txs) != 0 {
		t.Fatalf("a query_only connection was timed: %+v", txs)
	}
}

// openQueryOnly opens dbPath the way db.OpenExisting does.
func openQueryOnly(t *testing.T, dbPath string) *sql.DB {
	t.Helper()
	d, err := sql.Open(lockmetrics.DriverName, "file:"+dbPath+"?mode=rw&_pragma=busy_timeout(50)&_pragma=query_only(1)")
	if err != nil {
		t.Fatal(err)
	}
	d.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = d.Close() })
	return d
}

func countRows(d *sql.DB) error {
	var n int
	return d.QueryRow(`SELECT count(*) FROM t`).Scan(&n)
}

// An autocommit write run through Query (… RETURNING) is timed like an Exec.
func TestDriverSlowWriteThroughQueryRecordedAsExec(t *testing.T) {
	dbPath, sink := setupDriver(t, "30")
	holder := openMetrics(t, dbPath+"?_txlock=immediate")
	d := openMetrics(t, dbPath+"?_txlock=immediate&_pragma=busy_timeout(5000)")

	held, err := holder.Begin()
	if err != nil {
		t.Fatal(err)
	}
	released := make(chan error, 1)
	go func() {
		time.Sleep(80 * time.Millisecond)
		released <- held.Commit()
	}()
	if err := insertReturning(d); err != nil {
		t.Fatal(err)
	}
	if err := <-released; err != nil {
		t.Fatal(err)
	}

	for _, e := range ofKind(readEvents(t, sink), lockmetrics.KindExec) {
		if e.Site == testPkg+"insertReturning" {
			if e.HoldMS < 30 {
				t.Errorf("exec event = %+v, want hold_ms >= 30", e)
			}
			return
		}
	}
	t.Fatalf("no exec event from insertReturning in %+v", readEvents(t, sink))
}

func insertReturning(d *sql.DB) error {
	var v int
	return d.QueryRow(`INSERT INTO t (v) VALUES (4) RETURNING v`).Scan(&v)
}

func TestDSNQueryOnly(t *testing.T) {
	for dsn, want := range map[string]bool{
		"file:/x/w.db?mode=rw&_pragma=busy_timeout(500)&_pragma=query_only(1)": true,
		"file:/x/w.db?_pragma=query_only(ON)":                                  true,
		"file:/x/w.db?_pragma=query_only%28true%29":                            true,
		"file:/x/w.db?_pragma=query_only(0)":                                   false,
		"file:/x/w.db?mode=rw&_pragma=busy_timeout(500)&_txlock=immediate":     false,
		"/x/watchtower.db?_txlock=immediate":                                   false,
		"/x/watchtower.db":                                                     false,
	} {
		if got := lockmetrics.DSNQueryOnly(dsn); got != want {
			t.Errorf("DSNQueryOnly(%q) = %v, want %v", dsn, got, want)
		}
	}
}

func TestIsMemoryDSN(t *testing.T) {
	for dsn, want := range map[string]bool{
		":memory:":                           true,
		":memory:?_txlock=immediate":         true,
		"file::memory:?cache=shared":         true,
		"file:x?mode=memory":                 true,
		"":                                   true,
		"/x/watchtower.db?_txlock=immediate": false,
		"file:/x/w.db?mode=rw":               false,
	} {
		if got := lockmetrics.IsMemoryDSN(dsn); got != want {
			t.Errorf("IsMemoryDSN(%q) = %v, want %v", dsn, got, want)
		}
	}
}

// BenchmarkTxBelowThreshold is the per-transaction cost of a write
// transaction through the wrapper below the threshold; compare with
// BenchmarkTxBaseline (the bare driver). Budget: < 5 µs of difference.
func BenchmarkTxBelowThreshold(b *testing.B) {
	benchTx(b, lockmetrics.DriverName)
}

func BenchmarkTxBaseline(b *testing.B) {
	benchTx(b, "sqlite")
}

func benchTx(b *testing.B, driverName string) {
	b.Setenv("WATCHTOWER_DBLOCK_THRESHOLD_MS", "10000")
	lockmetrics.ResetForTest()
	b.Cleanup(lockmetrics.ResetForTest)
	dbPath := filepath.Join(b.TempDir(), "watchtower.db")
	lockmetrics.Configure(dbPath)
	d, err := sql.Open(driverName, dbPath+"?_txlock=immediate")
	if err != nil {
		b.Fatal(err)
	}
	d.SetMaxOpenConns(1)
	b.Cleanup(func() { _ = d.Close() })
	if _, err := d.Exec(`PRAGMA journal_mode=WAL`); err != nil {
		b.Fatal(err)
	}
	for b.Loop() {
		tx, err := d.Begin()
		if err != nil {
			b.Fatal(err)
		}
		if err := tx.Commit(); err != nil {
			b.Fatal(err)
		}
	}
}
