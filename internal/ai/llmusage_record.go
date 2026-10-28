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
	if u != nil {
		c.Model = llmusage.ModelFromUsage(u.ModelUsage, requestedModel)
		if u.CostUSD > 0 {
			cost := u.CostUSD
			c.ReportedCostUSD = &cost
		}
	}
	switch {
	case u != nil:
		t := u.Usage
		c.Input, c.CacheRead, c.Output = int64(t.InputTokens), int64(t.CacheReadInputTokens), int64(t.OutputTokens)
		c.CacheWrite5m, c.CacheWrite1h = llmusage.SplitCacheWrites(int64(t.CacheCreationInputTokens),
			int64(t.CacheCreation.FiveMin), int64(t.CacheCreation.OneHour))
	case ran:
		c.Estimated = true
		c.Input, c.Output = llmusage.EstimateTokens(prompt), llmusage.EstimateTokens(out)
	default:
		c.OK = false // never started: nothing was sent
	}
	llmusage.Record(ctx, c)
}
