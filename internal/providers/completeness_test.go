package providers

import (
	"strings"
	"testing"

	"watchtower/internal/providers/caps"
)

// TestLLMTRANSPORT01_CapsTableMatchesRegistry: the capability table and
// the provider registry list the same providers, in both directions (the
// registry's init only checks one), so a row left behind or a provider with
// no row is named (docs/features/adding-a-harness.md).
func TestLLMTRANSPORT01_CapsTableMatchesRegistry(t *testing.T) {
	if err := CheckRegistryRows("internal/providers/caps", caps.IDs()); err != nil {
		t.Error(err)
	}
}

// CheckRegistryRows names what is missing on each side, sorted.
func TestCheckRegistryRows_NamesBothDirections(t *testing.T) {
	if err := CheckRegistryRows("tbl", IDs()); err != nil {
		t.Fatalf("the registry against itself: %v", err)
	}
	err := CheckRegistryRows("tbl", []string{"claude", "ollama", "gemini"})
	if err == nil {
		t.Fatal("a missing and an extra row pass")
	}
	for _, want := range []string{`provider "codex" has no row in tbl`, `tbl has a row "gemini" that is no registered provider`} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("%v lacks %q", err, want)
		}
	}
}
