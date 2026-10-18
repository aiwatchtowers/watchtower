// Package db provides database operations and schema management for watchtower's SQLite database.
package db

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/pressly/goose/v3"
	"modernc.org/sqlite"
	sqlite3 "modernc.org/sqlite/lib"

	"watchtower/internal/db/lockmetrics"
	"watchtower/internal/fsutil"
)

// DB wraps a *sql.DB connection to the watchtower SQLite database.
type DB struct {
	*sql.DB
	// connector opens every pool connection of a handle from Open or
	// OpenExisting*; nil on the test-only in-memory clones.
	connector *pragmaConnector
}

// pragmaConnector opens each pool connection from dsn — the driver runs the
// DSN's _pragma params on it — and then re-runs the pragmas SetBusyTimeout
// and SetReadOnly set on the handle. database/sql drops a connection after a
// context-cancelled statement (modernc reports it bad while interrupted) and
// opens a fresh one; a pragma run once with Exec would be lost there for the
// rest of the process.
type pragmaConnector struct {
	drv driver.Driver
	dsn string

	mu    sync.Mutex
	state connState
}

// connState is what SetBusyTimeout and SetReadOnly set on a handle.
type connState struct {
	busyTimeoutSet bool // false: the DSN's busy_timeout
	busyTimeoutMS  int64
	queryOnly      bool
}

func (c *pragmaConnector) Connect(ctx context.Context) (driver.Conn, error) {
	conn, err := c.drv.Open(c.dsn)
	if err != nil {
		return nil, err
	}
	c.mu.Lock()
	st := c.state
	c.mu.Unlock()
	var pragmas []string
	if st.busyTimeoutSet {
		pragmas = append(pragmas, fmt.Sprintf("PRAGMA busy_timeout=%d", st.busyTimeoutMS))
	}
	if st.queryOnly {
		pragmas = append(pragmas, "PRAGMA query_only=ON")
	}
	if len(pragmas) == 0 {
		return conn, nil
	}
	ex, ok := conn.(driver.ExecerContext)
	if !ok {
		_ = conn.Close()
		return nil, errors.New("sqlite connection cannot execute pragmas")
	}
	for _, p := range pragmas {
		if _, err := ex.ExecContext(ctx, p, nil); err != nil {
			_ = conn.Close()
			return nil, fmt.Errorf("executing %q: %w", p, err)
		}
	}
	return conn, nil
}

func (c *pragmaConnector) Driver() driver.Driver { return c.drv }

// metricsDriver is the registered lock-metrics driver every watchtower.db
// handle opens through; plainDriver is the bare SQLite driver a sidecar
// database opens through (OpenSidecar).
var (
	metricsDriver = registeredDriver(lockmetrics.DriverName)
	plainDriver   = registeredDriver("sqlite")
)

// registeredDriver resolves a registered database/sql driver by name
// (sql.Open never connects; it only resolves the name).
func registeredDriver(name string) driver.Driver {
	probe, err := sql.Open(name, "")
	if err != nil {
		panic("db: driver " + name + " not registered: " + err.Error())
	}
	defer probe.Close()
	return probe.Driver()
}

// openPool opens dsn as a one-connection pool through pragmaConnector and
// the lock-metrics driver. One connection: an in-memory database is private
// to its connection, and SQLite serializes writes anyway.
func openPool(dsn string) *DB {
	return openPoolWith(metricsDriver, dsn)
}

