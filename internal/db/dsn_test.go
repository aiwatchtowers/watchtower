package db

import (
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// A '?' in the database path must not split the driver DSN: before
// sqliteDSN the driver took "<dir>/what" as the file and the rest as a
// garbled query, so Open wrote a different database than the one the Desktop
// (GRDB, plain path) reads, with none of the DSN params applied.
func TestOpen_PathWithQuestionMarkOpensThatFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "what?co", "watchtower.db")

	a, err := Open(path)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { a.Close() })
	if _, err := a.Exec(`CREATE TABLE dsn_probe (n INTEGER NOT NULL)`); err != nil {
		t.Fatalf("create table: %v", err)
	}

	if _, err := os.Stat(path); err != nil {
		t.Fatalf("the database must live at the exact path: %v", err)
	}
	// The file at the exact path exists either way once the test hook seeds
	// it, so read the probe table back off that file through a raw
	// connection: Open must have written there, not elsewhere.
	raw, err := sql.Open("sqlite3", sqliteDSN(path, ""))
	if err != nil {
		t.Fatalf("open raw: %v", err)
	}
	t.Cleanup(func() { raw.Close() })
	var probes int
	if err := raw.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'dsn_probe'`).Scan(&probes); err != nil {
		t.Fatalf("read the exact path: %v", err)
	}
	if probes != 1 {
		t.Fatalf("dsn_probe must exist in the file at the exact path, found %d", probes)
	}
	if _, err := os.Stat(filepath.Join(dir, "what")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("no database may appear at the path truncated at '?' (stat err %v)", err)
	}

	// _txlock=immediate still applies: an open write tx on A holds the write
	// lock from Begin, so B's write — not waiting at all — is refused busy
	// instead of landing at once.
	b, err := Open(path)
	if err != nil {
		t.Fatalf("open B: %v", err)
	}
	t.Cleanup(func() { b.Close() })
	if err := b.SetBusyTimeout(0); err != nil {
		t.Fatal(err)
	}
	tx, err := a.Begin()
	if err != nil {
		t.Fatalf("begin A: %v", err)
	}
	if _, err := b.Exec(`INSERT INTO dsn_probe (n) VALUES (1)`); !IsBusy(err) {
		_ = tx.Rollback()
		t.Fatalf("B's write while A held an IMMEDIATE tx: want busy, got %v: the DSN params were dropped", err)
	}
	if err := tx.Rollback(); err != nil {
		t.Fatalf("rollback A: %v", err)
	}
	if _, err := b.Exec(`INSERT INTO dsn_probe (n) VALUES (1)`); err != nil {
		t.Fatalf("B after A released: %v", err)
	}
}

// onUpgradeBegin replaces beforeUpgradeBegin for the test.
func onUpgradeBegin(t *testing.T, f func(*sql.DB)) {
	t.Helper()
	prev := beforeUpgradeBegin
	beforeUpgradeBegin = f
	t.Cleanup(func() { beforeUpgradeBegin = prev })
}

// wantUpgradeBusyTimeout checks that the transition's handle waits Open's
// busy timeout for another writer's lock.
func wantUpgradeBusyTimeout(t *testing.T, raw *sql.DB) {
	t.Helper()
	var ms int
	if err := raw.QueryRow(`PRAGMA busy_timeout`).Scan(&ms); err != nil {
		t.Errorf("busy_timeout of the transition's handle: %v", err)
		return
	}
	if ms != busyTimeoutMS {
		t.Errorf("the transition's handle waits %d ms for a lock, want Open's %d", ms, busyTimeoutMS)
	}
}

// RunSchemaUpgrade must wait for another process's write lock the way Open
// does (busy_timeout), not fail the one-shot transition with SQLITE_BUSY the
// moment the daemon or the Desktop happens to be writing.
func TestRunSchemaUpgrade_WaitsForAnotherWriter(t *testing.T) {
	path := newLegacyDB(t, legacySchemaTip)

	holder, err := sql.Open("sqlite3", path)
	if err != nil {
		t.Fatalf("open holder: %v", err)
	}
	defer holder.Close()
	tx, err := holder.Begin()
	if err != nil {
		t.Fatalf("begin holder: %v", err)
	}
	if _, err := tx.Exec(`CREATE TABLE lock_holder (x INTEGER)`); err != nil {
		t.Fatalf("take write lock: %v", err)
	}
	// The holder lets go only once the transition is about to begin its
	// write transaction, on a handle that waits busy_timeout for it (the
	// PRAGMA is the deterministic check; whether BEGIN meets the lock still
	// held or just released is left to the scheduler — both must succeed).
	released := make(chan struct{})
	onUpgradeBegin(t, func(raw *sql.DB) {
		wantUpgradeBusyTimeout(t, raw)
		go func() {
			defer close(released)
			_ = tx.Rollback()
		}()
	})

	if err := RunSchemaUpgrade(path); err != nil {
		t.Fatalf("the transition must wait for the write lock, got: %v", err)
	}
	<-released
}

// Now that a second upgrader waits for the first instead of failing with
// SQLITE_BUSY, it must find the table the first one created and do nothing —
// not fail startup on "table goose_db_version already exists".
func TestRunSchemaUpgrade_ConcurrentUpgradersBothSucceed(t *testing.T) {
	path := newLegacyDB(t, legacySchemaTip)

	holder, err := sql.Open("sqlite3", path)
	if err != nil {
		t.Fatalf("open holder: %v", err)
	}
	defer holder.Close()
	tx, err := holder.Begin()
	if err != nil {
		t.Fatalf("begin holder: %v", err)
	}
	if _, err := tx.Exec(`CREATE TABLE lock_holder (x INTEGER)`); err != nil {
		t.Fatalf("take write lock: %v", err)
	}

	// The holder lets go once both upgraders are past their first check (no
	// goose table yet) and about to begin their write transactions.
	arrived := make(chan struct{}, 2)
	onUpgradeBegin(t, func(raw *sql.DB) {
		wantUpgradeBusyTimeout(t, raw)
		arrived <- struct{}{}
	})
	errs := make(chan error, 2)
	for range 2 {
		go func() { errs <- RunSchemaUpgrade(path) }()
	}
	<-arrived
	<-arrived
	_ = tx.Rollback()
	for range 2 {
		if err := <-errs; err != nil {
			t.Fatalf("a concurrent upgrader must not fail: %v", err)
		}
	}

	d, err := sql.Open("sqlite3", path)
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	var rows int
	if err := d.QueryRow(`SELECT COUNT(*) FROM goose_db_version`).Scan(&rows); err != nil {
		t.Fatalf("goose_db_version: %v", err)
	}
	if rows != 2 {
		t.Fatalf("exactly one baseline (2 rows) must be written, got %d", rows)
	}
}

// The transition opens the same file Open will, even through a '?' path.
func TestRunSchemaUpgrade_PathWithQuestionMark(t *testing.T) {
	src := newLegacyDB(t, legacySchemaTip)
	dir := filepath.Join(t.TempDir(), "what?co")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "legacy.db")
	if err := os.Rename(src, path); err != nil {
		t.Fatal(err)
	}

	if err := RunSchemaUpgrade(path); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	// A bare legacy fixture cannot run goose's later migrations, so read the
	// marker straight off the file.
	d, err := sql.Open("sqlite3", sqliteDSN(path, ""))
	if err != nil {
		t.Fatalf("open after upgrade: %v", err)
	}
	defer d.Close()
	var baseline int
	if err := d.QueryRow(`SELECT COUNT(*) FROM goose_db_version WHERE version_id = 1`).Scan(&baseline); err != nil {
		t.Fatalf("goose_db_version: %v", err)
	}
	if baseline != 1 {
		t.Fatalf("the baseline must be marked on the '?' path's own file, got %d rows", baseline)
	}
}
