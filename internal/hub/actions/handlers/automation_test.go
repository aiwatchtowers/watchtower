package handlers

import (
	"context"
	"fmt"
	"slices"
	"testing"

	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/wire"
)

// Go twins of AutomationRunHandlerTests: the start-sessions grant, a recipe of
// this workbench that can run, and the run queued as `automations run` does.

type recipe struct {
	confirmedHash, parseError string
	disabled, button          bool
}

func (e *env) automation(wb int64, r recipe) int64 {
	e.t.Helper()
	trigger, spec := "manual", `{"manual":true}`
	if r.button {
		trigger, spec = "button", `{"button":{"label":"Release","confirm":true}}`
	}
	scope, project := "workbench", any(wb)
	if wb == 0 {
		scope, project = "personal", nil
	}
	e.seq++
	res, err := e.db.Exec(`INSERT INTO automations (slug, scope, project_id, path, name, trigger_kind, trigger_spec,
		approval_hash, confirmed_hash, parse_error, enabled) VALUES ('release', ?, ?, ?, 'Release', ?, ?, 'h1', ?, ?, ?)`,
		scope, project, fmt.Sprintf("/tmp/acme/automations/release-%d.md", e.seq), trigger, spec,
		r.confirmedHash, r.parseError, !r.disabled)
	if err != nil {
		e.t.Fatal(err)
	}
	aid, _ := res.LastInsertId()
	return aid
}

// automationRun seeds a workbench automation with one run in status.
func (e *env) automationRun(wb int64, status string) int64 {
	e.t.Helper()
	aid := e.automation(wb, recipe{confirmedHash: "h1"})
	res, err := e.db.Exec(`INSERT INTO automation_runs (automation_id, trigger, status) VALUES (?, 'manual', ?)`, aid, status)
	if err != nil {
		e.t.Fatal(err)
	}
	rid, _ := res.LastInsertId()
	return rid
}

func (e *env) runAction(aid, wb int64, confirmed bool) actions.Outcome {
	return e.h.automationRun(context.Background(),
		e.request("automation_run", id(aid), map[string]any{"workbench_id": wb, "confirmed": confirmed}))
}

func (e *env) runs(aid int64) int {
	return e.count(`SELECT COUNT(*) FROM automation_runs WHERE automation_id = ?`, aid)
}

func wantRun(t *testing.T, got actions.Outcome, coalesced bool) int64 {
	t.Helper()
	runID, ok := got.Result["run_id"].(int64)
	if got.Status != wire.StatusApplied || !ok || got.Result["coalesced"] != coalesced {
		t.Fatalf("outcome = %+v, want applied coalesced=%v", got, coalesced)
	}
	return runID
}

func TestARunnableRecipeRunsThroughQuickRun(t *testing.T) {
	e := newEnv(t)
	e.linkDevice(true, true, true)
	wb := e.workbench()
	aid := e.automation(wb, recipe{confirmedHash: "h1"})

	runID := wantRun(t, e.runAction(aid, wb, false), false)

	if tr := e.scalar(`SELECT trigger FROM automation_runs WHERE id = ? AND status = 'queued'`, runID); tr != "manual" {
		t.Fatalf("trigger = %q, want a queued manual run", tr)
	}
	if e.woken != 1 {
		t.Fatalf("woken = %d", e.woken)
	}
	if n := NudgeTable["automation_run"]; len(n) != 1 || n[0] != "workbench" {
		t.Fatalf("nudge = %v, want [workbench]", NudgeTable["automation_run"])
	}
}

// AUTO-06 (amended, ask #692): a confirm: true recipe runs only after Run in
// the phone's confirmation, carried as confirmed.
func TestAConfirmRecipeRunsOnlyWhenThePhoneConfirmedIt(t *testing.T) {
	e := newEnv(t)
	e.linkDevice(true, true, true)
	wb := e.workbench()
	aid := e.automation(wb, recipe{confirmedHash: "h1", button: true})

	unconfirmed := e.runAction(aid, wb, false)
	wantOutcome(t, unconfirmed, wire.StatusFailed, reasonConflict)
	if unconfirmed.Message != "This automation asks before it runs — confirm it on the phone" || e.runs(aid) != 0 {
		t.Fatalf("outcome = %+v runs = %d", unconfirmed, e.runs(aid))
	}

	runID := wantRun(t, e.runAction(aid, wb, true), false)
	if tr := e.scalar(`SELECT trigger FROM automation_runs WHERE id = ?`, runID); tr != "button" {
		t.Fatalf("trigger = %q, want button", tr)
	}
}

func TestAPhoneWithoutTheStartGrantIsRefused(t *testing.T) {
	for _, grant := range [][3]bool{{false, true, true}, {true, false, true}, {true, true, false}} {
		e := newEnv(t)
		e.linkDevice(grant[0], grant[1], grant[2])
		wb := e.workbench()
		aid := e.automation(wb, recipe{confirmedHash: "h1"})

		got := e.runAction(aid, wb, false)

		wantOutcome(t, got, wire.StatusFailed, reasonDeviceNotAllowed)
		if got.Message != automationNotAllowedMessage || e.runs(aid) != 0 {
			t.Fatalf("grant %v: %+v", grant, got)
		}
	}
	// A device that is not linked at all.
	e := newEnv(t)
	wb := e.workbench()
	wantOutcome(t, e.runAction(e.automation(wb, recipe{confirmedHash: "h1"}), wb, false), wire.StatusFailed, reasonDeviceNotAllowed)
}

