package builtin

import (
	"context"
	"errors"
	"testing"

	"watchtower/internal/automations"
	"watchtower/internal/db"
	"watchtower/internal/digest"
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
	mustBegin(t, s, 7, reactioncmd.Dispatch{ChannelID: "1:C1", MessageTS: "1.1", Emoji: "white_check_mark"})
	mustBegin(t, s, 8, reactioncmd.Dispatch{ChannelID: "1:C2", MessageTS: "2.2", Emoji: "bulb"})

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
	mustBegin(t, s, 3, reactioncmd.Dispatch{MessageTS: "1.1"})
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
	mustBegin(t, s, 5, reactioncmd.Dispatch{MessageTS: "1.1"})
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

func mustBegin(t *testing.T, s *ReactionSlot, runID int64, d reactioncmd.Dispatch) {
	t.Helper()
	if err := s.Begin(runID, d); err != nil {
		t.Fatal(err)
	}
}

// TestReactions_BeginTwiceRefused: a run that already carries a command
// keeps it; the second Begin is refused.
func TestReactions_BeginTwiceRefused(t *testing.T) {
	p := &fakeDispatcher{out: reactioncmd.Outcome{Status: "dispatched", ActionID: 1, Step: reactioncmd.StepFinalize}}
	s := NewReactionSlot()
	mustBegin(t, s, 4, reactioncmd.Dispatch{MessageTS: "first"})
	if err := s.Begin(4, reactioncmd.Dispatch{MessageTS: "second"}); !errors.Is(err, ErrReactionRunBusy) {
		t.Fatalf("second Begin = %v, want ErrReactionRunBusy", err)
	}
	if _, err := ReactionPrimitives(p, s)["reaction.compose"](context.Background(), composeCall(4)); err != nil {
		t.Fatal(err)
	}
	if len(p.got) != 1 || p.got[0].MessageTS != "first" {
		t.Errorf("dispatched %+v, want the first command", p.got)
	}
}

// blockingDispatcher blocks DispatchWith until release is closed.
type blockingDispatcher struct {
	started, release chan struct{}
}

func (b *blockingDispatcher) DispatchWith(context.Context, reactioncmd.Dispatch, string) reactioncmd.Outcome {
	close(b.started)
	<-b.release
	return reactioncmd.Outcome{Status: "dispatched", ActionID: 9, Step: reactioncmd.StepFinalize}
}

// TestReactions_EndDuringComposeIsStranded: a run that ends while its
// compose is still dispatching reports an unknown outcome (strand), never a
// finalize.
func TestReactions_EndDuringComposeIsStranded(t *testing.T) {
	b := &blockingDispatcher{started: make(chan struct{}), release: make(chan struct{})}
	s := NewReactionSlot()
	mustBegin(t, s, 11, reactioncmd.Dispatch{MessageTS: "1.1"})
	done := make(chan error, 1)
	go func() {
		_, err := ReactionPrimitives(b, s)["reaction.compose"](context.Background(), composeCall(11))
		done <- err
	}()
	<-b.started
	out, ok := s.End(11)
	close(b.release)
	if err := <-done; err != nil {
		t.Errorf("compose = %v", err)
	}
	if !ok || out.Step != reactioncmd.StepStrand || out.Detail != "the run ended before reaction.compose returned" {
		t.Errorf("End during compose = %+v, %v; want a strand", out, ok)
	}
	if _, ok := s.End(11); ok {
		t.Error("the late outcome was kept after End")
	}
}

// reaction.compose reports the compose call's usage as its own, dispatched
// or not, so the run row, Costs and the token budget see it.
func TestReactions_ComposeReportsUsage(t *testing.T) {
	usage := digest.Usage{InputTokens: 120, OutputTokens: 30}
	want := automations.PrimitiveUsage{InputTokens: 120, OutputTokens: 30}
	p := &fakeDispatcher{out: reactioncmd.Outcome{Status: "dispatched", ActionID: 1, Step: reactioncmd.StepFinalize, Usage: usage}}
	s := NewReactionSlot()
	compose := ReactionPrimitives(p, s)["reaction.compose"]
	mustBegin(t, s, 1, reactioncmd.Dispatch{ChannelID: "1:C1", MessageTS: "1.1"})
	res, err := compose(context.Background(), composeCall(1))
	if err != nil || res.Usage != want {
		t.Errorf("dispatched: usage = %+v, err = %v; want %+v", res.Usage, err, want)
	}
	p.out = reactioncmd.Outcome{Status: "failed", Detail: "compose: no JSON", Step: reactioncmd.StepFinalize, Usage: usage}
	mustBegin(t, s, 2, reactioncmd.Dispatch{ChannelID: "1:C1", MessageTS: "2.2"})
	res, err = compose(context.Background(), composeCall(2))
	if err == nil || res.Usage != want {
		t.Errorf("failed: usage = %+v, err = %v; want %+v and an error", res.Usage, err, want)
	}
}
