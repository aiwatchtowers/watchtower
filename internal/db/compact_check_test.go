package db

import (
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

// compactFixture migrates a database file in a temp dir, stubs the free disk
// space to plenty, and returns the file's path.
func compactFixture(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "watchtower.db")
	d, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if err := d.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	stubFreeDisk(t, 1<<50)
	return path
}

func stubFreeDisk(t *testing.T, n int64) {
	t.Helper()
	prev := freeDiskBytes
	freeDiskBytes = func(string) (int64, error) { return n, nil }
	t.Cleanup(func() { freeDiskBytes = prev })
}

// compactExec runs stmt on the fixture through a full Open.
func compactExec(t *testing.T, path, stmt string, args ...any) {
	t.Helper()
	d, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer d.Close()
	if _, err := d.Exec(stmt, args...); err != nil {
		t.Fatalf("exec %q: %v", stmt, err)
	}
}

func setMaintenance(t *testing.T, path, key, value string) {
	t.Helper()
	compactExec(t, path, `INSERT INTO db_maintenance (key, value) VALUES (?, ?)
		ON CONFLICT(key) DO UPDATE SET value = excluded.value`, key, value)
}

func highestAppliedVersion(t *testing.T, path string) int64 {
	t.Helper()
	d, err := OpenExisting(path, compactCheckBusy)
	if err != nil {
		t.Fatalf("OpenExisting: %v", err)
	}
	defer d.Close()
	var v int64
	if err := d.QueryRow(`SELECT MAX(version_id) FROM goose_db_version WHERE is_applied = 1`).Scan(&v); err != nil {
		t.Fatalf("reading goose version: %v", err)
	}
	return v
}

func checkCompaction(t *testing.T, path, version string) CompactCheck {
	t.Helper()
	c, err := CheckCompaction(path, version)
	if err != nil {
		t.Fatalf("CheckCompaction: %v", err)
	}
	return c
}

func TestCheckCompaction_DueAfterMigration134(t *testing.T) {
	path := compactFixture(t)
	c := checkCompaction(t, path, "1.0.0")
	if !c.Due || c.Reason != "migration:134" {
		t.Fatalf("got due=%v reason=%q, want due migration:134", c.Due, c.Reason)
	}
	if c.DBBytes <= 0 {
		t.Fatalf("DBBytes = %d, want > 0", c.DBBytes)
	}
	if c.NeedsDiskBytes != 2*c.DBBytes {
		t.Fatalf("NeedsDiskBytes = %d, want %d", c.NeedsDiskBytes, 2*c.DBBytes)
	}
	if !c.DiskOK {
		t.Fatal("DiskOK = false with plenty of disk")
	}
}

func TestCheckCompaction_NotDueAfterRecord(t *testing.T) {
	path := compactFixture(t)
	v := highestAppliedVersion(t, path)
	setMaintenance(t, path, maintLastCompactedVersion, strconv.FormatInt(v, 10))
	c := checkCompaction(t, path, "1.0.0")
	if c.Due || c.Reason != "" {
		t.Fatalf("got due=%v reason=%q, want not due, no reason", c.Due, c.Reason)
	}
	if c.DBBytes <= 0 || !c.DiskOK {
		t.Fatalf("sizes not filled on a not-due outcome: %+v", c)
	}
}

func TestCheckCompaction_FreelistRule(t *testing.T) {
	const pageSize = 16384
	cases := []struct {
		name        string
		pages, free int64
		want        bool
	}{
		{"big and over the ratio", 100_000, 30_000, true},       // 469 MiB, 30 %
		{"big but under the ratio", 100_000, 20_000, false},     // 312 MiB, 20 %
		{"over the ratio but small", 40_000, 15_000, false},     // 234 MiB, 37 %
		{"exactly at both thresholds", 4 * 16384, 16384, false}, // 256 MiB, 25 %
		{"empty file", 0, 0, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := freelistDue(tc.free, tc.pages, pageSize); got != tc.want {
				t.Fatalf("freelistDue(%d, %d, %d) = %v, want %v (min bytes %d, min ratio %v)",
					tc.free, tc.pages, pageSize, got, tc.want, compactFreelistMinBytes, compactFreelistMinRatio)
			}
		})
	}
}

