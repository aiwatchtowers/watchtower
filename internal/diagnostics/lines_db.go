package diagnostics

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"regexp"
	"slices"
	"strings"
	"sync"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/sqlcipher"
)

// DBReader is what ReadDB needs from an open database: the command's own
// aggregate reads and a close. *db.DB satisfies it; tests wrap one to slow
// or fail single statements.
type DBReader interface {
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
	Close() error
}

// OpenFunc opens the database at path under ctx.
type OpenFunc func(ctx context.Context, path string) (DBReader, error)

// Opener is the production OpenFunc: db.OpenExistingContext with busy as
// the per-statement busy timeout (Budgets.Busy). That opener never creates
// the file, runs no migration, opens query_only with the checkpoint on
// close off, and turns the lock-metrics sink off — the read writes nothing
// to the main database file (Decision 15).
func Opener(busy time.Duration) OpenFunc {
	return func(ctx context.Context, path string) (DBReader, error) {
		d, err := db.OpenExistingContext(ctx, path, busy)
		if err != nil {
			return nil, err
		}
		return d, nil
	}
}

// DBParts are the database parts of the report, values without labels.
// Sources is the account kinds part of the Sources line (`Slack 2 ok ·
// Gmail 1 ok`, "" when no kind is connected, or an `unknown (…)` text);
// QuickConnections is `Quick Connections <n>` (or `… unknown`), "" when
// Sources already says why the database parts are unknown; PipelineRuns
// holds the Recent errors rows from pipeline_runs joined by "\n" (each
// indented, "" when there are none) or one indented `pipeline runs
// unknown (…)` row; Schema is `schema <n>`, `schema unknown` or
// `schema unknown (…)`. Kinds are the form labels of the connected kinds,
// each once; Reasons holds ReasonDatabaseBusy when any part was busy.
type DBParts struct {
	Sources, QuickConnections, PipelineRuns, Schema string
	Kinds                                           []string
	Reasons                                         []string
}

const (
	quickConnectionsQuery = `SELECT count(*) FROM external_connections WHERE enabled = 1`
	recentErrorsQuery     = `SELECT pipeline, COALESCE(finished_at, started_at), error_msg FROM pipeline_runs
		WHERE status = 'error' ORDER BY COALESCE(finished_at, started_at) DESC, id DESC LIMIT 20`
	schemaQuery = `SELECT max(version_id) FROM goose_db_version`
)

// phaseRe is the shape of a pipeline name written by CreatePipelineRun (a
// code constant such as `digests` or `meeting_notes`); anything else is
// printed as `unknown`, so a stored value can never leak (DIAG-01).
var phaseRe = regexp.MustCompile(`^[a-z][a-z0-9_-]{0,39}$`)

// dbResult is ReadDB's shared state: the reader goroutine fills fields one
// by one; ReadDB snapshots it when the goroutine ends or it stops waiting.
type dbResult struct {
	mu                                        sync.Mutex
	stopped                                   bool
	schema, quick, runs, sources              string
	schemaSet, quickSet, runsSet, sourcesSet  bool
	schemaBusy, quickBusy, runsBusy, srcsBusy bool
	kinds                                     []string
}

// ReadDB reads the database parts of the report. All database work — the
// open and every query — runs under one deadline of b.DB started here,
// before the open; each statement also waits at most the busy timeout the
// opener was given. The reads run in a goroutine and ReadDB stops waiting
// for it at b.DBFallback (or when ctx ends), in case a call ignores its
// context: every part not delivered by then is `unknown (database busy)`,
// and a value delivered later is dropped. A missing file reads nothing and
// every part is `unknown (no database)`; an open that fails maps through
// OpenErrorText. The parts are read cheapest first: schema, Quick
// Connections, recent errors, then the source kinds.
//
// Writers of what is read: the account tables by the sync, sign-in and
// purge code (daemon and CLI), external_connections by Quick Connections,
// pipeline_runs by db.CreatePipelineRun/CompletePipelineRun, goose_db_version
// by migrations. ReadDB itself only reads: the production opener is
// query_only with no checkpoint on close.
func ReadDB(ctx context.Context, b Budgets, path string, open OpenFunc) DBParts {
	if _, err := os.Stat(path); errors.Is(err, fs.ErrNotExist) {
		return failedParts(UnknownNoDatabase)
	}
	dctx, cancel := context.WithTimeout(ctx, b.DB)
	defer cancel()

	res := &dbResult{}
	done := make(chan struct{})
	go func() {
		defer close(done)
		res.read(dctx, path, open)
	}()

	fallback := time.NewTimer(b.DBFallback)
	defer fallback.Stop()
	select {
	case <-done:
	case <-fallback.C:
	case <-ctx.Done():
	}
	return res.snapshot()
}

