package cmd

import (
	"bytes"
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestAIModels_JSONShape(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	buf := &bytes.Buffer{}
	aiModelsCmd.SetOut(buf)
	oldJSON := aiModelsFlagJSON
	aiModelsFlagJSON = true
	defer func() { aiModelsFlagJSON = oldJSON }()

	require.NoError(t, runAIModels(aiModelsCmd, nil))

	var parsed struct {
		ActiveProvider string `json:"active_provider"`
		Providers      []struct {
			ID             string `json:"id"`
			Kind           string `json:"kind"`
			DefaultLight   string `json:"default_light"`
			DefaultStrong  string `json:"default_strong"`
			ResolvedLight  string `json:"resolved_light"`
			ResolvedStrong string `json:"resolved_strong"`
			LiveModels     bool   `json:"live_models"`
			Error          string `json:"error"`
		} `json:"providers"`
	}
	require.NoError(t, json.Unmarshal(buf.Bytes(), &parsed), "output: %s", buf.String())

	assert.Equal(t, "claude", parsed.ActiveProvider)
	require.Len(t, parsed.Providers, 3)

	byID := map[string]int{}
	for i, p := range parsed.Providers {
		byID[p.ID] = i
	}
	claude := parsed.Providers[byID["claude"]]
	assert.Equal(t, "haiku", claude.ResolvedLight)
	assert.Equal(t, "sonnet", claude.ResolvedStrong)
	assert.Equal(t, "cli", claude.Kind)

	codexP := parsed.Providers[byID["codex"]]
	assert.Equal(t, "gpt-5.4-mini", codexP.ResolvedLight)
	assert.Equal(t, "gpt-5.4", codexP.ResolvedStrong)

	// Ollama: live listing is best-effort — whether or not a local server is
	// running, the command must succeed; resolution still yields models.
	ollamaP := parsed.Providers[byID["ollama"]]
	assert.True(t, ollamaP.LiveModels)
	assert.NotEmpty(t, ollamaP.ResolvedLight)
	assert.NotEmpty(t, ollamaP.ResolvedStrong)
}

func TestAIModels_HumanOutput(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	buf := &bytes.Buffer{}
	aiModelsCmd.SetOut(buf)
	oldJSON := aiModelsFlagJSON
	aiModelsFlagJSON = false
	defer func() { aiModelsFlagJSON = oldJSON }()

	require.NoError(t, runAIModels(aiModelsCmd, nil))

	out := buf.String()
	assert.Contains(t, out, "* Claude (claude)")
	assert.Contains(t, out, "light:  haiku")
	assert.Contains(t, out, "strong: sonnet")
	assert.Contains(t, out, "Codex (codex)")
	assert.Contains(t, out, "Ollama / Local (ollama)")
}
