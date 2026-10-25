package builtin

import (
	"context"

	"watchtower/internal/automations"
	"watchtower/internal/tracks"
)

// TracksRunner is the tracks pipeline as tracks.extract calls it
// (*tracks.Pipeline).
type TracksRunner interface {
	RunWith(ctx context.Context, o tracks.RunOptions) (int, int, error)
	AccumulatedUsage() (int, int, float64, int)
	LastPromptNote() string
}

// ThreadsHooks is what the Track my threads primitive takes from its caller.
type ThreadsHooks struct {
	// Track wraps the run (daemon: trackedPipelineRun("tracks") with
	// LastFrom/LastTo; CLI: its pipeline_runs row). nil = run directly.
	Track func(run func() (int, int, error)) (int, int, error)
}

// TrackMyThreadsPrimitives returns tracks.extract over p: one tracks run with
// the recipe's prompt, returning {status: "done", created, updated}. The
// tracks pipeline resets its usage at the start of every run, so the value
// read after the call is that call's (the Morning brief rule); a delta
// around the call would be wrong after a reset.
func TrackMyThreadsPrimitives(p TracksRunner, h ThreadsHooks) map[string]automations.PrimitiveFunc {
	return map[string]automations.PrimitiveFunc{
		"tracks.extract": func(ctx context.Context, call automations.PrimitiveCall) (automations.PrimitiveResult, error) {
			if p == nil {
				return automations.PrimitiveResult{}, errNotWired
			}
			run := func() (int, int, error) { return p.RunWith(ctx, tracks.RunOptions{Prompt: call.Prompt}) }
			var created, updated int
			var err error
			if h.Track != nil {
				created, updated, err = h.Track(run)
			} else {
				created, updated, err = run()
			}
			res := automations.PrimitiveResult{Status: "done", Note: p.LastPromptNote(),
				Fields: map[string]any{"created": created, "updated": updated},
				Usage:  usageOf(p.AccumulatedUsage())}
			return res, err
		},
	}
}
