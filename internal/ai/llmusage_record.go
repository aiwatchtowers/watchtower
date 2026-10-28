package ai

import (
	"context"
	"encoding/json"
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
		c.Model = modelFromUsage(u.ModelUsage, requestedModel)
		if u.CostUSD > 0 {
			cost := u.CostUSD
			c.ReportedCostUSD = &cost
		}
	}
	if u != nil && u.Usage.reported() {
		t := u.Usage
		c.Input, c.CacheRead, c.Output = int64(t.InputTokens), int64(t.CacheReadInputTokens), int64(t.OutputTokens)
		c.CacheWrite5m, c.CacheWrite1h = t.cacheWrites()
	} else {
		c.Estimated = true
		c.Input, c.Output = llmusage.EstimateTokens(prompt), llmusage.EstimateTokens(out)
	}
	llmusage.Record(ctx, c)
}

// reported says whether the result carried any token counts.
func (u cliUsage) reported() bool {
	return u.InputTokens+u.OutputTokens+u.CacheReadInputTokens+u.CacheCreationInputTokens > 0
}

// cacheWrites splits the cache write tokens into the 5-minute and 1-hour
// TTLs; a total the CLI did not split (or split only partly) counts as
// 5-minute writes, the CLI's default TTL.
func (u cliUsage) cacheWrites() (fiveMin, oneHour int64) {
	fiveMin, oneHour = int64(u.CacheCreation.FiveMin), int64(u.CacheCreation.OneHour)
	if rest := int64(u.CacheCreationInputTokens) - fiveMin - oneHour; rest > 0 {
		fiveMin += rest
	}
	return fiveMin, oneHour
}

// modelFromUsage is the model modelUsage names with the most output tokens
// (ties go to the first name in order), else requested — the same rule as
// digest.ModelFromUsage (ai does not depend on digest).
func modelFromUsage(modelUsage map[string]json.RawMessage, requested string) string {
	best, bestOut := "", int64(-1)
	for name, raw := range modelUsage {
		var m struct {
			OutputTokens int64 `json:"outputTokens"`
		}
		if json.Unmarshal(raw, &m) != nil {
			continue
		}
		if m.OutputTokens > bestOut || (m.OutputTokens == bestOut && name < best) {
			best, bestOut = name, m.OutputTokens
		}
	}
	if best == "" {
		return requested
	}
	return best
}
