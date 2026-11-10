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
	return ReadDB(context.Background(), DefaultBudgets, path, Opener(DefaultBudgets.Busy))
}

// fakeReader wraps a real reader: it can delay every statement (honouring
// ctx or not) and fail the statements containing failOn.
type fakeReader struct {
	DBReader
	delay    time.Duration
	honorCtx bool
	failOn   string
	failErr  error
}

func (f fakeReader) QueryContext(ctx context.Context, q string, args ...any) (*sql.Rows, error) {
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

func wrapOpener(f fakeReader) OpenFunc {
	return func(ctx context.Context, p string) (DBReader, error) {
		r, err := Opener(DefaultBudgets.Busy)(ctx, p)
		if err != nil {
			return nil, err
		}
		f.DBReader = r
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
			p := ReadDB(context.Background(), DefaultBudgets, path, open)
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
// kept, the rest print `unknown (database busy)`.
func TestDiagnostics_DeadlineMidway(t *testing.T) {
	t.Run("budget_db_midway", func(t *testing.T) {
		path, d := newDBFile(t)
		execAll(t, d, `INSERT INTO external_connections (name, enabled) VALUES ('a', 1)`)
		start := time.Now()
		p := ReadDB(context.Background(), DefaultBudgets, path, wrapOpener(fakeReader{delay: 1500 * time.Millisecond, honorCtx: true}))
		if el := time.Since(start); el > 5*time.Second {
			t.Errorf("took %v", el)
		}
		if !strings.HasPrefix(p.Schema, "schema ") || strings.Contains(p.Schema, "unknown") {
			t.Errorf("Schema = %q, want a version", p.Schema)
		}
		if p.QuickConnections != "Quick Connections 1" {
			t.Errorf("QuickConnections = %q", p.QuickConnections)
		}
		if p.PipelineRuns != PipelineRunsUnknown(UnknownDatabaseBusy) || p.Sources != UnknownDatabaseBusy {
			t.Errorf("runs %q, sources %q", p.PipelineRuns, p.Sources)
		}
		if !slices.Equal(p.Reasons, []string{ReasonDatabaseBusy}) {
			t.Errorf("Reasons = %q", p.Reasons)
		}
	})
}

// TestDiagnostics_DBFallbackStopsWaiting: statements that ignore their
// context are abandoned at Budgets.DBFallback.
func TestDiagnostics_DBFallbackStopsWaiting(t *testing.T) {
	path, _ := newDBFile(t)
	b := DefaultBudgets
	b.DB, b.DBFallback = 2*time.Second, 500*time.Millisecond
	start := time.Now()
	p := ReadDB(context.Background(), b, path, wrapOpener(fakeReader{delay: 300 * time.Millisecond}))
	if el := time.Since(start); el > 900*time.Millisecond {
		t.Errorf("took %v, want about 500ms", el)
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
}

// TestDiagnostics_ReadDBWritesNothing: the read leaves the main database
// file's bytes and mtime as they were.
func TestDiagnostics_ReadDBWritesNothing(t *testing.T) {
	path, d := newDBFile(t)
	execAll(t, d, `INSERT INTO slack_accounts (status) VALUES ('ok')`)
	if err := d.Close(); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	st, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if p := readParts(t, path); p.Sources != "Slack 1 ok" {
		t.Fatalf("Sources = %q", p.Sources)
	}
	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	st2, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(before, after) || !st.ModTime().Equal(st2.ModTime()) {
		t.Error("ReadDB changed the main database file")
	}
}

func TestDiagnostics_DBCancelled(t *testing.T) {
	path, _ := newDBFile(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	start := time.Now()
	p := ReadDB(ctx, DefaultBudgets, path, Opener(DefaultBudgets.Busy))
	if el := time.Since(start); el > time.Second {
		t.Errorf("took %v", el)
	}
	if p.Sources != UnknownDatabaseBusy || p.Schema != SchemaUnknownBecause(UnknownDatabaseBusy) ||
		!slices.Equal(p.Reasons, []string{ReasonDatabaseBusy}) {
		t.Errorf("got %+v", p)
	}
}

// busy_single_statement: one read fails with SQLITE_BUSY after its busy
// timeout; only that part is busy.
func TestDiagnostics_BusySingleStatement(t *testing.T) {
	t.Run("busy_single_statement", func(t *testing.T) {
		path, d := newDBFile(t)
		execAll(t, d, `INSERT INTO slack_accounts (status) VALUES ('ok')`)
		p := ReadDB(context.Background(), DefaultBudgets, path,
			wrapOpener(fakeReader{failOn: "FROM pipeline_runs", failErr: sqlcipher.Error{Code: sqlcipher.ErrBusy}}))
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
		p := ReadDB(context.Background(), DefaultBudgets, path,
			wrapOpener(fakeReader{failOn: "FROM jira_accounts", failErr: sqlcipher.Error{Code: sqlcipher.ErrCorrupt}}))
		if p.Sources != DatabaseUnreadableCorrupt || p.Kinds != nil || len(p.Reasons) != 0 {
			t.Errorf("got %+v", p)
		}
	})
}

// TestDiagnostics_ReadDBHeldLock: another connection holds an exclusive
// lock; every database part is busy and the read ends inside its budget.
func TestDiagnostics_ReadDBHeldLock(t *testing.T) {
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
	if el := time.Since(start); el > 2*time.Second {
		t.Errorf("took %v", el)
	}
	if p.Sources != UnknownDatabaseBusy || p.PipelineRuns != PipelineRunsUnknown(UnknownDatabaseBusy) ||
		p.Schema != SchemaUnknownBecause(UnknownDatabaseBusy) || !slices.Equal(p.Reasons, []string{ReasonDatabaseBusy}) {
		t.Errorf("got %+v", p)
	}
}
