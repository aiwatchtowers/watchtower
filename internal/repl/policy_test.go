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
