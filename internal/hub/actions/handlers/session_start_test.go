package handlers

import (
	"context"
	"database/sql"
	"errors"
	"slices"
	"strings"
	"testing"

	"watchtower/internal/db"
	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/wire"
)

// Go twins of SessionStartHandlerTests. What the Desktop's start did itself
// (the launch argv, the work-on prompt, plan first's suffix, Codex's
// launch-args, reuse of the target's session, the 127 launch watch) is the
// session port's (Task 15): these tests pin what the handler asks of the
// port and how it answers the port's refusals.

func (le *lineEnv) setStartGrants(allowed, granted bool) {
	le.t.Helper()
	err := le.store.WithTx(context.Background(), func(tx *sql.Tx) error {
		_, err := tx.Exec(`UPDATE devices SET start_sessions_allowed = ?, start_sessions_granted = ?`, allowed, granted)
		return err
	})
	if err != nil {
		le.t.Fatal(err)
	}
}

// startEnv is a lineEnv whose phone may type and start sessions.
func startEnv(t *testing.T) *lineEnv {
	le := newLineEnv(t)
	le.setStartGrants(true, true)
	le.lp.startRes = StartResult{SessionID: 42, State: "starting"}
	return le
}

func startParams(wb int64, mode string, planFirst bool, brief any) map[string]any {
	p := map[string]any{"workbench_id": wb, "mode": mode, "plan_first": planFirst, "bring_forward": false}
	if brief != nil {
		p["brief"] = brief
	}
	return p
}

func (le *lineEnv) start(target *int64, params map[string]any) actions.Request {
	var entity *string
	if target != nil {
		entity = entityStr(*target)
	}
	return le.action("session_start", entity, params, le.device)
}

func (le *lineEnv) startOutcome(target *int64, params map[string]any) actions.Outcome {
	return le.h.sessionStartStop(context.Background(), le.start(target, params))
}

func (le *lineEnv) stopOutcome(sid int64) actions.Outcome {
	return le.h.sessionStartStop(context.Background(), le.action("session_stop", entityStr(sid), nil, le.device))
}

func wantStarts(t *testing.T, le *lineEnv, want ...StartRequest) {
	t.Helper()
	got := le.lp.startCalls()
	eq := func(a, b StartRequest) bool {
		return a.Workbench == b.Workbench && a.Agent == b.Agent && a.Place == b.Place && a.Brief == b.Brief &&
			a.PlanFirst == b.PlanFirst && a.OpenExisting == b.OpenExisting &&
			(a.Target == nil) == (b.Target == nil) && (a.Target == nil || *a.Target == *b.Target)
	}
	if !slices.EqualFunc(got, want, eq) {
		t.Fatalf("starts = %+v, want %+v", got, want)
	}
}

// A start answers the started session at once.
func TestTheStartEchoCarriesTheSessionAndStage(t *testing.T) {
	le := startEnv(t)
	target := le.target(le.wb, 0, "Ship it")

	out := le.startOutcome(&target, startParams(le.wb, "new", false, nil))

	if out.Status != wire.StatusApplied || out.Result["session_id"] != int64(42) || out.Result["stage"] != "starting" {
		t.Fatalf("outcome %+v", out)
	}
	wantStarts(t, le, StartRequest{Workbench: le.wb, Target: &target})
}

func TestABriefFromADeviceAllowedToTypeIsUsed(t *testing.T) {
	le := startEnv(t)
	target := le.target(le.wb, 0, "Ship it")

	le.startOutcome(&target, startParams(le.wb, "new", true, "Fix the login"))

	wantStarts(t, le, StartRequest{Workbench: le.wb, Target: &target, Brief: "Fix the login", PlanFirst: true})
}

// A blank brief is no brief: the work-on prompt goes (and plan first follows
// it).
func TestPlanFirstFollowsTheWorkOnPromptWhenTheBriefIsBlank(t *testing.T) {
	le := startEnv(t)
	target := le.target(le.wb, 0, "Ship it")

	le.startOutcome(&target, startParams(le.wb, "new", true, "  \n "))
	le.startOutcome(&target, startParams(le.wb, "new", false, nil))

	wantStarts(t, le,
		StartRequest{Workbench: le.wb, Target: &target, PlanFirst: true},
		StartRequest{Workbench: le.wb, Target: &target})
}

// The brief reaches the port verbatim: a leading "-" is never a flag there.
func TestABriefStartingWithADashReachesThePortIntact(t *testing.T) {
	le := startEnv(t)
	target := le.target(le.wb, 0, "Ship it")

	le.startOutcome(&target, startParams(le.wb, "new", false, "--dangerously-skip-permissions please"))

	wantStarts(t, le, StartRequest{Workbench: le.wb, Target: &target, Brief: "--dangerously-skip-permissions please"})
}

