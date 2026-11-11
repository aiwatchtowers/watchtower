package diagnostics

import (
	"bytes"
	"context"
	"crypto/rand"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"testing/synctest"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/sqlcipher"
)

// newDBFile creates a migrated database file and returns its path and a
// handle for seeding (closed in cleanup).
func newDBFile(t *testing.T) (string, *db.DB) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "watchtower.db")
	d, err := db.Open(path)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { _ = d.Close() })
	return path, d
}

func execAll(t *testing.T, d *db.DB, stmts ...string) {
	t.Helper()
	for _, s := range stmts {
		if _, err := d.Exec(s); err != nil {
			t.Fatalf("%s: %v", s, err)
		}
	}
}

func readParts(t *testing.T, path string) DBParts {
	t.Helper()
	return readDB(t, DefaultBudgets, path, Opener(DefaultBudgets.Busy))
}

// readDB is ReadDB in a synctest bubble: its budgets are the bubble's time,
// which does not move while the reads run, so a slow machine never turns a
// part into `unknown (database busy)`.
func readDB(t *testing.T, b Budgets, path string, open OpenFunc) (p DBParts) {
	t.Helper()
	synctest.Test(t, func(*testing.T) { p = ReadDB(context.Background(), b, path, open) })
	return p
}

// fakeReader wraps a real reader: it can delay every statement (honouring
// ctx or not) and fail the statements containing failOn.
type fakeReader struct {
	DBReader
	delay    time.Duration
	honorCtx bool
	failOn   string
	failErr  error
	panicOn  string
	closed   chan struct{}
}

func (f fakeReader) QueryContext(ctx context.Context, q string, args ...any) (*sql.Rows, error) {
	if f.panicOn != "" && strings.Contains(q, f.panicOn) {
		panic("reader bug")
	}
	if f.failOn != "" && strings.Contains(q, f.failOn) {
		return nil, f.failErr
	}
	if f.delay > 0 {
		if f.honorCtx {
			select {
			case <-time.After(f.delay):
			case <-ctx.Done():
				return nil, ctx.Err()
			}
		} else {
			time.Sleep(f.delay)
		}
	}
	return f.DBReader.QueryContext(ctx, q, args...)
}

// Close closes the real reader, then tells the test the reader goroutine
// is done with the files.
func (f fakeReader) Close() error {
	defer close(f.closed)
	return f.DBReader.Close()
}

// wrapOpener opens the real database and wraps it in f. The test waits in
// cleanup until the reader was closed (or the open failed), so a reader
// goroutine ReadDB stopped waiting for never touches the -wal/-shm while
// t.TempDir is removed.
func wrapOpener(t *testing.T, f fakeReader) OpenFunc {
	t.Helper()
	finished := make(chan struct{})
	t.Cleanup(func() { <-finished }) // a reader never closed is go test -timeout's
	return func(ctx context.Context, p string) (DBReader, error) {
		r, err := Opener(DefaultBudgets.Busy)(ctx, p)
		if err != nil {
			close(finished)
			return nil, err
		}
		f.DBReader, f.closed = r, finished
		return f, nil
	}
}

func failingOpener(err error) OpenFunc {
	return func(context.Context, string) (DBReader, error) { return nil, err }
}

