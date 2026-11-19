package inboxfeed

import (
	"testing"
	"time"

	"watchtower/internal/automations/builtin"
	"watchtower/internal/db"
	"watchtower/internal/tower/api"
)

// The STRIP-03 row guards of the reminder's Needs approval fire
// (docs/inventory/reaction-commands.md, Inbox builder B Task 13), moved from
// the Desktop's InboxRowActionsTests when the Swift reminder writer and its
// `inbox approvals changed` call were deleted (#1170 Task 12): the Mac's
// reminder Done is one `inbox.act`, and Go fires the approval hook after the
// write in the same call.

var fireStart = time.Date(2026, 11, 16, 8, 0, 0, 0, time.UTC)

// needsApproval is the runnable Needs approval built-in, whose run the fire queues.
func needsApproval(t *testing.T, d *db.DB) int64 {
	t.Helper()
	id, err := d.UpsertBuiltinAutomation(db.Automation{
		BuiltinID: builtin.NeedsApprovalID, Slug: builtin.NeedsApprovalID, Name: "Needs approval",
		TriggerKind: "event", TriggerSpec: `{"type":"approval"}`,
		PermissionsJSON: `["builtin:approvals.list"]`, OutputsJSON: `["inbox"]`,
		RecipeText: "---\nname: Needs approval\n---\n", ContentHash: "c-na", ApprovalHash: "h-na",
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := d.ConfirmShippedBuiltin(id, "c-na", "h-na", fireStart); err != nil {
		t.Fatal(err)
	}
	if err := d.SetBuiltinEnabled(builtin.NeedsApprovalID, true, fireStart); err != nil {
		t.Fatal(err)
	}
	return id
}

func reminderDone(t *testing.T, d *db.DB, deps ActDeps) api.Response {
	t.Helper()
	return callAct(t, actTower(d, actNow, deps),
		actParams(t, "r1", api.ActRef, api.ActParams{RefKind: api.RefReminder, RefID: 1, RefVerb: api.RefDone}), socket)
}

// TestStrip03_ReminderFireRunsOnceAfterSuccess: a landed reminder Done
// queues one Needs approval run for that reminder and wakes the executor
// once.
func TestStrip03_ReminderFireRunsOnceAfterSuccess(t *testing.T) {
	d := seeded(t, reminderSeed())
	id := needsApproval(t, d)
	wakes := 0
	actResult(t, reminderDone(t, d, ActDeps{Wake: func() { wakes++ }}))

	runs, err := d.ListAutomationRuns(id, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(runs) != 1 || runs[0].Status != db.RunQueued || runs[0].Trigger != db.TriggerEvent {
		t.Fatalf("runs %+v, want one queued event run", runs)
	}
	if wakes != 1 {
		t.Errorf("%d wakes, want 1", wakes)
	}
}

// TestStrip03_ReminderFireFailureIgnored: a fire that fails is only
// logged — the Done still lands and answers ok.
func TestStrip03_ReminderFireFailureIgnored(t *testing.T) {
	d := seeded(t, append(reminderSeed(),
		"CREATE TRIGGER refuse_runs BEFORE INSERT ON automation_runs BEGIN SELECT RAISE(ABORT, 'disk said no'); END"))
	needsApproval(t, d)

	if res := actResult(t, reminderDone(t, d, ActDeps{})); res.Already || res.Error != "" {
		t.Errorf("Done answered %+v, want a plain ok", res)
	}
	if r := row(t, d, "reminders", 1); r["status"] != "done" {
		t.Errorf("reminder %v, want done", r)
	}
	if n := count(t, d, `SELECT COUNT(*) FROM automation_runs`); n != 0 {
		t.Errorf("%d runs, want none", n)
	}
}