// With the migration rule recorded as done, a real small fixture's freelist
// stays under the byte floor: CheckCompaction reads the pragmas and says not due.
func TestCheckCompaction_FreelistRuleSmallFileNotDue(t *testing.T) {
	path := compactFixture(t)
	setMaintenance(t, path, maintLastCompactedVersion, strconv.FormatInt(highestAppliedVersion(t, path), 10))
	compactExec(t, path, `CREATE TABLE compact_filler (b BLOB)`)
	compactExec(t, path, `INSERT INTO compact_filler WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 500) SELECT randomblob(4096) FROM n`)
	compactExec(t, path, `DROP TABLE compact_filler`)
	if c := checkCompaction(t, path, "1.0.0"); c.Due {
		t.Fatalf("got due reason=%q on a small freelist", c.Reason)
	}
}

// End to end through the pragmas: with the migration rule recorded as done
// and the byte floor lowered to fit a small fixture, a dropped table's free
// pages make the check due for "freelist".
func TestCheckCompaction_FreelistDueEndToEnd(t *testing.T) {
	path := compactFixture(t)
	prev := compactFreelistMinBytes
	compactFreelistMinBytes = 1 << 20
	t.Cleanup(func() { compactFreelistMinBytes = prev })
	setMaintenance(t, path, maintLastCompactedVersion, strconv.FormatInt(highestAppliedVersion(t, path), 10))
	if c := checkCompaction(t, path, "1.0.0"); c.Due {
		t.Fatalf("precondition: due (%q) before any free pages", c.Reason)
	}
	compactExec(t, path, `CREATE TABLE compact_filler (b BLOB)`)
	compactExec(t, path, `INSERT INTO compact_filler WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 2000) SELECT randomblob(4096) FROM n`)
	compactExec(t, path, `DROP TABLE compact_filler`)

	c := checkCompaction(t, path, "1.0.0")
	if !c.Due || c.Reason != "freelist" {
		t.Fatalf("got due=%v reason=%q, want due freelist", c.Due, c.Reason)
	}
}

func TestCheckCompaction_NoFileCreatesNothing(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "watchtower.db")
	c := checkCompaction(t, path, "1.0.0")
	if c.Due || !c.DiskOK {
		t.Fatalf("got %+v, want not due, disk OK", c)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("database file exists after the check: %v", err)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("check created %d entries in the dir (%s…)", len(entries), entries[0].Name())
	}
}