// failedParts is every database part saying unknown for one reason.
func failedParts(unknown string) DBParts {
	p := DBParts{
		Sources:      unknown,
		PipelineRuns: PipelineRunsUnknown(unknown),
		Schema:       SchemaUnknownBecause(unknown),
	}
	if unknown == UnknownDatabaseBusy {
		p.Reasons = []string{ReasonDatabaseBusy}
	}
	return p
}

// set stores one part unless ReadDB already stopped waiting.
func (r *dbResult) set(fn func()) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.stopped {
		return false
	}
	fn()
	return true
}

func (r *dbResult) read(ctx context.Context, path string, open OpenFunc) {
	d, err := open(ctx, path)
	if err != nil {
		text := OpenErrorText(err)
		if ctx.Err() != nil {
			text = UnknownDatabaseBusy
		}
		r.set(func() {
			f := failedParts(text)
			r.schema, r.runs, r.sources = f.Schema, f.PipelineRuns, f.Sources
			r.schemaSet, r.runsSet, r.sourcesSet, r.quickSet = true, true, true, true
			busy := text == UnknownDatabaseBusy
			r.schemaBusy, r.runsBusy, r.srcsBusy = busy, busy, busy
		})
		return
	}
	defer func() { _ = d.Close() }()

	schema, busy := readSchema(ctx, d)
	if !r.set(func() { r.schema, r.schemaBusy, r.schemaSet = schema, busy, true }) {
		return
	}
	quick, busy := readQuickConnections(ctx, d)
	if !r.set(func() { r.quick, r.quickBusy, r.quickSet = quick, busy, true }) {
		return
	}
	runs, busy := readRecentErrors(ctx, d)
	if !r.set(func() { r.runs, r.runsBusy, r.runsSet = runs, busy, true }) {
		return
	}
	sources, kinds, busy := readSources(ctx, d)
	r.set(func() { r.sources, r.kinds, r.srcsBusy, r.sourcesSet = sources, kinds, busy, true })
}

// snapshot stops further deliveries and turns every missing part into
// `unknown (database busy)`.
func (r *dbResult) snapshot() DBParts {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.stopped = true
	busy := failedParts(UnknownDatabaseBusy)
	p := DBParts{Kinds: r.kinds}
	anyBusy := false
	pick := func(set, isBusy bool, v, fallback string) string {
		if !set {
			anyBusy = true
			return fallback
		}
		anyBusy = anyBusy || isBusy
		return v
	}
	p.Schema = pick(r.schemaSet, r.schemaBusy, r.schema, busy.Schema)
	p.PipelineRuns = pick(r.runsSet, r.runsBusy, r.runs, busy.PipelineRuns)
	p.Sources = pick(r.sourcesSet, r.srcsBusy, r.sources, busy.Sources)
	p.QuickConnections = pick(r.quickSet, r.quickBusy, r.quick, kindWord(QuickConnections, UnknownDatabaseBusy))
	// When the whole Sources part is unknown it already says why; a
	// Quick Connections part failing the same way is left out
	// (`Sources: unknown (database busy) · iPhone companion on`).
	if strings.HasPrefix(p.Sources, UnknownWord) && strings.HasSuffix(p.QuickConnections, p.Sources) {
		p.QuickConnections = ""
	}
	if anyBusy {
		p.Reasons = []string{ReasonDatabaseBusy}
	}
	return p
}

// queryErr classifies a failed read: busy (the deadline, a cancel, a
// SQLITE_BUSY/LOCKED/INTERRUPT), a table or column an older schema lacks,
// or the database's own unreadable text.
func queryErr(ctx context.Context, err error) (unknown string, busy, missing bool) {
	if ctx.Err() != nil || isBusy(err) {
		return UnknownDatabaseBusy, true, false
	}
	msg := err.Error()
	if strings.Contains(msg, "no such table") || strings.Contains(msg, "no such column") {
		return UnknownWord, false, true
	}
	return OpenErrorText(err), false, false
}

func isBusy(err error) bool {
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) {
		return true
	}
	var se sqlcipher.Error
	if errors.As(err, &se) {
		switch se.Code {
		case sqlcipher.ErrBusy, sqlcipher.ErrLocked, sqlcipher.ErrInterrupt:
			return true
		}
	}
	return false
}

