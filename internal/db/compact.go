package db

import (
	"context"
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
// Tests mutate this; no t.Parallel.
var compactAfterMigrations = []int64{134}

// The free-pages rule: freelist_count * page_size > compactFreelistMinBytes
// and freelist_count > compactFreelistMinRatio * page_count. Vars so a test
// can reach the rule with a small fixture; tests mutate them, no t.Parallel.
var (
	compactFreelistMinBytes int64 = 256 << 20
	compactFreelistMinRatio       = 0.25
)

const (
	// compactMaxFailures consecutive failures for one CLI version stop the
	// check from reporting due until the version changes.
	compactMaxFailures = 3
	// compactCheckBusy bounds how long a check read waits on another
	// process's lock.
	compactCheckBusy = 5 * time.Second
)

// compactBusy bounds how long a compaction statement waits on another
// process's lock; a var so a test can shorten the final checkpoint's wait
// on a reader. Tests mutate this; no t.Parallel.
var compactBusy = 30 * time.Second

// db_maintenance keys (migration 00142).
const (
	maintLastCompactedVersion   = "last_compacted_version"
	maintCompactedAt            = "compacted_at"
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
// volume holding dir (statfs). Tests mutate this; no t.Parallel.
var freeDiskBytes = statfsFreeBytes

// SetFreeDiskBytesForTest overrides the free disk space CheckCompaction and
// Compact see. TEST-ONLY: no production code calls this; it exists for
// cmd's `db compact` tests, which cannot reach freeDiskBytes. Returns a
// restore func the caller must invoke (typically via t.Cleanup).
func SetFreeDiskBytesForTest(fn func(dir string) (int64, error)) (restore func()) {
	prev := freeDiskBytes
	freeDiskBytes = fn
	return func() { freeDiskBytes = prev }
}

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
	c := CompactCheck{DBBytes: info.Size(), NeedsDiskBytes: needsDiskBytes(info.Size())}
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

	current, err := d.schemaCurrentErr()
	if err != nil {
		return CompactCheck{}, err
	}
	if !current {
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

// needsDiskBytes is the free space a compaction of a size-byte file asks
// for: VACUUM writes a full copy beside the original, and in WAL mode the
// copy passes through the WAL first.
func needsDiskBytes(size int64) int64 { return 2 * size }

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

// CompactOptions configures Compact.
type CompactOptions struct {
	Force   bool   // skip the disk rule (the daemon rule lives in cmd)
	Reason  string // carried into the result: the check's reason, or "manual"
	Version string // CLI build version, for the failure counter
}

// CompactResult is the outcome of Compact, printed by `db compact --json`.
// Skipped is "not_due", "disk", "daemon_running", "interrupted" or
// "schema_pending" (not_due and daemon_running are set by the command).
type CompactResult struct {
	Compacted   bool   `json:"compacted"`
	Skipped     string `json:"skipped,omitempty"`
	Reason      string `json:"reason,omitempty"`
	BytesBefore int64  `json:"bytes_before,omitempty"`
	BytesAfter  int64  `json:"bytes_after,omitempty"`
	DurationMS  int64  `json:"duration_ms,omitempty"`
	Error       string `json:"error,omitempty"`
	Failures    int    `json:"failures,omitempty"`
	GaveUp      bool   `json:"gave_up,omitempty"`
	// CheckpointBusy: the final checkpoint could not pass a reader's
	// snapshot, so part of the space is reclaimed at the next checkpoint.
	CheckpointBusy bool `json:"checkpoint_busy,omitempty"`
}

// compactVacuumHook, nil in production, runs right before the VACUUM Exec
// (test seam for the interrupt test).
var compactVacuumHook func()

// compactVacuumSQL is the statement run (test seam for a forced failure).
var compactVacuumSQL = "VACUUM"

// compactRecord records a successful VACUUM (test seam for a failed record).
var compactRecord = recordCompaction

// Compact rewrites the database at dbPath with VACUUM between two
// wal_checkpoint(TRUNCATE)s and records last_compacted_version and
// compacted_at. It opens with OpenExistingRW, so it never creates the file
// or migrates; a schema that is not current is skipped as schema_pending.
// Unless opts.Force, a volume with less than twice the file's size free is
// skipped as disk before the database is opened. Cancelling ctx interrupts
// the VACUUM (skipped as interrupted, nothing written; VACUUM is atomic, so
// the old content stays). An interrupt that races the VACUUM's commit can
// still report interrupted with the file already compacted: nothing is
// recorded, so the next launch finds it due again and re-runs it cheaply.
// Skips return (result, nil); a VACUUM or I/O failure — including reading
// the size or recording the compaction after a VACUUM that succeeded —
// returns (result, err) with Error, Failures and GaveUp filled, after
// counting it in compact_failures for opts.Version. A VACUUM or checkpoint
// that gives up on another process's lock (SQLITE_BUSY/LOCKED) returns
// (result, err) with Error saying busy and is not counted: the file is fine,
// the next launch tries again.
func Compact(ctx context.Context, dbPath string, opts CompactOptions) (CompactResult, error) {
	res := CompactResult{Reason: opts.Reason}
	if !opts.Force {
		info, err := os.Stat(dbPath)
		if err != nil {
			return res, fmt.Errorf("checking database %s: %w", dbPath, err)
		}
		free, err := freeDiskBytes(filepath.Dir(dbPath))
		if err != nil {
			return res, fmt.Errorf("checking free disk space: %w", err)
		}
		if free < needsDiskBytes(info.Size()) {
			res.Skipped = "disk"
			return res, nil
		}
	}

	d, err := OpenExistingRW(dbPath, compactBusy)
	if err != nil {
		return res, err
	}
	defer d.Close()
	current, err := d.schemaCurrentErr()
	if err != nil {
		return res, err
	}
	if !current {
		res.Skipped = "schema_pending"
		return res, nil
	}

	start := time.Now()
	if res.BytesBefore, err = fileSize(dbPath); err != nil {
		return res, err
	}
	checkpointBusy, err := vacuumWithCheckpoints(ctx, d)
	if err != nil {
		if ctx.Err() != nil {
			res.Skipped = "interrupted"
			return res, nil
		}
		if IsBusy(err) {
			err = fmt.Errorf("the database is busy (another process holds its lock); not counted as a failure: %w", err)
			res.Error = err.Error()
			return res, err
		}
		return res, compactFailed(d, opts.Version, &res, err)
	}
	res.CheckpointBusy = checkpointBusy
	if res.BytesAfter, err = fileSize(dbPath); err != nil {
		return res, compactFailed(d, opts.Version, &res, err)
	}
	res.DurationMS = time.Since(start).Milliseconds()
	if err := compactRecord(d); err != nil {
		return res, compactFailed(d, opts.Version, &res, err)
	}
	res.Compacted = true
	return res, nil
}

// vacuumWithCheckpoints runs checkpoint, VACUUM, checkpoint. The first two
// honour ctx (the VACUUM through sqlite3_interrupt); the last runs to the
// end once the VACUUM has committed. A checkpoint that reports busy (a
// reader still on an older snapshot) is not an error; the final one's busy
// is returned, since the file then keeps part of its size until the next
// checkpoint.
func vacuumWithCheckpoints(ctx context.Context, d *DB) (checkpointBusy bool, err error) {
	if _, err := walCheckpointTruncate(ctx, d); err != nil {
		return false, err
	}
	if compactVacuumHook != nil {
		compactVacuumHook()
	}
	if _, err := d.ExecContext(ctx, compactVacuumSQL); err != nil {
		return false, fmt.Errorf("vacuum: %w", err)
	}
	return walCheckpointTruncate(context.WithoutCancel(ctx), d)
}

// walCheckpointTruncate runs PRAGMA wal_checkpoint(TRUNCATE) and reports
// whether it was blocked from completing (its busy column).
func walCheckpointTruncate(ctx context.Context, d *DB) (busy bool, err error) {
	var busyCol, logFrames, checkpointed int64
	if err := d.QueryRowContext(ctx, `PRAGMA wal_checkpoint(TRUNCATE)`).Scan(&busyCol, &logFrames, &checkpointed); err != nil {
		return false, fmt.Errorf("wal checkpoint: %w", err)
	}
	return busyCol != 0, nil
}

func fileSize(path string) (int64, error) {
	info, err := os.Stat(path)
	if err != nil {
		return 0, fmt.Errorf("checking database %s: %w", path, err)
	}
	return info.Size(), nil
}

// recordCompaction stores the highest applied goose version and the time in
// one write transaction and clears the failure counter.
func recordCompaction(d *DB) error {
	tx, err := d.Begin()
	if err != nil {
		return fmt.Errorf("recording the compaction: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	var version int64
	if err := tx.QueryRow(`SELECT MAX(version_id) FROM goose_db_version WHERE is_applied = 1`).Scan(&version); err != nil {
		return fmt.Errorf("recording the compaction: reading goose version: %w", err)
	}
	if err := writeMaintenance(tx, maintLastCompactedVersion, strconv.FormatInt(version, 10)); err != nil {
		return fmt.Errorf("recording the compaction: %w", err)
	}
	if err := writeMaintenance(tx, maintCompactedAt, time.Now().UTC().Format(time.RFC3339)); err != nil {
		return fmt.Errorf("recording the compaction: %w", err)
	}
	if _, err := tx.Exec(`DELETE FROM db_maintenance WHERE key IN (?, ?)`, maintCompactFailures, maintCompactFailuresVersion); err != nil {
		return fmt.Errorf("recording the compaction: clearing the failure counter: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("recording the compaction: %w", err)
	}
	return nil
}

// compactFailed counts cause in compact_failures — restarting at 1 when
// compact_failures_version is not version — and fills res. It returns the
// error to hand back: cause, joined with the counter write's error if that
// failed too.
func compactFailed(d *DB, version string, res *CompactResult, cause error) error {
	res.Error = cause.Error()
	failures, err := countCompactFailure(d, version)
	if err != nil {
		return errors.Join(cause, fmt.Errorf("recording the compaction failure: %w", err))
	}
	res.Failures = failures
	res.GaveUp = failures >= compactMaxFailures
	return cause
}

func countCompactFailure(d *DB, version string) (int, error) {
	tx, err := d.Begin()
	if err != nil {
		return 0, err
	}
	defer func() { _ = tx.Rollback() }()
	var failures int64
	failedVersion, ok, err := readMaintenance(tx, maintCompactFailuresVersion)
	if err != nil {
		return 0, err
	}
	if ok && failedVersion == version {
		if failures, err = readMaintenanceInt(tx, maintCompactFailures); err != nil {
			return 0, err
		}
	}
	failures++
	if err := writeMaintenance(tx, maintCompactFailures, strconv.FormatInt(failures, 10)); err != nil {
		return 0, err
	}
	if err := writeMaintenance(tx, maintCompactFailuresVersion, version); err != nil {
		return 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return int(failures), nil
}

func writeMaintenance(tx *sql.Tx, key, value string) error {
	_, err := tx.Exec(`INSERT INTO db_maintenance (key, value) VALUES (?, ?)
		ON CONFLICT(key) DO UPDATE SET value = excluded.value`, key, value)
	if err != nil {
		return fmt.Errorf("writing db_maintenance %s: %w", key, err)
	}
	return nil
}
