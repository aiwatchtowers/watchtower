package lockmetrics

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"net/url"
	"runtime"
	"strconv"
	"strings"
	"time"

	"modernc.org/sqlite"
	sqlite3 "modernc.org/sqlite/lib"
)

// DriverName is the database/sql driver internal/db opens: modernc's
// "sqlite" driver wrapped to time write locks. Every DSN, pragma, error and
// transaction mode passes through unchanged; the wrapper only measures.
//
// What it measures, on a file database (":memory:" is never measured):
//   - a transaction that is not ReadOnly: wait = BeginTx (BEGIN IMMEDIATE
//     waits there for the write lock), hold = BEGIN done → COMMIT/ROLLBACK
//     done; a KindTx event when Slow(wait, hold);
//   - an Exec outside a transaction that writes (autocommit): its whole
//     duration, which is both wait and hold, as HoldMS of a KindExec event;
//   - any SQLITE_BUSY/SQLITE_LOCKED from BeginTx, Exec, Query, Commit or
//     Rollback: a KindBusy event, whatever the threshold.
const DriverName = "sqlite+metrics"

// siteDepth bounds the stack captured for a transaction's site; frames past
// it are database/sql's and the driver's own far below the caller.
const siteDepth = 32

// modulePrefix is cut from function names in sites ("internal/sync.(*Syncer)…").
const modulePrefix = "watchtower/"

// siteSkipPrefixes are the frames a site never names: the runtime,
// database/sql, the driver and this package (the wrapper itself).
var siteSkipPrefixes = []string{
	"runtime.",
	"database/sql.",
	"modernc.org/",
	modulePrefix + "internal/db/lockmetrics.",
}

// genericHelpers are frames too generic to say who wrote: a site starting
// at one of them names the next caller too ("helper <- caller").
var genericHelpers = map[string]bool{
	modulePrefix + "internal/db.(*DB).WithTx": true,
}

func init() {
	// The registered modernc driver, not a fresh sqlite.Driver: functions,
	// collations and hooks registered on it apply to wrapped connections too.
	probe, err := sql.Open("sqlite", "")
	if err != nil {
		panic("lockmetrics: modernc sqlite driver not registered: " + err.Error())
	}
	base := probe.Driver()
	_ = probe.Close() // never connected; Close only drops the handle
	sql.Register(DriverName, metricsDriver{base: base})
}

type metricsDriver struct{ base driver.Driver }

// baseConn is the set of driver interfaces modernc's connection implements
// and database/sql uses; the wrapper forwards every one of them.
type baseConn interface {
	driver.Conn
	driver.ConnBeginTx
	driver.ConnPrepareContext
	driver.ExecerContext
	driver.QueryerContext
	driver.Pinger
	driver.SessionResetter
	driver.Validator
}

// Open opens the modernc connection and wraps it. A connection that lacks
// one of baseConn's interfaces (a different modernc version) goes back
// unwrapped, so the database keeps working, unmeasured.
func (d metricsDriver) Open(name string) (driver.Conn, error) {
	c, err := d.base.Open(name)
	if err != nil {
		return nil, err
	}
	bc, ok := c.(baseConn)
	if !ok {
		return c, nil
	}
	return &conn{base: bc, measured: !isMemoryDSN(name), busyTimeoutMS: dsnBusyTimeoutMS(name)}, nil
}

// conn is one wrapped connection. database/sql uses a connection from one
// goroutine at a time, so its fields need no lock.
type conn struct {
	base     baseConn
	measured bool
	// busyTimeoutMS mirrors the connection's busy_timeout: the DSN's
	// _pragma=busy_timeout(N), then every successful PRAGMA busy_timeout=N.
	busyTimeoutMS int64
	inTx          bool
	tx            tx // the open transaction; one per connection at a time
}

var (
	_ baseConn  = (*conn)(nil)
	_ driver.Tx = (*tx)(nil)
)

func (c *conn) Prepare(query string) (driver.Stmt, error) { return c.base.Prepare(query) }
func (c *conn) Close() error                              { return c.base.Close() }
func (c *conn) Ping(ctx context.Context) error            { return c.base.Ping(ctx) }
func (c *conn) IsValid() bool                             { return c.base.IsValid() }

