// Package pricing holds the Anthropic price table shared by agent analytics
// (agentlog) and the LLM usage ledger (llmusage), and the OpenAI table agent
// analytics prices Codex sessions with (CodexCost).
package pricing

import (
	"cmp"
	"slices"
)

// Version is stamped on every priced agent-analytics row; bump it with any
// change to prices so the next scan reprices stored rows (no reparse).
// 2: the Codex table (codexPrices).
const Version = 2

type price struct {
	input, output, cacheRead float64 // $ per million tokens
	longOver                 int64   // input tokens (incl. cache) above which the long tier applies; 0 = none
	longInput, longOutput    float64
	fast                     float64 // fast-speed multiplier; 0 = unknown
}

// Anthropic first-party rates, checked against the Claude API model table on
// 2026-10-15. Cache writes: 5m = 1.25x input, 1h = 2x input.
var prices = map[string]price{
	"claude-fable-5-1":  {input: 10, output: 50, cacheRead: 0.25},
	"claude-fable-5":    {input: 10, output: 50, cacheRead: 1.00},
	"claude-opus-5-5":   {input: 4, output: 20, cacheRead: 0.20, fast: 2},
	"claude-opus-5":     {input: 5, output: 25, cacheRead: 0.50, fast: 2},
	"claude-opus-4-8":   {input: 5, output: 25, cacheRead: 0.50},
	"claude-opus-4-7":   {input: 5, output: 25, cacheRead: 0.50},
	"claude-opus-4-6":   {input: 5, output: 25, cacheRead: 0.50},
	"claude-sonnet-5-5": {input: 2, output: 10, cacheRead: 0.20},
	"claude-sonnet-5":   {input: 2, output: 10, cacheRead: 0.20},
	"claude-sonnet-4-6": {input: 3, output: 15, cacheRead: 0.30},
	"claude-haiku-5-5":  {input: 0.10, output: 0.50, cacheRead: 0.01, longOver: 100_000, longInput: 0.50, longOutput: 2.50},
	"claude-haiku-4-5":  {input: 1, output: 5, cacheRead: 0.10},
}

var aliases = map[string]string{
	"claude-haiku-4-5-20251001": "claude-haiku-4-5",
}

// shortNames maps the CLI's model shorthands to the current model ids.
var shortNames = map[string]string{
	"opus":   "claude-opus-5-5",
	"sonnet": "claude-sonnet-5-5",
	"haiku":  "claude-haiku-5-5",
	"fable":  "claude-fable-5-1",
}

// Resolve maps a model shorthand (opus, sonnet, haiku, fable) to the current
// model id; any other name is returned unchanged.
func Resolve(model string) string {
	if id, ok := shortNames[model]; ok {
		return id
	}
	return model
}

// Cost prices one API call. known=false (cost 0) when the model, the speed
// ("", "standard" or "fast"), or the fast multiplier is not known — never guessed.
func Cost(model, speed string, in, out, cacheRead, cw5m, cw1h int64) (float64, bool) {
	if a, ok := aliases[model]; ok {
		model = a
	}
	p, ok := prices[model]
	if !ok {
		return 0, false
	}
	inRate, outRate, readRate := p.input, p.output, p.cacheRead
	if p.longOver > 0 && in+cacheRead+cw5m+cw1h > p.longOver {
		scale := p.longInput / p.input
		inRate, outRate, readRate = p.longInput, p.longOutput, p.cacheRead*scale
	}
	usd := (float64(in)*inRate + float64(out)*outRate + float64(cacheRead)*readRate +
		float64(cw5m)*inRate*1.25 + float64(cw1h)*inRate*2) / 1e6
	switch speed {
	case "", "standard":
	case "fast":
		if p.fast == 0 {
			return 0, false
		}
		usd *= p.fast
	default: // an unknown speed is never priced as standard
		return 0, false
	}
	return usd, true
}

// ModelTiers lists the priced models by output price, highest first (ties by
// name), so the next entry with a lower price is the next cheaper tier.
func ModelTiers() []string {
	out := make([]string, 0, len(prices))
	for m := range prices {
		out = append(out, m)
	}
	slices.SortFunc(out, func(a, b string) int {
		return cmp.Or(cmp.Compare(prices[b].output, prices[a].output), cmp.Compare(a, b))
	})
	return out
}

type codexPrice struct {
	input, cached, output float64 // $ per million tokens
	// cacheWrite is the published short-retention (30-minute) cache write
	// rate; 0 = none published, so a cache write is priced at the input rate
	// (spec 2026-11-03 D36).
	cacheWrite float64
}

// OpenAI's standard-tier, short-context (≤272K input tokens) rates for the
// model ids Codex writes in turn_context.model, checked against
// https://developers.openai.com/api/docs/pricing on 2026-11-10. The
// long-context tier is not applied (v1 limit). Kept apart from prices:
// ModelTiers and the LLM ledger stay Anthropic-only.
var codexPrices = map[string]codexPrice{
	"gpt-6-astra":   {input: 10, cached: 1, output: 50, cacheWrite: 12.50},
	"gpt-6.1-sol":   {input: 2, cached: 0.10, output: 10, cacheWrite: 2.50},
	"gpt-6.1-terra": {input: 1, cached: 0.05, output: 5, cacheWrite: 1.25},
	"gpt-6-sol":     {input: 2, cached: 0.20, output: 10, cacheWrite: 2.50},
	"gpt-6-luna":    {input: 0.10, cached: 0.01, output: 0.50, cacheWrite: 0.125},
	"gpt-5.6-sol":   {input: 4, cached: 0.40, output: 20, cacheWrite: 5},
	"gpt-5.6-terra": {input: 2, cached: 0.20, output: 12, cacheWrite: 2.50},
	"gpt-5.6-luna":  {input: 0.20, cached: 0.02, output: 1.20, cacheWrite: 0.25},
	"gpt-5.5":       {input: 5, cached: 0.50, output: 30},
	"gpt-5.4":       {input: 2.50, cached: 0.25, output: 15},
	"gpt-5.4-mini":  {input: 0.75, cached: 0.075, output: 4.50},
	"gpt-5.4-nano":  {input: 0.20, cached: 0.02, output: 1.25},
	"gpt-5.3-codex": {input: 1.75, cached: 0.175, output: 14},
	"gpt-5.2":       {input: 1.75, cached: 0.175, output: 14},
	"gpt-5.1":       {input: 1.25, cached: 0.125, output: 10},
	"gpt-5":         {input: 1.25, cached: 0.125, output: 10},
	"gpt-5-mini":    {input: 0.25, cached: 0.025, output: 2},
	"gpt-5-nano":    {input: 0.05, cached: 0.005, output: 0.40},
}

// CodexCost prices one Codex model response: fresh input at the input rate,
// cache reads at the cached rate, cache writes at the published write rate
// (else the input rate), output at the output rate. known=false (cost 0) for
// a model with no row — never guessed.
func CodexCost(model string, in, out, cacheRead, cacheWrite int64) (float64, bool) {
	p, ok := codexPrices[model]
	if !ok {
		return 0, false
	}
	write := cmp.Or(p.cacheWrite, p.input)
	return (float64(in)*p.input + float64(cacheRead)*p.cached + float64(cacheWrite)*write + float64(out)*p.output) / 1e6, true
}
