package db

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"path/filepath"
	"testing"
	"time"
)

const ledgerAt = "2026-10-12T12:00:00.000Z"

func TestRecordSessionWorktree_InsertsOnceAndIgnoresRepeats(t *testing.T) {
	ctx := context.Background()
	d := openTestDB(t)
	id := newAgentStateRow(t, d, newTestWorkbench(t, d), "claude", agentStateUUID)

	for i, want := range []bool{true, false} {
		got, err := d.RecordSessionWorktree(ctx, nil, id, "/tmp/example/wt", "feat/x", ledgerAt)
		if err != nil || got != want {
			t.Fatalf("record #%d = %v, %v; want %v, nil", i+1, got, err, want)
		}
	}
	if got, err := d.RecordSessionWorktree(ctx, nil, id, "/tmp/example/wt", "feat/y", ledgerAt); err != nil || !got {
		t.Fatalf("a new branch in the same root = %v, %v; want recorded", got, err)
	}
	has, _, full, err := d.HasSessionWorktree(ctx, id, "/tmp/example/wt", "feat/x")
	if err != nil || !has || full {
		t.Fatalf("HasSessionWorktree = %v, %v, %v; want true, false, nil", has, full, err)
	}
	rows, err := d.SessionWorktrees(ctx, id)
	if err != nil || len(rows) != 2 {
		t.Fatalf("SessionWorktrees = %v, %v; want 2 rows", rows, err)
	}
}

func TestRecordSessionWorktree_InsideTheCallersTx(t *testing.T) {
	ctx := context.Background()
	d := openTestDB(t)
	id := newAgentStateRow(t, d, newTestWorkbench(t, d), "claude", agentStateUUID)
	tx, err := d.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	if got, err := d.RecordSessionWorktree(ctx, tx, id, "/tmp/example/wt", "", ledgerAt); err != nil || !got {
		t.Fatalf("record in tx = %v, %v", got, err)
	}
	if err := tx.Rollback(); err != nil {
		t.Fatal(err)
	}
	if rows, _ := d.SessionWorktrees(ctx, id); len(rows) != 0 {
		t.Fatalf("a rolled-back tx left %d rows", len(rows))
	}
}

func TestRecordSessionWorktree_StopsAt64(t *testing.T) {
	ctx := context.Background()
	d := openTestDB(t)
	id := newAgentStateRow(t, d, newTestWorkbench(t, d), "claude", agentStateUUID)
	for i := range MaxSessionWorktrees {
		if got, err := d.RecordSessionWorktree(ctx, nil, id, fmt.Sprintf("/tmp/example/wt%d", i), "", ledgerAt); err != nil || !got {
			t.Fatalf("record %d = %v, %v", i, got, err)
		}
	}
	got, err := d.RecordSessionWorktree(ctx, nil, id, "/tmp/example/one-too-many", "", ledgerAt)
	if err != nil || got {
		t.Fatalf("record 65 = %v, %v; want false, nil", got, err)
	}
	rows, _ := d.SessionWorktrees(ctx, id)
	if len(rows) != MaxSessionWorktrees {
		t.Fatalf("%d rows, want %d", len(rows), MaxSessionWorktrees)
	}
	if has, _, full, err := d.HasSessionWorktree(ctx, id, "/tmp/example/one-too-many", ""); err != nil || has || !full {
		t.Fatalf("HasSessionWorktree past the cap = %v, %v, %v; want false, true, nil", has, full, err)
	}
	other := newAgentStateRow(t, d, newTestWorkbench(t, d), "claude", "1b6c1f7e-3c2a-4d5e-9f10-2a3b4c5d6e7f")
	if got, err := d.RecordSessionWorktree(ctx, nil, other, "/tmp/example/wt0", "", ledgerAt); err != nil || !got {
		t.Fatalf("another session's first row = %v, %v; the cap is per session", got, err)
	}
}

func TestSessionWorktrees_EmptyIsNotNil(t *testing.T) {
	d := openTestDB(t)
	id := newAgentStateRow(t, d, newTestWorkbench(t, d), "claude", agentStateUUID)
	rows, err := d.SessionWorktrees(context.Background(), id)
	if err != nil || rows == nil || len(rows) != 0 {
		t.Fatalf("SessionWorktrees = %#v, %v; want an empty non-nil slice", rows, err)
	}
	m, err := d.WorkbenchSessionWorktrees(context.Background(), 999)
	if err != nil || m == nil || len(m) != 0 {
		t.Fatalf("WorkbenchSessionWorktrees = %#v, %v; want an empty non-nil map", m, err)
	}
}

