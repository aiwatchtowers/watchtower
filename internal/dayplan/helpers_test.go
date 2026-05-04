package dayplan

import (
	"testing"

	"watchtower/internal/prompts"

	"github.com/stretchr/testify/assert"
)

func TestNormalizePriority(t *testing.T) {
	cases := []struct {
		in, out string
	}{
		{"high", "high"},
		{"HIGH", "high"},
		{"Medium", "medium"},
		{"LOW", "low"},
		{"unknown", "medium"},
		{"", "medium"},
		{"  high  ", "medium"}, // not trimmed → falls into default
	}
	for _, tc := range cases {
		t.Run(tc.in, func(t *testing.T) {
			assert.Equal(t, tc.out, normalizePriority(tc.in))
		})
	}
}

func TestSetPromptStore_Assigns(t *testing.T) {
	p := &Pipeline{}
	store := &prompts.Store{}
	p.SetPromptStore(store)
	assert.Same(t, store, p.promptStore)
}

func TestAccumulatedUsage_ZeroByDefault(t *testing.T) {
	p := &Pipeline{}
	in, out, cost, total := p.AccumulatedUsage()
	assert.Equal(t, 0, in)
	assert.Equal(t, 0, out)
	assert.Equal(t, float64(0), cost)
	assert.Equal(t, 0, total)
}

func TestAccumulatedUsage_AfterUpdate(t *testing.T) {
	p := &Pipeline{
		lastInputTokens:    50,
		lastOutputTokens:   25,
		lastTotalAPITokens: 75,
	}
	in, out, cost, total := p.AccumulatedUsage()
	assert.Equal(t, 50, in)
	assert.Equal(t, 25, out)
	assert.Equal(t, float64(0), cost) // costUSD always 0 for day-plan pipeline
	assert.Equal(t, 75, total)
}
