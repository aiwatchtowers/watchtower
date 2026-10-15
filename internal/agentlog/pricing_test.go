package agentlog

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