func TestWorkbenchSessionWorktrees_MapsRootsToTheWorkbenchSessions(t *testing.T) {
	ctx := context.Background()
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	a := newAgentStateRow(t, d, wb, "claude", agentStateUUID)
	b := newAgentStateRow(t, d, wb, "claude", "1b6c1f7e-3c2a-4d5e-9f10-2a3b4c5d6e7f")
	foreign := newAgentStateRow(t, d, newTestWorkbench(t, d), "claude", "2b6c1f7e-3c2a-4d5e-9f10-2a3b4c5d6e7f")
	for _, r := range []struct {
		id           int64
		root, branch string
	}{{a, "/tmp/example/wt", "feat/x"}, {a, "/tmp/example/wt", "feat/y"}, {b, "/tmp/example/wt", ""},
		{b, "/tmp/example/other", ""}, {foreign, "/tmp/example/wt", ""}} {
		if _, err := d.RecordSessionWorktree(ctx, nil, r.id, r.root, r.branch, ledgerAt); err != nil {
			t.Fatal(err)
		}
	}
	m, err := d.WorkbenchSessionWorktrees(ctx, wb)
	if err != nil {
		t.Fatal(err)
	}
	if got := m["/tmp/example/wt"]; len(got) != 2 || got[0] != a || got[1] != b {
		t.Fatalf("wt owners = %v, want [%d %d]", got, a, b)
	}
	if got := m["/tmp/example/other"]; len(got) != 1 || got[0] != b {
		t.Fatalf("other owners = %v, want [%d]", got, b)
	}
}

func TestSaveCleanupResult_WritesOnlyItsRow(t *testing.T) {
	ctx := context.Background()
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	id := newAgentStateRow(t, d, wb, "claude", agentStateUUID)
	other := newAgentStateRow(t, d, wb, "claude", "1b6c1f7e-3c2a-4d5e-9f10-2a3b4c5d6e7f")
	if err := d.SaveCleanupResult(ctx, id, `{"items":[]}`, ledgerAt); err != nil {
		t.Fatal(err)
	}
	var result, at string
	if err := d.QueryRow(`SELECT cleanup_result, cleanup_at FROM terminal_sessions WHERE id = ?`, id).
		Scan(&result, &at); err != nil {
		t.Fatal(err)
	}
	if result != `{"items":[]}` || at != ledgerAt {
		t.Fatalf("stored %q at %q", result, at)
	}
	var untouched bool
	if err := d.QueryRow(`SELECT cleanup_result IS NULL AND cleanup_at IS NULL FROM terminal_sessions WHERE id = ?`,
		other).Scan(&untouched); err != nil || !untouched {
		t.Fatalf("the other row changed (untouched=%v, err=%v)", untouched, err)
	}
	if err := d.SaveCleanupResult(ctx, 9999, "{}", ledgerAt); !errors.Is(err, ErrTerminalSessionNotFound) {
		t.Fatalf("a missing session = %v, want ErrTerminalSessionNotFound", err)
	}
}