func TestARecipeOfAnotherWorkbenchOrAPersonalOneIsRefused(t *testing.T) {
	e := newEnv(t)
	e.linkDevice(true, true, true)
	wb := e.workbench()
	aid := e.automation(wb, recipe{confirmedHash: "h1"})
	other := e.workbench()
	personal := e.automation(0, recipe{confirmedHash: "h1"})

	wantOutcome(t, e.runAction(aid, other, false), wire.StatusFailed, reasonNotOnBoard)
	wantOutcome(t, e.runAction(personal, wb, false), wire.StatusFailed, reasonNotOnBoard)
	wantOutcome(t, e.runAction(999, wb, false), wire.StatusFailed, reasonNotFound)
	if e.runs(aid)+e.runs(personal) != 0 {
		t.Fatal("nothing runs")
	}
}

func TestARecipeThatCannotRunIsRefusedWithItsReason(t *testing.T) {
	e := newEnv(t)
	e.linkDevice(true, true, true)
	for _, c := range []struct {
		r   recipe
		msg string
	}{
		{recipe{confirmedHash: ""}, "Confirm this automation on the Mac first"},
		{recipe{confirmedHash: "h1", disabled: true}, "This automation is turned off on the Mac"},
		{recipe{confirmedHash: "h1", parseError: "bad frontmatter"}, "This automation can't be read on the Mac"},
	} {
		wb := e.workbench()
		aid := e.automation(wb, c.r)
		got := e.runAction(aid, wb, false)
		wantOutcome(t, got, wire.StatusFailed, reasonConflict)
		if got.Message != c.msg || e.runs(aid) != 0 {
			t.Fatalf("%+v: %+v", c.r, got)
		}
	}
}

func TestARunningRecipeAnswersWithItsRun(t *testing.T) {
	e := newEnv(t)
	e.linkDevice(true, true, true)
	wb := e.workbench()
	runID := e.automationRun(wb, "running")
	aid := int64(e.count(`SELECT automation_id FROM automation_runs WHERE id = ?`, runID))

	if got := wantRun(t, e.runAction(aid, wb, false), true); got != runID {
		t.Fatalf("run_id = %d, want %d", got, runID)
	}
	if e.runs(aid) != 1 {
		t.Fatal("a second run is not started")
	}
}

func TestARefusedRunIsFailedWithTheWriteError(t *testing.T) {
	e := newEnv(t)
	e.linkDevice(true, true, true)
	wb := e.workbench()
	aid := e.automation(wb, recipe{confirmedHash: "h1"})
	e.exec(`CREATE TRIGGER fail_run BEFORE INSERT ON automation_runs BEGIN SELECT RAISE(ABORT, 'disk full'); END`)

	got := e.runAction(aid, wb, false)

	wantOutcome(t, got, wire.StatusFailed, reasonWriteFailed)
	if e.woken != 0 {
		t.Fatal("nothing queued, nothing to wake")
	}
}

func TestMissingAutomationParamsAreRefused(t *testing.T) {
	e := newEnv(t)
	e.linkDevice(true, true, true)
	wb := e.workbench()
	aid := e.automation(wb, recipe{confirmedHash: "h1"})
	got := e.h.automationRun(context.Background(), e.request("automation_run", id(aid), map[string]any{}))
	wantOutcome(t, got, wire.StatusFailed, reasonInvalidParams)
	if e.runs(aid) != 0 {
		t.Fatal("nothing runs")
	}
}

func TestARunIsNeverReplayed(t *testing.T) {
	if !slices.Contains(actions.NonIdempotentKinds, "automation_run") {
		t.Fatal("automation_run must be claimed begun")
	}
}

// Every kind Register adds has a NudgeTable entry (Register panics on one
// without, so newEnv proves that half) and every table entry is registered
// (spec §9: nudge after every applied action).
func TestNudgeTableCoversEveryRegisteredKind(t *testing.T) {
	e := newEnv(t)
	registered := append([]string{"ask_answer", "automation_run"}, boardKinds...)
	for _, k := range registered {
		if len(NudgeTable[k]) == 0 {
			t.Fatalf("%s has no nudge", k)
		}
		func() {
			defer func() {
				if recover() == nil {
					t.Fatalf("%s is in the table but was not registered", k)
				}
			}()
			e.disp.Register(k, func(context.Context, actions.Request) actions.Outcome { return actions.Outcome{} }, actions.KindOptions{})
		}()
	}
	for k := range NudgeTable {
		if !slices.Contains(registered, k) {
			t.Fatalf("%s is in the table but not registered", k)
		}
	}
}
