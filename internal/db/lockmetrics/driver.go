package lockmetrics

import (
	"context"
	"database/sql/driver"
	"errors"
	"io"
	"net/url"
	"runtime"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/sqlcipher"
)

// Wrap returns a connector over base that times write locks on every
// connection it opens; dsn is the DSN base opens (what is measured is read
// from it: memory, query_only, busy_timeout). Every DSN, pragma, error and
// transaction mode passes through unchanged; the wrapper only measures.
//
// What it measures, on a file database (":memory:" is never measured):
//   - a transaction that is not ReadOnly: wait = BeginTx (BEGIN IMMEDIATE
//     waits there for the write lock), hold = BEGIN done → COMMIT/ROLLBACK
//     done; a KindTx event when Slow(wait, hold);
//   - an Exec outside a transaction that writes (autocommit), or a Query
//     that writes (an UPDATE … RETURNING) up to its first step, where SQLite
//     does the write: the call's duration as HoldMS of a KindExec event.
//     The driver cannot split that duration, so an exec's HoldMS is its wait
//     for the write lock and its hold together — never a pure hold, and
//     `db lockstats` keeps it apart from tx holds. A writing Query's
//     autocommit transaction stays open until rows.Close, which is not timed;
//   - any SQLITE_BUSY/SQLITE_LOCKED from BeginTx, Exec, Query, Commit or
//     Rollback: a KindBusy event, whatever the threshold, with WaitMS the
//     failing call's own duration.
//
// A connection whose DSN sets query_only (OpenExisting) never takes the
// write lock: only its busy errors are recorded. Not seen: a busy error
// from a later rows.Next (a WAL read step) and a prepared statement's Exec
// (the repo prepares only inside transactions, which the tx event covers).
func Wrap(base driver.Connector, dsn string) driver.Connector {
	return &connector{
		base:          base,
		measured:      !isMemoryDSN(dsn),
		queryOnly:     dsnQueryOnly(dsn),
		busyTimeoutMS: dsnBusyTimeoutMS(dsn),
	}
}

// siteDepth bounds the stack captured for a transaction's site; frames past
// it are database/sql's and the driver's own far below the caller.
const siteDepth = 32

// modulePrefix is cut from function names in sites ("internal/sync.(*Syncer)…").
const modulePrefix = "watchtower/"

// siteSkipPrefixes are the frames a site never names: the runtime,
// database/sql, the engine and this package (the wrapper itself).
var siteSkipPrefixes = []string{
	"runtime.",
	"database/sql.",
	modulePrefix + "internal/sqlcipher.",
	modulePrefix + "internal/db/lockmetrics.",
}

// genericHelpers are frames too generic to say who wrote: a site starting
// at one of them names the next caller too ("helper <- caller").
var genericHelpers = map[string]bool{
	modulePrefix + "internal/db.(*DB).WithTx":          true,
	modulePrefix + "internal/kb.withTx":                true,
	modulePrefix + "internal/extsync.(*Engine).withTx": true,
}

type connector struct {
	base          driver.Connector
	measured      bool
	queryOnly     bool
	busyTimeoutMS int64
}

// baseConn is the set of driver interfaces the engine's connection
// implements and database/sql uses; the wrapper forwards every one of them.
type baseConn interface {
	driver.Conn
	driver.ConnBeginTx
	driver.ConnPrepareContext
	driver.ExecerContext
	driver.QueryerContext
	driver.Pinger
}

// errUnmeasurable: the engine's connection lacks one of baseConn's
// interfaces (an engine upgrade dropped one). It fails the open instead of
// handing back an unwrapped, silently unmeasured connection.
var errUnmeasurable = errors.New("lockmetrics: the SQLite connection lacks a driver interface the lock metrics wrap")

