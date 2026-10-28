package digest

import (
	"context"
	"time"

	"watchtower/internal/llmusage"
)

// recordClaude records one claude CLI call in the LLM usage ledger: the
// result envelope's usage (cache split and reported cost included) when
// resp carries any, else the length/4 estimate of prompt and out. err marks
// the call failed. It never changes what the caller returns.
func recordClaude(ctx context.Context, requestedModel string, resp *cliResponse, start time.Time,
	err error, prompt, out string) {
	c := llmusage.Call{
		Provider:   "claude",
		Model:      requestedModel,
		DurationMS: time.Since(start).Milliseconds(),
		OK:         err == nil,
	}
	if resp != nil {
		c.Model = llmusage.ModelFromUsage(resp.ModelUsage, requestedModel)
		if resp.CostUSD > 0 {
			cost := resp.CostUSD
			c.ReportedCostUSD = &cost
		}
	}
	if resp != nil && resp.Usage.InputTokens+resp.Usage.OutputTokens+resp.Usage.CacheReadInputTokens+
		resp.Usage.CacheCreationInputTokens > 0 {
		t := resp.Usage
		c.Input, c.CacheRead, c.Output = int64(t.InputTokens), int64(t.CacheReadInputTokens), int64(t.OutputTokens)
		c.CacheWrite5m, c.CacheWrite1h = llmusage.SplitCacheWrites(int64(t.CacheCreationInputTokens),
			int64(t.CacheCreation.FiveMin), int64(t.CacheCreation.OneHour))
	} else {
		c.Estimated = true
		c.Input, c.Output = llmusage.EstimateTokens(prompt), llmusage.EstimateTokens(out)
	}
	llmusage.Record(ctx, c)
}

// resultOf is resp's result text, "" without an envelope.
func resultOf(resp *cliResponse) string {
	if resp == nil {
		return ""
	}
	return resp.Result
}
