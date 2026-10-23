package builtin

import (
	"context"
	"errors"
	"testing"

	"watchtower/internal/automations"
	"watchtower/internal/db"
	"watchtower/internal/tracks"
)

type fakeTracks struct {
	opts             []tracks.RunOptions
	created, updated int
	err              error
	in, out          int
}

func (f *fakeTracks) RunWith(_ context.Context, o tracks.RunOptions) (int, int, error) {
	f.opts = append(f.opts, o)
	return f.created, f.updated, f.err
}
func (f *fakeTracks) AccumulatedUsage() (int, int, float64, int) { return f.in, f.out, 0, f.in + f.out }
func (f *fakeTracks) LastPromptNote() string                     { return "tracks note" }

func TestTrackMyThreads_PrimitivePassesPromptAndTracks(t *testing.T) {
	p := &fakeTracks{created: 2, updated: 3, in: 40, out: 9}
	tracked := 0
	prims := TrackMyThreadsPrimitives(p, ThreadsHooks{Track: func(run func() (int, int, error)) (int, int, error) {
		tracked++
		return run()
	}})
	c := automations.PrimitiveCall{Name: "tracks.extract", BuiltinID: "track-my-threads", Prompt: "P-extract",
		Trigger: automations.TriggerInfo{Kind: db.TriggerSync}}
	res, err := prims["tracks.extract"](context.Background(), c)
	if err != nil {
		t.Fatal(err)
	}
	if len(p.opts) != 1 || p.opts[0].Prompt != "P-extract" || tracked != 1 {
		t.Fatalf("runs = %+v, tracked %d; want one tracked run with the recipe's prompt", p.opts, tracked)
	}
	if res.Status != "done" || res.Fields["created"] != 2 || res.Fields["updated"] != 3 || res.Note != "tracks note" {
		t.Errorf("result = %+v", res)
	}
	// The pipeline resets its usage per run: the value after the call is the call's.
	if res.Usage.InputTokens != 40 || res.Usage.OutputTokens != 9 {
		t.Errorf("usage = %+v, want 40/9", res.Usage)
	}

	// A failed run still reports its usage and the error; no hooks runs directly.
	p.err = errors.New("boom")
	res, err = TrackMyThreadsPrimitives(p, ThreadsHooks{})["tracks.extract"](context.Background(), c)
	if err == nil || res.Usage.InputTokens != 40 || len(p.opts) != 2 {
		t.Errorf("failed run: %+v, %v", res, err)
	}
	if _, err := TrackMyThreadsPrimitives(nil, ThreadsHooks{})["tracks.extract"](context.Background(), c); !errors.Is(err, errNotWired) {
		t.Errorf("unwired = %v", err)
	}
}
