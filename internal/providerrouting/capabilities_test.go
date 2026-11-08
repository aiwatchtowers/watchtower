package providerrouting

import (
	"context"
	"errors"
	"testing"

	"watchtower/internal/providers"
)

// capsCheck is a CheckCapability reading the capability table only, and
// counting the providers it was asked about.
func capsCheck(asked *[]string) func(string, providers.InvocationProfile) (bool, error) {
	return func(p string, profile providers.InvocationProfile) (bool, error) {
		*asked = append(*asked, p)
		c, ok := providers.CapsFor(p)
		return ok && providers.Satisfies(c, profile), nil
	}
}

// POLICY-02 first: a provider the organization forbids is never reached,
// however capable its row is — the capability check never even runs for it.
func TestPolicy_ForbiddenProviderNeverReachableByCapability(t *testing.T) {
	forbidCodex := func(p string) error {
		if p == "codex" {
			return errors.New("policy")
		}
		return nil
	}
	var asked []string
	req := request()
	req.CheckCapability = capsCheck(&asked)
	r := Router{Allowed: forbidCodex}
	var attempted []string
	_, err := r.Run(context.Background(), req, func(_ context.Context, a Attempt) (Result, error) {
		attempted = append(attempted, a.Provider)
		return Result{}, quota(a.Provider)
	})
	if err == nil {
		t.Fatal("a quota on the only allowed provider must fail")
	}
	for _, p := range append(attempted, asked...) {
		if p == "codex" {
			t.Fatalf("the forbidden reserve was reached: attempted %v, capability asked %v", attempted, asked)
		}
	}

	// The forbidden provider as the preferred one: refused before any check.
	asked = nil
	req.Preferred, req.Reserve = "codex", "claude"
	if _, err := r.Select(context.Background(), req); err == nil {
		t.Fatal("a forbidden preferred provider must be refused")
	}
	if len(asked) != 0 {
		t.Fatalf("capability asked before policy: %v", asked)
	}
}

// The fallback pair is the table's reserve_peer: ollama pairs with nothing.
func TestValidPair_ReadsReservePeer(t *testing.T) {
	for _, tc := range []struct {
		preferred, reserve string
		want               bool
	}{{"claude", "codex", true}, {"codex", "claude", true}, {"ollama", "claude", false}, {"claude", "ollama", false}, {"claude", "", false}} {
		if got := validPair(Request{Preferred: tc.preferred, Reserve: tc.reserve}); got != tc.want {
			t.Errorf("%s+%s: %v, want %v", tc.preferred, tc.reserve, got, tc.want)
		}
	}
}
