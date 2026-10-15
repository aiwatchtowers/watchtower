// Package agentlog turns coding-agent session transcripts into the
// normalized analytics rows of agent_log_* (spec
// docs/superpowers/specs/2026-10-15-agent-analytics-core-design.md).
package agentlog

// PriceVersion is stamped on every priced row; bump it with any change to
// prices so the next scan reprices stored rows (no reparse).
const PriceVersion = 1

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

// Cost prices one API call. known=false (cost 0) when the model, or its fast
// multiplier, is not in the table — never guessed.
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
	if speed == "fast" {
		if p.fast == 0 {
			return 0, false
		}
		usd *= p.fast
	}
	return usd, true
}
