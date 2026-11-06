package transport

import (
	"slices"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/ai"
	"watchtower/internal/codex"
	"watchtower/internal/config"
	"watchtower/internal/digest"
	"watchtower/internal/ollama"
)

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

// The querier options reach the child's argv: the model, the turn cap and
// the read folder.
func TestNewQuerier_AppliesOptions(t *testing.T) {
	folder := t.TempDir()
	o := Options{Config: &config.Config{ClaudePath: "/usr/bin/false", CodexPath: "/usr/bin/false"},
		Model: "pinned", ReadFolder: folder, MaxTurns: 3}
	claudeArgs := For("claude").NewQuerier(o).(*ai.Client).ArgsForTest("sys", "user")
	require.Contains(t, claudeArgs, "pinned")
	i := slices.Index(claudeArgs, "--max-turns")
	require.GreaterOrEqual(t, i, 0, "%v", claudeArgs)
	assert.Equal(t, "3", claudeArgs[i+1])
	codexArgs := For("codex").NewQuerier(o).(*codex.Client).ArgsForTest("sys", "user")
	assert.Contains(t, codexArgs, "pinned")
	assert.Contains(t, codexArgs, folder)
}
