package db

import (
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
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
	if _, err := os.Stat(filepath.Join(dir, "what")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("no database may appear at the path truncated at '?' (stat err %v)", err)
	}

	// _txlock=immediate still applies: an open write tx on A holds the write
	// lock from Begin, so B's write waits for it instead of landing at once.
	b, err := Open(path)
	if err != nil {
		t.Fatalf("open B: %v", err)
	}
	t.Cleanup(func() { b.Close() })
	tx, err := a.Begin()
	if err != nil {
		t.Fatalf("begin A: %v", err)
	}
	bDone := make(chan error, 1)
	go func() {
		_, err := b.Exec(`INSERT INTO dsn_probe (n) VALUES (1)`)
		bDone <- err
	}()
	select {
	case err := <-bDone:
		_ = tx.Rollback()
		t.Fatalf("B wrote while A held an IMMEDIATE tx (err %v): the DSN params were dropped", err)
	case <-time.After(200 * time.Millisecond):
	}
	if err := tx.Rollback(); err != nil {
		t.Fatalf("rollback A: %v", err)
	}
	if err := <-bDone; err != nil {
		t.Fatalf("B after A released: %v", err)
	}
}

// RunSchemaUpgrade must wait for another process's write lock the way Open
// does (busy_timeout), not fail the one-shot transition with SQLITE_BUSY the
// moment the daemon or the Desktop happens to be writing.
func TestRunSchemaUpgrade_WaitsForAnotherWriter(t *testing.T) {
	path := newLegacyDB(t, legacySchemaTip)

	holder, err := sql.Open("sqlite", path)
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
	released := make(chan struct{})
	go func() {
		defer close(released)
		time.Sleep(300 * time.Millisecond)
		_ = tx.Rollback()
	}()

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

	holder, err := sql.Open("sqlite", path)
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

	errs := make(chan error, 2)
	for range 2 {
		go func() { errs <- RunSchemaUpgrade(path) }()
	}
	time.Sleep(200 * time.Millisecond) // both upgraders are now past their first check, waiting
	_ = tx.Rollback()
	for range 2 {
		if err := <-errs; err != nil {
			t.Fatalf("a concurrent upgrader must not fail: %v", err)
		}
	}

	d, err := sql.Open("sqlite", path)
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
	d, err := sql.Open("sqlite", sqliteDSN(path, ""))
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