// Connect opens the engine's connection and wraps it. The engine runs its
// connection pragmas on open, and one of them (synchronous) reads the
// schema, so an open can fail busy under another connection's exclusive
// lock: that busy error is recorded like a statement's.
func (c *connector) Connect(ctx context.Context) (driver.Conn, error) {
	start := time.Now()
	dc, err := c.base.Connect(ctx)
	if err != nil {
		if c.measured {
			(&conn{busyTimeoutMS: c.busyTimeoutMS}).recordBusy(err, time.Since(start), 0, nil)
		}
		return nil, err
	}
	bc, ok := dc.(baseConn)
	if !ok {
		_ = dc.Close()
		return nil, errUnmeasurable
	}
	return &conn{
		base:          bc,
		measured:      c.measured,
		queryOnly:     c.queryOnly,
		busyTimeoutMS: c.busyTimeoutMS,
	}, nil
}

func (c *connector) Driver() driver.Driver { return c.base.Driver() }

// conn is one wrapped connection. database/sql uses a connection from one
// goroutine at a time, so its fields need no lock.
type conn struct {
	base     baseConn
	measured bool
	// queryOnly: the DSN sets query_only, so the connection never writes —
	// its transactions and statements are not timed, only busy errors.
	queryOnly bool
	// busyTimeoutMS mirrors the connection's busy_timeout: the DSN's
	// _busy_timeout=N, then every successful PRAGMA busy_timeout=N.
	busyTimeoutMS int64
	inTx          bool
	tx            tx // the open transaction; one per connection at a time
}

var (
	_ baseConn  = (*conn)(nil)
	_ baseConn  = (*sqlcipher.SQLiteConn)(nil)
	_ baseRows  = (*sqlcipher.SQLiteRows)(nil)
	_ driver.Tx = (*tx)(nil)
)

func (c *conn) Prepare(query string) (driver.Stmt, error) { return c.base.Prepare(query) }
func (c *conn) Close() error                              { return c.base.Close() }
func (c *conn) Ping(ctx context.Context) error            { return c.base.Ping(ctx) }

func (c *conn) PrepareContext(ctx context.Context, query string) (driver.Stmt, error) {
	return c.base.PrepareContext(ctx, query)
}

// Begin is the deprecated form; database/sql calls BeginTx.
func (c *conn) Begin() (driver.Tx, error) {
	return c.BeginTx(context.Background(), driver.TxOptions{})
}

// BeginTx times the BEGIN of a write transaction and remembers the caller's
// stack (PCs only; symbolized only if an event is written). A ReadOnly
// transaction stays deferred and takes no write lock, nor does any on a
// query_only connection: those are not timed, only a busy BEGIN is recorded.
func (c *conn) BeginTx(ctx context.Context, opts driver.TxOptions) (driver.Tx, error) {
	if !c.measured {
		return c.base.BeginTx(ctx, opts)
	}
	if opts.ReadOnly || c.queryOnly {
		start := time.Now()
		t, err := c.base.BeginTx(ctx, opts)
		if err != nil {
			c.recordBusy(err, time.Since(start), 0, nil)
		}
		return t, err
	}
	c.tx = tx{c: c}
	c.tx.npc = runtime.Callers(2, c.tx.pcs[:])
	start := time.Now()
	t, err := c.base.BeginTx(ctx, opts)
	begun := time.Now()
	if err != nil {
		c.recordBusy(err, begun.Sub(start), 0, c.tx.pcs[:c.tx.npc])
		return nil, err
	}
	c.tx.base, c.tx.wait, c.tx.begun = t, begun.Sub(start), begun
	c.inTx = true
	return &c.tx, nil
}

// ExecContext times an autocommit write — wait and hold together, which the
// driver cannot split — and tracks busy_timeout. Inside a transaction only a
// busy error is recorded; the tx event covers the rest.
func (c *conn) ExecContext(ctx context.Context, query string, args []driver.NamedValue) (driver.Result, error) {
	if !c.measured {
		return c.base.ExecContext(ctx, query, args)
	}
	start := time.Now()
	res, err := c.base.ExecContext(ctx, query, args)
	took := time.Since(start)
	switch {
	case err != nil:
		c.recordBusy(err, took, 0, nil)
	case c.inTx || c.queryOnly:
	case Slow(0, took) && isWrite(query):
		c.record(Event{Kind: KindExec, HoldMS: took.Milliseconds()}, nil)
	}
	if err == nil {
		if ms, ok := pragmaBusyTimeoutMS(query); ok {
			c.busyTimeoutMS = ms
		}
	}
	return res, err
}

