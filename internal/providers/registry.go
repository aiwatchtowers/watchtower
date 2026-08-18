// Package providers is the single source of truth for the AI provider
// registry: which backends exist, their default per-tier models, and how a
// config resolves to concrete light/strong models. The Desktop app consumes
// the same registry through `watchtower ai models --json`, so model lists are
// never hardcoded in Swift.
package providers

import "watchtower/internal/config"

// Provider describes one AI backend.
type Provider struct {
	ID          string `json:"id"`
	DisplayName string `json:"display_name"`
	// Kind is "cli" (subprocess harness) or "http" (OpenAI-compatible server).
	Kind string `json:"kind"`
	// DefaultLight/DefaultStrong are the tier defaults used when the config
	// carries no override. Claude uses CLI aliases (they track the newest
	// model of each class without a Watchtower release).
	DefaultLight  string `json:"default_light"`
	DefaultStrong string `json:"default_strong"`
	// LiveModels reports whether the provider can list its models at runtime
	// (OpenAI-compatible `GET /v1/models`).
	LiveModels bool `json:"live_models"`
}

// registry order is the display order in UIs.
var registry = []Provider{
	{
		ID:            "claude",
		DisplayName:   "Claude",
		Kind:          "cli",
		DefaultLight:  "haiku",
		DefaultStrong: "sonnet",
	},
	{
		ID:            "codex",
		DisplayName:   "Codex",
		Kind:          "cli",
		DefaultLight:  "gpt-5.4-mini",
		DefaultStrong: "gpt-5.4",
	},
	{
		ID:            "ollama",
		DisplayName:   "Ollama / Local",
		Kind:          "http",
		DefaultLight:  "gemma4:31b",
		DefaultStrong: "gemma4:31b",
		LiveModels:    true,
	},
}

// All returns the registry in display order.
func All() []Provider {
	out := make([]Provider, len(registry))
	copy(out, registry)
	return out
}

// ByID looks a provider up by id. An unknown or empty id resolves to claude,
// mirroring the historical "anything but codex is claude" wiring.
func ByID(id string) Provider {
	for _, p := range registry {
		if p.ID == id {
			return p
		}
	}
	return registry[0]
}

// ResolveModelsFor returns the concrete light/strong models the given
// provider should use under cfg. Precedence per tier:
//
//	ai.models.<tier> → legacy ai.model (strong only) → registry default.
//
// The legacy ai.model value is ignored when it equals the retired
// config.DefaultAIModel constant: setup used to seed that literal into every
// config.yaml, so it means "never chose a model", not a deliberate pin.
// For single-model backends (ollama), an unset light tier follows the
// resolved strong model instead of the registry default, so configuring one
// model configures both tiers.
func ResolveModelsFor(cfg *config.Config, providerID string) (light, strong string) {
	p := ByID(providerID)

	strong = cfg.AI.Models.Strong
	if strong == "" {
		if legacy := cfg.AI.Model; legacy != "" && legacy != config.DefaultAIModel {
			strong = legacy
		}
	}
	if strong == "" {
		strong = p.DefaultStrong
	}

	light = cfg.AI.Models.Light
	if light == "" {
		if p.ID == "ollama" {
			light = strong
		} else {
			light = p.DefaultLight
		}
	}
	return light, strong
}
