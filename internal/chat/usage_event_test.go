package chat

import (
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/ai"
	"watchtower/internal/llmusage"
)

// usageKeys is the v2 usage event's JSON as a key → value map.
func usageKeys(t *testing.T, e Event) map[string]any {
	t.Helper()
	require.Equal(t, EventUsage, e.Type)
	b, err := json.Marshal(e)
	require.NoError(t, err)
	var m map[string]any
	require.NoError(t, json.Unmarshal(b, &m))
	return m
}

// The v2 usage event carries the split beside tokens_in, which keeps its
// meaning (all input, CHAT-01): fresh_in, cache_read, cache_write (5 m + 1 h),
// cost_usd and estimated. The keys are pinned: the Desktop decodes them.
func TestUsageEvent_V2CarriesSplitKeys(t *testing.T) {
	cost := 0.125
	evs := ChunkEvents("t1", ai.StreamChunk{Usage: &ai.TurnUsage{Model: "m", Tokens: llmusage.Tokens{
		Input: 10, CacheRead: 200, CacheWrite5m: 30, CacheWrite1h: 5, Output: 7, ReportedCostUSD: &cost, Estimated: true}}})
	require.Len(t, evs, 1)
	m := usageKeys(t, evs[0])
	assert.Equal(t, map[string]any{
		"type": "usage", "turn_id": "t1", "model": "m",
		"tokens_in": 245.0, "tokens_out": 7.0,
		"fresh_in": 10.0, "cache_read": 200.0, "cache_write": 35.0, "cost_usd": 0.125, "estimated": true,
	}, m)

	// A transport without a cache split (runtime B, plain ollama) fills
	// fresh_in whole; no cost, not estimated.
	evs = ChunkEvents("t1", ai.StreamChunk{Usage: &ai.TurnUsage{Model: "m", Tokens: llmusage.Tokens{Input: 40, Output: 3}}})
	m = usageKeys(t, evs[0])
	assert.Equal(t, 40.0, m["tokens_in"])
	assert.Equal(t, 40.0, m["fresh_in"])
	assert.NotContains(t, m, "cost_usd")
	assert.NotContains(t, m, "estimated")
}

// Claude's own stream gives the same split on its usage event, with the
// turn's reported cost.
func TestUsageEvent_ClaudeResultCarriesSplitKeys(t *testing.T) {
	tr := NewClaudeTranslator(fixedTurn("t1"))
	evs := feedAll(t, tr,
		`{"type":"system","subtype":"init","session_id":"s1","model":"claude-sonnet-x"}`,
		`{"type":"result","subtype":"success","is_error":false,"result":"Hi","session_id":"s1","total_cost_usd":0.5,`+
			`"usage":{"input_tokens":10,"cache_read_input_tokens":5,"cache_creation_input_tokens":2,"output_tokens":7,`+
			`"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":2}}}`,
	)
	require.Equal(t, []string{EventUsage, EventTurnDone}, types(evs))
	m := usageKeys(t, evs[0])
	assert.Equal(t, 17.0, m["tokens_in"], "tokens_in keeps all input")
	assert.Equal(t, 10.0, m["fresh_in"])
	assert.Equal(t, 5.0, m["cache_read"])
	assert.Equal(t, 2.0, m["cache_write"])
	assert.Equal(t, 0.5, m["cost_usd"])
	assert.NotContains(t, m, "estimated")
}

// A result line without a usage object stores no counts (CHAT-01) but still
// carries the turn's reported cost, flagged as estimated.
func TestUsageEvent_ClaudeResultWithoutUsageKeepsCost(t *testing.T) {
	tr := NewClaudeTranslator(fixedTurn("t1"))
	evs := feedAll(t, tr,
		`{"type":"system","subtype":"init","session_id":"s1","model":"claude-sonnet-x"}`,
		`{"type":"result","subtype":"success","is_error":false,"result":"Hi","session_id":"s1","total_cost_usd":0.5}`,
	)
	require.Equal(t, []string{EventUsage, EventTurnDone}, types(evs))
	m := usageKeys(t, evs[0])
	assert.NotContains(t, m, "tokens_in")
	assert.NotContains(t, m, "tokens_out")
	assert.Equal(t, 0.5, m["cost_usd"])
	assert.Equal(t, true, m["estimated"])
}
