package config

import "fmt"

// Validate checks configuration, never policy: reading a managed installation
// must preserve the owner's values even when policy currently forbids them.
func (a AIConfig) Validate() error {
	preferred := a.ConfiguredProviderID()
	if preferred == "" {
		preferred = DefaultAIProvider
	}
	if !KnownAIProvider(preferred) {
		return fmt.Errorf("unknown AI provider %q", preferred)
	}
	for id := range a.Providers {
		if !KnownAIProvider(id) {
			return fmt.Errorf("unknown AI provider bucket %q", id)
		}
	}
	reserve := a.Fallback.Provider
	if reserve != "" {
		if !KnownAIProvider(reserve) {
			return fmt.Errorf("unknown fallback provider %q", reserve)
		}
		if reserve == preferred {
			return fmt.Errorf("fallback provider must differ from preferred provider")
		}
		if reserve == "ollama" {
			return fmt.Errorf("fallback provider must be claude or codex")
		}
	}
	if a.Fallback.Enabled && (reserve == "" || preferred == "ollama") {
		return fmt.Errorf("enabled fallback requires a Claude/Codex pair")
	}
	return nil
}

// KnownAIProvider validates IDs without the registry's historical display fallback.
func KnownAIProvider(id string) bool { return id == "claude" || id == "codex" || id == "ollama" }

// PreserveEmptyModelBuckets retains YAML `provider: {}` entries that Viper's
// leaf-key unmarshaller otherwise drops. Their presence means Default.
func (a *AIConfig) PreserveEmptyModelBuckets(raw map[string]any) {
	for id := range raw {
		if a.Providers == nil {
			a.Providers = make(map[string]AIProviderConfig)
		}
		if _, ok := a.Providers[id]; !ok {
			a.Providers[id] = AIProviderConfig{}
		}
	}
}
