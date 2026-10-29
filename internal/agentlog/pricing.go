// Package agentlog turns coding-agent session transcripts into the
// normalized analytics rows of agent_log_* (spec
// docs/superpowers/specs/2026-10-15-agent-analytics-core-design.md).
package agentlog

import "watchtower/internal/pricing"

// PriceVersion is stamped on every priced row (see pricing.Version).
const PriceVersion = pricing.Version

// Cost prices one API call (see pricing.Cost).
func Cost(model, speed string, in, out, cacheRead, cw5m, cw1h int64) (float64, bool) {
	return pricing.Cost(model, speed, in, out, cacheRead, cw5m, cw1h)
}

// ModelTiers lists the priced models by output price, highest first (see
// pricing.ModelTiers).
func ModelTiers() []string { return pricing.ModelTiers() }
