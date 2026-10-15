// Package db provides database operations and schema management for watchtower's SQLite database.
package db

import (
	"database/sql"
	"errors"
	"fmt"
	"log/slog"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/pressly/goose/v3"
	"modernc.org/sqlite"
	sqlite3 "modernc.org/sqlite/lib"

	"watchtower/internal/db/lockmetrics"
)

// DB wraps a *sql.DB connection to the watchtower SQLite database.
type DB struct {
	*sql.DB
}

// IsForeignKeyViolation reports whether err (or an error it wraps) is SQLite's
// FOREIGN KEY constraint failure (extended code SQLITE_CONSTRAINT_FOREIGNKEY),
// so a caller can tell a vanished parent row from any other write failure.
func IsForeignKeyViolation(err error) bool {
	var sqliteErr *sqlite.Error
	return errors.As(err, &sqliteErr) && sqliteErr.Code() == sqlite3.SQLITE_CONSTRAINT_FOREIGNKEY
}

// openMemoryHook, when non-nil, is called instead of the normal migration path
// whenever Open(":memory:") is invoked. Tests set this in TestMain to return a
// pre-migrated clone and avoid running goose on every test call.
var openMemoryHook func() (*DB, error)

// seedNewFileHook, when non-nil, is called by Open with a file path that does
// not exist yet, before the database is opened. This package's tests set it
// to write the pre-migrated template there, so a file-backed Open finds every
// migration applied instead of running goose from scratch (~15 s under -race)
// while still taking the real open path: DSN, pragmas, WAL, goose check,
// drift check, file modes. Never set outside tests.
var seedNewFileHook func(dbPath string) error

// immediateTxDSN makes every Begin/BeginTx that is not ReadOnly issue BEGIN
// IMMEDIATE, so a write transaction waits for the write lock under
// busy_timeout up front. A DEFERRED read-then-write transaction instead fails
// at once with SQLITE_BUSY_SNAPSHOT when another process commits in between —
// busy_timeout never covers that upgrade. The driver cuts the query off a
// plain path before opening the file (see sqliteDSN).
const immediateTxDSN = "?_txlock=immediate"

// busyTimeoutMS is how long a connection waits for another process's write
// lock before failing with SQLITE_BUSY — Open's default (SetBusyTimeout
// raises it for owner-click paths) and RunSchemaUpgrade's.
const busyTimeoutMS = 5000

// sqliteDSN appends the driver query params (params, starting with "?") to
// dbPath. The driver splits a DSN at its FIRST '?', so a plain path holding
// one would open the file named by the part before it and drop every param
// (the tx lock mode, pragmas) into a bogus query. Such a path goes in as a
// file: URI with the '?' percent-encoded, which SQLite decodes back to the
// real file name; every other path stays the plain path it always was.
func sqliteDSN(dbPath, params string) string {
	if !strings.Contains(dbPath, "?") {
		return dbPath + params
	}
	return "file:" + (&url.URL{Path: dbPath}).EscapedPath() + params
}

// ErrSchemaSetup marks an Open that reached the database but could not set
// its pragmas or apply the migrations (as opposed to a path or driver
// failure before it).
var ErrSchemaSetup = errors.New("database schema setup failed")

