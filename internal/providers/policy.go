package providers

import (
	"fmt"

	"watchtower/internal/config"
	"watchtower/internal/policy"
)

// Allowed refuses an LLM provider the organization's policy
// (AllowedAIProviders, #608) does not allow; nil when it may be used. id is
// empty means Claude; unknown IDs are rejected. Every AI path asks
// it before it builds or runs a provider, and never falls back to an allowed
// one.
func Allowed(id string) error {
	if id == "" {
		id = "claude"
	}
	if !config.KnownAIProvider(id) {
		return fmt.Errorf("unknown AI provider %q", id)
	}
	if p := policy.Current(); !p.ProviderAllowed(id) {
		return WithFailure(id, Policy, p.ProviderError(id))
	}
	return nil
}
