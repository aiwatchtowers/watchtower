package providers

import (
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Every row of the spec's §3.3 table (2026-11-05), field by field; codex's
// web_search stays off while L5 waits for the owner (ask #533).
func TestCapabilities_TableMatchesSpec(t *testing.T) {
	want := map[string]Capabilities{
		"claude": {Tools: "watchtower+quick_connections", ToolEvents: true, TextStream: "token", Usage: "split",
			CostReported: true, Images: true, PDFs: true, WebSearch: true, ReadFolder: "tools", TurnCap: "native",
			Interrupt: "in_turn", WarmSession: true, ClaudeAITools: true, ReservePeer: "codex", Quota: true},
		"codex": {Tools: "watchtower+quick_connections", ToolEvents: true, TextStream: "message", Usage: "split",
			Images: true, ReadFolder: "shell_sandbox", TurnCap: "counted", Interrupt: "kill_turn",
			ReservePeer: "claude", Quota: true},
		"ollama": {Tools: "watchtower+quick_connections", ToolEvents: true, TextStream: "token", Usage: "totals",
			ReadFolder: "none", TurnCap: "native", Interrupt: "kill_turn"},
	}
	for _, p := range All() {
		got, ok := CapsFor(p.ID)
		require.True(t, ok, p.ID)
		assert.Equal(t, want[p.ID], got, p.ID)
		assert.Equal(t, got, p.Caps, "%s: the registry row carries its capabilities", p.ID)
	}
	assert.Len(t, All(), len(want))
	_, ok := CapsFor("gemini")
	assert.False(t, ok, "an unknown provider has no row")
}

// The JSON keys the Desktop decodes (ProviderCapabilities.swift).
func TestCapabilities_JSONKeysPinned(t *testing.T) {
	c, _ := CapsFor("claude")
	b, err := json.Marshal(c)
	require.NoError(t, err)
	var m map[string]any
	require.NoError(t, json.Unmarshal(b, &m))
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	assert.ElementsMatch(t, []string{"tools", "tool_events", "text_stream", "usage", "cost_reported", "images",
		"pdfs", "web_search", "read_folder", "turn_cap", "interrupt", "warm_session", "claude_ai_tools",
		"reserve_peer", "quota"}, keys)
}

// A profile is satisfied by what it needs: a batch call by any transport,
// an image by image input, a read-only review by folder reading, a tool
// preflight by the watchtower tools.
func TestCapabilities_SatisfiesProfile(t *testing.T) {
	cases := []struct {
		provider string
		profile  InvocationProfile
		want     bool
	}{
		{"claude", BatchText, true}, {"codex", BatchText, true}, {"ollama", BatchText, true},
		{"claude", Image, true}, {"codex", Image, true}, {"ollama", Image, false},
		{"claude", ReviewReadonly, true}, {"codex", ReviewReadonly, true}, {"ollama", ReviewReadonly, false},
		{"claude", ToolPreflight, true}, {"codex", ToolPreflight, true}, {"ollama", ToolPreflight, true},
		{"claude", InvocationProfile("unknown"), false},
	}
	for _, tc := range cases {
		c, _ := CapsFor(tc.provider)
		assert.Equal(t, tc.want, Satisfies(c, tc.profile), "%s %s", tc.provider, tc.profile)
	}
}

// The fallback pair is data: each side names the other as its reserve
// peer; ollama has none.
func TestCapabilities_PairsFromReservePeer(t *testing.T) {
	assert.True(t, Pairs("claude", "codex"))
	assert.True(t, Pairs("codex", "claude"))
	assert.False(t, Pairs("ollama", "claude"))
	assert.False(t, Pairs("claude", "ollama"))
	assert.False(t, Pairs("claude", "claude"))
	assert.False(t, Pairs("claude", ""))
}
