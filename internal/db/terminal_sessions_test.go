package db

import (
	"database/sql"
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
	t.Parallel()
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
		written, err := d.SetTerminalAgentState(tc.id, tc.workbench, tc.uuid, tc.state, tc.at, "", nil, false, AgentOrder{})
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
	if ok, err := d.SetTerminalAgentState(id, pid, agentStateUUID, "waiting", newer, "", nil, false, AgentOrder{}); err != nil || !ok {
		t.Fatalf("first write: ok=%v err=%v", ok, err)
	}
	for _, at := range []time.Time{newer.Add(-time.Millisecond), newer} {
		ok, err := d.SetTerminalAgentState(id, pid, agentStateUUID, "working", at, "", nil, false, AgentOrder{})
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
			if _, err := d.SetTerminalAgentState(id, pid, agentStateUUID, tc.stored, at, "", nil, false, AgentOrder{}); err != nil {
				t.Fatal(err)
			}
		}
		ok, err := d.SetTerminalAgentState(id, pid, agentStateUUID, "working", at.Add(time.Second), "approval", nil, false, AgentOrder{})
		if err != nil {
			t.Fatal(err)
		}
		if ok != tc.want {
			t.Fatalf("from %q: written=%v, want %v", tc.stored, ok, tc.want)
		}
	}
}

func TestGetTerminalSession_UnreadableStampReadsAsNeverReported(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	id := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
	if _, err := d.Exec(`UPDATE terminal_sessions SET agent_state = 'waiting', agent_state_at = 'yesterday' WHERE id = ?`, id); err != nil {
		t.Fatal(err)
	}
	s, err := d.GetTerminalSession(id)
	if err != nil {
		t.Fatalf("a bad stamp must not fail the row's other readers: %v", err)
	}
	if !s.AgentStateAt.IsZero() || s.AgentState.String != "waiting" || s.ClaudeSessionID.String != agentStateUUID {
		t.Fatalf("row = %+v", s)
	}
	// The next write replaces it, though "yesterday" sorts after any real stamp.
	at := time.Now()
	if ok, err := d.SetTerminalAgentState(id, pid, agentStateUUID, "working", at, "", nil, false, AgentOrder{}); err != nil || !ok {
		t.Fatalf("a write over a bad stamp: ok=%v err=%v", ok, err)
	}
	if s, err = d.GetTerminalSession(id); err != nil || !s.AgentStateAt.Equal(at.Truncate(time.Millisecond)) {
		t.Fatalf("stamp after the write = %v (err %v), want %v", s.AgentStateAt, err, at)
	}
	if _, err := d.Exec(`UPDATE terminal_sessions SET agent_state_at = 'yesterday' WHERE id = ?`, id); err != nil {
		t.Fatal(err)
	}
	if ok, err := d.ClearTerminalAgentState(id, pid, agentStateUUID, at); err != nil || !ok {
		t.Fatalf("a clear over a bad stamp: ok=%v err=%v", ok, err)
	}
}

