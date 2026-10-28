package ai

import (
	"context"
	"time"

	"watchtower/internal/llmusage"
)

// recordClaude records one claude CLI call in the LLM usage ledger: the
// result's usage (cache split and reported cost included) when u carries
// any, else the length/4 estimate of prompt and out. err marks the call
// failed. It never changes what the caller returns.
func recordClaude(ctx context.Context, requestedModel string, u *resultUsage, start time.Time,
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
	if u != nil && u.Usage.InputTokens+u.Usage.OutputTokens+u.Usage.CacheReadInputTokens+
		u.Usage.CacheCreationInputTokens > 0 {
		t := u.Usage
		c.Input, c.CacheRead, c.Output = int64(t.InputTokens), int64(t.CacheReadInputTokens), int64(t.OutputTokens)
		c.CacheWrite5m, c.CacheWrite1h = llmusage.SplitCacheWrites(int64(t.CacheCreationInputTokens),
			int64(t.CacheCreation.FiveMin), int64(t.CacheCreation.OneHour))
	} else {
		c.Estimated = true
		c.Input, c.Output = llmusage.EstimateTokens(prompt), llmusage.EstimateTokens(out)
	}
	llmusage.Record(ctx, c)
}