func TestDiagnostics_SourcesLine(t *testing.T) {
	path, d := newDBFile(t)
	execAll(t, d,
		`INSERT INTO slack_accounts (status, enabled, team_name) VALUES ('ok', 1, 'canary-team'), ('revoked', 1, ''), ('removed', 1, ''), ('removed', 0, ''), ('ok', 0, '')`,
		`INSERT INTO google_accounts (email, status, gmail_enabled, calendar_enabled) VALUES ('a@example.com', 'ok', 1, 1), ('b@example.com', 'revoked', 1, 0), ('c@example.com', 'ok', 0, 0)`,
		`INSERT INTO jira_accounts (id, status, enabled) VALUES (1, 'ok', 1)`,
		`INSERT INTO ext_sources (provider, jira_account_id, container_key, status, enabled) VALUES ('confluence', 1, 'A', 'ok', 1), ('confluence', 1, 'B', 'ok', 1), ('confluence', 1, 'C', 'needs_consent', 1)`,
		`INSERT INTO linear_accounts (status, enabled) VALUES ('error', 1), ('removed', 1)`,
		`INSERT INTO email_accounts (provider, status) VALUES ('imap', 'ok'), ('outlook', 'ok'), ('outlook', 'error')`,
		`INSERT INTO calendar_accounts (provider, status) VALUES ('caldav', 'ok')`,
		`INSERT INTO external_connections (name, enabled) VALUES ('canary-a', 1), ('canary-b', 1), ('canary-c', 0)`,
	)
	p := readParts(t, path)
	want := "Slack 3 (1 needs sign-in, 1 off) · Gmail 2 (1 needs sign-in) · Google Calendar 1 ok · Jira 1 ok · " +
		"Confluence 3 spaces (1 needs sign-in) · Linear 1 (1 error) · Email (IMAP) 1 ok · Outlook 2 (1 error) · " +
		"Calendar (CalDAV/ICS) 1 ok"
	if p.Sources != want {
		t.Errorf("Sources:\n got %q\nwant %q", p.Sources, want)
	}
	if p.QuickConnections != "Quick Connections 2" {
		t.Errorf("QuickConnections = %q", p.QuickConnections)
	}
	wantKinds := []string{"Slack", "Gmail", "Google Calendar", "Jira", "Confluence", "Linear", "Email over IMAP"}
	if !slices.Equal(p.Kinds, wantKinds) {
		t.Errorf("Kinds = %q, want %q", p.Kinds, wantKinds)
	}
	if len(p.Reasons) != 0 {
		t.Errorf("Reasons = %q", p.Reasons)
	}
	if strings.Contains(fmt.Sprint(p), "canary") || strings.Contains(fmt.Sprint(p), "example.com") {
		t.Errorf("a name leaked: %+v", p)
	}
}

func TestDiagnostics_SourcesOutlookOnlyAndEmpty(t *testing.T) {
	path, d := newDBFile(t)
	if p := readParts(t, path); p.Sources != "" || p.Kinds != nil || p.QuickConnections != "Quick Connections 0" {
		t.Errorf("empty database: %+v", p)
	}
	execAll(t, d,
		`INSERT INTO email_accounts (provider, status) VALUES ('outlook', 'ok')`,
		`INSERT INTO slack_accounts (status) VALUES ('removed')`,
	)
	p := readParts(t, path)
	if p.Sources != "Outlook 1 ok" || !slices.Equal(p.Kinds, []string{FormEmailOverIMAP}) {
		t.Errorf("got %q, kinds %q", p.Sources, p.Kinds)
	}
}

func TestDiagnostics_SourcesMissingTable(t *testing.T) {
	path, d := newDBFile(t)
	execAll(t, d,
		`DROP TABLE linear_accounts`,
		`INSERT INTO slack_accounts (status) VALUES ('ok'), ('weird')`,
		`INSERT INTO jira_accounts (status) VALUES ('ok')`,
	)
	p := readParts(t, path)
	want := "Slack 2 (1 unknown state) · Jira 1 ok · Linear unknown"
	if p.Sources != want {
		t.Errorf("Sources = %q, want %q", p.Sources, want)
	}
	if len(p.Reasons) != 0 {
		t.Errorf("Reasons = %q", p.Reasons)
	}
}

// TestDiagnostics_AccountTablesMapped: every `%_accounts` table of a fully
// migrated database has a SourceTables entry, so a new source cannot be
// silently missing from the report.
func TestDiagnostics_AccountTablesMapped(t *testing.T) {
	_, d := newDBFile(t)
	rows, err := d.Query(`SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE '%\_accounts' ESCAPE '\'`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	n := 0
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			t.Fatal(err)
		}
		n++
		if !slices.ContainsFunc(SourceTables, func(st SourceTable) bool { return st.Table == name }) {
			t.Errorf("account table %s has no SourceTables entry", name)
		}
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	if n == 0 {
		t.Fatal("no account tables found")
	}
}