func (c *conn) ResetSession(ctx context.Context) error { return c.base.ResetSession(ctx) }

func (c *conn) PrepareContext(ctx context.Context, query string) (driver.Stmt, error) {
	return c.base.PrepareContext(ctx, query)
}

// Begin is the deprecated form; database/sql calls BeginTx.
func (c *conn) Begin() (driver.Tx, error) {
	return c.BeginTx(context.Background(), driver.TxOptions{})
}

// BeginTx times the BEGIN of a write transaction and remembers the caller's
// stack (PCs only; symbolized only if an event is written). A ReadOnly
// transaction stays deferred and takes no write lock: it is not measured.
func (c *conn) BeginTx(ctx context.Context, opts driver.TxOptions) (driver.Tx, error) {
	if !c.measured || opts.ReadOnly {
		return c.base.BeginTx(ctx, opts)
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

// ExecContext times an autocommit write and tracks busy_timeout. Inside a
// transaction only a busy error is recorded; the tx event covers the rest.
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
	case c.inTx:
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

// QueryContext records a busy error from the statement's first step.
func (c *conn) QueryContext(ctx context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	if !c.measured {
		return c.base.QueryContext(ctx, query, args)
	}
	start := time.Now()
	rows, err := c.base.QueryContext(ctx, query, args)
	if err != nil {
		c.recordBusy(err, time.Since(start), 0, nil)
	}
	return rows, err
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

func (t *tx) Commit() error   { return t.end(t.base.Commit()) }
func (t *tx) Rollback() error { return t.end(t.base.Rollback()) }

// end records the finished transaction (err is its COMMIT/ROLLBACK
// result): a busy error (a COMMIT that could not get the lock) always, a
// slow transaction otherwise.
func (t *tx) end(err error) error {
	hold := time.Since(t.begun)
	t.c.inTx = false
	pcs := t.pcs[:t.npc]
	if !t.c.recordBusy(err, t.wait, hold, pcs) && Slow(t.wait, hold) {
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
	var se *sqlite.Error
	if err == nil || !errors.As(err, &se) {
		return "", false
	}
	code := se.Code()
	var primary string
	switch code & 0xff {
	case sqlite3.SQLITE_BUSY:
		primary = "SQLITE_BUSY"
	case sqlite3.SQLITE_LOCKED:
		primary = "SQLITE_LOCKED"
	default:
		return "", false
	}
	if code == code&0xff {
		return primary, true
	}
	if ext, ok := extendedBusyNames[code]; ok {
		return ext, true
	}
	return primary + "/" + strconv.Itoa(code), true
}

var extendedBusyNames = map[int]string{
	sqlite3.SQLITE_BUSY_RECOVERY:      "SQLITE_BUSY_RECOVERY",
	sqlite3.SQLITE_BUSY_SNAPSHOT:      "SQLITE_BUSY_SNAPSHOT",
	sqlite3.SQLITE_BUSY_TIMEOUT:       "SQLITE_BUSY_TIMEOUT",
	sqlite3.SQLITE_LOCKED_SHAREDCACHE: "SQLITE_LOCKED_SHAREDCACHE",
	sqlite3.SQLITE_LOCKED_VTAB:        "SQLITE_LOCKED_VTAB",
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
		return strings.Contains(q, "=")
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
// both a PRAGMA statement and the DSN's _pragma value use.
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

// dsnBusyTimeoutMS is the busy timeout a DSN's _pragma=busy_timeout(N) sets
// on every connection; 0 (SQLite's default) when it sets none.
func dsnBusyTimeoutMS(dsn string) int64 {
	_, query, ok := strings.Cut(dsn, "?")
	if !ok {
		return 0
	}
	vals, err := url.ParseQuery(query)
	if err != nil {
		return 0
	}
	var ms int64
	for _, p := range vals["_pragma"] {
		if v, ok := busyTimeoutValue(strings.ToLower(p)); ok {
			ms = v
		}
	}
	return ms
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
