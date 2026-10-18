package db

import (
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"time"
)

// compactAfterMigrations lists the goose versions whose migration frees a lot
// of space: once one is applied and newer than last_compacted_version, a
// compaction is due. A new space-freeing migration adds its version here.
var compactAfterMigrations = []int64{134}

const (
	// The free-pages rule: freelist_count * page_size > compactFreelistMinBytes
	// and freelist_count > compactFreelistMinRatio * page_count.
	compactFreelistMinBytes = 256 << 20
	compactFreelistMinRatio = 0.25
	// compactMaxFailures consecutive failures for one CLI version stop the
	// check from reporting due until the version changes.
	compactMaxFailures = 3
	// compactCheckBusy bounds how long a check read waits on another
	// process's lock.
	compactCheckBusy = 5 * time.Second
)

// db_maintenance keys (migration 00142).
const (
	maintLastCompactedVersion   = "last_compacted_version"
	maintCompactFailures        = "compact_failures"
	maintCompactFailuresVersion = "compact_failures_version"
)

// CompactCheck is the outcome of CheckCompaction, printed by
// `db compact --check --json`. Reason is "migration:<v>", "freelist",
// "schema_pending", "gave_up" or "".
type CompactCheck struct {
	Due            bool   `json:"due"`
	Reason         string `json:"reason"`
	DBBytes        int64  `json:"db_bytes"`
	WALBytes       int64  `json:"wal_bytes"`
	FreeDiskBytes  int64  `json:"free_disk_bytes"`
	NeedsDiskBytes int64  `json:"needs_disk_bytes"`
	DiskOK         bool   `json:"disk_ok"`
}

// freeDiskBytes returns the bytes available to an unprivileged writer on the
// volume holding dir (statfs); tests replace it.
var freeDiskBytes = statfsFreeBytes

// CheckCompaction reports whether the database at dbPath is due for a
// compaction, by reads only: it opens with OpenExisting, so it never creates
// the file, migrates or writes. No file → not due, disk OK. version is the CLI
// build version, compared with compact_failures_version.
func CheckCompaction(dbPath, version string) (CompactCheck, error) {
	info, err := os.Stat(dbPath)
	if errors.Is(err, os.ErrNotExist) {
		return CompactCheck{DiskOK: true}, nil
	}
	if err != nil {
		return CompactCheck{}, fmt.Errorf("checking database %s: %w", dbPath, err)
	}
	c := CompactCheck{DBBytes: info.Size(), NeedsDiskBytes: 2 * info.Size()}
	if wal, err := os.Stat(dbPath + "-wal"); err == nil {
		c.WALBytes = wal.Size()
	} else if !errors.Is(err, os.ErrNotExist) {
		return CompactCheck{}, fmt.Errorf("checking database WAL: %w", err)
	}
	if c.FreeDiskBytes, err = freeDiskBytes(filepath.Dir(dbPath)); err != nil {
		return CompactCheck{}, fmt.Errorf("checking free disk space: %w", err)
	}
	c.DiskOK = c.FreeDiskBytes >= c.NeedsDiskBytes

	d, err := OpenExisting(dbPath, compactCheckBusy)
	if err != nil {
		return CompactCheck{}, err
	}
	defer d.Close()

	if !d.SchemaCurrent() {
		c.Reason = "schema_pending"
		return c, nil
	}
	gaveUp, err := compactGaveUp(d, version)
	if err != nil {
		return CompactCheck{}, err
	}
	if gaveUp {
		c.Reason = "gave_up"
		return c, nil
	}
	if v, err := pendingCompactMigration(d); err != nil {
		return CompactCheck{}, err
	} else if v > 0 {
		c.Due, c.Reason = true, fmt.Sprintf("migration:%d", v)
		return c, nil
	}
	var freelist, pageCount, pageSize int64
	for _, p := range []struct {
		pragma string
		dst    *int64
	}{{"freelist_count", &freelist}, {"page_count", &pageCount}, {"page_size", &pageSize}} {
		if err := d.QueryRow(`PRAGMA ` + p.pragma).Scan(p.dst); err != nil {
			return CompactCheck{}, fmt.Errorf("reading %s: %w", p.pragma, err)
		}
	}
	if freelistDue(freelist, pageCount, pageSize) {
		c.Due, c.Reason = true, "freelist"
	}
	return c, nil
}

// freelistDue is the free-pages rule: the free pages hold more than
// compactFreelistMinBytes and are more than compactFreelistMinRatio of the file.
func freelistDue(freelist, pageCount, pageSize int64) bool {
	return freelist*pageSize > compactFreelistMinBytes &&
		float64(freelist) > compactFreelistMinRatio*float64(pageCount)
}

// compactGaveUp reports whether compactMaxFailures consecutive compactions
// failed under this CLI version.
func compactGaveUp(q queryRower, version string) (bool, error) {
	failedVersion, ok, err := readMaintenance(q, maintCompactFailuresVersion)
	if err != nil || !ok || failedVersion != version {
		return false, err
	}
	failures, err := readMaintenanceInt(q, maintCompactFailures)
	if err != nil {
		return false, err
	}
	return failures >= compactMaxFailures, nil
}

// pendingCompactMigration returns the highest applied version in
// compactAfterMigrations that is newer than last_compacted_version, or 0.
func pendingCompactMigration(q queryRower) (int64, error) {
	last, err := readMaintenanceInt(q, maintLastCompactedVersion)
	if err != nil {
		return 0, err
	}
	var pending int64
	for _, v := range compactAfterMigrations {
		if v <= last || v <= pending {
			continue
		}
		var applied bool
		err := q.QueryRow(`SELECT EXISTS(SELECT 1 FROM goose_db_version WHERE version_id = ? AND is_applied = 1)`, v).Scan(&applied)
		if err != nil {
			return 0, fmt.Errorf("checking migration %d: %w", v, err)
		}
		if applied {
			pending = v
		}
	}
	return pending, nil
}

type queryRower interface {
	QueryRow(query string, args ...any) *sql.Row
}

// readMaintenance reads key from db_maintenance. A missing table (a database
// not yet migrated to 00142) or key reads ("", false, nil).
func readMaintenance(q queryRower, key string) (string, bool, error) {
	var hasTable bool
	if err := q.QueryRow(`SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'db_maintenance')`).Scan(&hasTable); err != nil {
		return "", false, fmt.Errorf("looking up db_maintenance: %w", err)
	}
	if !hasTable {
		return "", false, nil
	}
	var value string
	err := q.QueryRow(`SELECT value FROM db_maintenance WHERE key = ?`, key).Scan(&value)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, fmt.Errorf("reading db_maintenance %s: %w", key, err)
	}
	return value, true, nil
}

// readMaintenanceInt reads an integer key; absent reads 0, a value that is
// not an integer is an error.
func readMaintenanceInt(q queryRower, key string) (int64, error) {
	s, ok, err := readMaintenance(q, key)
	if err != nil || !ok {
		return 0, err
	}
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("db_maintenance %s is not an integer: %w", key, err)
	}
	return n, nil
}