func TestDiagnostics_QuickConnections(t *testing.T) {
	t.Run("quick_connections_count", func(t *testing.T) {
		path, d := newDBFile(t)
		execAll(t, d, `INSERT INTO external_connections (name, enabled) VALUES ('a', 1), ('b', 0), ('c', 1), ('d', 1)`)
		if got := readParts(t, path).QuickConnections; got != "Quick Connections 3" {
			t.Errorf("got %q", got)
		}
	})
	t.Run("quick_connections_missing_table", func(t *testing.T) {
		path, d := newDBFile(t)
		execAll(t, d, `DROP TABLE external_connection_tools`, `DROP TABLE ext_sources`, `DROP TABLE external_connections`)
		p := readParts(t, path)
		if p.QuickConnections != "Quick Connections unknown" {
			t.Errorf("got %q", p.QuickConnections)
		}
		if !strings.Contains(p.Sources, "Confluence unknown") {
			t.Errorf("Sources = %q", p.Sources)
		}
	})
}

func TestDiagnostics_RecentErrors(t *testing.T) {
	path, d := newDBFile(t)
	if got := readParts(t, path).PipelineRuns; got != "" {
		t.Fatalf("no rows: %q", got)
	}
	base := time.Date(2026, 11, 4, 10, 0, 0, 0, time.UTC)
	for i := range 25 {
		pipeline, msg := "digests", "rate limit hit for canary-channel"
		if i == 24 {
			pipeline, msg = "Canary:U123", "invalid_auth canary-person"
		}
		at := base.Add(time.Duration(i) * time.Minute).Format(time.RFC3339)
		if _, err := d.Exec(`INSERT INTO pipeline_runs (pipeline, status, error_msg, finished_at) VALUES (?, 'error', ?, ?)`, pipeline, msg, at); err != nil {
			t.Fatal(err)
		}
	}
	execAll(t, d, `INSERT INTO pipeline_runs (pipeline, status, finished_at) VALUES ('people', 'done', '2026-11-05T00:00:00Z')`)

	got := readParts(t, path).PipelineRuns
	rows := strings.Split(got, "\n")
	if len(rows) != 20 {
		t.Fatalf("%d rows, want 20:\n%s", len(rows), got)
	}
	if rows[0] != "  2026-11-04 10:24Z  unknown  auth" {
		t.Errorf("row 0 = %q", rows[0])
	}
	if rows[1] != "  2026-11-04 10:23Z  digests  rate_limit" {
		t.Errorf("row 1 = %q", rows[1])
	}
	if rows[19] != "  2026-11-04 10:05Z  digests  rate_limit" {
		t.Errorf("row 19 = %q", rows[19])
	}
	if strings.Contains(got, "canary") || strings.Contains(got, "Canary") {
		t.Errorf("stored text leaked:\n%s", got)
	}
}

func TestDiagnostics_RecentErrorsMissingTable(t *testing.T) {
	path, d := newDBFile(t)
	execAll(t, d, `DROP TABLE pipeline_runs`, `INSERT INTO slack_accounts (status) VALUES ('ok')`)
	p := readParts(t, path)
	if p.PipelineRuns != "  pipeline runs unknown (older schema)" {
		t.Errorf("PipelineRuns = %q", p.PipelineRuns)
	}
	if p.Sources != "Slack 1 ok" || len(p.Reasons) != 0 {
		t.Errorf("other parts: %+v", p)
	}
}

