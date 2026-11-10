package config

import (
	"fmt"

	"watchtower/internal/providers/caps"
)

// InvalidValueError is the error AIConfig.Validate returns for a value it
// rejects. Its message is the same text the plain errors it replaced carried;
// the type lets a caller (watchtower diagnostics) tell "the config holds an
// invalid value" from "the config could not be read" without parsing text.
type InvalidValueError struct{ Msg string }

func (e *InvalidValueError) Error() string { return e.Msg }

func invalidValue(format string, args ...any) error {
	return &InvalidValueError{Msg: fmt.Sprintf(format, args...)}
}

// Validate checks configuration, never policy: reading a managed installation
// must preserve the owner's values even when policy currently forbids them.
// Every error it returns is an *InvalidValueError.
func (a AIConfig) Validate() error {
	preferred := a.ConfiguredProviderID()
	if preferred == "" {
		preferred = DefaultAIProvider
	}
	if !KnownAIProvider(preferred) {
		return invalidValue("unknown AI provider %q", preferred)
	}
	for id := range a.Providers {
		if !KnownAIProvider(id) {
			return invalidValue("unknown AI provider bucket %q", id)
		}
	}
	reserve := a.Fallback.Provider
	if reserve != "" {
		if !KnownAIProvider(reserve) {
			return invalidValue("unknown fallback provider %q", reserve)
		}
		if reserve == preferred {
			return invalidValue("fallback provider must differ from preferred provider")
		}
		if !inAnyPair(reserve) {
			return invalidValue("fallback provider must be claude or codex")
		}
	}
	if a.Fallback.Enabled && (reserve == "" || !caps.Pairs(preferred, reserve)) {
		return invalidValue("enabled fallback requires a Claude/Codex pair")
	}
	return nil
}

// inAnyPair reports whether id has a fallback reserve peer (the capability
// table's reserve_peer).
func inAnyPair(id string) bool {
	c, ok := caps.For(id)
	return ok && c.ReservePeer != ""
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
