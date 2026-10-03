package db

import (
	"errors"
	"path/filepath"
	"testing"
	"time"

	"github.com/pressly/goose/v3"
)

func TestSetTerminalSessionAITitle_NeverOverwritesUserOrAI(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	for _, src := range []string{"auto", "ai", "user"} {
		res, err := d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, title_source, folder_path, claude_session_id)
			VALUES (?, 'claude', 'New session', ?, '/tmp/acme', 'uuid-'||?)`, pid, src, src)
		if err != nil {
			t.Fatal(err)
		}
		id, _ := res.LastInsertId()
		written, err := d.SetTerminalSessionAITitle(id, "Fix login")
		if err != nil {
			t.Fatal(err)
		}
		if want := src == "auto"; written != want {
			t.Fatalf("source %s: written=%v, want %v", src, written, want)
		}
	}
}

func TestGetTerminalSession_NotFound(t *testing.T) {
	d := openTestDB(t)
	if _, err := d.GetTerminalSession(999); !errors.Is(err, ErrTerminalSessionNotFound) {
		t.Fatalf("err = %v", err)
	}
}

func TestSetTerminalClaudeSessionID_OnlyThatProjectsClaudeRow(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	other := newTestWorkbench(t, d)
	insert := func(project any, kind string, uuid any) int64 {
		t.Helper()
		res, err := d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id)
			VALUES (?, ?, 's', '/tmp/acme', ?)`, project, kind, uuid)
		if err != nil {
			t.Fatal(err)
		}
		id, _ := res.LastInsertId()
		return id
	}
	claude := insert(pid, "claude", "old")
	shell := insert(pid, "shell", nil)
	standalone := insert(nil, "claude", "old")
	for _, tc := range []struct {
		name    string
		id      int64
		project int64
		uuid    string
		want    bool
	}{
		{"its own claude row", claude, pid, "new", true},
		{"already current", claude, pid, "new", false},
		{"another project's session", claude, other, "newer", false},
		{"a shell row", shell, pid, "new", false},
		{"a standalone row", standalone, pid, "new", false},
		{"no such row", 999, pid, "new", false},
	} {
		written, err := d.SetTerminalClaudeSessionID(tc.id, tc.project, tc.uuid)
		if err != nil {
			t.Fatalf("%s: %v", tc.name, err)
		}
		if written != tc.want {
			t.Fatalf("%s: written=%v, want %v", tc.name, written, tc.want)
		}
	}
	s, err := d.GetTerminalSession(claude)
	if err != nil {
		t.Fatal(err)
	}
	if s.ClaudeSessionID.String != "new" {
		t.Fatalf("claude_session_id = %q, want new", s.ClaudeSessionID.String)
	}
	if s, _ := d.GetTerminalSession(shell); s.ClaudeSessionID.Valid {
		t.Fatal("a shell row gained a claude session id")
	}
}

