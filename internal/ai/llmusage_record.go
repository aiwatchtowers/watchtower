package ai

import (
	"context"
	"time"

	"watchtower/internal/llmusage"
)

// recordClaude records one claude CLI call in the LLM usage ledger. A
// parsed result envelope (u) is recorded with its numbers as they are,
// zeros included (cache split and reported cost too). A child that never
// started (ran false: binary not found, a pipe or start error) is a failed
// call with no tokens. Only a child that ran and left no envelope is
// estimated, length/4 of prompt and out. err marks the call failed. It
// never changes what the caller returns.
func recordClaude(ctx context.Context, requestedModel string, u *resultUsage, ran bool, start time.Time,
	err error, prompt, out string) {
	c := llmusage.Call{
		Provider:   "claude",
		Model:      requestedModel,
		DurationMS: time.Since(start).Milliseconds(),
		OK:         err == nil,
	}
	switch {
	case u != nil:
		c.Model = llmusage.ModelFromUsage(u.ModelUsage, requestedModel)
		c.Tokens = u.tokens()
	case ran:
		c.Estimated = true
		c.Input, c.Output = llmusage.EstimateTokens(prompt), llmusage.EstimateTokens(out)
	default:
		c.OK = false // never started: nothing was sent
	}
	llmusage.Record(ctx, c)
}
