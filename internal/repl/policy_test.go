package repl

import (
	"context"
	"errors"
	"testing"

	"watchtower/internal/policy"
	"watchtower/internal/policy/policytest"
)

// The REPL's Claude fallback follows the organization's provider policy.
func TestREPL_FallbackRefusesForbiddenClaude(t *testing.T) {
	r, _ := newTestREPL(t)
	policytest.Set(t, map[string]any{"AllowedAIProviders": []any{"codex"}})
	if _, _, err := r.aiProvider().QuerySync(context.Background(), "", "", ""); !errors.Is(err, policy.ErrNotAllowed) {
		t.Fatalf("QuerySync = %v; want the policy refusal", err)
	}
}

// The refused fallback's stream reports the policy error before it ends.
func TestREPL_RefusedProviderStreamDeliversTheError(t *testing.T) {
	r, _ := newTestREPL(t)
	policytest.Set(t, map[string]any{"AllowedAIProviders": []any{"ollama"}})
	chunks, errs, ids := r.aiProvider().Query(context.Background(), "", "", "")
	for range chunks {
		t.Fatal("no text from a refused provider")
	}
	for range ids {
		t.Fatal("no session id from a refused provider")
	}
	if err := <-errs; !errors.Is(err, policy.ErrNotAllowed) {
		t.Fatalf("stream error = %v; want the policy refusal", err)
	}
	// A question answered through the refused provider reports the refusal
	// and returns without hanging.
	r.processInput("what happened today?")
}
