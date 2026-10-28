package llmusage

import "encoding/json"

// ModelOutputs reads the output tokens per model from a claude result's
// modelUsage (keyed by the model's full name); unreadable entries are
// skipped.
func ModelOutputs(modelUsage map[string]json.RawMessage) map[string]int64 {
	outs := make(map[string]int64, len(modelUsage))
	for name, raw := range modelUsage {
		var m struct {
			OutputTokens int64 `json:"outputTokens"`
		}
		if json.Unmarshal(raw, &m) == nil {
			outs[name] = m.OutputTokens
		}
	}
	return outs
}

// ModelFromOutputs is the model with the most output tokens (ties go to the
// first name in order), else requested.
func ModelFromOutputs(outs map[string]int64, requested string) string {
	best, bestOut := "", int64(-1)
	for name, out := range outs {
		if out > bestOut || (out == bestOut && name < best) {
			best, bestOut = name, out
		}
	}
	if best == "" {
		return requested
	}
	return best
}

// ModelFromUsage is the model a claude result's modelUsage names with the
// most output tokens, else requested.
func ModelFromUsage(modelUsage map[string]json.RawMessage, requested string) string {
	return ModelFromOutputs(ModelOutputs(modelUsage), requested)
}

// SplitCacheWrites splits a claude result's cache write total into the
// 5-minute and 1-hour TTLs from its cache_creation split; a total the CLI
// did not split (or split only partly) counts as 5-minute writes, the CLI's
// default TTL.
func SplitCacheWrites(total, fiveMin, oneHour int64) (int64, int64) {
	if rest := total - fiveMin - oneHour; rest > 0 {
		fiveMin += rest
	}
	return fiveMin, oneHour
}