// QueryContext records a busy error from the statement's first step, and
// times an autocommit write run as a query (UPDATE … RETURNING) up to that
// first step, where SQLite does the whole write, so the lock wait falls
// inside it. The engine steps the first row on the first rows.Next, so the
// rows are wrapped to see that step (firstStepRows). The autocommit
// transaction then stays open until rows.Close, which is not timed.
func (c *conn) QueryContext(ctx context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	if !c.measured {
		return c.base.QueryContext(ctx, query, args)
	}
	start := time.Now()
	rows, err := c.base.QueryContext(ctx, query, args)
	if err != nil {
		c.recordBusy(err, time.Since(start), 0, nil)
		return nil, err
	}
	br, ok := rows.(baseRows)
	if !ok {
		_ = rows.Close()
		return nil, errUnmeasurable
	}
	timed := !c.inTx && !c.queryOnly && isWrite(query)
	return &firstStepRows{baseRows: br, c: c, start: start, timed: timed}, nil
}

// baseRows is the set of driver rows interfaces the engine's rows implement
// and database/sql uses; firstStepRows forwards every one of them.
type baseRows interface {
	driver.Rows
	driver.RowsColumnTypeDatabaseTypeName
	driver.RowsColumnTypeNullable
	driver.RowsColumnTypeScanType
}

// firstStepRows watches the first Next — the statement's first step: a busy
// error there is recorded, and a write run as a query (timed) is recorded
// as a KindExec event from QueryContext's start to that step's end.
type firstStepRows struct {
	baseRows
	c     *conn
	start time.Time
	timed bool
	done  bool // the first step was seen
}

func (r *firstStepRows) Next(dest []driver.Value) error {
	err := r.baseRows.Next(dest)
	if r.done {
		return err
	}
	r.done = true
	took := time.Since(r.start)
	switch {
	case err != nil && !errors.Is(err, io.EOF):
		r.c.recordBusy(err, took, 0, nil)
	case r.timed && Slow(0, took):
		r.c.record(Event{Kind: KindExec, HoldMS: took.Milliseconds()}, nil)
	}
	return err
}

// tx wraps the driver's transaction to time its hold.
type tx struct {
	c     *conn
	base  driver.Tx
	wait  time.Duration
	begun time.Time
	pcs   [siteDepth]uintptr
	npc   int
}

func (t *tx) Commit() error   { return t.end(t.base.Commit) }
func (t *tx) Rollback() error { return t.end(t.base.Rollback) }

// end runs finish (the COMMIT or ROLLBACK) and records the transaction: a
// busy error (a COMMIT that could not get the lock) always, with the
// COMMIT's own wait, a slow transaction otherwise.
func (t *tx) end(finish func() error) error {
	start := time.Now()
	err := finish()
	done := time.Now()
	hold := done.Sub(t.begun)
	t.c.inTx = false
	pcs := t.pcs[:t.npc]
	if !t.c.recordBusy(err, done.Sub(start), hold, pcs) && Slow(t.wait, hold) {
		t.c.record(Event{Kind: KindTx, WaitMS: t.wait.Milliseconds(), HoldMS: hold.Milliseconds()}, pcs)
	}
	return err
}

// recordBusy writes a KindBusy event when err is SQLITE_BUSY/SQLITE_LOCKED
// and reports whether it was one. pcs nil means the caller is still on the
// stack: capture it now.
func (c *conn) recordBusy(err error, wait, hold time.Duration, pcs []uintptr) bool {
	name, ok := busyName(err)
	if !ok {
		return false
	}
	c.record(Event{Kind: KindBusy, Err: name, WaitMS: wait.Milliseconds(), HoldMS: hold.Milliseconds()}, pcs)
	return true
}

