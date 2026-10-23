package builtin

import (
	"context"
	"testing"

	"watchtower/internal/automations"
)

func (f *fixture) captureBackends() automations.Backends {
	return automations.Backends{DB: f.d, Clock: f.clock, DefaultPrompt: DefaultPromptFunc}
}

func TestCapturePrompts_ShippedAndOwnerCopy(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	e := mustEntry(t)
	brief, _ := e.DefaultPrompt("brief", "")
	plan, _ := e.DefaultPrompt("plan", "")

	got, err := CapturePrompts(context.Background(), f.captureBackends(), f.row(t))
	if err != nil {
		t.Fatalf("CapturePrompts(shipped): %v", err)
	}
	if len(got) != 2 || got["brief.compose"] != brief || got["plan.compose"] != plan {
		t.Errorf("shipped prompts = %v; want the shipped brief and plan", got)
	}

	f.writeCopy(t, editedCopy(t, e, "the owner's brief"))
	f.sync(t)
	row := f.row(t)
	if err := f.d.ConfirmAutomation(row.ID, row.ApprovalHash, f.clock.Now()); err != nil {
		t.Fatal(err)
	}
	got, err = CapturePrompts(context.Background(), f.captureBackends(), f.row(t))
	if err != nil {
		t.Fatalf("CapturePrompts(owner copy): %v", err)
	}
	if got["brief.compose"] != "the owner's brief" || got["plan.compose"] != plan {
		t.Errorf("owner copy prompts = %v; want the copy's brief and the shipped plan", got)
	}
	if n := len(f.brief.snapshot()) + len(f.plan.snapshot()); n != 0 {
		t.Errorf("%d primitive calls; a capture calls none", n)
	}
	if n := len(f.runs(t)); n != 0 {
		t.Errorf("%d runs; a capture writes none", n)
	}
}

func TestCapturePrompts_RefusesUnconfirmed(t *testing.T) {
	f := newFixture(t)
	f.writeCopy(t, editedCopy(t, mustEntry(t), "the owner's brief"))
	f.sync(t)
	if f.row(t).Confirmed() {
		t.Fatal("the owner copy is confirmed without the owner")
	}
	got, err := CapturePrompts(context.Background(), f.captureBackends(), f.row(t))
	if !isNotRunnable(err) || got != nil {
		t.Errorf("unconfirmed: %v, %v; want ErrNotRunnable and no prompts", got, err)
	}
	if len(f.asked.all()) != 0 {
		t.Error("an unconfirmed recipe was dry-run")
	}
}
