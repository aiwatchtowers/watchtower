package db

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/pressly/goose/v3"
)

func TestMigration00106_AddsTheBackgroundColumns(t *testing.T) {
	d := openTestDB(t)
	cols := columnNames(t, d.DB, "terminal_sessions")
	if !cols["agent_background"] || !cols["agent_background_at"] {
		t.Fatalf("terminal_sessions lacks the background columns: %v", cols)
	}
	pid := newTestWorkbench(t, d)
	id := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
	s := storedSession(t, d, id)
	if s.Background.Valid || !s.BackgroundAt.IsZero() {
		t.Fatalf("a fresh row reads background %+v at %v, want NULL and zero", s.Background, s.BackgroundAt)
	}
}

func TestMigration00106_CountCannotBeNegative(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	id := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
	if _, err := d.Exec(`UPDATE terminal_sessions SET agent_background = -1 WHERE id = ?`, id); err == nil {
		t.Fatal("the CHECK accepted agent_background -1")
	}
	for _, n := range []int{0, 3} {
		if _, err := d.Exec(`UPDATE terminal_sessions SET agent_background = ? WHERE id = ?`, n, id); err != nil {
			t.Fatalf("agent_background %d: %v", n, err)
		}
	}
}

func TestMigration00106_DownDropsAndReUpRestoresTheColumns(t *testing.T) {
	t.Parallel()
	d, err := Open(filepath.Join(t.TempDir(), "background-cycle.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	pid := newTestWorkbench(t, d)
	id := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
	if _, err := d.Exec(`UPDATE terminal_sessions SET agent_state = 'waiting',
		agent_state_at = '2026-10-10T12:00:00.000Z', agent_background = 2,
		agent_background_at = '2026-10-10T12:00:00.000Z' WHERE id = ?`, id); err != nil {
		t.Fatal(err)
	}

	// DownTo(105), not a bare Down: a later migration can move the tip past 00106.
	if err := goose.DownTo(d.DB, "migrations", 105); err != nil {
		t.Fatal(err)
	}
	cols := columnNames(t, d.DB, "terminal_sessions")
	if cols["agent_background"] || cols["agent_background_at"] {
		t.Fatal("Down kept the background columns")
	}
	var state, claudeID string
	if err := d.QueryRow(`SELECT agent_state, claude_session_id FROM terminal_sessions WHERE id = ?`, id).
		Scan(&state, &claudeID); err != nil {
		t.Fatalf("the row did not survive Down: %v", err)
	}
	if state != "waiting" || claudeID != agentStateUUID {
		t.Fatalf("Down changed the row's other columns: state=%q claude_session_id=%q", state, claudeID)
	}

	if err := goose.Up(d.DB, "migrations"); err != nil {
		t.Fatal(err)
	}
	cols = columnNames(t, d.DB, "terminal_sessions")
	if !cols["agent_background"] || !cols["agent_background_at"] {
		t.Fatal("re-Up did not restore the background columns")
	}
	if s := storedSession(t, d, id); s.Background.Valid || !s.BackgroundAt.IsZero() {
		t.Fatalf("re-Up background = %+v at %v, want NULL", s.Background, s.BackgroundAt)
	}
}

func TestGetTerminalSessionReadsTheBackgroundColumns(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	id := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
	at := time.Date(2026, 10, 10, 12, 34, 56, 789_000_000, time.UTC)
	if _, err := d.Exec(`UPDATE terminal_sessions SET agent_state = 'waiting', agent_background = 2,
		agent_background_at = ? WHERE id = ?`, at.Format(agentStateAtLayout), id); err != nil {
		t.Fatal(err)
	}
	s := storedSession(t, d, id)
	if !s.Background.Valid || s.Background.Int64 != 2 || !s.BackgroundAt.Equal(at) {
		t.Fatalf("background = %+v at %v, want {2 true} at %v", s.Background, s.BackgroundAt, at)
	}

	if _, err := d.Exec(`UPDATE terminal_sessions SET agent_background_at = 'yesterday' WHERE id = ?`, id); err != nil {
		t.Fatal(err)
	}
	s = storedSession(t, d, id)
	if !s.BackgroundAt.IsZero() || s.Background.Int64 != 2 {
		t.Fatalf("an unreadable stamp read as %v (background %+v), want zero time", s.BackgroundAt, s.Background)
	}
}
