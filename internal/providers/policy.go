package providers

import "watchtower/internal/policy"

// Allowed refuses an LLM provider the organization's policy
// (AllowedAIProviders, #608) does not allow; nil when it may be used. id is
// read as ByID reads it ("" and unknown ids are claude). Every AI path asks
// it before it builds or runs a provider, and never falls back to an allowed
// one.
func Allowed(id string) error {
	id = ByID(id).ID
	if p := policy.Current(); !p.ProviderAllowed(id) {
		return p.ProviderError(id)
	}
	return nil
}