func TestSetTerminalAgentState_TimestampFormat(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	id := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
	// A whole second in a non-UTC zone: the stored text still carries
	// three fraction digits and Z, so string order is time order.
	at := time.Now().Truncate(time.Second).In(time.FixedZone("UTC+3", 3*3600))
	if ok, err := d.SetTerminalAgentState(id, pid, agentStateUUID, "working", at, "", nil, false, AgentOrder{}); err != nil || !ok {
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

// Board #312: a new run starts with no state, so its first state is written
// even when it equals the previous run's last one; a late hook of the
// previous run (stamped before the clear) still cannot land.
func TestClearTerminalAgentState_NewRunStartsEmpty(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	other := newTestWorkbench(t, d)
	id := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
	t0 := time.Now().UTC().Truncate(time.Millisecond)
	if ok, err := d.SetTerminalAgentState(id, pid, agentStateUUID, "waiting", t0, "", nil, false, AgentOrder{}); err != nil || !ok {
		t.Fatalf("first write: ok=%v err=%v", ok, err)
	}
	for _, tc := range []struct {
		name      string
		workbench int64
		uuid      string
	}{
		{"another workbench", other, agentStateUUID},
		{"a nested session's id", pid, "1b6c1f7e-3c2a-4d5e-9f10-2a3b4c5d6e7f"},
	} {
		if ok, err := d.ClearTerminalAgentState(id, tc.workbench, tc.uuid, t0.Add(time.Second)); err != nil || ok {
			t.Fatalf("%s: cleared=%v err=%v", tc.name, ok, err)
		}
	}
	cleared := t0.Add(2 * time.Second)
	if ok, err := d.ClearTerminalAgentState(id, pid, agentStateUUID, cleared); err != nil || !ok {
		t.Fatalf("clear: ok=%v err=%v", ok, err)
	}
	s, err := d.GetTerminalSession(id)
	if err != nil {
		t.Fatal(err)
	}
	if s.AgentState.Valid || !s.AgentStateAt.Equal(cleared) {
		t.Fatalf("after the clear: state %v at %v, want NULL at %v", s.AgentState, s.AgentStateAt, cleared)
	}
	if ok, _ := d.ClearTerminalAgentState(id, pid, agentStateUUID, cleared.Add(time.Second)); ok {
		t.Fatal("a second clear with nothing stored wrote")
	}
	if ok, _ := d.SetTerminalAgentState(id, pid, agentStateUUID, "waiting", t0.Add(time.Second), "", nil, false, AgentOrder{}); ok {
		t.Fatal("a late hook of the previous run landed after the clear")
	}
	if ok, err := d.SetTerminalAgentState(id, pid, agentStateUUID, "waiting", cleared.Add(time.Second), "", nil, false, AgentOrder{}); err != nil || !ok {
		t.Fatalf("the new run's first state, equal to the old one: ok=%v err=%v", ok, err)
	}
}

// Board #368: the Stop replaces a `working` a main-thread tool result wrote,
// even one stamped after it, and keeps the later time; any other `working`
// (a prompt, a subagent's tool result) keeps the time order.
func TestSetTerminalAgentState_StopReplacesAToolRunsWorking(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	t0 := time.Now().UTC().Truncate(time.Millisecond)
	for _, tc := range []struct {
		name  string
		order AgentOrder
		want  bool
	}{
		{"a main-thread tool result", AgentOrder{ToolRun: true}, true},
		{"a prompt or a subagent's tool result", AgentOrder{}, false},
	} {
		id := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
		if ok, err := d.SetTerminalAgentState(id, pid, agentStateUUID, "working", t0.Add(2*time.Second), "", nil, false, tc.order); err != nil || !ok {
			t.Fatalf("%s: working: ok=%v err=%v", tc.name, ok, err)
		}
		if ok, err := d.SetTerminalAgentState(id, pid, agentStateUUID, "waiting", t0.Add(time.Second), "", nil, false, AgentOrder{}); err != nil || ok {
			t.Fatalf("%s: a plain older waiting: ok=%v err=%v", tc.name, ok, err)
		}
		ok, err := d.SetTerminalAgentState(id, pid, agentStateUUID, "waiting", t0.Add(time.Second), "", nil, false, AgentOrder{Stop: true})
		if err != nil {
			t.Fatal(err)
		}
		if ok != tc.want {
			t.Fatalf("%s: the Stop wrote=%v, want %v", tc.name, ok, tc.want)
		}
		s, err := d.GetTerminalSession(id)
		if err != nil {
			t.Fatal(err)
		}
		if !s.AgentStateAt.Equal(t0.Add(2 * time.Second)) {
			t.Fatalf("%s: stored time %v, want the later %v", tc.name, s.AgentStateAt, t0.Add(2*time.Second))
		}
		if s.ToolRun {
			t.Fatalf("%s: agent_tool_run set after the Stop", tc.name)
		}
	}
}

// Board #368: SetTerminalTurnEnd keeps the row guards — its own workbench's
// row and conversation only — and skips an unchanged end.
func TestSetTerminalTurnEnd_KeepsTheRowGuards(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	id := newAgentStateRow(t, d, pid, "claude", agentStateUUID)

	for _, tc := range []struct {
		name      string
		workbench int64
		uuid      string
		end       int64
		want      bool
	}{
		{"its own row", pid, agentStateUUID, 100, true},
		{"the same end", pid, agentStateUUID, 100, false},
		{"another workbench", pid + 1, agentStateUUID, 200, false},
		{"a nested session's id", pid, "1b6c1f7e-3c2a-4d5e-9f10-2a3b4c5d6e7f", 200, false},
	} {
		ok, err := d.SetTerminalTurnEnd(id, tc.workbench, tc.uuid, tc.end)
		if err != nil || ok != tc.want {
			t.Fatalf("%s: ok=%v err=%v, want %v", tc.name, ok, err, tc.want)
		}
	}
}

// Board #368: a tool result's write lands only while the turn end it checked
// its call against still holds.
func TestSetTerminalAgentState_ToolRunNeedsTheCurrentTurnEnd(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	id := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
	t0 := time.Now().UTC().Truncate(time.Millisecond)
	if _, err := d.SetTerminalTurnEnd(id, pid, agentStateUUID, 100); err != nil {
		t.Fatal(err)
	}
	if _, err := d.SetTerminalAgentState(id, pid, agentStateUUID, "waiting", t0, "", nil, false, AgentOrder{Stop: true}); err != nil {
		t.Fatal(err)
	}
	stale := AgentOrder{ToolRun: true} // checked before the Stop recorded 100
	if ok, err := d.SetTerminalAgentState(id, pid, agentStateUUID, "working", t0.Add(time.Second), "", nil, false, stale); err != nil || ok {
		t.Fatalf("a tool result checked against an older turn end: ok=%v err=%v", ok, err)
	}
	seen := AgentOrder{ToolRun: true, SeenTurnEnd: sql.NullInt64{Int64: 100, Valid: true}}
	if ok, err := d.SetTerminalAgentState(id, pid, agentStateUUID, "working", t0.Add(time.Second), "", nil, false, seen); err != nil || !ok {
		t.Fatalf("a tool result checked against the current turn end: ok=%v err=%v", ok, err)
	}
	s, err := d.GetTerminalSession(id)
	if err != nil {
		t.Fatal(err)
	}
	if !s.ToolRun || s.TurnEnd.Int64 != 100 {
		t.Fatalf("tool run %v, turn end %v; want true, 100", s.ToolRun, s.TurnEnd)
	}
}

// Board #368: a new process run starts with no turn order.
func TestClearTerminalAgentState_DropsTheTurnOrder(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	id := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
	t0 := time.Now().UTC().Truncate(time.Millisecond)
	if _, err := d.SetTerminalTurnEnd(id, pid, agentStateUUID, 100); err != nil {
		t.Fatal(err)
	}
	seen := AgentOrder{ToolRun: true, SeenTurnEnd: sql.NullInt64{Int64: 100, Valid: true}}
	if ok, err := d.SetTerminalAgentState(id, pid, agentStateUUID, "working", t0, "", nil, false, seen); err != nil || !ok {
		t.Fatalf("tool result: ok=%v err=%v", ok, err)
	}

	if ok, err := d.ClearTerminalAgentState(id, pid, agentStateUUID, t0.Add(time.Second)); err != nil || !ok {
		t.Fatalf("clear: ok=%v err=%v", ok, err)
	}
	if s, _ := d.GetTerminalSession(id); s.ToolRun || s.TurnEnd.Valid {
		t.Fatalf("after the clear: tool run %v, turn end %v", s.ToolRun, s.TurnEnd)
	}
}

// Board #368: a conversation switch drops the old transcript's turn order,
// and a new run clears a turn order left on a row with no state (the
// Desktop's Start fresh moves the id without it).
func TestTerminalTurnOrder_ResetOnSwitchAndNewRun(t *testing.T) {
	const otherUUID = "1b6c1f7e-3c2a-4d5e-9f10-2a3b4c5d6e7f"
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	id := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
	t0 := time.Now().UTC().Truncate(time.Millisecond)
	if _, err := d.SetTerminalTurnEnd(id, pid, agentStateUUID, 100); err != nil {
		t.Fatal(err)
	}
	if _, err := d.SetTerminalAgentState(id, pid, agentStateUUID, "working", t0, "", nil, false,
		AgentOrder{ToolRun: true, SeenTurnEnd: sql.NullInt64{Int64: 100, Valid: true}}); err != nil {
		t.Fatal(err)
	}
	if ok, err := d.SetTerminalClaudeSessionID(id, pid, otherUUID); err != nil || !ok {
		t.Fatalf("switch: ok=%v err=%v", ok, err)
	}
	s, err := d.GetTerminalSession(id)
	if err != nil {
		t.Fatal(err)
	}
	if s.TurnEnd.Valid || s.ToolRun || s.AgentState.String != "working" {
		t.Fatalf("after the switch: turn end %v, tool run %v, state %q", s.TurnEnd, s.ToolRun, s.AgentState.String)
	}

	// A row with no state but a turn order: the new run's clear still runs.
	if _, err := d.Exec(`UPDATE terminal_sessions SET agent_state = NULL, agent_turn_end = 50 WHERE id = ?`, id); err != nil {
		t.Fatal(err)
	}
	if ok, err := d.ClearTerminalAgentState(id, pid, otherUUID, t0.Add(time.Second)); err != nil || !ok {
		t.Fatalf("clear: ok=%v err=%v", ok, err)
	}
	if s, _ := d.GetTerminalSession(id); s.TurnEnd.Valid {
		t.Fatalf("after the clear: turn end %v", s.TurnEnd)
	}
}