func TestCheckCompaction_SchemaPending(t *testing.T) {
	path := compactFixture(t)
	compactExec(t, path, `DELETE FROM goose_db_version WHERE version_id = (SELECT MAX(version_id) FROM goose_db_version)`)
	countRows := func() int {
		d, err := OpenExisting(path, compactCheckBusy)
		if err != nil {
			t.Fatalf("OpenExisting: %v", err)
		}
		defer d.Close()
		var n int
		if err := d.QueryRow(`SELECT COUNT(*) FROM goose_db_version`).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	before := countRows()
	c := checkCompaction(t, path, "1.0.0")
	if c.Due || c.Reason != "schema_pending" {
		t.Fatalf("got due=%v reason=%q, want not due schema_pending", c.Due, c.Reason)
	}
	if c.DBBytes <= 0 {
		t.Fatalf("sizes not filled on schema_pending: %+v", c)
	}
	if after := countRows(); after != before {
		t.Fatalf("goose_db_version rows %d → %d: the check migrated", before, after)
	}
}

func TestCheckCompaction_DiskShort(t *testing.T) {
	path := compactFixture(t)
	c := checkCompaction(t, path, "1.0.0")

	stubFreeDisk(t, 2*c.DBBytes-1)
	short := checkCompaction(t, path, "1.0.0")
	if short.DiskOK || !short.Due {
		t.Fatalf("one byte short: got disk_ok=%v due=%v, want false/true", short.DiskOK, short.Due)
	}
	if short.FreeDiskBytes != 2*c.DBBytes-1 {
		t.Fatalf("FreeDiskBytes = %d, want the stub's %d", short.FreeDiskBytes, 2*c.DBBytes-1)
	}

	stubFreeDisk(t, 2*c.DBBytes)
	if exact := checkCompaction(t, path, "1.0.0"); !exact.DiskOK {
		t.Fatalf("exactly 2x: DiskOK = false (%+v)", exact)
	}
}

func TestCheckCompaction_GaveUpForThisVersionOnly(t *testing.T) {
	path := compactFixture(t)
	setMaintenance(t, path, maintCompactFailures, "3")
	setMaintenance(t, path, maintCompactFailuresVersion, "1.0.0")

	if c := checkCompaction(t, path, "1.0.0"); c.Due || c.Reason != "gave_up" {
		t.Fatalf("same version: got due=%v reason=%q, want not due gave_up", c.Due, c.Reason)
	}
	if c := checkCompaction(t, path, "1.0.1"); !c.Due || c.Reason != "migration:134" {
		t.Fatalf("new version: got due=%v reason=%q, want due migration:134", c.Due, c.Reason)
	}
	setMaintenance(t, path, maintCompactFailures, "2")
	if c := checkCompaction(t, path, "1.0.0"); !c.Due {
		t.Fatalf("2 failures: got not due reason=%q, want due", c.Reason)
	}
}

func TestCheckCompaction_MalformedCounterIsAnError(t *testing.T) {
	path := compactFixture(t)
	setMaintenance(t, path, maintLastCompactedVersion, "not-a-number")
	if _, err := CheckCompaction(path, "1.0.0"); err == nil {
		t.Fatal("CheckCompaction accepted a non-integer last_compacted_version")
	}
}

func TestCheckCompaction_MissingMaintenanceTableReadsNeverCompacted(t *testing.T) {
	path := compactFixture(t)
	compactExec(t, path, `DROP TABLE db_maintenance`)
	d, err := OpenExisting(path, compactCheckBusy)
	if err != nil {
		t.Fatalf("OpenExisting: %v", err)
	}
	defer d.Close()
	for _, key := range []string{maintLastCompactedVersion, maintCompactFailures, maintCompactFailuresVersion} {
		v, ok, err := readMaintenance(d, key)
		if err != nil || ok || v != "" {
			t.Fatalf("readMaintenance(%s) = (%q, %v, %v), want (\"\", false, nil)", key, v, ok, err)
		}
	}
	last, err := readMaintenanceInt(d, maintLastCompactedVersion)
	if err != nil || last != 0 {
		t.Fatalf("readMaintenanceInt = (%d, %v), want (0, nil)", last, err)
	}
}

// The order of compactAfterMigrations does not matter: the highest applied
// version newer than the record is named.
func TestCheckCompaction_NamesHighestListedMigration(t *testing.T) {
	path := compactFixture(t)
	prev := compactAfterMigrations
	compactAfterMigrations = []int64{134, 100}
	t.Cleanup(func() { compactAfterMigrations = prev })
	setMaintenance(t, path, maintLastCompactedVersion, "99")
	if c := checkCompaction(t, path, "1.0.0"); c.Reason != "migration:134" {
		t.Fatalf("reason = %q, want migration:134", c.Reason)
	}
	setMaintenance(t, path, maintLastCompactedVersion, "134")
	if c := checkCompaction(t, path, "1.0.0"); c.Due {
		t.Fatalf("reason = %q after recording 134, want not due", c.Reason)
	}
}