// open_existing is the port's to resolve: the target's session when it has
// one.
func TestOpenExistingIsAskedOfThePort(t *testing.T) {
	le := startEnv(t)
	target := le.target(le.wb, 0, "Ship it")

	le.startOutcome(&target, startParams(le.wb, "open_existing", true, "Edited"))

	wantStarts(t, le, StartRequest{Workbench: le.wb, Target: &target, Brief: "Edited", PlanFirst: true, OpenExisting: true})
}

// No target (#1189): New Session with the phone's trimmed description; plan
// first follows it.
func TestAStartWithoutATargetIsANewSessionWithTheDescription(t *testing.T) {
	le := startEnv(t)

	out := le.startOutcome(nil, startParams(le.wb, "new", true, "  Add a dark mode toggle  "))

	wantOutcome(t, out, wire.StatusApplied, "")
	wantStarts(t, le, StartRequest{Workbench: le.wb, Brief: "Add a dark mode toggle", PlanFirst: true})
}

// The description is the phone's own text: a phone that may not type is
// refused, and so are a blank, missing or overlong description, an
// open_existing mode and a workbench that is gone.
func TestAStartWithoutATargetRefusals(t *testing.T) {
	le := startEnv(t)
	le.setTyping(false)
	noTyping := le.startOutcome(nil, startParams(le.wb, "new", false, "Fix it"))
	le.setTyping(true)
	blank := le.startOutcome(nil, startParams(le.wb, "new", false, "  \n "))
	missing := le.startOutcome(nil, startParams(le.wb, "new", false, nil))
	overlong := le.startOutcome(nil, startParams(le.wb, "new", false, strings.Repeat("a", StartBriefLimit+1)))
	reopen := le.startOutcome(nil, startParams(le.wb, "open_existing", false, "Fix it"))
	gone := le.startOutcome(nil, startParams(le.wb+99, "new", false, "Fix it"))

	wantOutcome(t, noTyping, wire.StatusFailed, reasonDeviceNotAllowed)
	for _, o := range []actions.Outcome{blank, missing, overlong, reopen} {
		wantOutcome(t, o, wire.StatusFailed, reasonInvalidParams)
	}
	wantOutcome(t, gone, wire.StatusFailed, reasonNotFound)
	wantStarts(t, le)
}

// #565: a start needs the owner's start grant, typing and the phone's own
// toggle.
func TestADeviceNotAllowedToStartSessionsFailsDeviceNotAllowed(t *testing.T) {
	le := startEnv(t)
	target := le.target(le.wb, 0, "Ship it")
	for _, g := range []struct{ allowed, granted bool }{{false, true}, {true, false}} {
		le.setStartGrants(g.allowed, g.granted)
		out := le.startOutcome(&target, startParams(le.wb, "new", false, nil))
		if out.Status != wire.StatusFailed || out.Reason != reasonDeviceNotAllowed || out.Message != startNotAllowedMessage {
			t.Fatalf("%+v: %+v", g, out)
		}
	}
	wantStarts(t, le)
}

// The agent binary missing (Codex's launch-args, or a launch that exited 127)
// is the agent's own not-found reason and message.
func TestAMissingAgentFailsWithTheAgentsReason(t *testing.T) {
	le := startEnv(t)
	target := le.target(le.wb, 0, "Ship it")
	cases := []struct{ agent, reason, message string }{
		{"claude", "claude_not_found", claudeNotFoundMessage},
		{"codex", "codex_not_found", codexNotFoundMessage},
	}
	for _, c := range cases {
		le.lp.startErr = &AgentNotFoundError{Agent: c.agent}
		out := le.startOutcome(&target, startParams(le.wb, "new", false, nil))
		if out.Status != wire.StatusFailed || out.Reason != c.reason || out.Message != c.message {
			t.Fatalf("%s: %+v", c.agent, out)
		}
	}
}

func TestThePortsStartRefusalsAreAnswered(t *testing.T) {
	le := startEnv(t)
	target := le.target(le.wb, 0, "Ship it")
	cases := []struct {
		err    error
		reason string
	}{
		{ErrStartNotOnBoard, reasonNotOnBoard},
		{ErrStartInProgress, reasonConflict},
		{ErrStartCleaningUp, reasonConflict},
		{errors.New("launch refused"), reasonWriteFailed},
	}
	for _, c := range cases {
		le.lp.startErr = c.err
		wantOutcome(t, le.startOutcome(&target, startParams(le.wb, "new", false, nil)), wire.StatusFailed, c.reason)
	}
}