// newAgentStateRow inserts a claude row of workbench pid running uuid.
func newAgentStateRow(t *testing.T, d *DB, pid any, kind string, uuid any) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id)
		VALUES (?, ?, 's', '/tmp/acme', ?)`, pid, kind, uuid)
	if err != nil {
		t.Fatal(err)
	}
	id, _ := res.LastInsertId()
	return id
}

const agentStateUUID = "0b6c1f7e-3c2a-4d5e-9f10-2a3b4c5d6e7f"

func TestMigration00098_AgentStateCheckAndDownUp(t *testing.T) {
	d, err := Open(filepath.Join(t.TempDir(), "agent-state-cycle.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	pid := newTestWorkbench(t, d)
	id := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
	if _, err := d.Exec(`UPDATE terminal_sessions SET agent_state = 'idle' WHERE id = ?`, id); err == nil {
		t.Fatal("the CHECK accepted agent_state 'idle'")
	}
	for _, s := range []string{"working", "waiting", "approval"} {
		if _, err := d.Exec(`UPDATE terminal_sessions SET agent_state = ? WHERE id = ?`, s, id); err != nil {
			t.Fatalf("agent_state %q: %v", s, err)
		}
	}

	// DownTo(97), not a bare Down: a later migration can move the tip past 00098.
	if err := goose.DownTo(d.DB, "migrations", 97); err != nil {
		t.Fatal(err)
	}
	cols := columnNames(t, d.DB, "terminal_sessions")
	if cols["agent_state"] || cols["agent_state_at"] {
		t.Fatal("Down kept the agent state columns")
	}
	if err := goose.Up(d.DB, "migrations"); err != nil {
		t.Fatal(err)
	}
	cols = columnNames(t, d.DB, "terminal_sessions")
	if !cols["agent_state"] || !cols["agent_state_at"] {
		t.Fatal("re-Up did not restore the agent state columns")
	}
	var n int
	if err := d.QueryRow(`SELECT COUNT(*) FROM terminal_sessions WHERE id = ?`, id).Scan(&n); err != nil || n != 1 {
		t.Fatalf("the row did not survive down/up: n=%d err=%v", n, err)
	}
}

func TestSetTerminalAgentState_Guards(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	other := newTestWorkbench(t, d)
	claude := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
	shell := newAgentStateRow(t, d, pid, "shell", nil)
	standalone := newAgentStateRow(t, d, nil, "claude", agentStateUUID)
	t0 := time.Now().UTC().Truncate(time.Millisecond)

	for _, tc := range []struct {
		name      string
		id        int64
		workbench int64
		uuid      string
		state     string
		at        time.Time
		want      bool
	}{
		{"its own claude row", claude, pid, agentStateUUID, "working", t0, true},
		{"another workbench's row", claude, other, agentStateUUID, "waiting", t0.Add(time.Second), false},
		{"a shell row", shell, pid, agentStateUUID, "waiting", t0.Add(time.Second), false},
		{"a standalone row", standalone, pid, agentStateUUID, "waiting", t0.Add(time.Second), false},
		{"a nested session's id", claude, pid, "1b6c1f7e-3c2a-4d5e-9f10-2a3b4c5d6e7f", "waiting", t0.Add(time.Second), false},
		{"no such row", 999, pid, agentStateUUID, "waiting", t0.Add(time.Second), false},
		{"the same state", claude, pid, agentStateUUID, "working", t0.Add(time.Second), false},
	} {
		written, err := d.SetTerminalAgentState(tc.id, tc.workbench, tc.uuid, tc.state, tc.at, "")
		if err != nil {
			t.Fatalf("%s: %v", tc.name, err)
		}
		if written != tc.want {
			t.Fatalf("%s: written=%v, want %v", tc.name, written, tc.want)
		}
	}
	s, err := d.GetTerminalSession(claude)
	if err != nil {
		t.Fatal(err)
	}
	if s.AgentState.String != "working" || !s.AgentStateAt.Equal(t0) {
		t.Fatalf("state = %q at %v, want working at %v (a repeat keeps the transition time)", s.AgentState.String, s.AgentStateAt, t0)
	}
	if s, _ := d.GetTerminalSession(shell); s.AgentState.Valid || !s.AgentStateAt.IsZero() {
		t.Fatal("a shell row gained an agent state")
	}
}

func TestProj11_OlderEventNeverOverwritesANewerState(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	id := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
	newer := time.Now().UTC().Truncate(time.Millisecond)
	if ok, err := d.SetTerminalAgentState(id, pid, agentStateUUID, "waiting", newer, ""); err != nil || !ok {
		t.Fatalf("first write: ok=%v err=%v", ok, err)
	}
	for _, at := range []time.Time{newer.Add(-time.Millisecond), newer} {
		ok, err := d.SetTerminalAgentState(id, pid, agentStateUUID, "working", at, "")
		if err != nil {
			t.Fatal(err)
		}
		if ok {
			t.Fatalf("an event at %v replaced the state stored at %v", at, newer)
		}
	}
	s, err := d.GetTerminalSession(id)
	if err != nil {
		t.Fatal(err)
	}
	if s.AgentState.String != "waiting" || !s.AgentStateAt.Equal(newer) {
		t.Fatalf("state = %q at %v, want waiting at %v", s.AgentState.String, s.AgentStateAt, newer)
	}
}

func TestSetTerminalAgentState_OnlyFromApproval(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	at := time.Now().UTC()
	for _, tc := range []struct {
		stored string // "" = NULL
		want   bool
	}{
		{"approval", true},
		{"waiting", false},
		{"", false},
	} {
		id := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
		if tc.stored != "" {
			if _, err := d.SetTerminalAgentState(id, pid, agentStateUUID, tc.stored, at, ""); err != nil {
				t.Fatal(err)
			}
		}
		ok, err := d.SetTerminalAgentState(id, pid, agentStateUUID, "working", at.Add(time.Second), "approval")
		if err != nil {
			t.Fatal(err)
		}
		if ok != tc.want {
			t.Fatalf("from %q: written=%v, want %v", tc.stored, ok, tc.want)
		}
	}
}

func TestSetTerminalAgentState_TimestampFormat(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	id := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
	// A whole second in a non-UTC zone: the stored text still carries
	// three fraction digits and Z, so string order is time order.
	at := time.Now().Truncate(time.Second).In(time.FixedZone("UTC+3", 3*3600))
	if ok, err := d.SetTerminalAgentState(id, pid, agentStateUUID, "working", at, ""); err != nil || !ok {
		t.Fatalf("ok=%v err=%v", ok, err)
	}
	var raw string
	if err := d.QueryRow(`SELECT agent_state_at FROM terminal_sessions WHERE id = ?`, id).Scan(&raw); err != nil {
		t.Fatal(err)
	}
	if want := at.UTC().Format("2006-01-02T15:04:05") + ".000Z"; raw != want {
		t.Fatalf("agent_state_at = %q, want %q", raw, want)
	}
	s, err := d.GetTerminalSession(id)
	if err != nil {
		t.Fatal(err)
	}
	if !s.AgentStateAt.Equal(at) || s.AgentStateAt.Location() != time.UTC {
		t.Fatalf("round trip = %v, want %v in UTC", s.AgentStateAt, at)
	}
}