// record fills the site and busy timeout and writes e. pcs nil captures the
// current stack.
func (c *conn) record(e Event, pcs []uintptr) {
	if !Enabled() {
		return
	}
	if pcs == nil {
		var buf [siteDepth]uintptr
		pcs = buf[:runtime.Callers(2, buf[:])]
	}
	e.Site = siteOf(pcs)
	e.BusyTimeoutMS = c.busyTimeoutMS
	Record(e)
}

// busyName names a SQLITE_BUSY/SQLITE_LOCKED error by its primary code,
// with the extended code when it differs ("SQLITE_BUSY_SNAPSHOT").
func busyName(err error) (string, bool) {
	var se sqlcipher.Error
	if err == nil || !errors.As(err, &se) {
		return "", false
	}
	var primary string
	switch se.Code {
	case sqlcipher.ErrBusy:
		primary = "SQLITE_BUSY"
	case sqlcipher.ErrLocked:
		primary = "SQLITE_LOCKED"
	default:
		return "", false
	}
	ext := int(se.ExtendedCode)
	if ext == 0 || ext == int(se.Code) {
		return primary, true
	}
	if name, ok := extendedBusyNames[ext]; ok {
		return name, true
	}
	return primary + "/" + strconv.Itoa(ext), true
}

// The extended codes the engine package has no constant for.
const (
	sqliteBusyTimeout = 773 // SQLITE_BUSY | 3<<8
	sqliteLockedVTab  = 518 // SQLITE_LOCKED | 2<<8
)

var extendedBusyNames = map[int]string{
	int(sqlcipher.ErrBusyRecovery):      "SQLITE_BUSY_RECOVERY",
	int(sqlcipher.ErrBusySnapshot):      "SQLITE_BUSY_SNAPSHOT",
	sqliteBusyTimeout:                   "SQLITE_BUSY_TIMEOUT",
	int(sqlcipher.ErrLockedSharedCache): "SQLITE_LOCKED_SHAREDCACHE",
	sqliteLockedVTab:                    "SQLITE_LOCKED_VTAB",
}

// siteOf names the first frame outside the runtime, database/sql, the
// driver and this package, module prefix cut; a generic helper there is
// followed by its caller ("internal/db.(*DB).WithTx <- internal/x.F").
func siteOf(pcs []uintptr) string {
	if len(pcs) == 0 {
		return ""
	}
	frames := runtime.CallersFrames(pcs)
	site := ""
	for {
		f, more := frames.Next()
		if f.Function != "" && !skipFrame(f.Function) {
			name := strings.TrimPrefix(f.Function, modulePrefix)
			if site != "" {
				return site + " <- " + name
			}
			site = name
			if !genericHelpers[f.Function] {
				return site
			}
		}
		if !more {
			return site
		}
	}
}

func skipFrame(fn string) bool {
	for _, p := range siteSkipPrefixes {
		if strings.HasPrefix(fn, p) {
			return true
		}
	}
	return false
}

// isWrite reports whether an autocommit statement may take the write lock:
// everything except SELECT, EXPLAIN, WITH (a CTE is almost always a read)
// and a PRAGMA that sets nothing.
func isWrite(query string) bool {
	q := skipSpaceAndComments(query)
	end := 0
	for end < len(q) && isWordByte(q[end]) {
		end++
	}
	switch strings.ToLower(q[:end]) {
	case "select", "explain", "with":
		return false
	case "pragma":
		stmt, _, _ := strings.Cut(q, ";")
		return strings.Contains(stmt, "=")
	}
	return true
}

func isWordByte(b byte) bool {
	return b >= 'a' && b <= 'z' || b >= 'A' && b <= 'Z' || b == '_'
}

