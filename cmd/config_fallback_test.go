package cmd

import (
	"os"
	"path/filepath"
	"testing"
	"watchtower/internal/config"
	"watchtower/internal/providers"
)

func TestConfigFallbackAtomicMigration(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.yaml")
	original := []byte("ai:\n  provider: claude\n  model: sonnet\nunknown: keep\n")
	if err := os.WriteFile(path, original, 0600); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		key   string
		value any
	}{{"ai.provider", "unknown"}, {"ai.fallback.enabled", true}, {"ai.fallback.provider", "claude"}} {
		if err := setAIConfigKey(path, tc.key, tc.value); err == nil {
			t.Fatalf("accepted invalid %s", tc.key)
		}
		data, _ := os.ReadFile(path)
		if string(data) != string(original) {
			t.Fatal("failed validation wrote file")
		}
	}
	if err := setAIConfigKey(path, "ai.provider", "codex"); err != nil {
		t.Fatal(err)
	}
	cfg, err := config.Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.AI.Provider != "codex" || cfg.AI.Fallback.Enabled {
		t.Fatal("migration changed selection")
	}
	_, claude := providers.ResolveModelsFor(cfg, "claude")
	_, codex := providers.ResolveModelsFor(cfg, "codex")
	if claude != "sonnet" || codex == "sonnet" {
		t.Fatalf("model pin lost or leaked: claude=%q codex=%q cfg=%+v", claude, codex, cfg.AI)
	}
	before, _ := os.ReadFile(path)
	if _, err := config.Load(path); err != nil {
		t.Fatal(err)
	}
	after, _ := os.ReadFile(path)
	if string(before) != string(after) {
		t.Fatal("read wrote config")
	}
	info, _ := os.Stat(path)
	if info.Mode().Perm() != 0600 {
		t.Fatal("config permissions")
	}
}

func TestConfigFallbackPolicyRefusalPreservesFile(t *testing.T) {
	claudeOnly(t)
	path := filepath.Join(t.TempDir(), "config.yaml")
	body := []byte("ai:\n  provider: claude\n  fallback: {provider: codex, enabled: false}\n")
	if err := os.WriteFile(path, body, 0600); err != nil {
		t.Fatal(err)
	}
	if err := setAIConfigKey(path, "ai.fallback.enabled", true); err == nil {
		t.Fatal("policy-forbidden reserve enabled")
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(body) {
		t.Fatal("policy refusal rewrote settings")
	}
	// Policy is not applied by the reader: removing the profile restores choices.
	cfg, err := config.Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.AI.Fallback.Provider != "codex" {
		t.Fatal("read erased owner choice")
	}
}

func TestConfigFallbackWriteFailureKeepsOriginal(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.yaml")
	body := []byte("ai: {provider: claude, model: sonnet}\n")
	if err := os.WriteFile(path, body, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(dir, 0500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(dir, 0700) })
	if err := setAIConfigKey(path, "ai.fallback.provider", "codex"); err == nil {
		t.Fatal("write unexpectedly succeeded in read-only directory")
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(body) {
		t.Fatal("failed atomic save changed original")
	}
}