func TestDiagnostics_DatabaseLine(t *testing.T) {
	path, d := newDBFile(t)
	var version int64
	if err := d.QueryRow(`SELECT max(version_id) FROM goose_db_version`).Scan(&version); err != nil {
		t.Fatal(err)
	}
	if got, want := readParts(t, path).Schema, fmt.Sprintf("schema %d", version); got != want {
		t.Errorf("Schema = %q, want %q", got, want)
	}
	execAll(t, d, `DROP TABLE goose_db_version`)
	if got := readParts(t, path).Schema; got != SchemaUnknown {
		t.Errorf("no goose table: %q", got)
	}
}

// TestDiagnostics_DBInputFailures: every database part says why it is
// unknown, with the spec's exact text, and the error text never shows.
func TestDiagnostics_DBInputFailures(t *testing.T) {
	cases := []struct {
		name    string
		setup   func(t *testing.T) string
		open    OpenFunc
		unknown string
	}{
		{
			name:    "db_missing",
			setup:   func(t *testing.T) string { return filepath.Join(t.TempDir(), "watchtower.db") },
			unknown: UnknownNoDatabase,
		},
		{
			name: "db_not_a_database",
			setup: func(t *testing.T) string {
				b := make([]byte, 16384)
				_, _ = rand.Read(b)
				p := filepath.Join(t.TempDir(), "watchtower.db")
				writeFile(t, p, string(b))
				return p
			},
			unknown: DatabaseUnreadableNotADB,
		},
		{
			name:    "db_corrupt",
			setup:   corruptDB,
			unknown: DatabaseUnreadableCorrupt,
		},
		{
			name: "db_permission",
			setup: func(t *testing.T) string {
				skipIfRoot(t)
				path, d := newDBFile(t)
				_ = d.Close()
				unreadable(t, path)
				return path
			},
			unknown: DatabaseUnreadablePermission,
		},
		{
			name:    "db_no_ckpt_guard",
			setup:   existingFile,
			open:    failingOpener(fmt.Errorf("opening database: %w (sqlite reported 0)", sqlcipher.ErrNoCheckpointGuard)),
			unknown: DatabaseNoCkptGuard,
		},
		{
			name:    "db_no_ckpt_guard_pragma_busy",
			setup:   existingFile,
			open:    failingOpener(fmt.Errorf("%w (wal_autocheckpoint: %w)", sqlcipher.ErrNoCheckpointGuard, sqlcipher.Error{Code: sqlcipher.ErrBusy})),
			unknown: DatabaseNoCkptGuard,
		},
		{
			name:    "db_other",
			setup:   existingFile,
			open:    failingOpener(errors.New("canary failure at /Users/someone/x")),
			unknown: DatabaseUnreadableOther,
		},
		{
			name:    "db_open_busy",
			setup:   existingFile,
			open:    failingOpener(sqlcipher.Error{Code: sqlcipher.ErrBusy}),
			unknown: UnknownDatabaseBusy,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			path := tc.setup(t)
			open := tc.open
			if open == nil {
				open = Opener(DefaultBudgets.Busy)
			}
			p := readDB(t, DefaultBudgets, path, open)
			want := DBParts{
				Sources:      tc.unknown,
				PipelineRuns: "  pipeline runs " + tc.unknown,
				Schema:       "schema " + tc.unknown,
			}
			if tc.unknown == UnknownDatabaseBusy {
				want.Reasons = []string{ReasonDatabaseBusy}
			}
			if p.Sources != want.Sources || p.PipelineRuns != want.PipelineRuns || p.Schema != want.Schema ||
				p.QuickConnections != "" || p.Kinds != nil || !slices.Equal(p.Reasons, want.Reasons) {
				t.Errorf("got  %+v\nwant %+v", p, want)
			}
		})
	}
}

func existingFile(t *testing.T) string {
	p := filepath.Join(t.TempDir(), "watchtower.db")
	writeFile(t, p, "x")
	return p
}