// OpenErrorText maps a database error to its printed part: the checkpoint
// guard (checked first — it also wraps a failed PRAGMA wal_autocheckpoint),
// busy, not a database, corrupt, permission, else other. The error's own
// text is never printed (DIAG-01).
func OpenErrorText(err error) string {
	if errors.Is(err, sqlcipher.ErrNoCheckpointGuard) {
		return DatabaseNoCkptGuard
	}
	if isBusy(err) {
		return UnknownDatabaseBusy
	}
	if errors.Is(err, fs.ErrPermission) {
		return DatabaseUnreadablePermission
	}
	var se sqlcipher.Error
	if errors.As(err, &se) {
		switch se.Code {
		case sqlcipher.ErrNotADB:
			return DatabaseUnreadableNotADB
		case sqlcipher.ErrCorrupt:
			return DatabaseUnreadableCorrupt
		case sqlcipher.ErrCantOpen, sqlcipher.ErrPerm, sqlcipher.ErrReadonly:
			return DatabaseUnreadablePermission
		}
	}
	return DatabaseUnreadableOther
}

// readSchema is `schema <max goose version>`; no goose table or no row →
// `schema unknown`.
func readSchema(ctx context.Context, d DBReader) (string, bool) {
	var v sql.NullInt64
	if err := queryRow(ctx, d, schemaQuery, &v); err != nil {
		unknown, busy, missing := queryErr(ctx, err)
		if missing {
			return SchemaUnknown, false
		}
		return SchemaUnknownBecause(unknown), busy
	}
	if !v.Valid {
		return SchemaUnknown, false
	}
	return Schema(v.Int64), false
}

// readQuickConnections is `Quick Connections <n>` (enabled ones); a
// missing table → `Quick Connections unknown`.
func readQuickConnections(ctx context.Context, d DBReader) (string, bool) {
	var n int
	if err := queryRow(ctx, d, quickConnectionsQuery, &n); err != nil {
		unknown, busy, _ := queryErr(ctx, err)
		return kindWord(QuickConnections, unknown), busy
	}
	return kindCount(QuickConnections, n), false
}

// readRecentErrors is the newest 20 failed pipeline runs as rows
// `<time>  <pipeline>  <class>`; the stored message only feeds ErrorClass.
func readRecentErrors(ctx context.Context, d DBReader) (string, bool) {
	var rows []string
	err := query(ctx, d, recentErrorsQuery, func(r *sql.Rows) error {
		var phase, at, msg string
		if err := r.Scan(&phase, &at, &msg); err != nil {
			return err
		}
		if !phaseRe.MatchString(phase) {
			phase = UnknownWord
		}
		class := ErrorClass(msg)
		if t, err := time.Parse(time.RFC3339, at); err == nil {
			rows = append(rows, RecentErrorRow(t, phase, class))
		} else {
			rows = append(rows, RowIndent+fmt.Sprintf(recentErrorRowFmt, UnknownWord, phase, class))
		}
		return nil
	})
	if err != nil {
		unknown, busy, _ := queryErr(ctx, err)
		return PipelineRunsUnknown(unknown), busy
	}
	return strings.Join(rows, "\n"), false
}

// readSources reads each kind on its own: a missing table or column makes
// that kind `<kind> unknown` while the others print; a busy read makes the
// whole part `unknown (database busy)`; any other failure makes it the
// database's unreadable text.
func readSources(ctx context.Context, d DBReader) (string, []string, bool) {
	var parts, kinds []string
	for _, st := range SourceTables {
		var tally kindTally
		err := query(ctx, d, st.Query, func(r *sql.Rows) error {
			var status string
			var enabled, n int
			if err := r.Scan(&status, &enabled, &n); err != nil {
				return err
			}
			tally.add(st, status, enabled != 0, n)
			return nil
		})
		if err != nil {
			unknown, busy, missing := queryErr(ctx, err)
			if !missing {
				return unknown, nil, busy
			}
			parts = append(parts, kindWord(st.Kind, UnknownWord))
			continue
		}
		if text := tally.text(st); text != "" {
			parts = append(parts, text)
			if st.FormLabel != "" && !slices.Contains(kinds, st.FormLabel) {
				kinds = append(kinds, st.FormLabel)
			}
		}
	}
	return JoinParts(parts...), kinds, false
}

// queryRow scans the single row of q into dest.
func queryRow(ctx context.Context, d DBReader, q string, dest ...any) error {
	found := false
	err := query(ctx, d, q, func(r *sql.Rows) error {
		found = true
		return r.Scan(dest...)
	})
	if err == nil && !found {
		return sql.ErrNoRows
	}
	return err
}

// query runs q and calls each for every row.
func query(ctx context.Context, d DBReader, q string, each func(*sql.Rows) error) error {
	rows, err := d.QueryContext(ctx, q)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		if err := each(rows); err != nil {
			return err
		}
	}
	return rows.Err()
}