// skipSpaceAndComments drops leading whitespace, "--" line comments and
// "/* */" block comments.
func skipSpaceAndComments(q string) string {
	for {
		q = strings.TrimLeft(q, " \t\r\n")
		switch {
		case strings.HasPrefix(q, "--"):
			i := strings.IndexByte(q, '\n')
			if i < 0 {
				return ""
			}
			q = q[i+1:]
		case strings.HasPrefix(q, "/*"):
			i := strings.Index(q, "*/")
			if i < 0 {
				return ""
			}
			q = q[i+2:]
		default:
			return q
		}
	}
}

// pragmaBusyTimeoutMS parses "PRAGMA busy_timeout=N" / "PRAGMA
// busy_timeout(N)" (any case and spacing; a "main." schema prefix allowed).
func pragmaBusyTimeoutMS(query string) (int64, bool) {
	q := strings.ToLower(skipSpaceAndComments(query))
	rest, ok := strings.CutPrefix(q, "pragma")
	if !ok {
		return 0, false
	}
	rest = strings.TrimSpace(rest)
	rest = strings.TrimPrefix(rest, "main.")
	return busyTimeoutValue(rest)
}

// busyTimeoutValue parses "busy_timeout=N" or "busy_timeout(N)", the form
// a PRAGMA statement uses.
func busyTimeoutValue(s string) (int64, bool) {
	rest, ok := strings.CutPrefix(strings.TrimSpace(s), "busy_timeout")
	if !ok {
		return 0, false
	}
	rest = strings.TrimSpace(rest)
	switch {
	case strings.HasPrefix(rest, "="):
		rest = rest[1:]
	case strings.HasPrefix(rest, "("):
		rest = strings.TrimSuffix(strings.TrimSpace(rest[1:]), ")")
	default:
		return 0, false
	}
	rest = strings.TrimSuffix(strings.TrimSpace(rest), ";")
	ms, err := strconv.ParseInt(strings.TrimSpace(rest), 10, 64)
	if err != nil {
		return 0, false
	}
	return ms, true
}

// engineDefaultBusyTimeoutMS is the busy_timeout the engine sets on every
// connection whose DSN names none (mattn's default).
const engineDefaultBusyTimeoutMS = 5000

// dsnBusyTimeoutMS is the busy timeout a DSN's _busy_timeout=N (or its
// _timeout alias) sets on every connection; the engine's default when it
// sets none.
func dsnBusyTimeoutMS(dsn string) int64 {
	vals, ok := dsnParams(dsn)
	if !ok {
		return engineDefaultBusyTimeoutMS
	}
	for _, key := range []string{"_busy_timeout", "_timeout"} {
		if v := vals.Get(key); v != "" {
			if ms, err := strconv.ParseInt(v, 10, 64); err == nil {
				return ms
			}
		}
	}
	return engineDefaultBusyTimeoutMS
}

// dsnQueryOnly reports whether a DSN's _query_only turns query_only on for
// every connection.
func dsnQueryOnly(dsn string) bool {
	vals, ok := dsnParams(dsn)
	if !ok {
		return false
	}
	switch strings.ToLower(vals.Get("_query_only")) {
	case "1", "yes", "true", "on":
		return true
	}
	return false
}

// dsnParams is a DSN's query params, as the engine reads them.
func dsnParams(dsn string) (url.Values, bool) {
	_, query, ok := strings.Cut(dsn, "?")
	if !ok {
		return nil, false
	}
	vals, err := url.ParseQuery(query)
	if err != nil {
		return nil, false
	}
	return vals, true
}

// isMemoryDSN reports an in-memory database: ":memory:", "file::memory:",
// a mode=memory URI or the empty name (a temporary database).
func isMemoryDSN(dsn string) bool {
	path, query, _ := strings.Cut(dsn, "?")
	path = strings.TrimPrefix(path, "file:")
	if path == "" || path == ":memory:" {
		return true
	}
	vals, err := url.ParseQuery(query)
	return err == nil && vals.Get("mode") == "memory"
}