// Open creates directories if needed, opens the SQLite database, sets pragmas,
// and runs migrations. Pass ":memory:" for an in-memory database.
//
// Migrations are managed by goose against files embedded in migrations/.
// For pre-existing databases that used the legacy PRAGMA-based scheme,
// callers must invoke RunSchemaUpgrade(dbPath) once before Open() — see
// cmd/root.go for the centralized pre-flight.
func Open(dbPath string) (*DB, error) {
	if dbPath == ":memory:" && openMemoryHook != nil {
		return openMemoryHook()
	}
	if dbPath != ":memory:" {
		dir := filepath.Dir(dbPath)
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return nil, fmt.Errorf("creating database directory: %w", err)
		}
		if seedNewFileHook != nil {
			if _, err := os.Stat(dbPath); errors.Is(err, os.ErrNotExist) {
				if err := seedNewFileHook(dbPath); err != nil {
					return nil, fmt.Errorf("seeding test database: %w", err)
				}
			} else if err != nil {
				return nil, fmt.Errorf("checking database path: %w", err)
			}
		}
	}

	sqlDB, err := sql.Open(lockmetrics.DriverName, sqliteDSN(dbPath, immediateTxDSN))
	if err != nil {
		return nil, fmt.Errorf("opening database: %w", err)
	}

	// Limit to 1 connection: for :memory: databases each connection gets
	// its own independent database, and for file databases per-connection
	// pragmas (busy_timeout, foreign_keys, synchronous) would not apply
	// to new pooled connections. SQLite serializes writes anyway, so a
	// single connection avoids both issues with no performance loss.
	sqlDB.SetMaxOpenConns(1)

	db := &DB{DB: sqlDB}

	if err := db.setPragmas(); err != nil {
		sqlDB.Close()
		return nil, fmt.Errorf("setting pragmas: %w: %w", ErrSchemaSetup, err)
	}

	// The lock-metrics sink sits next to the file. It is pointed there only
	// once the connection works (a failed open must not re-point this
	// process's sink) and before the migrations, so a slow one is recorded.
	// An in-memory open is never measured and must not unset the sink
	// another open configured.
	if dbPath != ":memory:" {
		lockmetrics.Configure(dbPath)
	}

	if err := db.migrate(); err != nil {
		sqlDB.Close()
		return nil, fmt.Errorf("running migrations: %w: %w", ErrSchemaSetup, err)
	}

	// Logged, not returned: a database missing one feature's table must still
	// open for everything else. `watchtower db migrate` returns the error.
	if err := db.CheckSchemaDrift(); err != nil {
		slog.Error("database schema drift", "error", err)
	}

	if dbPath != ":memory:" {
		tightenDBFilePerms(dbPath)
	}

	return db, nil
}

// OpenExisting opens the database at dbPath for a caller on a hard time
// budget that only reads — a Claude Code hook the agent waits for. Unlike
// Open it never creates the directory or the database file (mode=rw),
// runs no migration and writes no schema (a schema older than the caller's
// query just fails that query), sets query_only so a statement that writes
// fails, and a statement waits at most busy for another process's lock,
// never Open's 5 s. SQLite itself may still create the -wal/-shm sidecars
// (when no other connection has them open) and checkpoint on close; neither
// changes the database's content.
func OpenExisting(dbPath string, busy time.Duration) (*DB, error) {
	return openExistingDSN(dbPath, existingDSN(dbPath, busy, "_pragma=query_only(1)"))
}

// existingDSN is the DSN of the hook openers: a file: URI so mode=rw (open,
// never create) reaches SQLite, a busy timeout of busy, and params (each
// "key=value"); the driver applies the _pragma params on every connection.
func existingDSN(dbPath string, busy time.Duration, params ...string) string {
	q := append([]string{"mode=rw", fmt.Sprintf("_pragma=busy_timeout(%d)", busy.Milliseconds())}, params...)
	return "file:" + (&url.URL{Path: dbPath}).EscapedPath() + "?" + strings.Join(q, "&")
}

// openExistingDSN opens dsn on one connection and checks the file is there.
func openExistingDSN(dbPath, dsn string) (*DB, error) {
	sqlDB, err := sql.Open(lockmetrics.DriverName, dsn)
	if err != nil {
		return nil, fmt.Errorf("opening database: %w", err)
	}
	sqlDB.SetMaxOpenConns(1)
	if err := sqlDB.Ping(); err != nil {
		sqlDB.Close()
		return nil, fmt.Errorf("opening database %s: %w", dbPath, err)
	}
	// Only an open that worked points the lock-metrics sink at its file.
	lockmetrics.Configure(dbPath)
	return &DB{DB: sqlDB}, nil
}

// OpenExistingRW opens the database at dbPath for a hook on a hard time
// budget that reads and then writes a little — the Stop ask guard. Like
// OpenExisting it never creates the directory or the file (mode=rw), runs no
// migration and writes no schema, and a statement waits at most busy for
// another process's lock; unlike it, writes are allowed (no query_only),
// foreign keys are enforced, synchronous is NORMAL and a write transaction
// begins IMMEDIATE, as on Open, and the file modes are tightened as Open
// does (a write may create the -wal/-shm sidecars). A schema older than the
// caller needs is found with HasColumns, never by the goose version (a
// crossed migration line is possible).
func OpenExistingRW(dbPath string, busy time.Duration) (*DB, error) {
	d, err := openExistingDSN(dbPath, existingDSN(dbPath, busy, strings.TrimPrefix(immediateTxDSN, "?"),
		"_pragma=foreign_keys(1)", "_pragma=synchronous(NORMAL)"))
	if err != nil {
		return nil, err
	}
	tightenDBFilePerms(dbPath)
	return d, nil
}