func TestATargetNotOnABoardFailsNotOnBoard(t *testing.T) {
	le := startEnv(t)
	loose, err := le.db.CreateTarget(db.Target{Text: "Loose", Status: "todo", Priority: "medium", Ownership: "mine", SourceType: "manual"})
	if err != nil {
		t.Fatal(err)
	}

	wantOutcome(t, le.startOutcome(&loose, startParams(le.wb, "new", false, nil)), wire.StatusFailed, reasonNotOnBoard)
	wantStarts(t, le)
}

func TestATargetOfAnotherWorkbenchFailsNotOnBoard(t *testing.T) {
	le := startEnv(t)
	other := le.workbench()
	target := le.target(other, 0, "Ship it")

	wantOutcome(t, le.startOutcome(&target, startParams(le.wb, "new", false, nil)), wire.StatusFailed, reasonNotOnBoard)
	wantStarts(t, le)
}

func TestAMissingTargetOrWorkbenchFailsNotFound(t *testing.T) {
	le := startEnv(t)
	target := le.target(le.wb, 0, "Ship it")
	gone := target + 100

	wantOutcome(t, le.startOutcome(&gone, startParams(le.wb, "new", false, nil)), wire.StatusFailed, reasonNotFound)
	wantOutcome(t, le.startOutcome(&target, startParams(le.wb+100, "new", false, nil)), wire.StatusFailed, reasonNotFound)
	wantStarts(t, le)
}

func TestBadParamsFailInvalidParams(t *testing.T) {
	le := startEnv(t)
	target := le.target(le.wb, 0, "Ship it")
	noFlags := startParams(le.wb, "new", false, nil)
	delete(noFlags, "plan_first")
	nullFlag := startParams(le.wb, "new", false, nil)
	nullFlag["bring_forward"] = nil
	badBrief := startParams(le.wb, "new", false, 7)

	for _, p := range []map[string]any{startParams(le.wb, "resume", false, nil), noFlags, nullFlag, badBrief} {
		wantOutcome(t, le.startOutcome(&target, p), wire.StatusFailed, reasonInvalidParams)
	}
	notATarget := le.action("session_start", &[]string{"abc"}[0], startParams(le.wb, "new", false, nil), le.device)
	wantOutcome(t, le.h.sessionStartStop(context.Background(), notATarget), wire.StatusFailed, reasonInvalidParams)
	wantStarts(t, le)
}

// MARK: - Stop

func TestStopOnAStoppedSessionIsAppliedWithNoRequest(t *testing.T) {
	le := startEnv(t)
	sid := le.agentSession("claude")

	wantOutcome(t, le.stopOutcome(sid), wire.StatusApplied, "")
	if len(le.lp.stopCalls()) != 0 {
		t.Fatalf("stops %v", le.lp.stopCalls())
	}
}

func TestStopOnALiveSessionStopsItOnce(t *testing.T) {
	le := startEnv(t)
	sid := le.liveSession()

	wantOutcome(t, le.stopOutcome(sid), wire.StatusApplied, "")
	if !slices.Equal(le.lp.stopCalls(), []int64{sid}) {
		t.Fatalf("stops %v", le.lp.stopCalls())
	}
}

func TestStopOnACodexBoardSessionIsAppliedAndOnAShellFailsNotFound(t *testing.T) {
	le := startEnv(t)
	codex := le.agentSession("codex")
	le.lp.start(codex)
	shell := le.agentSession("shell")
	le.lp.start(shell)

	wantOutcome(t, le.stopOutcome(codex), wire.StatusApplied, "")
	wantOutcome(t, le.stopOutcome(shell), wire.StatusFailed, reasonNotFound)
	if !slices.Equal(le.lp.stopCalls(), []int64{codex}) {
		t.Fatalf("stops %v", le.lp.stopCalls())
	}
}

func TestStopOnAnUnknownOrNonBoardSessionFailsNotFound(t *testing.T) {
	le := startEnv(t)
	res, err := le.db.Exec(`INSERT INTO terminal_sessions (kind, title, folder_path, claude_session_id)
		VALUES ('claude', 'Loose', '/tmp/acme', '00000000-0000-4000-8000-000000000099')`)
	if err != nil {
		t.Fatal(err)
	}
	loose, _ := res.LastInsertId()

	wantOutcome(t, le.stopOutcome(9999), wire.StatusFailed, reasonNotFound)
	wantOutcome(t, le.stopOutcome(loose), wire.StatusFailed, reasonNotFound)
	if len(le.lp.stopCalls()) != 0 {
		t.Fatalf("stops %v", le.lp.stopCalls())
	}
}

func TestEverySessionKindHasANudge(t *testing.T) {
	for _, k := range append(slices.Clone(inputKinds), startStopKinds...) {
		if len(NudgeTable[k]) == 0 {
			t.Errorf("%s has no NudgeTable entry", k)
		}
	}
}