func TestHasSessionWorktree_UsesAReadOnlyTx(t *testing.T) {
	ctx := context.Background()
	d, err := Open(filepath.Join(t.TempDir(), "ledger-ro.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	id := newAgentStateRow(t, d, newTestWorkbench(t, d), "claude", agentStateUUID)
	if _, err := d.RecordSessionWorktree(ctx, nil, id, "/tmp/example/wt", "", ledgerAt); err != nil {
		t.Fatal(err)
	}
	if err := d.SetReadOnly(); err != nil {
		t.Fatal(err)
	}
	has, _, full, err := d.HasSessionWorktree(ctx, id, "/tmp/example/wt", "")
	if err != nil || !has || full {
		t.Fatalf("HasSessionWorktree on a query_only handle = %v, %v, %v; want true, false, nil", has, full, err)
	}
}

func TestTerminalSessionStart_ReadsCreatedAt(t *testing.T) {
	ctx := context.Background()
	d := openTestDB(t)
	id := newAgentStateRow(t, d, newTestWorkbench(t, d), "claude", agentStateUUID)
	if _, err := d.Exec(`UPDATE terminal_sessions SET created_at = '2026-10-12T09:30:00Z' WHERE id = ?`, id); err != nil {
		t.Fatal(err)
	}
	at, err := d.TerminalSessionStart(ctx, id)
	if err != nil {
		t.Fatal(err)
	}
	if got := at.UTC().Format("2006-01-02T15:04:05Z"); got != "2026-10-12T09:30:00Z" {
		t.Fatalf("start = %s", got)
	}
	if _, err := d.TerminalSessionStart(ctx, id+100); !errors.Is(err, ErrTerminalSessionNotFound) {
		t.Fatalf("missing row = %v, want ErrTerminalSessionNotFound", err)
	}
}

// An unreadable created_at is an error, never a zero time: a zero start
// would make everything the session saw look younger than it.
func TestTerminalSessionStart_UnreadableIsAnError(t *testing.T) {
	ctx := context.Background()
	d := openTestDB(t)
	id := newAgentStateRow(t, d, newTestWorkbench(t, d), "claude", agentStateUUID)
	for _, bad := range []string{"", "yesterday", "2026-10-12 09:30"} {
		if _, err := d.Exec(`UPDATE terminal_sessions SET created_at = ? WHERE id = ?`, bad, id); err != nil {
			t.Fatal(err)
		}
		if at, err := d.TerminalSessionStart(ctx, id); err == nil {
			t.Fatalf("created_at %q read as %v, want an error", bad, at)
		}
	}
}

// GetTerminalSession reads no column the cleanup added (and not created_at
// either): the readers that open a database without migrating it keep
// working on a database older than 00111.
func TestGetTerminalSessionNeedsNoCleanupColumns(t *testing.T) {
	d := openTestDB(t)
	id := newAgentStateRow(t, d, newTestWorkbench(t, d), "claude", agentStateUUID)
	for _, col := range []string{"cleanup_result", "cleanup_at"} {
		if _, err := d.Exec(`ALTER TABLE terminal_sessions DROP COLUMN ` + col); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := d.Exec(`DROP TABLE terminal_session_worktrees`); err != nil {
		t.Fatal(err)
	}
	if _, err := d.GetTerminalSession(id); err != nil {
		t.Fatalf("GetTerminalSession on a pre-00111 schema: %v", err)
	}
}

func TestSessionTargetBranches_TrimmedDistinctNonEmpty(t *testing.T) {
	ctx := context.Background()
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	id := newAgentStateRow(t, d, wb, "claude", agentStateUUID)
	if got, err := d.SessionTargetBranches(ctx, id); err != nil || got == nil || len(got) != 0 {
		t.Fatalf("no links = %#v, %v; want an empty, non-nil list", got, err)
	}
	for _, branch := range []string{"feat/b", " feat/a ", "", " ", "feat/b"} {
		target := insertWorkbenchTargetRow(t, d, wb, "t "+branch)
		if _, err := d.Exec(`UPDATE targets SET branch = ? WHERE id = ?`, branch, target); err != nil {
			t.Fatal(err)
		}
		if err := d.LinkSessionTarget(id, target); err != nil {
			t.Fatal(err)
		}
	}
	other := insertWorkbenchTargetRow(t, d, wb, "not linked")
	if _, err := d.Exec(`UPDATE targets SET branch = 'feat/other' WHERE id = ?`, other); err != nil {
		t.Fatal(err)
	}
	got, err := d.SessionTargetBranches(ctx, id)
	if err != nil || fmt.Sprint(got) != "[feat/a feat/b]" {
		t.Fatalf("SessionTargetBranches = %v, %v; want [feat/a feat/b]", got, err)
	}
}

func TestListTerminalSessionActivity_EverySessionWithItsCwd(t *testing.T) {
	ctx := context.Background()
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	inWB := newAgentStateRow(t, d, wb, "claude", agentStateUUID)
	standalone := newAgentStateRow(t, d, nil, "shell", nil)
	if _, err := d.Exec(`UPDATE terminal_sessions SET agent_cwd = '/tmp/example/wt', agent_cwd_at = ?,
		agent_state_at = ?, last_active_at = '2026-10-12T12:00:00Z', finished_at = ? WHERE id = ?`,
		ledgerAt, ledgerAt, ledgerAt, inWB); err != nil {
		t.Fatal(err)
	}
	got, err := d.ListTerminalSessionActivity(ctx)
	if err != nil || len(got) != 2 {
		t.Fatalf("ListTerminalSessionActivity = %+v, %v; want 2 rows", got, err)
	}
	want := TerminalSessionActivity{ID: inWB, WorkbenchID: wb, Title: "s", AgentCwd: "/tmp/example/wt",
		AgentStateAt: ledgerAt, LastActiveAt: "2026-10-12T12:00:00Z", Finished: true}
	if got[0] != want {
		t.Fatalf("row = %+v, want %+v", got[0], want)
	}
	if got[1].ID != standalone || got[1].WorkbenchID != 0 || got[1].AgentCwd != "" || got[1].AgentStateAt != "" ||
		got[1].Finished || got[1].DeleteRequested {
		t.Fatalf("standalone row = %+v", got[1])
	}
	// A row being deleted is still listed, with the flag (ask #1389).
	setDeleteRequestedForTest(t, d, inWB, ledgerAt)
	got, err = d.ListTerminalSessionActivity(ctx)
	if err != nil || len(got) != 2 || !got[0].DeleteRequested || got[1].DeleteRequested {
		t.Fatalf("after the delete request = %+v, %v; want row %d flagged", got, err, inWB)
	}
}

// Board #1018: a pair is stale only when its last sighting predates a
// readable run mark; a touch moves last_at forward and never first_at.
func TestSessionWorktree_StaleAgainstTheRunMarkAndTouch(t *testing.T) {
	ctx := context.Background()
	d := openTestDB(t)
	id := newAgentStateRow(t, d, newTestWorkbench(t, d), "claude", agentStateUUID)
	const root, later, mark = "/tmp/example/wt", "2026-10-12T13:00:00.000Z", "2026-10-12T12:30:00.000Z"
	if _, err := d.RecordSessionWorktree(ctx, nil, id, root, "", ledgerAt); err != nil {
		t.Fatal(err)
	}
	setSince := func(turns string) {
		t.Helper()
		if _, err := d.Exec(`UPDATE terminal_sessions SET agent_turns = ? WHERE id = ?`, turns, id); err != nil {
			t.Fatal(err)
		}
	}
	stale := func() bool {
		t.Helper()
		has, stale, _, err := d.HasSessionWorktree(ctx, id, root, "")
		if err != nil || !has {
			t.Fatalf("HasSessionWorktree = %v, %v; want a recorded pair", has, err)
		}
		return stale
	}
	if stale() {
		t.Fatal("no run mark: never stale")
	}
	for _, bad := range []string{`{"since": 5}`, `{"since": "yesterday"}`, `not json`} {
		setSince(bad)
		if stale() {
			t.Fatalf("an unreadable run mark %s read as stale", bad)
		}
	}
	setSince(`{"since":"` + ledgerAt + `"}`)
	if stale() {
		t.Fatal("seen at the run mark is this run's")
	}
	setSince(`{"since":"` + mark + `"}`)
	if !stale() {
		t.Fatal("seen before the run mark: stale")
	}

	if got, err := d.TouchSessionWorktree(ctx, id, root, "", later); err != nil || !got {
		t.Fatalf("touch = %v, %v; want touched", got, err)
	}
	if stale() {
		t.Fatal("touched in this run: not stale")
	}
	if got, err := d.TouchSessionWorktree(ctx, id, root, "", mark); err != nil || got {
		t.Fatalf("an older touch = %v, %v; want left alone", got, err)
	}
	if got, err := d.TouchSessionWorktree(ctx, id, "/tmp/example/none", "", later); err != nil || got {
		t.Fatalf("touching an unknown pair = %v, %v; want nothing", got, err)
	}
	var first, last string
	if err := d.QueryRow(`SELECT first_at, last_at FROM terminal_session_worktrees WHERE session_id = ?`, id).
		Scan(&first, &last); err != nil {
		t.Fatal(err)
	}
	if first != ledgerAt || last != later {
		t.Fatalf("first_at, last_at = %s, %s; want %s, %s", first, last, ledgerAt, later)
	}
}

// Board #1018: a row from before migration 00174 has no last_at; its
// first_at is its last sighting against the run mark, and a touch sets
// last_at, keeping first_at.
func TestSessionWorktree_UpgradedRowWithNoLastAt(t *testing.T) {
	ctx := context.Background()
	d := openTestDB(t)
	id := newAgentStateRow(t, d, newTestWorkbench(t, d), "claude", agentStateUUID)
	const root, later = "/tmp/example/wt", "2026-10-12T13:00:00.000Z"
	if _, err := d.Exec(`INSERT INTO terminal_session_worktrees (session_id, root, branch, first_at) VALUES (?, ?, '', ?)`,
		id, root, ledgerAt); err != nil {
		t.Fatal(err)
	}
	setSince := func(since string) {
		t.Helper()
		if _, err := d.Exec(`UPDATE terminal_sessions SET agent_turns = ? WHERE id = ?`, `{"since":"`+since+`"}`, id); err != nil {
			t.Fatal(err)
		}
	}
	stale := func() bool {
		t.Helper()
		has, stale, _, err := d.HasSessionWorktree(ctx, id, root, "")
		if err != nil || !has {
			t.Fatalf("HasSessionWorktree = %v, %v; want a recorded pair", has, err)
		}
		return stale
	}
	setSince(ledgerAt)
	if stale() {
		t.Fatal("first seen at the run mark: this run's")
	}
	setSince("2026-10-12T12:30:00.000Z")
	if !stale() {
		t.Fatal("first seen before the run mark, no last_at: stale")
	}
	if got, err := d.TouchSessionWorktree(ctx, id, root, "", later); err != nil || !got {
		t.Fatalf("touch = %v, %v; want touched", got, err)
	}
	var first string
	var last sql.NullString
	if err := d.QueryRow(`SELECT first_at, last_at FROM terminal_session_worktrees WHERE session_id = ?`, id).
		Scan(&first, &last); err != nil {
		t.Fatal(err)
	}
	if first != ledgerAt || last.String != later {
		t.Fatalf("first_at, last_at = %s, %v; want %s, %s", first, last, ledgerAt, later)
	}
	if stale() {
		t.Fatal("touched in this run: not stale")
	}
}

// setDeleteRequestedForTest marks session id as deleting the way the Desktop,
// the column's only writer, does (spec §4): Go has no writer of it.
func setDeleteRequestedForTest(t *testing.T, d *DB, id int64, at string) {
	t.Helper()
	if _, err := d.Exec(`UPDATE terminal_sessions SET delete_requested_at = ? WHERE id = ?`, at, id); err != nil {
		t.Fatal(err)
	}
}

func TestSessionAutoCleanupColumns(t *testing.T) {
	d := openTestDB(t)
	id := newAgentStateRow(t, d, newTestWorkbench(t, d), "claude", agentStateUUID)
	var got sql.NullString
	if err := d.QueryRow(`SELECT delete_requested_at FROM terminal_sessions WHERE id = ?`, id).Scan(&got); err != nil || got.Valid {
		t.Fatalf("a new row's delete_requested_at = %v, %v; want NULL", got, err)
	}
	if at, err := d.TerminalDeleteRequestedAt(context.Background(), id); err != nil || at != "" {
		t.Fatalf("TerminalDeleteRequestedAt of a new row = %q, %v; want \"\"", at, err)
	}
	setDeleteRequestedForTest(t, d, id, ledgerAt)
	if err := d.QueryRow(`SELECT delete_requested_at FROM terminal_sessions WHERE id = ?`, id).Scan(&got); err != nil || got.String != ledgerAt {
		t.Fatalf("delete_requested_at = %v, %v; want %s", got, err, ledgerAt)
	}
	if at, err := d.TerminalDeleteRequestedAt(context.Background(), id); err != nil || at != ledgerAt {
		t.Fatalf("TerminalDeleteRequestedAt = %q, %v; want %s", at, err, ledgerAt)
	}
	if _, err := d.TerminalDeleteRequestedAt(context.Background(), id+100); !errors.Is(err, ErrTerminalSessionNotFound) {
		t.Fatalf("TerminalDeleteRequestedAt of a missing row = %v; want ErrTerminalSessionNotFound", err)
	}
}

// The ledger stays as it is on main (auto cleanup spec 2026-11-10 §6): cwd
// sightings only, no source/kind columns. Every cwd-hook writer and reader
// works on a freshly migrated database and sees the row — a leftover
// source/kind reference would fail only at run time ("no such column"),
// where the hook logs it and carries on.
func TestSessionLedgerCwdWritersOnMigratedSchema(t *testing.T) {
	ctx := context.Background()
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	id := newAgentStateRow(t, d, wb, "claude", agentStateUUID)

	var extra int
	if err := d.QueryRow(`SELECT COUNT(*) FROM pragma_table_info('terminal_session_worktrees')
		WHERE name IN ('source', 'kind')`).Scan(&extra); err != nil || extra != 0 {
		t.Fatalf("terminal_session_worktrees source/kind columns = %d, %v; the ledger keeps main's columns", extra, err)
	}

	const root, branch = "/tmp/example/wt", "feat/x"
	if got, err := d.RecordSessionWorktree(ctx, nil, id, root, branch, ledgerAt); err != nil || !got {
		t.Fatalf("RecordSessionWorktree = %v, %v; want recorded", got, err)
	}
	if has, _, full, err := d.HasSessionWorktree(ctx, id, root, branch); err != nil || !has || full {
		t.Fatalf("HasSessionWorktree = has %v, full %v, %v; want has, not full", has, full, err)
	}
	if touched, err := d.TouchSessionWorktree(ctx, id, root, branch, "2026-10-12T13:00:00.000Z"); err != nil || !touched {
		t.Fatalf("TouchSessionWorktree = %v, %v; want touched", touched, err)
	}
	ws, err := d.SessionWorktrees(ctx, id)
	if err != nil || len(ws) != 1 || ws[0].Root != root || ws[0].Branch != branch {
		t.Fatalf("SessionWorktrees = %+v, %v; want the one row", ws, err)
	}
	m, err := d.WorkbenchSessionWorktrees(ctx, wb)
	if err != nil || len(m[root]) != 1 || m[root][0] != id {
		t.Fatalf("WorkbenchSessionWorktrees = %v, %v; want %s → [%d]", m, err, root, id)
	}
}

// endedFixture is a workbench with a way to add agent rows and set columns.
type endedFixture struct {
	t   *testing.T
	d   *DB
	wb  int64
	now time.Time
	n   int
}

func newEndedFixture(t *testing.T) *endedFixture {
	t.Helper()
	d := openTestDB(t)
	return &endedFixture{t: t, d: d, wb: newTestWorkbench(t, d), now: time.Date(2026, 11, 20, 12, 0, 0, 0, time.UTC)}
}

func (f *endedFixture) row(sql string, args ...any) int64 {
	f.t.Helper()
	f.n++
	id := newAgentStateRow(f.t, f.d, f.wb, "claude", fmt.Sprintf("%08d-1111-4111-8111-111111111111", f.n))
	if sql != "" {
		if _, err := f.d.Exec(`UPDATE terminal_sessions SET `+sql+` WHERE id = ?`, append(args, id)...); err != nil {
			f.t.Fatal(err)
		}
	}
	return id
}

func (f *endedFixture) list() []FinishedSessionForCleanup {
	f.t.Helper()
	got, err := f.d.EndedSessionsForCleanup(context.Background(), f.now.Add(-14*24*time.Hour), f.now.Add(-24*time.Hour))
	if err != nil {
		f.t.Fatal(err)
	}
	return got
}

// TestEndedSessionsForCleanup_Finished lists finished agent rows of a
// workbench since the given time, not being deleted, never-cleaned first
// (#2131).
func TestEndedSessionsForCleanup_Finished(t *testing.T) {
	f := newEndedFixture(t)
	cleaned := f.row(`finished_at = ?, cleanup_at = ?, cleanup_result = '{}'`,
		AgentStateStamp(f.now.Add(-2*time.Hour)), AgentStateStamp(f.now.Add(-time.Hour)))
	never := f.row(`finished_at = ?`, AgentStateStamp(f.now.Add(-3*time.Hour)))
	f.row(`finished_at = ?`, AgentStateStamp(f.now.Add(-30*24*time.Hour)))
	got := f.list()
	if len(got) != 2 || got[0].SessionID != never || got[1].SessionID != cleaned {
		t.Fatalf("got %+v", got)
	}
	if got[0].WorkbenchID != f.wb || !got[0].CleanupAt.IsZero() || got[0].Quiet ||
		!got[0].FinishedAt.Equal(f.now.Add(-3*time.Hour)) || !got[0].EndedAt.Equal(got[0].FinishedAt) {
		t.Fatalf("never-cleaned row %+v", got[0])
	}
	if !got[1].CleanupAt.Equal(f.now.Add(-time.Hour)) || got[1].CleanupResult != "{}" {
		t.Fatalf("cleaned row %+v", got[1])
	}
}

// TestEndedSessionsForCleanup_Quiet: a never-finished row idle for 24 h or
// more is listed as quiet, ended at its newest activity of the three
// columns (whatever their layouts); one active within 24 h is not.
func TestEndedSessionsForCleanup_Quiet(t *testing.T) {
	f := newEndedFixture(t)
	quiet := f.row(`last_active_at = ?, agent_state_at = ?, closed_at = ?`,
		f.now.Add(-60*time.Hour).Format(time.RFC3339), AgentStateStamp(f.now.Add(-30*time.Hour)),
		f.now.Add(-50*time.Hour).Format(time.RFC3339))
	f.row(`last_active_at = ?, agent_state_at = ?`, f.now.Add(-60*time.Hour).Format(time.RFC3339),
		AgentStateStamp(f.now.Add(-time.Hour))) // a hook wrote an hour ago
	f.row(`last_active_at = ?`, f.now.Add(-time.Hour).Format(time.RFC3339))
	got := f.list()
	if len(got) != 1 || got[0].SessionID != quiet || !got[0].Quiet || !got[0].FinishedAt.IsZero() ||
		!got[0].EndedAt.Equal(f.now.Add(-30*time.Hour)) {
		t.Fatalf("got %+v", got)
	}
}

// TestEndedSessionsForCleanup_QuietOutsideWindow: a quiet row whose last
// activity is older than the window is not listed.
func TestEndedSessionsForCleanup_QuietOutsideWindow(t *testing.T) {
	f := newEndedFixture(t)
	f.row(`last_active_at = ?`, f.now.Add(-20*24*time.Hour).Format(time.RFC3339))
	if got := f.list(); len(got) != 0 {
		t.Fatalf("got %+v", got)
	}
}

// TestEndedSessionsForCleanup_DeletingExcluded: a row with
// delete_requested_at is the Desktop's, finished or quiet.
func TestEndedSessionsForCleanup_DeletingExcluded(t *testing.T) {
	f := newEndedFixture(t)
	f.row(`finished_at = ?, delete_requested_at = ?`, AgentStateStamp(f.now), f.now.Format(time.RFC3339))
	f.row(`last_active_at = ?, delete_requested_at = ?`, f.now.Add(-48*time.Hour).Format(time.RFC3339), f.now.Format(time.RFC3339))
	if got := f.list(); len(got) != 0 {
		t.Fatalf("got %+v", got)
	}
}

// TestEndedSessionsForCleanup_UnparsableStampSkipsTheRow: a stamp that does
// not parse means the row is not known to have ended.
func TestEndedSessionsForCleanup_UnparsableStampSkipsTheRow(t *testing.T) {
	f := newEndedFixture(t)
	f.row(`finished_at = 'garbage'`)
	f.row(`last_active_at = 'garbage'`)
	f.row(`last_active_at = ?, agent_state_at = 'garbage'`, f.now.Add(-48*time.Hour).Format(time.RFC3339))
	f.row(`last_active_at = ?, closed_at = 'garbage'`, f.now.Add(-48*time.Hour).Format(time.RFC3339))
	if got := f.list(); len(got) != 0 {
		t.Fatalf("got %+v", got)
	}
}

// TestEndedSessionsForCleanup_WholeSecondAgentState: an old agent_state_at
// written in whole seconds is a valid stamp for the listing, and
// ParseActivityStamp (the rule the cleanup's re-check shares) reads it.
func TestEndedSessionsForCleanup_WholeSecondAgentState(t *testing.T) {
	f := newEndedFixture(t)
	old := f.now.Add(-48 * time.Hour)
	id := f.row(`last_active_at = ?, agent_state_at = ?`, old.Format(time.RFC3339), old.Format(time.RFC3339))
	got := f.list()
	if len(got) != 1 || got[0].SessionID != id || !got[0].Quiet || !got[0].EndedAt.Equal(old) {
		t.Fatalf("got %+v", got)
	}
	for _, st := range []string{old.Format(time.RFC3339), AgentStateStamp(old)} {
		if at, ok := ParseActivityStamp(st); !ok || !at.Equal(old) {
			t.Fatalf("ParseActivityStamp(%q) = %v, %v", st, at, ok)
		}
	}
	if _, ok := ParseActivityStamp("garbage"); ok {
		t.Fatal("garbage parsed")
	}
}
