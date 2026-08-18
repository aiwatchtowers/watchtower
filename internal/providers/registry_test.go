package providers

import (
	"testing"

	"watchtower/internal/config"
)

func cfgWith(provider, legacy, light, strong string) *config.Config {
	return &config.Config{AI: config.AIConfig{
		Provider: provider,
		Model:    legacy,
		Models:   config.AIModels{Light: light, Strong: strong},
	}}
}

func TestResolveModelsFor(t *testing.T) {
	tests := []struct {
		name                  string
		cfg                   *config.Config
		provider              string
		wantLight, wantStrong string
	}{
		{
			name:     "claude defaults are aliases",
			cfg:      cfgWith("claude", "", "", ""),
			provider: "claude", wantLight: "haiku", wantStrong: "sonnet",
		},
		{
			name:     "config overrides win over defaults",
			cfg:      cfgWith("claude", "", "claude-haiku-4-5-20251001", "claude-opus-4-6"),
			provider: "claude", wantLight: "claude-haiku-4-5-20251001", wantStrong: "claude-opus-4-6",
		},
		{
			name:     "legacy ai.model fills strong only",
			cfg:      cfgWith("claude", "claude-opus-4-6", "", ""),
			provider: "claude", wantLight: "haiku", wantStrong: "claude-opus-4-6",
		},
		{
			name:     "legacy ai.model equal to the retired seeded default is unset",
			cfg:      cfgWith("claude", config.DefaultAIModel, "", ""),
			provider: "claude", wantLight: "haiku", wantStrong: "sonnet",
		},
		{
			name:     "models.strong beats legacy ai.model",
			cfg:      cfgWith("claude", "claude-opus-4-6", "", "sonnet"),
			provider: "claude", wantLight: "haiku", wantStrong: "sonnet",
		},
		{
			name:     "codex defaults",
			cfg:      cfgWith("codex", "", "", ""),
			provider: "codex", wantLight: "gpt-5.4-mini", wantStrong: "gpt-5.4",
		},
		{
			name:     "codex ignores carried-over claude seeded default",
			cfg:      cfgWith("codex", config.DefaultAIModel, "", ""),
			provider: "codex", wantLight: "gpt-5.4-mini", wantStrong: "gpt-5.4",
		},
		{
			name:     "ollama single model configures both tiers",
			cfg:      cfgWith("ollama", "", "", "llama4:70b"),
			provider: "ollama", wantLight: "llama4:70b", wantStrong: "llama4:70b",
		},
		{
			name:     "ollama explicit light stays",
			cfg:      cfgWith("ollama", "", "qwen3:8b", "llama4:70b"),
			provider: "ollama", wantLight: "qwen3:8b", wantStrong: "llama4:70b",
		},
		{
			name:     "unknown provider resolves as claude",
			cfg:      cfgWith("whatever", "", "", ""),
			provider: "whatever", wantLight: "haiku", wantStrong: "sonnet",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			light, strong := ResolveModelsFor(tt.cfg, tt.provider)
			if light != tt.wantLight || strong != tt.wantStrong {
				t.Fatalf("ResolveModelsFor() = (%q, %q), want (%q, %q)", light, strong, tt.wantLight, tt.wantStrong)
			}
		})
	}
}

func TestByID(t *testing.T) {
	if got := ByID("codex").ID; got != "codex" {
		t.Errorf("ByID(codex).ID = %q", got)
	}
	if got := ByID("").ID; got != "claude" {
		t.Errorf("ByID(\"\").ID = %q, want claude fallback", got)
	}
	if got := ByID("ollama"); !got.LiveModels || got.Kind != "http" {
		t.Errorf("ByID(ollama) = %+v, want http kind with live models", got)
	}
}

func TestAllIsACopy(t *testing.T) {
	a := All()
	a[0].ID = "mutated"
	if All()[0].ID != "claude" {
		t.Fatal("All() must return a copy, not the registry backing array")
	}
}
