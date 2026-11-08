package transport

import (
	"slices"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"

	"watchtower/internal/ai"
	"watchtower/internal/codex"
	"watchtower/internal/config"
	"watchtower/internal/digest"
	"watchtower/internal/ollama"
)

// TestLLMTRANSPORT01_ConstructorsCoverRegistry: the one factory builds
// every registered provider and no other, so For never panics on a
// registered id (docs/features/adding-a-harness.md).
func TestLLMTRANSPORT01_ConstructorsCoverRegistry(t *testing.T) {
	if err := CheckConstructors(); err != nil {
		t.Error(err)
	}
}

// An unknown or empty id is the default provider's row, as providers.ByID.
func TestFor_UnknownIsDefault(t *testing.T) {
	assert.Equal(t, "claude", For("").ID)
	assert.Equal(t, "claude", For("no-such-provider").ID)
	assert.Equal(t, "codex", For("codex").ID)
}

// Each constructor builds its own adapter's client.
func TestFor_BuildsTheAdapter(t *testing.T) {
	cfg := &config.Config{}
	o := Options{Config: cfg, Model: "m"}
	assert.IsType(t, &digest.ClaudeGenerator{}, For("claude").NewGenerator(o))
	assert.IsType(t, &codex.CodexGenerator{}, For("codex").NewGenerator(o))
	assert.IsType(t, &ollama.Generator{}, For("ollama").NewGenerator(o))
	assert.IsType(t, &ai.Client{}, For("claude").NewQuerier(o))
	assert.IsType(t, &codex.Client{}, For("codex").NewQuerier(o))
	assert.IsType(t, &ollama.Client{}, For("ollama").NewQuerier(o))
}

// The querier options reach the child's argv: the model and the read folder.
func TestNewQuerier_AppliesOptions(t *testing.T) {
	folder := t.TempDir()
	o := Options{Config: &config.Config{ClaudePath: "/usr/bin/false", CodexPath: "/usr/bin/false"},
		Model: "pinned", ReadFolder: folder}
	claudeArgs := For("claude").NewQuerier(o).(*ai.Client).ArgsForTest("sys", "user")
	assert.Contains(t, claudeArgs, "pinned")
	assert.True(t, slices.ContainsFunc(claudeArgs, func(a string) bool { return strings.Contains(a, "Read") }), "%v", claudeArgs)
	codexArgs := For("codex").NewQuerier(o).(*codex.Client).ArgsForTest("sys", "user")
	assert.Contains(t, codexArgs, "pinned")
	assert.Contains(t, codexArgs, folder)
}
