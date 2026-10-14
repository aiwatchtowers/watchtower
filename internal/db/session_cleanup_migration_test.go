package db

import (
	"path/filepath"
	"testing"

	"github.com/pressly/goose/v3"
)

func TestMigrationSessionCleanup_UpCreatesTableAndColumns(t *testing.T) {
	d := openTestDB(t)
	cols := columnNames(t, d.DB, "terminal_session_worktrees")
	for _, c := range []string{"session_id", "root", "branch", "first_at"} {
		if !cols[c] {
			t.Fatalf("terminal_session_worktrees lacks %q: %v", c, cols)
		}
	}
	pk := map[string]int{}
	rows, err := d.Query(`SELECT name, pk FROM pragma_table_info('terminal_session_worktrees') WHERE pk > 0`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	for rows.Next() {
		var name string
		var n int
		if err := rows.Scan(&name, &n); err != nil {
			t.Fatal(err)
		}
		pk[name] = n
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	if pk["session_id"] != 1 || pk["root"] != 2 || pk["branch"] != 3 || len(pk) != 3 {
		t.Fatalf("primary key = %v, want (session_id, root, branch)", pk)
	}

	pid := newTestWorkbench(t, d)
	id := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
	var nullResult, nullAt bool
	if err := d.QueryRow(`SELECT cleanup_result IS NULL, cleanup_at IS NULL FROM terminal_sessions WHERE id = ?`, id).
		Scan(&nullResult, &nullAt); err != nil {
		t.Fatal(err)
	}
	if !nullResult || !nullAt {
		t.Fatalf("a fresh row has cleanup_result NULL=%v, cleanup_at NULL=%v; want both NULL", nullResult, nullAt)
	}
}

func TestMigrationSessionCleanup_DownDropsAndReUpRestores(t *testing.T) {
	t.Parallel()
	d, err := Open(filepath.Join(t.TempDir(), "session-cleanup-cycle.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	pid := newTestWorkbench(t, d)
	id := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
	if _, err := d.Exec(`UPDATE terminal_sessions SET cleanup_result = '{}', cleanup_at = '2026-10-12T12:00:00.000Z',
		agent_state = 'waiting' WHERE id = ?`, id); err != nil {
		t.Fatal(err)
	}

	// DownTo(110), not a bare Down: a later migration can move the tip past 00111.
	if err := goose.DownTo(d.DB, "migrations", 110); err != nil {
		t.Fatal(err)
	}
	cols := columnNames(t, d.DB, "terminal_sessions")
	if cols["cleanup_result"] || cols["cleanup_at"] {
		t.Fatal("Down kept the cleanup columns")
	}
	if len(columnNames(t, d.DB, "terminal_session_worktrees")) != 0 {
		t.Fatal("Down kept terminal_session_worktrees")
	}
	var state string
	if err := d.QueryRow(`SELECT agent_state FROM terminal_sessions WHERE id = ?`, id).Scan(&state); err != nil || state != "waiting" {
		t.Fatalf("the row did not survive Down intact: state=%q err=%v", state, err)
	}

	if err := goose.Up(d.DB, "migrations"); err != nil {
		t.Fatal(err)
	}
	cols = columnNames(t, d.DB, "terminal_sessions")
	if !cols["cleanup_result"] || !cols["cleanup_at"] {
		t.Fatal("re-Up did not restore the cleanup columns")
	}
	if len(columnNames(t, d.DB, "terminal_session_worktrees")) == 0 {
		t.Fatal("re-Up did not restore terminal_session_worktrees")
	}
}

func TestMigrationSessionCleanup_LedgerCascadesWithTheSession(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	id := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
	if _, err := d.Exec(`INSERT INTO terminal_session_worktrees (session_id, root, branch, first_at)
		VALUES (?, '/tmp/example/wt', 'feat/x', '2026-10-12T12:00:00.000Z'),
		       (?, '/tmp/example/wt', '', '2026-10-12T12:00:00.000Z')`, id, id); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(`DELETE FROM terminal_sessions WHERE id = ?`, id); err != nil {
		t.Fatal(err)
	}
	var n int
	if err := d.QueryRow(`SELECT COUNT(*) FROM terminal_session_worktrees`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Fatalf("%d ledger rows survived the session delete, want 0", n)
	}
}