// corruptDB is a migrated file whose header is intact and whose schema
// page is damaged.
func corruptDB(t *testing.T) string {
	t.Helper()
	path, d := newDBFile(t)
	if err := d.Close(); err != nil {
		t.Fatal(err)
	}
	f, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	junk := make([]byte, 3000)
	for i := range junk {
		junk[i] = 0xA5
	}
	if _, err := f.WriteAt(junk, 100); err != nil {
		t.Fatal(err)
	}
	if err := f.Close(); err != nil {
		t.Fatal(err)
	}
	return path
}

// TestDiagnostics_DeadlineMidway is the spec's budget_db_midway case: each
// statement takes 1.5 s; the parts finished before the 4 s deadline are
// kept, the rest print `unknown (database busy)`: the schema (done at
// 1.5 s) and Quick Connections (3 s) are kept, the recent errors (4.5 s)
// and the sources (after it) are busy. The clock is a synctest bubble's,
// so the read ends exactly at the deadline.
func TestDiagnostics_DeadlineMidway(t *testing.T) {
	t.Run("budget_db_midway", func(t *testing.T) {
		synctest.Test(t, func(t *testing.T) {
			path, _ := newDBFile(t)
			start := time.Now()
			p := ReadDB(context.Background(), DefaultBudgets, path, wrapOpener(t, fakeReader{delay: 1500 * time.Millisecond, honorCtx: true}))
			if el := time.Since(start); el != DefaultBudgets.DB {
				t.Errorf("took %v, want the %v deadline", el, DefaultBudgets.DB)
			}
			if !strings.HasPrefix(p.Schema, "schema ") || strings.Contains(p.Schema, "unknown") {
				t.Errorf("Schema = %q, want a version", p.Schema)
			}
			if p.QuickConnections != "Quick Connections 0" {
				t.Errorf("QuickConnections = %q, done before the deadline", p.QuickConnections)
			}
			if p.PipelineRuns != PipelineRunsUnknown(UnknownDatabaseBusy) || p.Sources != UnknownDatabaseBusy {
				t.Errorf("runs %q, sources %q", p.PipelineRuns, p.Sources)
			}
			if !slices.Equal(p.Reasons, []string{ReasonDatabaseBusy}) {
				t.Errorf("Reasons = %q", p.Reasons)
			}
		})
	})
}

// TestDiagnostics_DBFallbackStopsWaiting: statements that ignore their
// context are abandoned at Budgets.DBFallback.
func TestDiagnostics_DBFallbackStopsWaiting(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		path, _ := newDBFile(t)
		b := DefaultBudgets
		b.DB, b.DBFallback = 2*time.Second, 500*time.Millisecond
		start := time.Now()
		p := ReadDB(context.Background(), b, path, wrapOpener(t, fakeReader{delay: 300 * time.Millisecond}))
		if el := time.Since(start); el != b.DBFallback {
			t.Errorf("took %v, want the %v fallback", el, b.DBFallback)
		}
		if strings.Contains(p.Schema, "unknown") {
			t.Errorf("Schema = %q", p.Schema)
		}
		// Sources says why, so the Quick Connections part is left out.
		if p.Sources != UnknownDatabaseBusy || p.PipelineRuns != PipelineRunsUnknown(UnknownDatabaseBusy) || p.QuickConnections != "" {
			t.Errorf("got %+v", p)
		}
		if !slices.Equal(p.Reasons, []string{ReasonDatabaseBusy}) {
			t.Errorf("Reasons = %q", p.Reasons)
		}
	})
}

