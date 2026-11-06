package llmusage

import (
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestTokens_AllInputIsFreshPlusCache(t *testing.T) {
	tok := Tokens{Input: 10, CacheRead: 100, CacheWrite5m: 7, CacheWrite1h: 3, Output: 50}
	assert.Equal(t, int64(120), tok.AllInput(), "fresh + cache read + both cache writes; output never counts")
	assert.Equal(t, int64(0), Tokens{Output: 9}.AllInput())
}

// The spool line and the llm_calls columns keep their keys with the token
// block embedded in Call (LLMUSAGE-01: an older process's spool line still
// imports, and a newer line reads in an older importer).
func TestLLMUSAGE01_CallTokenKeysStayFlat(t *testing.T) {
	cost := 0.25
	c := Call{CallID: "c", Tokens: Tokens{Input: 1, CacheRead: 2, CacheWrite5m: 3, CacheWrite1h: 4, Output: 5,
		Estimated: true, ReportedCostUSD: &cost}}
	b, err := json.Marshal(c)
	require.NoError(t, err)
	var m map[string]any
	require.NoError(t, json.Unmarshal(b, &m))
	for k, want := range map[string]any{"input_tokens": 1.0, "cache_read_tokens": 2.0, "cache_write_5m_tokens": 3.0,
		"cache_write_1h_tokens": 4.0, "output_tokens": 5.0, "usage_estimated": true, "reported_cost_usd": 0.25} {
		assert.Equal(t, want, m[k], k)
	}
	assert.NotContains(t, m, "Tokens")

	var back Call
	require.NoError(t, json.Unmarshal(b, &back))
	assert.Equal(t, c, back)
}

// N3: runtime B's old "http" rows read as ollama; every other label as is.
func TestLLMUSAGE01_ProviderLabelHTTPReadsAsOllama(t *testing.T) {
	assert.Equal(t, "ollama", ProviderLabel("http"))
	for _, p := range []string{"claude", "codex", "ollama", ""} {
		assert.Equal(t, p, ProviderLabel(p))
	}
}
