package db

import (
	"database/sql"
	"path/filepath"
	"regexp"
	"testing"

	"github.com/pressly/goose/v3"
)

// TestMigrationsDownAllUpAllRoundTrip rolls a freshly migrated database all
// the way down and back up in one sequential pass, so every migration's Down
// runs at least once, against the state its own Up left behind (everything
// above it is already rolled back). The schema after the round trip must
// match the fresh one exactly. Per-migration DownUpCycle tests keep their
// data assertions; this is the one test that catches a Down nobody wrote a
// test for (00014's Down once failed on tables 00070 had already dropped).
// No version is hard-coded: the pass covers whatever migrations are embedded.
func TestMigrationsDownAllUpAllRoundTrip(t *testing.T) {
	d, err := Open(filepath.Join(t.TempDir(), "down-all-up-all.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer d.Close()

	fresh := normalizeRenamedTables(dumpSchema(t, d))
	latest, err := goose.GetDBVersion(d.DB)
	if err != nil {
		t.Fatalf("reading goose version: %v", err)
	}

	if err := goose.DownTo(d.DB, "migrations", 0); err != nil {
		t.Fatalf("goose down to 0: %v", err)
	}
	if v, err := goose.GetDBVersion(d.DB); err != nil || v != 0 {
		t.Fatalf("goose version after down-all = %d (err %v), want 0", v, err)
	}

	if err := goose.Up(d.DB, "migrations"); err != nil {
		t.Fatalf("goose up after down-all: %v", err)
	}
	if v, err := goose.GetDBVersion(d.DB); err != nil || v != latest {
		t.Fatalf("goose version after up-all = %d (err %v), want %d", v, err, latest)
	}
	if got := normalizeRenamedTables(dumpSchema(t, d)); got != fresh {
		t.Errorf("schema after down-all/up-all differs from a fresh migrate\n--- fresh\n+++ round trip\n%s", firstDiff(fresh, got))
	}
}

// renamedTableHeader matches the quoted table name SQLite writes into a
// table's stored CREATE statement when ALTER TABLE ... RENAME TO produced it.
var renamedTableHeader = regexp.MustCompile(`(?m)^CREATE TABLE "([A-Za-z0-9_]+)"`)

// normalizeRenamedTables unquotes renamed table names in a dumpSchema dump.
// 00076's Down hands the app-owned chat tables back instead of dropping them,
// so the round trip re-adopts them through a rename and their stored SQL
// differs from a fresh migrate only by the quotes.
func normalizeRenamedTables(dump string) string {
	return renamedTableHeader.ReplaceAllString(dump, "CREATE TABLE $1")
}

// openAfterMigrationCycle migrates a new file database up to version, rolls
// that one migration back (DownTo version-1; versions may have gaps), then
// migrates up to the latest version and returns the database. Pinning the
// cycle to its own version keeps a DownUpCycle test exercising its
// migration's Down once later migrations land — a plain goose.Down only ever
// rolls back the newest one. It costs one full migrate, the same as Open.
func openAfterMigrationCycle(t *testing.T, version int64) *DB {
	t.Helper()
	sqlDB, err := sql.Open("sqlite", sqliteDSN(filepath.Join(t.TempDir(), "cycle.db"), immediateTxDSN))
	if err != nil {
		t.Fatalf("opening database: %v", err)
	}
	sqlDB.SetMaxOpenConns(1)
	d := &DB{DB: sqlDB}
	t.Cleanup(func() { _ = d.Close() })

	if err := d.setPragmas(); err != nil {
		t.Fatalf("setting pragmas: %v", err)
	}
	if err := goose.UpTo(d.DB, "migrations", version); err != nil {
		t.Fatalf("goose up to %d: %v", version, err)
	}
	if err := goose.DownTo(d.DB, "migrations", version-1); err != nil {
		t.Fatalf("goose down to %d: %v", version-1, err)
	}
	if v, err := goose.GetDBVersion(d.DB); err != nil || v >= version {
		t.Fatalf("goose version after down = %d (err %v), want below %d", v, err, version)
	}
	if err := goose.Up(d.DB, "migrations"); err != nil {
		t.Fatalf("goose up after down: %v", err)
	}
	return d
}