// TestDiagnostics_ReadDBWritesNothing: on a file whose -wal holds
// committed frames not yet in the main file and no other connection (a
// daemon that died, or a stopped install), the reader is the last
// connection to close. SQLite would checkpoint the frames into the main
// file and drop the -wal there; the read must leave the main file's bytes
// and mtime as they were and the -wal whole (NoCheckpointOnClose,
// query_only).
func TestDiagnostics_ReadDBWritesNothing(t *testing.T) {
	src, d := newDBFile(t)
	ctx := context.Background()
	conn, err := d.Conn(ctx)
	if err != nil {
		t.Fatal(err)
	}
	for _, s := range []string{
		`PRAGMA wal_checkpoint(TRUNCATE)`,
		`PRAGMA wal_autocheckpoint = 0`,
		`INSERT INTO slack_accounts (status) VALUES ('ok')`,
	} {
		if _, err := conn.ExecContext(ctx, s); err != nil {
			t.Fatalf("%s: %v", s, err)
		}
	}
	// Copy the pair while the writer is still open: the copy has unmerged
	// frames in its -wal and no connection at all.
	path := filepath.Join(t.TempDir(), "watchtower.db")
	for _, suffix := range []string{"", "-wal"} {
		b, err := os.ReadFile(src + suffix)
		if err != nil {
			t.Fatal(err)
		}
		writeFile(t, path+suffix, string(b))
	}
	_ = conn.Close()

	mainBefore, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	st, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	walBefore, err := os.ReadFile(path + "-wal")
	if err != nil {
		t.Fatal(err)
	}
	if len(walBefore) == 0 {
		t.Fatal("the -wal has no frames; the test would prove nothing")
	}

	if p := readParts(t, path); p.Sources != "Slack 1 ok" {
		t.Fatalf("Sources = %q (the row lives only in the -wal)", p.Sources)
	}

	mainAfter, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	st2, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(mainBefore, mainAfter) || !st.ModTime().Equal(st2.ModTime()) {
		t.Error("ReadDB changed the main database file")
	}
	walAfter, err := os.ReadFile(path + "-wal")
	if err != nil {
		t.Fatalf("the -wal is gone after the read: %v", err)
	}
	if !bytes.Equal(walBefore, walAfter) {
		t.Errorf("the -wal changed: %d bytes before, %d after", len(walBefore), len(walAfter))
	}
}

// TestDiagnostics_QueriesValid runs every query ReadDB uses against a
// fully migrated database, so a typo'd column cannot hide behind the
// older-schema `unknown` path.
func TestDiagnostics_QueriesValid(t *testing.T) {
	_, d := newDBFile(t)
	queries := []string{schemaQuery, quickConnectionsQuery, recentErrorsQuery}
	for _, st := range SourceTables {
		queries = append(queries, st.Query)
	}
	for _, q := range queries {
		if err := query(context.Background(), d, q, func(*sql.Rows) error { return nil }); err != nil {
			t.Errorf("%s: %v", q, err)
		}
	}
}

func TestDiagnostics_DBCancelled(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		path, _ := newDBFile(t)
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		start := time.Now()
		p := ReadDB(ctx, DefaultBudgets, path, Opener(DefaultBudgets.Busy))
		if el := time.Since(start); el != 0 {
			t.Errorf("took %v", el)
		}
		if p.Sources != UnknownDatabaseBusy || p.Schema != SchemaUnknownBecause(UnknownDatabaseBusy) ||
			!slices.Equal(p.Reasons, []string{ReasonDatabaseBusy}) {
			t.Errorf("got %+v", p)
		}
	})
}

// busy_single_statement: one read fails with SQLITE_BUSY after its busy
// timeout; only that part is busy.
func TestDiagnostics_BusySingleStatement(t *testing.T) {
	t.Run("busy_single_statement", func(t *testing.T) {
		path, d := newDBFile(t)
		execAll(t, d, `INSERT INTO slack_accounts (status) VALUES ('ok')`)
		p := readDB(t, DefaultBudgets, path,
			wrapOpener(t, fakeReader{failOn: "FROM pipeline_runs", failErr: sqlcipher.Error{Code: sqlcipher.ErrBusy}}))
		if p.PipelineRuns != PipelineRunsUnknown(UnknownDatabaseBusy) {
			t.Errorf("PipelineRuns = %q", p.PipelineRuns)
		}
		if p.Sources != "Slack 1 ok" || p.QuickConnections != "Quick Connections 0" || strings.Contains(p.Schema, "unknown") {
			t.Errorf("other parts: %+v", p)
		}
		if !slices.Equal(p.Reasons, []string{ReasonDatabaseBusy}) {
			t.Errorf("Reasons = %q", p.Reasons)
		}
	})
	t.Run("sources_query_error_other", func(t *testing.T) {
		path, _ := newDBFile(t)
		p := readDB(t, DefaultBudgets, path,
			wrapOpener(t, fakeReader{failOn: "FROM jira_accounts", failErr: sqlcipher.Error{Code: sqlcipher.ErrCorrupt}}))
		if p.Sources != DatabaseUnreadableCorrupt || p.Kinds != nil || len(p.Reasons) != 0 {
			t.Errorf("got %+v", p)
		}
	})
}

