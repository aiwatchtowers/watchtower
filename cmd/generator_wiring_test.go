package cmd

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/providers"
)

func TestCliGeneratorProviderSwitch(t *testing.T) {
	tests := []struct {
		provider string
		wantType string
	}{
		{"claude", "*digest.ClaudeGenerator"},
		{"codex", "*codex.CodexGenerator"},
		{"ollama", "*ollama.Generator"},
		{"", "*digest.ClaudeGenerator"},
		{"unknown", "*digest.ClaudeGenerator"},
	}
	for _, tt := range tests {
		t.Run("gen/"+tt.provider, func(t *testing.T) {
			cfg := &config.Config{AI: config.AIConfig{Provider: tt.provider}}
			if got := fmt.Sprintf("%T", cliGenerator(cfg)); got != tt.wantType {
				t.Errorf("cliGenerator(%q) = %s, want %s", tt.provider, got, tt.wantType)
			}
		})
	}
}

func TestNewAIClientProviderSwitch(t *testing.T) {
	tests := []struct {
		provider string
		wantType string
	}{
		{"claude", "*ai.Client"},
		{"codex", "*codex.Client"},
		{"ollama", "*ollama.Client"},
		{"", "*ai.Client"},
	}
	for _, tt := range tests {
		t.Run("client/"+tt.provider, func(t *testing.T) {
			cfg := &config.Config{AI: config.AIConfig{Provider: tt.provider}}
			if got := fmt.Sprintf("%T", newAIClient(cfg, "")); got != tt.wantType {
				t.Errorf("newAIClient(%q) = %s, want %s", tt.provider, got, tt.wantType)
			}
		})
	}
}

// TestProviderOverrideDoesNotInheritConfiguredModels goes through the REAL
// override path: config.Load (which snapshots ConfiguredProvider) followed by
// applyProviderOverride mutating cfg.AI.Provider — the exact sequence every
// per-command --provider override (including Desktop chat's `ai query
// --provider codex` with Auto model) runs. The overridden provider must
// resolve to ITS registry defaults, not the yaml provider's configured
// models. This test fails when ResolveModelsFor compares against the mutated
// cfg.AI.Provider instead of the Load-time snapshot.
func TestProviderOverrideDoesNotInheritConfiguredModels(t *testing.T) {
	dir := t.TempDir()
	configPath := filepath.Join(dir, "config.yaml")
	configYAML := `active_workspace: test-ws
workspaces:
  test-ws:
    slack_token: "xoxp-test-token"
ai:
  provider: claude
  models:
    strong: claude-opus-4-6
    light: claude-haiku-4-5-20251001
`
	require.NoError(t, os.WriteFile(configPath, []byte(configYAML), 0o600))

	cfg, err := config.Load(configPath)
	require.NoError(t, err)

	oldFlag := flagProvider
	flagProvider = "codex"
	defer func() { flagProvider = oldFlag }()
	applyProviderOverride(cfg)
	require.Equal(t, "codex", cfg.AI.Provider)

	light, strong := providers.ResolveModelsFor(cfg, cfg.AI.Provider)
	assert.Equal(t, "gpt-5.4-mini", light, "override provider must get its own defaults")
	assert.Equal(t, "gpt-5.4", strong, "a claude model must never leak into a codex session")

	// The yaml provider keeps its configured models.
	light, strong = providers.ResolveModelsFor(cfg, "claude")
	assert.Equal(t, "claude-haiku-4-5-20251001", light)
	assert.Equal(t, "claude-opus-4-6", strong)
}
