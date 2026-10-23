package builtin

import (
	"context"
	"errors"
	"testing"

	"watchtower/internal/automations"
	"watchtower/internal/db"
	"watchtower/internal/reactioncmd"
)

type fakeDispatcher struct {
	got     []reactioncmd.Dispatch
	prompts []string
	out     reactioncmd.Outcome
}

func (f *fakeDispatcher) DispatchWith(_ context.Context, d reactioncmd.Dispatch, prompt string) reactioncmd.Outcome {
	f.got = append(f.got, d)
	f.prompts = append(f.prompts, prompt)
	return f.out
}

func composeCall(runID int64) automations.PrimitiveCall {
	return automations.PrimitiveCall{Name: "reaction.compose", BuiltinID: "reactions", Prompt: "P-compose",
		Trigger: automations.TriggerInfo{Kind: db.TriggerSync, RunID: runID}}
}

func isValidation(err error) bool {
	var se *automations.SDKError
	return errors.As(err, &se) && se.Name == automations.ErrNameValidation
}

func TestReactions_ComposeUsesPendingDispatch(t *testing.T) {
	p := &fakeDispatcher{out: reactioncmd.Outcome{Status: "dispatched", ActionID: 42, Step: reactioncmd.StepFinalize}}
	s := NewReactionSlot()
	compose := ReactionPrimitives(p, s)["reaction.compose"]
	s.Begin(7, reactioncmd.Dispatch{ChannelID: "1:C1", MessageTS: "1.1", Emoji: "white_check_mark"})
	s.Begin(8, reactioncmd.Dispatch{ChannelID: "1:C2", MessageTS: "2.2", Emoji: "bulb"})

	res, err := compose(context.Background(), composeCall(8))
	if err != nil {
		t.Fatal(err)
	}
	if len(p.got) != 1 || p.got[0].MessageTS != "2.2" || p.prompts[0] != "P-compose" {
		t.Fatalf("dispatched %+v with %q; want run 8's command with the recipe's prompt", p.got, p.prompts)
	}
	if res.Status != "done" || res.Fields["outcome"] != "dispatched" || res.Fields["action_id"] != int64(42) || res.Usage != (automations.PrimitiveUsage{}) {
		t.Errorf("result = %+v", res)
	}
	if out, ok := s.End(8); !ok || out != p.out {
		t.Errorf("End(8) = %+v, %v; want the stored outcome", out, ok)
	}
	if _, ok := s.End(8); ok {
		t.Error("End twice returned the outcome again")
	}

	// A run with no pending command is a ValidationError and dispatches nothing.
	if _, err := compose(context.Background(), composeCall(99)); !isValidation(err) {
		t.Errorf("no pending dispatch: %v, want a ValidationError", err)
	}

	// A failed outcome is stored for the pass and fails the call.
	p.out = reactioncmd.Outcome{Status: "failed", Detail: "compose failed", Step: reactioncmd.StepFinalize}
	if _, err := compose(context.Background(), composeCall(7)); err == nil || isValidation(err) {
		t.Errorf("failed outcome: %v, want a primitive error", err)
	}
	if out, ok := s.End(7); !ok || out.Status != "failed" {
		t.Errorf("End(7) = %+v, %v; want the failed outcome", out, ok)
	}
}

func TestReactions_SecondComposeInOneRunRefused(t *testing.T) {
	p := &fakeDispatcher{out: reactioncmd.Outcome{Status: "dispatched", ActionID: 1, Step: reactioncmd.StepFinalize}}
	s := NewReactionSlot()
	compose := ReactionPrimitives(p, s)["reaction.compose"]
	s.Begin(3, reactioncmd.Dispatch{MessageTS: "1.1"})
	if _, err := compose(context.Background(), composeCall(3)); err != nil {
		t.Fatal(err)
	}
	if _, err := compose(context.Background(), composeCall(3)); !isValidation(err) {
		t.Fatalf("second compose: %v, want a ValidationError", err)
	}
	if len(p.got) != 1 {
		t.Errorf("dispatched %d times, want once", len(p.got))
	}
	if out, ok := s.End(3); !ok || out.ActionID != 1 {
		t.Errorf("End = %+v, %v; the refused call must keep the first outcome", out, ok)
	}
}

func TestReactions_EndWithoutComposeReportsFalse(t *testing.T) {
	s := NewReactionSlot()
	s.Begin(5, reactioncmd.Dispatch{MessageTS: "1.1"})
	if _, ok := s.End(5); ok {
		t.Error("End of a run that never composed reported an outcome")
	}
	if _, ok := s.End(6); ok {
		t.Error("End of a run never begun reported an outcome")
	}
	// After End the run's command is gone: a late compose is refused.
	compose := ReactionPrimitives(&fakeDispatcher{}, s)["reaction.compose"]
	if _, err := compose(context.Background(), composeCall(5)); !isValidation(err) {
		t.Errorf("compose after End: %v, want a ValidationError", err)
	}
}
