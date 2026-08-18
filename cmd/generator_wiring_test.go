package cmd

import (
	"fmt"
	"testing"

	"watchtower/internal/config"
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
