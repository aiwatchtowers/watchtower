package builtin

import (
	"context"
	"errors"
	"testing"

	"watchtower/internal/automations"
	"watchtower/internal/db"
	"watchtower/internal/ideas"
)

type fakeIdeas struct {
	opts     []ideas.RunOptions
	proposed int
	in, out  int
	// perRun is what one run adds to the accumulated usage.
	perIn, perOut int
}

func (f *fakeIdeas) RunWith(_ context.Context, o ideas.RunOptions) (int, error) {
	f.opts = append(f.opts, o)
	f.in += f.perIn
	f.out += f.perOut
	return f.proposed, nil
}
func (f *fakeIdeas) AccumulatedUsage() (int, int, float64, int) { return f.in, f.out, 0, f.in + f.out }
func (f *fakeIdeas) LastPromptNote() string                     { return "" }

func ideasCall() automations.PrimitiveCall {
	return automations.PrimitiveCall{Name: "ideas.consolidate", BuiltinID: "idea-finder", Prompt: "P-consolidate",
		Trigger: automations.TriggerInfo{Kind: db.TriggerSync}}
}

func TestIdeaFinder_LockHeldIsSkipped(t *testing.T) {
	ws := t.TempDir()
	release, err := ideas.AcquireBackfillLock(ws, "CLI backfill")
	if err != nil {
		t.Fatal(err)
	}
	p := &fakeIdeas{}
	tracked := 0
	prims := IdeaFinderPrimitives(p, IdeaHooks{
		Lock: func() (func(), error) { return ideas.AcquireBackfillLock(ws, "daemon") },
		Track: func(run func() (int, error)) (int, error) {
			tracked++
			return run()
		},
	})
	res, err := prims["ideas.consolidate"](context.Background(), ideasCall())
	if err != nil || res.Status != "skipped" || res.Note != "another ideas run holds the lock" {
		t.Fatalf("held lock: %+v, %v; want skipped with the note", res, err)
	}
	if len(p.opts) != 0 || tracked != 0 {
		t.Fatalf("a skipped consolidate ran: %d runs, %d tracked", len(p.opts), tracked)
	}

	// Any other lock failure fails the call.
	boom := errors.New("unwritable workspace")
	prims = IdeaFinderPrimitives(p, IdeaHooks{Lock: func() (func(), error) { return nil, boom }})
	if _, err := prims["ideas.consolidate"](context.Background(), ideasCall()); !errors.Is(err, boom) {
		release()
		t.Fatalf("lock error = %v, want %v", err, boom)
	}

	// Once free, the run takes the lock, passes the prompt and releases it.
	release()
	prims = IdeaFinderPrimitives(p, IdeaHooks{Lock: func() (func(), error) { return ideas.AcquireBackfillLock(ws, "daemon") }})
	p.proposed = 4
	res, err = prims["ideas.consolidate"](context.Background(), ideasCall())
	if err != nil || res.Status != "done" || res.Fields["proposed"] != 4 || len(p.opts) != 1 || p.opts[0].Prompt != "P-consolidate" {
		t.Fatalf("free lock: %+v, %v, runs %+v", res, err, p.opts)
	}
	if ideas.BackfillLockFresh(ws) {
		t.Error("the lock is still held after the run")
	}
}

func TestIdeaFinder_UsageIsTheDelta(t *testing.T) {
	p := &fakeIdeas{in: 1000, out: 200, perIn: 30, perOut: 5}
	prims := IdeaFinderPrimitives(p, IdeaHooks{})
	for range 2 {
		res, err := prims["ideas.consolidate"](context.Background(), ideasCall())
		if err != nil {
			t.Fatal(err)
		}
		if res.Usage.InputTokens != 30 || res.Usage.OutputTokens != 5 {
			t.Fatalf("usage = %+v, want the call's 30/5, not the accumulated total", res.Usage)
		}
	}
}