// openPoolWith is openPool over drv.
func openPoolWith(drv driver.Driver, dsn string) *DB {
	c := &pragmaConnector{drv: drv, dsn: dsn}
	sqlDB := sql.OpenDB(c)
	sqlDB.SetMaxOpenConns(1)
	return &DB{DB: sqlDB, connector: c}
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

// connPragmas are the per-connection pragmas of a writing handle (Open,
// OpenExistingRW) besides busy_timeout, which each opener sets itself; in
// the "name(value)" form both a DSN _pragma param and a PRAGMA statement take.
var connPragmas = []string{"foreign_keys(1)", "synchronous(NORMAL)"}

// connPragmaParams is connPragmas as DSN params ("_pragma=…").
func connPragmaParams() []string {
	out := make([]string, len(connPragmas))
	for i, p := range connPragmas {
		out[i] = "_pragma=" + p
	}
	return out
}

// openDSN is Open's DSN params: the tx lock mode plus the per-connection
// pragmas, which the driver runs on every new pool connection (journal_mode
// WAL is stored in the file, so setPragmas runs it once).
var openDSN = fmt.Sprintf("%s&_pragma=busy_timeout(%d)&%s",
	immediateTxDSN, busyTimeoutMS, strings.Join(connPragmaParams(), "&"))

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

	db := openPool(sqliteDSN(dbPath, openDSN))

	if err := db.setupSchema(dbPath); err != nil {
		db.Close()
		return nil, err
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

// OpenSidecar opens a database file another package owns beside
// watchtower.db (agentlog.db), creating it if needed: Open's DSN, pragmas
// and one-connection pool, and that package's migrations (the SQL files at
// the root of migrations) run with a goose Provider, which never touches the
// global goose state Open's migrations use. A file not yet current migrates
// under <path>.migrate.lock as Open does; the file modes are tightened as
// Open does. It does not go through the lock-metrics driver: dblock.jsonl
// events carry no database field, so its holds would read as watchtower.db's.
func OpenSidecar(path string, migrations fs.FS) (*sql.DB, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, fmt.Errorf("creating database directory: %w", err)
	}
	d := openPoolWith(plainDriver, sqliteDSN(path, openDSN))
	if err := d.setupSidecarSchema(path, migrations); err != nil {
		d.Close()
		return nil, err
	}
	tightenDBFilePerms(path)
	return d.DB, nil
}

// setupSidecarSchema is OpenSidecar's pragmas and migrations: setupSchema's
// order and lock, with a goose Provider over migrations.
func (db *DB) setupSidecarSchema(path string, migrations fs.FS) error {
	ctx := context.Background()
	p, err := goose.NewProvider(goose.DialectSQLite3, db.DB, migrations, goose.WithDisableGlobalRegistry(true))
	if err != nil {
		return fmt.Errorf("loading migrations: %w: %w", ErrSchemaSetup, err)
	}
	var mode string
	current := db.QueryRow(`PRAGMA journal_mode`).Scan(&mode) == nil && strings.EqualFold(mode, "wal")
	if current {
		// A new file has no version table yet: an error reads not current.
		pending, err := p.HasPending(ctx)
		current = err == nil && !pending
	}
	if !current {
		unlock, err := lockMigrations(path)
		if err != nil {
			return err
		}
		defer unlock()
	}
	if err := db.setPragmas(); err != nil {
		return fmt.Errorf("setting pragmas: %w: %w", ErrSchemaSetup, err)
	}
	if current {
		return nil
	}
	if _, err := p.Up(ctx); err != nil {
		return fmt.Errorf("running migrations: %w: %w", ErrSchemaSetup, err)
	}
	return nil
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
	d := openPool(dsn)
	if err := d.Ping(); err != nil {
		d.Close()
		return nil, fmt.Errorf("opening database %s: %w", dbPath, err)
	}
	// Only an open that worked points the lock-metrics sink at its file.
	lockmetrics.Configure(dbPath)
	return d, nil
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
	params := append([]string{strings.TrimPrefix(immediateTxDSN, "?")}, connPragmaParams()...)
	d, err := openExistingDSN(dbPath, existingDSN(dbPath, busy, params...))
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

// setPragmas switches the file to WAL (stored in the file) and sets the
// per-connection pragmas on the current connection. On Open's handles the
// latter repeat openDSN, which is what carries them to a later pool
// connection; the test-only in-memory clone needs them here because
// deserializing its snapshot resets synchronous.
func (db *DB) setPragmas() error {
	pragmas := []string{"PRAGMA journal_mode=WAL", fmt.Sprintf("PRAGMA busy_timeout=%d", busyTimeoutMS)}
	for _, p := range connPragmas {
		pragmas = append(pragmas, "PRAGMA "+p)
	}
	for _, p := range pragmas {
		if _, err := db.Exec(p); err != nil {
			return fmt.Errorf("executing %q: %w", p, err)
		}
	}
	return nil
}

// migrateLockWait bounds how long Open waits for another process's
// migration run; past it the Open fails with ErrMigrationInProgress. A var
// so a test can shorten it.
var migrateLockWait = 2 * time.Minute

// ErrMigrationInProgress marks an Open that gave up waiting for another
// process's migrations: a temporary condition, to be retried, unlike
// ErrSchemaSetup.
var ErrMigrationInProgress = errors.New("another Watchtower process is updating the database; try again in a moment")

// setupSchema is Open's pragmas and migrations. When the file is not yet
// current (schemaCurrent) they run under an exclusive flock on
// <dbPath>.migrate.lock, so two processes opening the database right after
// an update (the CLI, MCP servers, the session host's children) never apply
// the same pending migration at once: goose reads the applied versions once
// and then applies each pending one without re-checking, so a second runner
// would re-run DDL ("table already exists") or interleave a NO TRANSACTION
// table recreation. The waiter runs goose once the holder is done and finds
// nothing pending. The WAL switch is under the lock too: on a new file two
// concurrent switches fail one opener with SQLITE_BUSY. A current file takes
// no lock and runs no goose. The hooks on a hard time budget never get here:
// they open with OpenExisting*, which runs no migration; the Desktop's GRDB
// pool never takes this lock either.
func (db *DB) setupSchema(dbPath string) error {
	current := false
	if dbPath != ":memory:" {
		current = db.schemaCurrent()
	}
	if dbPath != ":memory:" && !current {
		unlock, err := lockMigrations(dbPath)
		if err != nil {
			return err
		}
		defer unlock()
	}

	if err := db.setPragmas(); err != nil {
		return fmt.Errorf("setting pragmas: %w: %w", ErrSchemaSetup, err)
	}

	// The lock-metrics sink sits next to the file. It is pointed there only
	// once the connection works (a failed open must not re-point this
	// process's sink) and before the migrations, so a slow one is recorded.
	// An in-memory open is never measured and must not unset the sink
	// another open configured.
	if dbPath != ":memory:" {
		lockmetrics.Configure(dbPath)
	}

	if current {
		return nil
	}
	if err := db.migrate(); err != nil {
		return fmt.Errorf("running migrations: %w: %w", ErrSchemaSetup, err)
	}
	return nil
}

// lockMigrations takes the exclusive flock on <dbPath>.migrate.lock,
// waiting at most migrateLockWait (then ErrMigrationInProgress).
func lockMigrations(dbPath string) (func(), error) {
	ctx, cancel := context.WithTimeout(context.Background(), migrateLockWait)
	defer cancel()
	unlock, err := fsutil.LockFile(ctx, dbPath+".migrate.lock")
	switch {
	case errors.Is(err, context.DeadlineExceeded):
		return nil, fmt.Errorf("%w: %w", ErrMigrationInProgress, err)
	case err != nil:
		return nil, fmt.Errorf("taking the migration lock: %w: %w", ErrSchemaSetup, err)
	}
	return unlock, nil
}

// embeddedMigrationVersions is the version of every migration in this
// binary — the embedded SQL files and the registered Go migrations, as
// goose collects them — read once.
var embeddedMigrationVersions = sync.OnceValues(func() ([]int64, error) {
	migrations, err := goose.CollectMigrations("migrations", 0, goose.MaxVersion)
	if err != nil {
		return nil, fmt.Errorf("collecting embedded migrations: %w", err)
	}
	out := make([]int64, len(migrations))
	for i, m := range migrations {
		out[i] = m.Version
	}
	return out, nil
})

// schemaCurrent reports, by reads only and without the migration lock,
// whether the file is already in WAL mode and records every embedded
// migration as applied — so goose.Up would have nothing to do. A failed read
// reads false: the locked path then decides, as before.
func (db *DB) schemaCurrent() bool {
	var mode string
	if err := db.QueryRow(`PRAGMA journal_mode`).Scan(&mode); err != nil || !strings.EqualFold(mode, "wal") {
		return false
	}
	want, err := embeddedMigrationVersions()
	if err != nil {
		return false
	}
	rows, err := db.Query(`SELECT version_id FROM goose_db_version WHERE is_applied = 1`)
	if err != nil {
		return false // no version table yet: a new file
	}
	defer rows.Close()
	applied := map[int64]bool{}
	for rows.Next() {
		var v int64
		if err := rows.Scan(&v); err != nil {
			return false
		}
		applied[v] = true
	}
	if rows.Err() != nil {
		return false
	}
	for _, v := range want {
		if !applied[v] {
			return false
		}
	}
	return true
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
// It holds for every later pool connection of the handle too.
func (db *DB) SetBusyTimeout(d time.Duration) error {
	ms := d.Milliseconds()
	err := db.setConnPragma(fmt.Sprintf("PRAGMA busy_timeout=%d", ms), func(st *connState) {
		st.busyTimeoutSet, st.busyTimeoutMS = true, ms
	})
	if err != nil {
		return fmt.Errorf("setting busy_timeout: %w", err)
	}
	return nil
}

// SetReadOnly flips the connection to SQLite query_only mode: any subsequent
// write (INSERT/UPDATE/DELETE/DDL) fails while reads keep working. Used by
// read-only consumers (the MCP server) after Open has run migrations.
// Because Begin is immediate (see Open), Begin() itself fails on such a
// handle; a transaction there must be opened with sql.TxOptions{ReadOnly: true}.
// It holds for every later pool connection of the handle too, so the fence
// survives a connection the pool replaced after a cancelled query.
func (db *DB) SetReadOnly() error {
	if err := db.setConnPragma("PRAGMA query_only=ON", func(st *connState) { st.queryOnly = true }); err != nil {
		return fmt.Errorf("setting query_only: %w", err)
	}
	return nil
}

// setConnPragma records change on the handle's connector before running
// pragma on the current connection, so a connection the pool opens in
// between already gets it; a failed pragma restores the previous state.
func (db *DB) setConnPragma(pragma string, change func(*connState)) error {
	c := db.connector
	var prev connState
	if c != nil {
		c.mu.Lock()
		prev = c.state
		change(&c.state)
		c.mu.Unlock()
	}
	if _, err := db.Exec(pragma); err != nil {
		if c != nil {
			c.mu.Lock()
			c.state = prev
			c.mu.Unlock()
		}
		return err
	}
	return nil
}

// HasTable reports whether the database has a table named name.
func (db *DB) HasTable(name string) (bool, error) {
	var ok bool
	err := db.QueryRow(`SELECT EXISTS (SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?)`, name).Scan(&ok)
	if err != nil {
		return false, fmt.Errorf("checking table %s: %w", name, err)
	}
	return ok, nil
}