// TestDiagnostics_ReadDBHeldLock: another connection holds an exclusive
// lock; every database part is busy and the read ends inside its budget.
func TestDiagnostics_ReadDBHeldLock(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		path, d := newDBFile(t)
		ctx := context.Background()
		conn, err := d.Conn(ctx)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = conn.Close() })
		for _, s := range []string{`PRAGMA locking_mode = EXCLUSIVE`, `BEGIN EXCLUSIVE`, `INSERT INTO slack_accounts (status) VALUES ('ok')`} {
			if _, err := conn.ExecContext(ctx, s); err != nil {
				t.Fatalf("%s: %v", s, err)
			}
		}
		t.Cleanup(func() { _, _ = conn.ExecContext(ctx, `ROLLBACK`) })

		b := DefaultBudgets
		b.DB, b.DBFallback, b.Busy = time.Second, 1500*time.Millisecond, 100*time.Millisecond
		start := time.Now()
		p := ReadDB(ctx, b, path, Opener(b.Busy))
		// SQLite's busy wait is not the bubble's clock: every part is busy
		// from SQLITE_BUSY, before the read's own budget.
		if el := time.Since(start); el >= b.DB {
			t.Errorf("took %v", el)
		}
		if p.Sources != UnknownDatabaseBusy || p.PipelineRuns != PipelineRunsUnknown(UnknownDatabaseBusy) ||
			p.Schema != SchemaUnknownBecause(UnknownDatabaseBusy) || !slices.Equal(p.Reasons, []string{ReasonDatabaseBusy}) {
			t.Errorf("got %+v", p)
		}
	})
}

// A panic inside the reader goroutine is contained: the parts read before
// it stay, the rest print `unknown (internal error)`, and the database is
// still closed.
func TestDiagnostics_ReadDBPanicIsContained(t *testing.T) {
	path, _ := newDBFile(t)
	p := readDB(t, DefaultBudgets, path, wrapOpener(t, fakeReader{panicOn: "pipeline_runs"}))
	if !strings.HasPrefix(p.Schema, "schema ") || p.Schema == SchemaUnknown || strings.Contains(p.Schema, UnknownWord) {
		t.Errorf("schema %q", p.Schema)
	}
	if p.QuickConnections != kindCount(QuickConnections, 0) {
		t.Errorf("quick connections %q", p.QuickConnections)
	}
	if p.PipelineRuns != PipelineRunsUnknown(UnknownInternal) || p.Sources != UnknownInternal {
		t.Errorf("got %+v", p)
	}
	if len(p.Reasons) != 0 {
		t.Errorf("reasons %v", p.Reasons)
	}
}

// A panic in the open itself: every part is `unknown (internal error)`.
func TestDiagnostics_ReadDBOpenPanicIsContained(t *testing.T) {
	path, _ := newDBFile(t)
	p := readDB(t, DefaultBudgets, path, func(context.Context, string) (DBReader, error) {
		panic("opener bug")
	})
	want := FailedParts(UnknownInternal)
	if p.Sources != want.Sources || p.PipelineRuns != want.PipelineRuns || p.Schema != want.Schema || p.QuickConnections != "" {
		t.Errorf("got %+v", p)
	}
}