// HasColumns reports whether table exists with every one of cols, by schema
// lookup; a missing table reads false, a failed lookup is an error.
func (db *DB) HasColumns(table string, cols ...string) (bool, error) {
	rows, err := db.Query(`SELECT name FROM pragma_table_info(?)`, table)
	if err != nil {
		return false, fmt.Errorf("reading %s's columns: %w", table, err)
	}
	defer rows.Close()
	have := map[string]bool{}
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			return false, fmt.Errorf("reading %s's columns: %w", table, err)
		}
		have[name] = true
	}
	if err := rows.Err(); err != nil {
		return false, fmt.Errorf("reading %s's columns: %w", table, err)
	}
	if len(have) == 0 {
		return false, nil
	}
	for _, c := range cols {
		if !have[c] {
			return false, nil
		}
	}
	return true, nil
}

// tightenDBFilePerms restricts the database file and its WAL/SHM sidecars to
// 0600. SQLite creates all three itself, per the process umask (0644 in
// practice), so the mode is fixed after the fact rather than at creation —
// which also brings databases created before this code existed up to the
// house standard on their next open, instead of leaving them world-readable
// forever. The file holds every synced message, mail body and transcript.
//
// Best-effort by design: the parent directory is already 0700, so a chmod
// failure leaves the database no more exposed than before and must never stop
// the process from starting. It is logged, not swallowed. A sidecar that does
// not exist is a normal no-op — SQLite removes both on a clean close.
func tightenDBFilePerms(dbPath string) {
	for _, p := range []string{dbPath, dbPath + "-wal", dbPath + "-shm"} {
		if err := os.Chmod(p, 0o600); err != nil && !errors.Is(err, os.ErrNotExist) {
			slog.Warn("could not restrict database file permissions", "path", p, "error", err)
		}
	}
}

func (db *DB) setPragmas() error {
	pragmas := []string{
		"PRAGMA journal_mode=WAL",
		fmt.Sprintf("PRAGMA busy_timeout=%d", busyTimeoutMS),
		"PRAGMA foreign_keys=ON",
		"PRAGMA synchronous=NORMAL",
	}
	for _, p := range pragmas {
		if _, err := db.Exec(p); err != nil {
			return fmt.Errorf("executing %q: %w", p, err)
		}
	}
	return nil
}

func (db *DB) migrate() error {
	// Before goose: adopt Swift-created chat tables into the shape 00076
	// expects (see normalizeLegacyChatTables).
	if err := normalizeLegacyChatTables(db.DB); err != nil {
		return fmt.Errorf("normalizing legacy chat tables: %w", err)
	}
	return goose.Up(db.DB, "migrations")
}

// SetBusyTimeout replaces Open's 5 s busy_timeout on the connection: how long
// a write waits for another process's write lock before failing with
// SQLITE_BUSY. The owner-click write paths (approving an action, recording a
// chat proposal) raise it so a background daemon transaction cannot fail them.
func (db *DB) SetBusyTimeout(d time.Duration) error {
	if _, err := db.Exec(fmt.Sprintf("PRAGMA busy_timeout=%d", d.Milliseconds())); err != nil {
		return fmt.Errorf("setting busy_timeout: %w", err)
	}
	return nil
}

// SetReadOnly flips the connection to SQLite query_only mode: any subsequent
// write (INSERT/UPDATE/DELETE/DDL) fails while reads keep working. Used by
// read-only consumers (the MCP server) after Open has run migrations.
// Because Begin is immediate (see Open), Begin() itself fails on such a
// handle; a transaction there must be opened with sql.TxOptions{ReadOnly: true}.
func (db *DB) SetReadOnly() error {
	if _, err := db.Exec("PRAGMA query_only=ON"); err != nil {
		return fmt.Errorf("setting query_only: %w", err)
	}
	return nil
}
