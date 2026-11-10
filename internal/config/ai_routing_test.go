package config

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestLoadAIBucketsReadOnly(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.yaml")
	body := []byte("ai:\n  provider: claude\n  model: sonnet\n  providers: {claude: {}}\n")
	if err := os.WriteFile(path, body, 0600); err != nil {
		t.Fatal(err)
	}
	cfg, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := cfg.AI.Providers["claude"]; !ok {
		t.Fatal("explicit empty bucket disappeared")
	}
	got, _ := os.ReadFile(path)
	if string(got) != string(body) {
		t.Fatal("Load wrote config")
	}
	if err := os.WriteFile(path, []byte("ai:\n  providers: {unknown: {}}\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(path); err == nil {
		t.Fatal("unknown empty bucket accepted")
	}
}

func TestAIConfigValidate_InvalidValueError(t *testing.T) {
	cases := []struct {
		name string
		cfg  AIConfig
		msg  string
	}{
		{"unknown preferred", AIConfig{Provider: "zz"}, `unknown AI provider "zz"`},
		{"unknown bucket", AIConfig{Provider: "claude", Providers: map[string]AIProviderConfig{"yy": {}}}, `unknown AI provider bucket "yy"`},
		{"unknown fallback", AIConfig{Provider: "claude", Fallback: AIFallbackConfig{Provider: "xx"}}, `unknown fallback provider "xx"`},
		{"fallback equals preferred", AIConfig{Provider: "claude", Fallback: AIFallbackConfig{Provider: "claude"}}, "fallback provider must differ from preferred provider"},
		{"fallback outside a pair", AIConfig{Provider: "claude", Fallback: AIFallbackConfig{Provider: "ollama"}}, "fallback provider must be claude or codex"},
		{"enabled without pair", AIConfig{Provider: "ollama", Fallback: AIFallbackConfig{Enabled: true}}, "enabled fallback requires a Claude/Codex pair"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := tc.cfg.Validate()
			var invalid *InvalidValueError
			if !errors.As(err, &invalid) {
				t.Fatalf("Validate() = %v (%T), want *InvalidValueError", err, err)
			}
			if err.Error() != tc.msg {
				t.Fatalf("Validate() message = %q, want %q", err.Error(), tc.msg)
			}
		})
	}
	valid := AIConfig{Provider: "claude", Fallback: AIFallbackConfig{Enabled: true, Provider: "codex"}}
	if err := valid.Validate(); err != nil {
		t.Fatalf("valid pair rejected: %v", err)
	}
}
