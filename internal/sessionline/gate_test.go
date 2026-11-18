package sessionline

import (
	"database/sql"
	"errors"
	"path/filepath"
	"testing"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/sessionagent"
	"watchtower/internal/sessionstate"
)

var (
	runStart = time.Date(2026, 11, 18, 9, 0, 0, 0, time.UTC)
	gateNow  = runStart.Add(10 * time.Minute)
)

func ptr[T any](v T) *T { return &v }

// row is a live session of kind whose hooks wrote state at the time at (state "" is
// the run's mark: a stamp and no state).
func row(kind, state string, at time.Time) sessionstate.Row {
	r := sessionstate.Row{ID: 7, Kind: kind, RunStartedAt: db.AgentStateStamp(runStart), AgentStateAt: ptr(db.AgentStateStamp(at))}
	if state != "" {
		r.AgentState = ptr(state)
	}
	return r
}

type gateCase struct {
	name      string
	row       sessionstate.Row
	hold      string
	whileBusy bool
}

func runGate(t *testing.T, cases []gateCase) {
	t.Helper()
	for _, c := range cases {
		hold, busy := Gate(c.row, gateNow)
		if hold != c.hold || busy != c.whileBusy {
			t.Errorf("%s: Gate = (%q, %v), want (%q, %v)", c.name, hold, busy, c.hold, c.whileBusy)
		}
	}
}

// A Claude Code session takes the line while it works (Claude queues it to
// its next step), sent while busy; idle, it takes it plainly. Without a hook
// of this run it is neither idle nor known to work: held.
func TestGate_ClaudeTakesTheLineWhileWorking(t *testing.T) {
	at := runStart.Add(time.Minute)
	agentsWorking := row("claude", "waiting", at)
	agentsWorking.AgentBackground, agentsWorking.AgentBackgroundAt = ptr(2), ptr(db.AgentStateStamp(at))
	notLive := row("claude", "waiting", at)
	notLive.RunStartedAt = ""
	runGate(t, []gateCase{
		{"working", row("claude", "working", at), "", true},
		{"agents working", agentsWorking, "", true},
		{"stopped", row("claude", "waiting", at), "", false},
		{"marked idle", row("claude", "", at), "", false},
		{"no hook this run", row("claude", "working", runStart.Add(-time.Minute)), HoldAgentBusy, false},
		{"not live", notLive, HoldAgentBusy, false},
	})
}

// A Codex session takes the line only when idle: working holds it. The rule
// is the capability row's, never the kind's: a row that takes lines while
// working gets the line.
func TestGate_CodexOnlyWhenIdle(t *testing.T) {
	at := runStart.Add(time.Minute)
	runGate(t, []gateCase{
		{"working", row("codex", "working", at), HoldAgentBusy, false},
		{"stopped", row("codex", "waiting", at), "", false},
		{"marked idle", row("codex", "", at), "", false},
	})
	hold, busy := GateWith(row("codex", "working", at), gateNow, sessionagent.CapsOf("claude"))
	if hold != "" || !busy {
		t.Fatalf("GateWith(claude caps) = (%q, %v), want (\"\", true)", hold, busy)
	}
	if hold, _ := GateWith(row("claude", "waiting", at), gateNow, sessionagent.Caps{}); hold != "" {
		t.Fatalf("an idle row with no caps = %q, want the line", hold)
	}
}

// A permission prompt holds the line for every agent.
func TestGate_PermissionPromptHolds(t *testing.T) {
	at := runStart.Add(time.Minute)
	runGate(t, []gateCase{
		{"claude", row("claude", "approval", at), HoldNeedsApproval, false},
		{"codex", row("codex", "approval", at), HoldNeedsApproval, false},
	})
}

// A line just submitted holds the next until a hook reports after it, or
// BusyAfterSubmit passed.
func TestGate_JustSubmittedHoldsUntilAHook(t *testing.T) {
	submitted := runStart.Add(5 * time.Minute)
	before := row("claude", "waiting", submitted.Add(-time.Second))
	cases := []struct {
		name      string
		submitted time.Time
		row       sessionstate.Row
		now       time.Time
		want      bool
	}{
		{"never submitted", time.Time{}, before, submitted.Add(time.Second), false},
		{"no hook since", submitted, before, submitted.Add(BusyAfterSubmit - time.Second), true},
		{"no trusted hook", submitted, row("claude", "", submitted.Add(-time.Second)), submitted.Add(time.Second), true},
		{"a hook at the submit", submitted, row("claude", "working", submitted), submitted.Add(time.Second), true},
		{"a hook since", submitted, row("claude", "working", submitted.Add(time.Second)), submitted.Add(2 * time.Second), false},
		{"settled", submitted, before, submitted.Add(BusyAfterSubmit), false},
	}
	for _, c := range cases {
		if got := JustSubmitted(c.submitted, c.row, c.now); got != c.want {
			t.Errorf("%s: JustSubmitted = %v, want %v", c.name, got, c.want)
		}
	}
}

// The Return goes only where the hooks vouch for the run (PROJ-12): a fresh
// read, hooks reported this run, no dialog; a dialog is answered, never
// submitted into.
func TestVouch_HooksVouchForTheRun(t *testing.T) {
	at := runStart.Add(time.Minute)
	cases := []struct {
		name              string
		row               sessionstate.Row
		fresh             bool
		canSubmit, dialog bool
	}{
		{"reported, fresh", row("claude", "waiting", at), true, true, false},
		{"marked, fresh", row("claude", "", at), true, true, false},
		{"stale read", row("claude", "waiting", at), false, false, false},
		{"no hooks this run", row("claude", "waiting", runStart.Add(-time.Minute)), true, false, false},
		{"dialog", row("claude", "approval", at), true, false, true},
	}
	for _, c := range cases {
		s := sessionstate.Resolve(c.row, gateNow)
		fresh, can, dlg := Vouch(c.row, s, c.fresh)
		if fresh != c.fresh || can != c.canSubmit || dlg != c.dialog {
			t.Errorf("%s: Vouch = (%v, %v, %v), want (%v, %v, %v)", c.name, fresh, can, dlg, c.fresh, c.canSubmit, c.dialog)
		}
	}
}

// Load reads the row, stamps the live run's start and resolves its state; a
// row that is gone is sql.ErrNoRows.
func TestLoad_StampsTheRunAndResolves(t *testing.T) {
	d, err := db.Open(filepath.Join(t.TempDir(), "w.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = d.Close() })
	wb, err := d.CreateWorkbench("acme", t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	at := db.AgentStateStamp(runStart.Add(time.Minute))
	res, err := d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id, agent_state, agent_state_at)
		VALUES (?, 'claude', 'claude', '/tmp/acme', 'c-1', 'working', ?)`, wb, at)
	if err != nil {
		t.Fatal(err)
	}
	sid, _ := res.LastInsertId()
	ctx := t.Context()

	s, r, err := Load(ctx, d, sid, runStart, gateNow)
	if err != nil {
		t.Fatal(err)
	}
	if r.RunStartedAt != db.AgentStateStamp(runStart) || s != sessionstate.StateWorking {
		t.Fatalf("Load = %q, run %q; want working in the run", s, r.RunStartedAt)
	}
	if s, _, err := Load(ctx, d, sid, time.Time{}, gateNow); err != nil || s != sessionstate.StateNotStarted {
		t.Fatalf("Load without a run = %q, %v; want not_started", s, err)
	}
	if _, _, err := Load(ctx, d, sid+100, runStart, gateNow); !errors.Is(err, sql.ErrNoRows) {
		t.Fatalf("Load missing = %v, want sql.ErrNoRows", err)
	}
}
