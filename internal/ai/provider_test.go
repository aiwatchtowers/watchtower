package ai

import (
	"testing"

	"watchtower/internal/llmusage"
)

// Verify at compile time that Client implements Provider.
var _ Provider = (*Client)(nil)

func TestProviderInterface(t *testing.T) {
	// This test verifies that ai.Client satisfies the Provider interface.
	// The actual compliance check is done by the var _ line above.
	t.Log("ai.Client implements ai.Provider")
}

// CHAT-01: a chat message's tokens_in is every input token, cached ones
// included; the split rides alongside.
func TestTurnUsage_InputTokensStaysAllInput(t *testing.T) {
	u := TurnUsage{Model: "m", Tokens: llmusage.Tokens{Input: 10, CacheRead: 200, CacheWrite5m: 30, CacheWrite1h: 5, Output: 7}}
	if got := u.InputTokens(); got != 245 {
		t.Fatalf("InputTokens() = %d, want 245 (fresh + cache)", got)
	}
	if got := u.OutputTokens(); got != 7 {
		t.Fatalf("OutputTokens() = %d, want 7", got)
	}
}

// ai.Usage keeps its old meanings as accessors: InputTokens is fresh input,
// TotalAPITokens every input token.
func TestUsage_AccessorsKeepTheirMeaning(t *testing.T) {
	cost := 0.5
	u := Usage{Tokens: llmusage.Tokens{Input: 10, CacheRead: 200, CacheWrite1h: 5, Output: 7, ReportedCostUSD: &cost}}
	if u.InputTokens() != 10 || u.OutputTokens() != 7 || u.TotalAPITokens() != 215 || u.CostUSD() != 0.5 {
		t.Fatalf("accessors = %d/%d/%d/%v", u.InputTokens(), u.OutputTokens(), u.TotalAPITokens(), u.CostUSD())
	}
	if (Usage{}).CostUSD() != 0 {
		t.Fatal("no reported cost reads as 0")
	}
}
