package db

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"path/filepath"
	"testing"
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
	if got[1].ID != standalone || got[1].WorkbenchID != 0 || got[1].AgentCwd != "" || got[1].AgentStateAt != "" || got[1].Finished {
		t.Fatalf("standalone row = %+v", got[1])
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

func TestSessionCommandRows_CapIs512(t *testing.T) {
	ctx := context.Background()
	d := openTestDB(t)
	id := newAgentStateRow(t, d, newTestWorkbench(t, d), "claude", agentStateUUID)
	for i := range MaxSessionCommandRows {
		recorded, full, err := d.RecordSessionCommandRow(ctx, id, "/tmp/example/repo", fmt.Sprintf("feat/b%d", i), "branch", ledgerAt)
		if err != nil || !recorded || full {
			t.Fatalf("record %d = %v, %v, %v; want true, false, nil", i, recorded, full, err)
		}
	}
	recorded, full, err := d.RecordSessionCommandRow(ctx, id, "/tmp/example/repo", "feat/one-too-many", "branch", ledgerAt)
	if err != nil || recorded || !full {
		t.Fatalf("record 513 = %v, %v, %v; want false, true, nil", recorded, full, err)
	}
	rows, _ := d.SessionWorktrees(ctx, id)
	if len(rows) != MaxSessionCommandRows {
		t.Fatalf("%d rows, want %d", len(rows), MaxSessionCommandRows)
	}
	if rows[0].Source != "command" || rows[0].Kind != "branch" {
		t.Fatalf("row = %+v; want source command, kind branch", rows[0])
	}
}

func TestSessionCommandRows_DoNotCountAgainstCwdCap(t *testing.T) {
	ctx := context.Background()
	d := openTestDB(t)
	id := newAgentStateRow(t, d, newTestWorkbench(t, d), "claude", agentStateUUID)
	if recorded, _, err := d.RecordSessionCommandRow(ctx, id, "/tmp/example/cmd-wt", "feat/c", "worktree", ledgerAt); err != nil || !recorded {
		t.Fatalf("command row before the cwd rows = %v, %v", recorded, err)
	}
	for i := range MaxSessionWorktrees {
		if got, err := d.RecordSessionWorktree(ctx, nil, id, fmt.Sprintf("/tmp/example/wt%d", i), "", ledgerAt); err != nil || !got {
			t.Fatalf("cwd record %d = %v, %v; a command row must not count against the cwd cap", i, got, err)
		}
	}
	if recorded, full, err := d.RecordSessionCommandRow(ctx, id, "/tmp/example/repo", "feat/d", "branch", ledgerAt); err != nil || !recorded || full {
		t.Fatalf("command row past 64 cwd rows = %v, %v, %v; want true, false, nil", recorded, full, err)
	}
	if _, _, full, err := d.HasSessionWorktree(ctx, id, "/tmp/example/new", ""); err != nil || !full {
		t.Fatalf("HasSessionWorktree full = %v, %v; want the cwd cap reached", full, err)
	}
	rows, _ := d.SessionWorktrees(ctx, id)
	if len(rows) != MaxSessionWorktrees+2 {
		t.Fatalf("%d rows, want %d", len(rows), MaxSessionWorktrees+2)
	}
}

func TestSessionCommandRows_ExistingCwdRowKeepsSource(t *testing.T) {
	ctx := context.Background()
	d := openTestDB(t)
	id := newAgentStateRow(t, d, newTestWorkbench(t, d), "claude", agentStateUUID)
	if got, err := d.RecordSessionWorktree(ctx, nil, id, "/tmp/example/wt", "feat/x", ledgerAt); err != nil || !got {
		t.Fatalf("cwd record = %v, %v", got, err)
	}
	const later = "2026-10-12T13:00:00.000Z"
	recorded, full, err := d.RecordSessionCommandRow(ctx, id, "/tmp/example/wt", "feat/x", "branch", later)
	if err != nil || recorded || full {
		t.Fatalf("command record of a cwd pair = %v, %v, %v; want false, false, nil", recorded, full, err)
	}
	var source, kind, lastAt string
	if err := d.QueryRow(`SELECT source, kind, last_at FROM terminal_session_worktrees WHERE session_id = ?`, id).
		Scan(&source, &kind, &lastAt); err != nil {
		t.Fatal(err)
	}
	if source != "cwd" || kind != "worktree" || lastAt != later {
		t.Fatalf("row = %s, %s, %s; want cwd, worktree, %s", source, kind, lastAt, later)
	}
	// An older sighting never moves last_at back.
	if _, _, err := d.RecordSessionCommandRow(ctx, id, "/tmp/example/wt", "feat/x", "branch", ledgerAt); err != nil {
		t.Fatal(err)
	}
	if err := d.QueryRow(`SELECT last_at FROM terminal_session_worktrees WHERE session_id = ?`, id).Scan(&lastAt); err != nil {
		t.Fatal(err)
	}
	if lastAt != later {
		t.Fatalf("last_at = %s after an older sighting; want %s", lastAt, later)
	}
}

func TestSessionAutoCleanupColumns(t *testing.T) {
	d := openTestDB(t)
	id := newAgentStateRow(t, d, newTestWorkbench(t, d), "claude", agentStateUUID)
	var got sql.NullString
	if err := d.QueryRow(`SELECT delete_requested_at FROM terminal_sessions WHERE id = ?`, id).Scan(&got); err != nil || got.Valid {
		t.Fatalf("a new row's delete_requested_at = %v, %v; want NULL", got, err)
	}
	setDeleteRequestedForTest(t, d, id, ledgerAt)
	if err := d.QueryRow(`SELECT delete_requested_at FROM terminal_sessions WHERE id = ?`, id).Scan(&got); err != nil || got.String != ledgerAt {
		t.Fatalf("delete_requested_at = %v, %v; want %s", got, err, ledgerAt)
	}
	for _, q := range []string{
		`INSERT INTO terminal_session_worktrees (session_id, root, branch, first_at, source) VALUES (?, '/tmp/example/a', '', 'x', 'other')`,
		`INSERT INTO terminal_session_worktrees (session_id, root, branch, first_at, kind) VALUES (?, '/tmp/example/b', '', 'x', 'other')`,
	} {
		if _, err := d.Exec(q, id); err == nil {
			t.Fatalf("%s: accepted a value outside the CHECK", q)
		}
	}
	if _, _, err := d.RecordSessionCommandRow(context.Background(), id, "/tmp/example/c", "", "other", ledgerAt); err == nil {
		t.Fatal("RecordSessionCommandRow accepted kind \"other\"")
	}
}
