package db

import (
	"database/sql"
	"errors"
	"fmt"
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
	if ok, err := d.MarkTerminalAgentRun(id, pid, agentStateUUID, at); err != nil || !ok {
		t.Fatalf("a mark over a bad stamp: ok=%v err=%v", ok, err)
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
// previous run (stamped before the mark) still cannot land. Board #396: the
// mark is written with nothing stored too — the stamp with no state is
// what tells the Desktop the hooks run.
func TestMarkTerminalAgentRun_NewRunStartsEmpty(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	other := newTestWorkbench(t, d)
	id := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
	wrote := writeResult(t)
	t0 := time.Now().UTC().Truncate(time.Millisecond)
	if !wrote(d.SetTerminalAgentState(id, pid, agentStateUUID, "waiting", t0, "", nil, false, AgentOrder{})) {
		t.Fatal("first write wrote nothing")
	}
	for _, tc := range []struct {
		name      string
		workbench int64
		uuid      string
	}{
		{"another workbench", other, agentStateUUID},
		{"a nested session's id", pid, "1b6c1f7e-3c2a-4d5e-9f10-2a3b4c5d6e7f"},
	} {
		if wrote(d.MarkTerminalAgentRun(id, tc.workbench, tc.uuid, t0.Add(time.Second))) {
			t.Fatalf("%s: marked", tc.name)
		}
	}
	if wrote(d.MarkTerminalAgentRun(id, pid, agentStateUUID, t0)) {
		t.Fatal("a mark not later than the stored state wrote")
	}
	marked := t0.Add(2 * time.Second)
	if !wrote(d.MarkTerminalAgentRun(id, pid, agentStateUUID, marked)) {
		t.Fatal("the mark wrote nothing")
	}
	if s := storedSession(t, d, id); s.AgentState.Valid || !s.AgentStateAt.Equal(marked) {
		t.Fatalf("after the mark: state %v at %v, want NULL at %v", s.AgentState, s.AgentStateAt, marked)
	}
	again := marked.Add(time.Second)
	if !wrote(d.MarkTerminalAgentRun(id, pid, agentStateUUID, again)) {
		t.Fatal("a mark with nothing stored wrote nothing")
	}
	if s := storedSession(t, d, id); !s.AgentStateAt.Equal(again) {
		t.Fatalf("after the second mark: at %v, want %v", s.AgentStateAt, again)
	}
	if wrote(d.SetTerminalAgentState(id, pid, agentStateUUID, "waiting", t0.Add(time.Second), "", nil, false, AgentOrder{})) {
		t.Fatal("a late hook of the previous run landed after the mark")
	}
	if !wrote(d.SetTerminalAgentState(id, pid, agentStateUUID, "waiting", again.Add(time.Second), "", nil, false, AgentOrder{})) {
		t.Fatal("the new run's first state, equal to the old one, wrote nothing")
	}
}

// Board #396: without the state hooks a new run is cleared with no stamp —
// one would read as the run's mark — and a row with nothing stored, a mark
// of an earlier run included, is cleared once.
func TestClearTerminalAgentState_LeavesNoStamp(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	other := newTestWorkbench(t, d)
	id := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
	wrote := writeResult(t)
	t0 := time.Now().UTC().Truncate(time.Millisecond)
	if !wrote(d.SetTerminalAgentState(id, pid, agentStateUUID, "waiting", t0, "", nil, false, AgentOrder{})) {
		t.Fatal("first write wrote nothing")
	}
	if wrote(d.ClearTerminalAgentState(id, other, agentStateUUID)) {
		t.Fatal("another workbench's clear wrote")
	}
	if !wrote(d.ClearTerminalAgentState(id, pid, agentStateUUID)) {
		t.Fatal("the clear wrote nothing")
	}
	if s := storedSession(t, d, id); s.AgentState.Valid || !s.AgentStateAt.IsZero() {
		t.Fatalf("after the clear: state %v at %v, want both NULL", s.AgentState, s.AgentStateAt)
	}
	if wrote(d.ClearTerminalAgentState(id, pid, agentStateUUID)) {
		t.Fatal("a second clear with nothing stored wrote")
	}
	wrote(d.MarkTerminalAgentRun(id, pid, agentStateUUID, t0))
	if !wrote(d.ClearTerminalAgentState(id, pid, agentStateUUID)) {
		t.Fatal("an earlier run's mark was not cleared")
	}
	if s := storedSession(t, d, id); !s.AgentStateAt.IsZero() {
		t.Fatalf("the earlier mark stayed: at %v", s.AgentStateAt)
	}
}

// writeResult turns a guarded write's (ok, err) into ok, failing the test
// on an error.
func writeResult(t *testing.T) func(bool, error) bool {
	t.Helper()
	return func(ok bool, err error) bool {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
		return ok
	}
}

// storedSession reads row id, failing the test on an error.
func storedSession(t *testing.T, d *DB, id int64) *TerminalSession {
	t.Helper()
	s, err := d.GetTerminalSession(id)
	if err != nil {
		t.Fatal(err)
	}
	return s
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
	for name, start := range map[string]func(d *DB, id, pid int64, at time.Time) (bool, error){
		"clear": func(d *DB, id, pid int64, _ time.Time) (bool, error) {
			return d.ClearTerminalAgentState(id, pid, agentStateUUID)
		},
		"mark": func(d *DB, id, pid int64, at time.Time) (bool, error) {
			return d.MarkTerminalAgentRun(id, pid, agentStateUUID, at)
		},
	} {
		t.Run(name, func(t *testing.T) {
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

			if ok, err := start(d, id, pid, t0.Add(time.Second)); err != nil || !ok {
				t.Fatalf("%s: ok=%v err=%v", name, ok, err)
			}
			if s, _ := d.GetTerminalSession(id); s.ToolRun || s.TurnEnd.Valid {
				t.Fatalf("after the %s: tool run %v, turn end %v", name, s.ToolRun, s.TurnEnd)
			}
		})
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
	if ok, err := d.ClearTerminalAgentState(id, pid, otherUUID); err != nil || !ok {
		t.Fatalf("clear: ok=%v err=%v", ok, err)
	}
	if s, _ := d.GetTerminalSession(id); s.TurnEnd.Valid {
		t.Fatalf("after the clear: turn end %v", s.TurnEnd)
	}
}

// backgroundColumns reads row id's agent_background and agent_background_at
// as stored.
func backgroundColumns(t *testing.T, d *DB, id int64) (sql.NullInt64, sql.NullString) {
	t.Helper()
	var n sql.NullInt64
	var at sql.NullString
	if err := d.QueryRow(`SELECT agent_background, agent_background_at FROM terminal_sessions WHERE id = ?`, id).
		Scan(&n, &at); err != nil {
		t.Fatal(err)
	}
	return n, at
}

// requireNoBackground fails unless row id stores neither background column.
func requireNoBackground(t *testing.T, d *DB, id int64, what string) {
	t.Helper()
	if n, at := backgroundColumns(t, d, id); n.Valid || at.Valid {
		t.Fatalf("%s: agent_background %v, agent_background_at %v, want both NULL", what, n, at)
	}
}

// requireBackground fails unless row id stores count n reported at at.
func requireBackground(t *testing.T, d *DB, id int64, n int64, at time.Time, what string) {
	t.Helper()
	gotN, gotAt := backgroundColumns(t, d, id)
	if !gotN.Valid || gotN.Int64 != n || gotAt.String != at.UTC().Format(agentStateAtLayout) {
		t.Fatalf("%s: agent_background %v at %v, want %d at %v", what, gotN, gotAt, n, at)
	}
}

// terminalRowSnapshot renders every column of row id, for a byte-identical
// comparison.
func terminalRowSnapshot(t *testing.T, d *DB, id int64) string {
	t.Helper()
	rows, err := d.Query(`SELECT * FROM terminal_sessions WHERE id = ?`, id)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	cols, err := rows.Columns()
	if err != nil {
		t.Fatal(err)
	}
	if !rows.Next() {
		t.Fatalf("row %d not found", id)
	}
	vals := make([]any, len(cols))
	ptrs := make([]any, len(cols))
	for i := range vals {
		ptrs[i] = &vals[i]
	}
	if err := rows.Scan(ptrs...); err != nil {
		t.Fatal(err)
	}
	out := ""
	for i, c := range cols {
		out += fmt.Sprintf("%s=%#v;", c, vals[i])
	}
	return out
}

// otherAgentColumns renders the columns LowerTerminalBackground must never
// touch.
func otherAgentColumns(t *testing.T, d *DB, id int64) string {
	t.Helper()
	var state, stateAt, finishedAt, failedAt sql.NullString
	var turnEnd sql.NullInt64
	var toolRun int
	var agentError string
	if err := d.QueryRow(`SELECT agent_state, agent_state_at, finished_at, agent_turn_end, agent_tool_run,
		agent_failed_at, agent_error FROM terminal_sessions WHERE id = ?`, id).
		Scan(&state, &stateAt, &finishedAt, &turnEnd, &toolRun, &failedAt, &agentError); err != nil {
		t.Fatal(err)
	}
	return fmt.Sprintf("%v|%v|%v|%v|%d|%v|%q", state, stateAt, finishedAt, turnEnd, toolRun, failedAt, agentError)
}

// stopWith is the Stop's order carrying snapshot n (n < 0: none).
func stopWith(n int64) AgentOrder {
	if n < 0 {
		return AgentOrder{Stop: true}
	}
	return AgentOrder{Stop: true, Background: sql.NullInt64{Int64: n, Valid: true}}
}

// Board #411: the Stop stores its snapshot of in-flight background subagents
// next to its `waiting`, stamped with the write; none or zero stores NULL.
func TestProj11_StopWriteStoresTheSnapshot(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	t0 := time.Now().UTC().Truncate(time.Millisecond)
	w := writeResult(t)

	id := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
	if !w(d.SetTerminalAgentState(id, pid, agentStateUUID, "waiting", t0, "", nil, false, stopWith(2))) {
		t.Fatal("the Stop did not write")
	}
	s := storedSession(t, d, id)
	if s.Background != (sql.NullInt64{Int64: 2, Valid: true}) || !s.BackgroundAt.Equal(s.AgentStateAt) || !s.BackgroundAt.Equal(t0) {
		t.Fatalf("count %v at %v, want 2 at the state's time %v", s.Background, s.BackgroundAt, s.AgentStateAt)
	}

	for _, tc := range []struct {
		name  string
		order AgentOrder
	}{
		{"a zero count", stopWith(0)},
		{"no count", stopWith(-1)},
	} {
		id := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
		if !w(d.SetTerminalAgentState(id, pid, agentStateUUID, "waiting", t0, "", nil, false, tc.order)) {
			t.Fatalf("%s: the Stop did not write", tc.name)
		}
		requireNoBackground(t, d, id, tc.name)
	}
}

// Board #411 (db half): agent_background goes from NULL to a number only in
// the Stop's write — LowerTerminalBackground and every other `waiting` leave
// a NULL count alone.
func TestProj11_OnlyTheStopStartsBackground(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	t0 := time.Now().UTC().Truncate(time.Millisecond)
	w := writeResult(t)

	id := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
	// A non-Stop write ignores a snapshot it carries.
	if !w(d.SetTerminalAgentState(id, pid, agentStateUUID, "waiting", t0, "", nil, false,
		AgentOrder{Background: sql.NullInt64{Int64: 3, Valid: true}})) {
		t.Fatal("the plain waiting did not write")
	}
	requireNoBackground(t, d, id, "a plain waiting")

	before := terminalRowSnapshot(t, d, id)
	one := int64(1)
	for _, count := range []*int64{nil, &one} {
		if w(d.LowerTerminalBackground(id, pid, agentStateUUID, t0.Add(time.Second), count)) {
			t.Fatalf("LowerTerminalBackground(%v) wrote over a NULL count", count)
		}
		if after := terminalRowSnapshot(t, d, id); after != before {
			t.Fatalf("the row changed:\nbefore %s\nafter  %s", before, after)
		}
	}
}

// Board #411: LowerTerminalBackground only refreshes the report time and
// lowers the count of a counted `waiting`, never raises it and never touches
// another column.
func TestProj11_LowerTerminalBackgroundOnlyLowers(t *testing.T) {
	const otherUUID = "1b6c1f7e-3c2a-4d5e-9f10-2a3b4c5d6e7f"
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	other := newTestWorkbench(t, d)
	t0 := time.Now().UTC().Truncate(time.Millisecond)
	w := writeResult(t)
	ptr := func(n int64) *int64 { return &n }

	// counted is a failed, finished `waiting` with a turn end, counted 3 at t0.
	counted := func() int64 {
		id := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
		if !w(d.SetTerminalAgentState(id, pid, agentStateUUID, "waiting", t0.Add(-time.Second), "",
			&AgentFailure{Error: "rate_limit"}, false, AgentOrder{})) {
			t.Fatal("the StopFailure did not write")
		}
		if !w(d.SetTerminalTurnEnd(id, pid, agentStateUUID, 100)) {
			t.Fatal("the turn end did not write")
		}
		if _, err := d.Exec(`UPDATE terminal_sessions SET finished_at = '2026-01-01T00:00:00Z' WHERE id = ?`, id); err != nil {
			t.Fatal(err)
		}
		if !w(d.SetTerminalAgentState(id, pid, agentStateUUID, "waiting", t0, "", nil, false, stopWith(3))) {
			t.Fatal("the Stop did not write")
		}
		requireBackground(t, d, id, 3, t0, "setup")
		return id
	}

	for _, tc := range []struct {
		name  string
		count *int64
		wantN int64
	}{
		{"a higher count", ptr(5), 3},
		{"a lower count", ptr(1), 1},
		{"a zero count", ptr(0), 0},
		{"no count", nil, 3},
	} {
		id := counted()
		others := otherAgentColumns(t, d, id)
		at := t0.Add(time.Second)
		if !w(d.LowerTerminalBackground(id, pid, agentStateUUID, at, tc.count)) {
			t.Fatalf("%s: did not write", tc.name)
		}
		requireBackground(t, d, id, tc.wantN, at, tc.name)
		if got := otherAgentColumns(t, d, id); got != others {
			t.Fatalf("%s: other columns changed:\nbefore %s\nafter  %s", tc.name, others, got)
		}
	}

	for _, tc := range []struct {
		name      string
		setup     func(id int64)
		workbench int64
		uuid      string
		at        time.Time
	}{
		{"an equal stamp", nil, pid, agentStateUUID, t0},
		{"an older stamp", nil, pid, agentStateUUID, t0.Add(-time.Second)},
		{"another conversation", nil, pid, otherUUID, t0.Add(time.Second)},
		{"another workbench", nil, other, agentStateUUID, t0.Add(time.Second)},
		{"over approval", func(id int64) {
			if !w(d.SetTerminalAgentState(id, pid, agentStateUUID, "approval", t0.Add(time.Second), "", nil, false, AgentOrder{})) {
				t.Fatal("approval did not write")
			}
		}, pid, agentStateUUID, t0.Add(2 * time.Second)},
		{"over working", func(id int64) {
			// No write path leaves a count under `working`; the guard holds anyway.
			if _, err := d.Exec(`UPDATE terminal_sessions SET agent_state = 'working' WHERE id = ?`, id); err != nil {
				t.Fatal(err)
			}
		}, pid, agentStateUUID, t0.Add(2 * time.Second)},
	} {
		id := counted()
		if tc.setup != nil {
			tc.setup(id)
		}
		before := terminalRowSnapshot(t, d, id)
		for _, count := range []*int64{nil, ptr(1)} {
			if w(d.LowerTerminalBackground(id, tc.workbench, tc.uuid, tc.at, count)) {
				t.Fatalf("%s: wrote (count %v)", tc.name, count)
			}
			if after := terminalRowSnapshot(t, d, id); after != before {
				t.Fatalf("%s: the row changed:\nbefore %s\nafter  %s", tc.name, before, after)
			}
		}
	}
}

// Board #411 (db half): a Stop whose count differs from the stored
// `waiting`'s is a change — it writes and advances agent_state_at; a failed
// `waiting` keeps its error through a counted Stop and an idle notice.
func TestProj11_StopOverWaitingWithAnotherCountWrites(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	t0 := time.Now().UTC().Truncate(time.Millisecond)
	w := writeResult(t)

	id := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
	if !w(d.SetTerminalAgentState(id, pid, agentStateUUID, "waiting", t0, "", nil, false, stopWith(2))) {
		t.Fatal("the first Stop did not write")
	}
	if !w(d.SetTerminalAgentState(id, pid, agentStateUUID, "waiting", t0.Add(time.Second), "", nil, false, stopWith(1))) {
		t.Fatal("a Stop with another count did not write")
	}
	requireBackground(t, d, id, 1, t0.Add(time.Second), "a Stop with another count")
	if s := storedSession(t, d, id); !s.AgentStateAt.Equal(t0.Add(time.Second)) {
		t.Fatalf("agent_state_at %v, want it advanced to %v", s.AgentStateAt, t0.Add(time.Second))
	}
	if w(d.SetTerminalAgentState(id, pid, agentStateUUID, "waiting", t0.Add(2*time.Second), "", nil, false, stopWith(1))) {
		t.Fatal("a Stop with the same count wrote a state")
	}
	if !w(d.SetTerminalAgentState(id, pid, agentStateUUID, "waiting", t0.Add(3*time.Second), "", nil, false, stopWith(-1))) {
		t.Fatal("a Stop with no count over a counted waiting did not write")
	}
	requireNoBackground(t, d, id, "a Stop with no count")
	if s := storedSession(t, d, id); !s.AgentStateAt.Equal(t0.Add(3 * time.Second)) {
		t.Fatalf("agent_state_at %v, want it advanced to %v", s.AgentStateAt, t0.Add(3*time.Second))
	}

	// F3: a failed `waiting` keeps its error through a counted Stop and an
	// idle notice, which still write the count columns. Error outranks
	// background: agent_failed_at moves along with agent_state_at, so the
	// Desktop (failed only when agent_failed_at == agent_state_at) still
	// reads the row as failed.
	failed := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
	if !w(d.SetTerminalAgentState(failed, pid, agentStateUUID, "waiting", t0, "", &AgentFailure{Error: "rate_limit"}, false, AgentOrder{})) {
		t.Fatal("the StopFailure did not write")
	}
	requireFailedNow := func(at time.Time, what string) {
		t.Helper()
		s := storedSession(t, d, failed)
		want := AgentFailure{At: at.Format(agentStateAtLayout), Error: "rate_limit"}
		if s.AgentFailure == nil || *s.AgentFailure != want {
			t.Fatalf("after %s: failure %+v, want %+v", what, s.AgentFailure, want)
		}
		if got := AgentStateStamp(s.AgentStateAt); got != s.AgentFailure.At {
			t.Fatalf("after %s: agent_state_at %s != agent_failed_at %s: the row no longer reads failed", what, got, s.AgentFailure.At)
		}
	}
	if !w(d.SetTerminalAgentState(failed, pid, agentStateUUID, "waiting", t0.Add(time.Second), "", nil, false, stopWith(2))) {
		t.Fatal("a counted Stop over a failed waiting did not write")
	}
	requireBackground(t, d, failed, 2, t0.Add(time.Second), "a counted Stop over a failed waiting")
	requireFailedNow(t0.Add(time.Second), "the counted Stop")
	if !w(d.SetTerminalAgentState(failed, pid, agentStateUUID, "waiting", t0.Add(2*time.Second), "", nil, false, AgentOrder{})) {
		t.Fatal("an idle notice over a counted failed waiting did not write")
	}
	requireNoBackground(t, d, failed, "an idle notice over a counted failed waiting")
	requireFailedNow(t0.Add(2*time.Second), "the idle notice")
}

// Board #411 (db half): a main turn (a prompt, a main or a subagent's tool
// result), a StopFailure and an idle notice clear the count; a permission
// prompt keeps it.
func TestProj11_MainTurnAndIdleNoticeClearTheCount(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	t0 := time.Now().UTC().Truncate(time.Millisecond)
	w := writeResult(t)

	for _, tc := range []struct {
		name     string
		state    string
		onlyFrom string
		failure  *AgentFailure
		prompt   bool
		order    AgentOrder
	}{
		{"a prompt", "working", "", nil, true, AgentOrder{}},
		{"a main-thread tool result", "working", "", nil, false, AgentOrder{ToolRun: true}},
		{"a StopFailure", "waiting", "", &AgentFailure{Error: "rate_limit"}, false, AgentOrder{}},
		{"an idle notice", "waiting", "", nil, false, AgentOrder{}},
	} {
		id := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
		if !w(d.SetTerminalAgentState(id, pid, agentStateUUID, "waiting", t0, "", nil, false, stopWith(2))) {
			t.Fatalf("%s: the Stop did not write", tc.name)
		}
		if !w(d.SetTerminalAgentState(id, pid, agentStateUUID, tc.state, t0.Add(time.Second), tc.onlyFrom, tc.failure, tc.prompt, tc.order)) {
			t.Fatalf("%s: did not write", tc.name)
		}
		requireNoBackground(t, d, id, tc.name)
	}

	id := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
	if !w(d.SetTerminalAgentState(id, pid, agentStateUUID, "waiting", t0, "", nil, false, stopWith(2))) {
		t.Fatal("the Stop did not write")
	}
	if !w(d.SetTerminalAgentState(id, pid, agentStateUUID, "approval", t0.Add(time.Second), "", nil, false, AgentOrder{})) {
		t.Fatal("approval did not write")
	}
	requireBackground(t, d, id, 2, t0, "a permission prompt")
	// A subagent's tool result after the grant: `working` outranks background.
	if !w(d.SetTerminalAgentState(id, pid, agentStateUUID, "working", t0.Add(2*time.Second), "approval", nil, false, AgentOrder{})) {
		t.Fatal("the subagent's working over approval did not write")
	}
	requireNoBackground(t, d, id, "a subagent's working over approval")
}

// Board #411: a new run (the mark or the stampless clear) and a conversation
// switch clear the count.
func TestProj11_NewRunAndConversationSwitchClearTheCount(t *testing.T) {
	const otherUUID = "1b6c1f7e-3c2a-4d5e-9f10-2a3b4c5d6e7f"
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	t0 := time.Now().UTC().Truncate(time.Millisecond)
	w := writeResult(t)

	for _, tc := range []struct {
		name  string
		write func(id int64) (bool, error)
	}{
		{"MarkTerminalAgentRun", func(id int64) (bool, error) {
			return d.MarkTerminalAgentRun(id, pid, agentStateUUID, t0.Add(time.Second))
		}},
		{"ClearTerminalAgentState", func(id int64) (bool, error) {
			return d.ClearTerminalAgentState(id, pid, agentStateUUID)
		}},
		{"SetTerminalClaudeSessionID", func(id int64) (bool, error) {
			return d.SetTerminalClaudeSessionID(id, pid, otherUUID)
		}},
	} {
		id := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
		if !w(d.SetTerminalAgentState(id, pid, agentStateUUID, "waiting", t0, "", nil, false, stopWith(2))) {
			t.Fatalf("%s: the Stop did not write", tc.name)
		}
		if !w(tc.write(id)) {
			t.Fatalf("%s: did not write", tc.name)
		}
		requireNoBackground(t, d, id, tc.name)
	}
}

// Board #411: EndTerminalBackground NULLs the count only while the row still
// carries the agent_background_at the probe read — a report or Stop that
// landed since wins — and never touches another column.
func TestEndTerminalBackgroundIsCompareAndClear(t *testing.T) {
	const otherUUID = "1b6c1f7e-3c2a-4d5e-9f10-2a3b4c5d6e7f"
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	other := newTestWorkbench(t, d)
	t0 := time.Now().UTC().Truncate(time.Millisecond)
	seen := t0.Format(agentStateAtLayout)
	w := writeResult(t)

	// counted is a finished `waiting` with a turn end, counted 2 at t0.
	counted := func() int64 {
		id := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
		if !w(d.SetTerminalTurnEnd(id, pid, agentStateUUID, 100)) {
			t.Fatal("the turn end did not write")
		}
		if _, err := d.Exec(`UPDATE terminal_sessions SET finished_at = '2026-01-01T00:00:00Z' WHERE id = ?`, id); err != nil {
			t.Fatal(err)
		}
		if !w(d.SetTerminalAgentState(id, pid, agentStateUUID, "waiting", t0, "", nil, false, stopWith(2))) {
			t.Fatal("the Stop did not write")
		}
		requireBackground(t, d, id, 2, t0, "setup")
		return id
	}

	id := counted()
	others := otherAgentColumns(t, d, id)
	if !w(d.EndTerminalBackground(id, pid, agentStateUUID, seen)) {
		t.Fatal("the matching stamp did not clear")
	}
	requireNoBackground(t, d, id, "the matching stamp")
	if got := otherAgentColumns(t, d, id); got != others {
		t.Fatalf("other columns changed:\nbefore %s\nafter  %s", others, got)
	}
	if w(d.EndTerminalBackground(id, pid, agentStateUUID, seen)) {
		t.Fatal("a second end over a NULL count wrote")
	}

	for _, tc := range []struct {
		name      string
		setup     func(id int64)
		workbench int64
		uuid      string
	}{
		{"a newer report", func(id int64) {
			if !w(d.LowerTerminalBackground(id, pid, agentStateUUID, t0.Add(time.Second), nil)) {
				t.Fatal("the heartbeat did not write")
			}
		}, pid, agentStateUUID},
		{"a newer Stop", func(id int64) {
			if !w(d.SetTerminalAgentState(id, pid, agentStateUUID, "waiting", t0.Add(time.Second), "", nil, false, stopWith(1))) {
				t.Fatal("the second Stop did not write")
			}
		}, pid, agentStateUUID},
		{"over working", func(id int64) {
			// No write path leaves a count under `working`; the guard holds anyway.
			if _, err := d.Exec(`UPDATE terminal_sessions SET agent_state = 'working' WHERE id = ?`, id); err != nil {
				t.Fatal(err)
			}
		}, pid, agentStateUUID},
		{"another conversation", nil, pid, otherUUID},
		{"another workbench", nil, other, agentStateUUID},
	} {
		id := counted()
		if tc.setup != nil {
			tc.setup(id)
		}
		before := terminalRowSnapshot(t, d, id)
		if w(d.EndTerminalBackground(id, tc.workbench, tc.uuid, seen)) {
			t.Fatalf("%s: wrote", tc.name)
		}
		if after := terminalRowSnapshot(t, d, id); after != before {
			t.Fatalf("%s: the row changed:\nbefore %s\nafter  %s", tc.name, before, after)
		}
	}
}
