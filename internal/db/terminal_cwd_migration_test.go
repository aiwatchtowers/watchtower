package db

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/pressly/goose/v3"
)

func TestMigration00110_AddsTheCwdColumns(t *testing.T) {
	d := openTestDB(t)
	cols := columnNames(t, d.DB, "terminal_sessions")
	if !cols["agent_cwd"] || !cols["agent_cwd_at"] {
		t.Fatalf("terminal_sessions lacks the cwd columns: %v", cols)
	}
	pid := newTestWorkbench(t, d)
	id := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
	s := storedCwd(t, d, id)
	if s.Path != "" || !s.At.IsZero() {
		t.Fatalf("a fresh row reads cwd %q at %v, want empty and zero", s.Path, s.At)
	}
}

func TestMigration00110_DownDropsAndReUpRestores(t *testing.T) {
	t.Parallel()
	d, err := Open(filepath.Join(t.TempDir(), "cwd-cycle.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	pid := newTestWorkbench(t, d)
	id := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
	if _, err := d.Exec(`UPDATE terminal_sessions SET agent_state = 'working',
		agent_state_at = '2026-10-12T12:00:00.000Z', agent_cwd = '/tmp/wb/.claude/worktrees/mobile-a',
		agent_cwd_at = '2026-10-12T12:00:00.000Z' WHERE id = ?`, id); err != nil {
		t.Fatal(err)
	}

	// DownTo(108), not a bare Down: a later migration can move the tip past 00110.
	if err := goose.DownTo(d.DB, "migrations", 108); err != nil {
		t.Fatal(err)
	}
	cols := columnNames(t, d.DB, "terminal_sessions")
	if cols["agent_cwd"] || cols["agent_cwd_at"] {
		t.Fatal("Down kept the cwd columns")
	}
	var state, claudeID string
	if err := d.QueryRow(`SELECT agent_state, claude_session_id FROM terminal_sessions WHERE id = ?`, id).
		Scan(&state, &claudeID); err != nil {
		t.Fatalf("the row did not survive Down: %v", err)
	}
	if state != "working" || claudeID != agentStateUUID {
		t.Fatalf("Down changed the row's other columns: state=%q claude_session_id=%q", state, claudeID)
	}

	if err := goose.Up(d.DB, "migrations"); err != nil {
		t.Fatal(err)
	}
	cols = columnNames(t, d.DB, "terminal_sessions")
	if !cols["agent_cwd"] || !cols["agent_cwd_at"] {
		t.Fatal("re-Up did not restore the cwd columns")
	}
	if s := storedCwd(t, d, id); s.Path != "" || !s.At.IsZero() {
		t.Fatalf("re-Up cwd = %q at %v, want NULL", s.Path, s.At)
	}
}

func TestTerminalAgentCwdReadsTheCwd(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	id := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
	at := time.Date(2026, 10, 12, 12, 34, 56, 789_000_000, time.UTC)
	if _, err := d.Exec(`UPDATE terminal_sessions SET agent_cwd = '/tmp/wb', agent_cwd_at = ? WHERE id = ?`,
		at.Format(agentStateAtLayout), id); err != nil {
		t.Fatal(err)
	}
	s := storedCwd(t, d, id)
	if s.Path != "/tmp/wb" || !s.At.Equal(at) {
		t.Fatalf("cwd = %q at %v, want /tmp/wb at %v", s.Path, s.At, at)
	}

	if _, err := d.Exec(`UPDATE terminal_sessions SET agent_cwd_at = 'yesterday' WHERE id = ?`, id); err != nil {
		t.Fatal(err)
	}
	s = storedCwd(t, d, id)
	if s.Path != "/tmp/wb" || !s.At.IsZero() {
		t.Fatalf("an unreadable stamp read as %v (cwd %q), want zero time", s.At, s.Path)
	}
}
