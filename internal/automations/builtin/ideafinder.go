package builtin

import (
	"context"
	"errors"

	"watchtower/internal/automations"
	"watchtower/internal/ideas"
)

// IdeasRunner is the ideas pipeline as ideas.consolidate calls it
// (*ideas.Pipeline).
type IdeasRunner interface {
	RunWith(ctx context.Context, o ideas.RunOptions) (int, error)
	AccumulatedUsage() (int, int, float64, int)
	LastPromptNote() string
}

// IdeaHooks is what the Idea finder primitive takes from its caller.
type IdeaHooks struct {
	// Lock takes the ideas backfill lock (ideas.AcquireBackfillLock(ws,
	// "daemon"|"cli")); nil = no lock.
	Lock func() (release func(), err error)
	// Track wraps the run (daemon: trackedPipelineRun("ideas") and the
	// lastIdeas stamp; CLI: direct). nil = run directly.
	Track func(run func() (int, error)) (int, error)
}

// ideasLockHeldNote is the step note of a consolidate the lock refused.
const ideasLockHeldNote = "another ideas run holds the lock"

// IdeaFinderPrimitives returns ideas.consolidate over p: it takes the lock
// first (one another live holder has is {status: "skipped"}: the daemon's
// gate only probed it; any other lock error fails the call), then runs one consolidation with the recipe's prompt, returning
// {status: "done", proposed}. The ideas pipeline accumulates its usage
// across runs, so the call's usage is the delta around it.
func IdeaFinderPrimitives(p IdeasRunner, h IdeaHooks) map[string]automations.PrimitiveFunc {
	return map[string]automations.PrimitiveFunc{
		"ideas.consolidate": func(ctx context.Context, call automations.PrimitiveCall) (automations.PrimitiveResult, error) {
			if p == nil {
				return automations.PrimitiveResult{}, errNotWired
			}
			if h.Lock != nil {
				release, err := h.Lock()
				if errors.Is(err, ideas.ErrBackfillLockHeld) {
					return automations.PrimitiveResult{Status: "skipped", Note: ideasLockHeldNote}, nil
				}
				if err != nil {
					return automations.PrimitiveResult{}, err
				}
				if release != nil {
					defer release()
				}
			}
			in0, out0, _, _ := p.AccumulatedUsage()
			run := func() (int, error) { return p.RunWith(ctx, ideas.RunOptions{Prompt: call.Prompt}) }
			var proposed int
			var err error
			if h.Track != nil {
				proposed, err = h.Track(run)
			} else {
				proposed, err = run()
			}
			in1, out1, _, _ := p.AccumulatedUsage()
			res := automations.PrimitiveResult{Status: "done", Note: p.LastPromptNote(),
				Fields: map[string]any{"proposed": proposed},
				Usage:  automations.PrimitiveUsage{InputTokens: in1 - in0, OutputTokens: out1 - out0}}
			return res, err
		},
	}
}
