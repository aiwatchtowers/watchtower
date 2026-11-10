package pricing

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestCost_Opus55WithCacheTiers(t *testing.T) {
	// 1M input @4, 1M output @20, 1M cache read @0.20, 1M 5m write @5 (1.25x), 1M 1h write @8 (2x)
	usd, known := Cost("claude-opus-5-5", "standard", 1e6, 1e6, 1e6, 1e6, 1e6)
	assert.True(t, known)
	assert.InDelta(t, 4+20+0.20+5+8, usd, 1e-9)
}

func TestCost_Fable51CacheReadIsNotTenthOfInput(t *testing.T) {
	usd, _ := Cost("claude-fable-5-1", "", 0, 0, 1e6, 0, 0)
	assert.InDelta(t, 0.25, usd, 1e-9)
}

func TestCost_FastModeMultiplier(t *testing.T) {
	usd, known := Cost("claude-opus-5-5", "fast", 1e6, 1e6, 0, 0, 0)
	assert.True(t, known)
	assert.InDelta(t, 8+40, usd, 1e-9)
}

func TestCost_FastWithoutMultiplierIsEstimated(t *testing.T) {
	_, known := Cost("claude-opus-4-8", "fast", 1, 1, 0, 0, 0)
	assert.False(t, known)
}

func TestCost_UnknownModelIsEstimated(t *testing.T) {
	usd, known := Cost("claude-opus-9", "standard", 1e6, 0, 0, 0, 0)
	assert.False(t, known)
	assert.Zero(t, usd)
	_, known = Cost("claude-opus-5-5-preview", "", 1, 0, 0, 0, 0) // no prefix match
	assert.False(t, known)
}

func TestCost_AliasAndLongInputTier(t *testing.T) {
	_, known := Cost("claude-haiku-4-5-20251001", "", 1, 0, 0, 0, 0)
	assert.True(t, known)
	// Haiku 5.5 above 100K input: $0.50 / $2.50
	usd, _ := Cost("claude-haiku-5-5", "", 200_000, 1e6, 0, 0, 0)
	assert.InDelta(t, 0.2*0.50+2.50, usd, 1e-9)
}

func TestCost_UnknownSpeedIsEstimated(t *testing.T) {
	usd, known := Cost("claude-opus-5-5", "turbo", 1e6, 1e6, 0, 0, 0)
	assert.False(t, known)
	assert.Zero(t, usd)
	for _, speed := range []string{"", "standard", "fast"} {
		_, known = Cost("claude-opus-5-5", speed, 1, 1, 0, 0, 0)
		assert.True(t, known, speed)
	}
}

func TestModelTiers_ByOutputPriceHighestFirst(t *testing.T) {
	tiers := ModelTiers()
	assert.Len(t, tiers, len(prices))
	assert.Equal(t, []string{"claude-fable-5", "claude-fable-5-1"}, tiers[:2])
	assert.Equal(t, "claude-haiku-5-5", tiers[len(tiers)-1])
	for i := 1; i < len(tiers); i++ {
		assert.GreaterOrEqual(t, prices[tiers[i-1]].output, prices[tiers[i]].output)
	}
}

func TestResolveAliases(t *testing.T) {
	for short, id := range map[string]string{
		"opus": "claude-opus-5-5", "sonnet": "claude-sonnet-5-5",
		"haiku": "claude-haiku-5-5", "fable": "claude-fable-5-1",
	} {
		assert.Equal(t, id, Resolve(short), short)
		_, known := Cost(Resolve(short), "", 1, 1, 0, 0, 0)
		assert.True(t, known, short)
	}
	assert.Equal(t, "gpt-5.6-sol", Resolve("gpt-5.6-sol"))
	assert.Equal(t, "claude-opus-5-5", Resolve("claude-opus-5-5"))
	assert.Empty(t, Resolve(""))
}

func TestCodexCost_Formula(t *testing.T) {
	// A row with a published write rate, and one priced at the input rate (D36).
	for _, m := range []string{"gpt-5.6-sol", "gpt-5.4"} {
		p := codexPrices[m]
		write := p.cacheWrite
		if write == 0 {
			write = p.input
		}
		usd, known := CodexCost(m, 1e6, 1e6, 1e6, 1e6)
		assert.True(t, known, m)
		assert.InDelta(t, p.input+p.output+p.cached+write, usd, 1e-9, m)
	}
	usd, _ := CodexCost("gpt-5.4", 0, 0, 0, 1e6)
	assert.InDelta(t, 2.50, usd, 1e-9, "no published write rate: the input rate")
	usd, _ = CodexCost("gpt-5.6-sol", 0, 0, 0, 1e6)
	assert.InDelta(t, 5, usd, 1e-9, "the published 30-minute write rate")
}

func TestCodexCost_UnknownModel(t *testing.T) {
	usd, known := CodexCost("gpt-test", 1e6, 1e6, 0, 0)
	assert.False(t, known)
	assert.Zero(t, usd)
	_, known = CodexCost("claude-opus-5-5", 1, 1, 0, 0)
	assert.False(t, known, "the Anthropic table is not the Codex one")
}

func TestModelTiers_NoCodexModels(t *testing.T) {
	tiers := ModelTiers()
	for m := range codexPrices {
		assert.NotContains(t, tiers, m)
	}
	_, known := Cost("gpt-5.6-sol", "", 1, 1, 0, 0, 0)
	assert.False(t, known, "the LLM ledger's Cost never prices a Codex model")
}
