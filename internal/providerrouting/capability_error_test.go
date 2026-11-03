package providerrouting

import (
	"context"
	"errors"
	"testing"

	"github.com/stretchr/testify/require"

	"watchtower/internal/providerhealth"
	"watchtower/internal/providers"
)

func TestCapabilityCheckPreservesOperationalErrorsAndPolicyOrder(t *testing.T) {
	for _, entry := range []string{"select", "run"} {
		t.Run(entry, func(t *testing.T) {
			sentinel := errors.New("synthetic connection storage failure")
			health := providerhealth.New(t.TempDir(), nil)
			checks, children, legacy := 0, 0, 0
			req := Request{Preferred: "claude", Mode: Pinned, Profile: providers.ToolPreflight, Retry: Never,
				CheckCapability: func(string, providers.InvocationProfile) (bool, error) { checks++; return false, sentinel },
				Capable:         func(string, providers.InvocationProfile) bool { legacy++; return true }}
			router := &Router{Health: health, Allowed: func(string) error { return nil }}
			invoke := func() error {
				if entry == "select" {
					_, err := router.Select(context.Background(), req)
					return err
				}
				_, err := router.Run(context.Background(), req, func(context.Context, Attempt) (Result, error) { children++; return Result{}, nil })
				return err
			}
			require.ErrorIs(t, invoke(), sentinel)
			require.Equal(t, 1, checks)
			require.Zero(t, legacy)
			require.Zero(t, children)
			req.CheckCapability = func(string, providers.InvocationProfile) (bool, error) { checks++; return false, nil }
			err := invoke()
			var failure *providers.Failure
			require.ErrorAs(t, err, &failure)
			require.Equal(t, providers.Capability, failure.Category)
			require.Zero(t, children)
			req.CheckCapability = func(string, providers.InvocationProfile) (bool, error) { checks++; return true, nil }
			require.NoError(t, invoke())
			require.Equal(t, 1, legacy)
			policyErr := providers.WithFailure("claude", providers.Policy, errors.New("synthetic policy refusal"))
			router.Allowed = func(string) error { return policyErr }
			before := checks
			require.ErrorIs(t, invoke(), policyErr)
			require.Equal(t, before, checks)
			state, err := health.Read(context.Background(), providerhealth.AccountScope("claude", ""))
			require.NoError(t, err)
			require.Equal(t, providerhealth.Available, state.State)
		})
	}
}

func TestSelectChecksCapabilitiesOnlyForAvailableCandidate(t *testing.T) {
	for _, scenario := range []string{"blocked", "healthy", "both-wait", "policy", "pinned"} {
		t.Run(scenario, func(t *testing.T) {
			health := providerhealth.New(t.TempDir(), nil)
			if scenario != "healthy" {
				require.NoError(t, health.RecordQuota(context.Background(), providerhealth.AccountScope("codex", ""), &providers.Failure{Provider: "codex", Category: providers.Quota}))
			}
			if scenario == "both-wait" {
				require.NoError(t, health.RecordQuota(context.Background(), providerhealth.AccountScope("claude", ""), &providers.Failure{Provider: "claude", Category: providers.Quota}))
			}
			calls := map[string]int{}
			req := Request{Preferred: "codex", Reserve: "claude", Mode: PreferredReserve, Profile: providers.ToolPreflight, CheckCapability: func(provider string, _ providers.InvocationProfile) (bool, error) {
				calls[provider]++
				return provider == "claude", nil
			}}
			router := &Router{Health: health, Allowed: func(string) error { return nil }}
			if scenario == "policy" {
				router.Allowed = func(provider string) error {
					return providers.WithFailure(provider, providers.Policy, errors.New("policy refusal"))
				}
			}
			if scenario == "pinned" {
				req.Mode = Pinned
			}
			actual, err := router.Select(context.Background(), req)
			switch scenario {
			case "blocked":
				require.NoError(t, err)
				require.Equal(t, "claude", actual)
				require.Zero(t, calls["codex"])
				require.Equal(t, 1, calls["claude"])
			case "healthy", "pinned":
				var failure *providers.Failure
				require.ErrorAs(t, err, &failure)
				require.Equal(t, providers.Capability, failure.Category)
				require.Equal(t, 1, calls["codex"])
				require.Zero(t, calls["claude"])
			case "both-wait":
				require.ErrorIs(t, err, ErrDeferred)
				require.Empty(t, calls)
			case "policy":
				var failure *providers.Failure
				require.ErrorAs(t, err, &failure)
				require.Equal(t, providers.Policy, failure.Category)
				require.Empty(t, calls)
			default:
				t.Fatal("unknown scenario")
			}
		})
	}
}
