package cmd

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"

	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// pointOllamaAt appends an ai.ollama_url override to the test config so
// runAIModels never dials the real localhost:11434 (hermeticity — a dev
// machine actually running Ollama must not change which branch the test
// exercises).
func pointOllamaAt(t *testing.T, url string) {
	t.Helper()
	f, err := os.OpenFile(flagConfig, os.O_APPEND|os.O_WRONLY, 0o600)
	require.NoError(t, err)
	defer f.Close()
	_, err = f.WriteString("ai:\n  ollama_url: " + url + "\n")
	require.NoError(t, err)
}

func TestAIModels_JSONShape(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	mux := http.NewServeMux()
	mux.HandleFunc("/v1/models", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"data":[{"id":"llama4:8b"}]}`))
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()
	pointOllamaAt(t, srv.URL)

	buf := &bytes.Buffer{}
	aiModelsCmd.SetOut(buf)
	oldJSON := aiModelsFlagJSON
	aiModelsFlagJSON = true
	defer func() { aiModelsFlagJSON = oldJSON }()

	require.NoError(t, runAIModels(aiModelsCmd, nil))

	var parsed struct {
		ActiveProvider string `json:"active_provider"`
		Providers      []struct {
			ID             string   `json:"id"`
			Kind           string   `json:"kind"`
			DefaultLight   string   `json:"default_light"`
			DefaultStrong  string   `json:"default_strong"`
			ResolvedLight  string   `json:"resolved_light"`
			ResolvedStrong string   `json:"resolved_strong"`
			LiveModels     bool     `json:"live_models"`
			Models         []string `json:"models"`
			Error          string   `json:"error"`
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
	assert.Equal(t, "opus", claude.ResolvedStrong)
	assert.Equal(t, "cli", claude.Kind)
	// Known CLI aliases flow through `models` so the Desktop picker can
	// suggest opus even though it is no tier's default.
	assert.Equal(t, []string{"haiku", "sonnet", "opus"}, claude.Models)

	codexP := parsed.Providers[byID["codex"]]
	assert.Equal(t, "gpt-5.6-luna", codexP.ResolvedLight)
	assert.Equal(t, "gpt-5.6-sol", codexP.ResolvedStrong)

	// Ollama ships no default model: unconfigured resolves empty, and the
	// live list flows through from the (stubbed) server.
	ollamaP := parsed.Providers[byID["ollama"]]
	assert.True(t, ollamaP.LiveModels)
	assert.Empty(t, ollamaP.ResolvedLight)
	assert.Empty(t, ollamaP.ResolvedStrong)
	assert.Empty(t, ollamaP.Error)
	assert.Equal(t, []string{"llama4:8b"}, ollamaP.Models)
}

func TestAIModels_JSONShape_OllamaDown(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	// A dead server: the command must still succeed, carrying an error
	// string instead of a model list (best-effort contract).
	srv := httptest.NewServer(http.NewServeMux())
	deadURL := srv.URL
	srv.Close()
	pointOllamaAt(t, deadURL)

	buf := &bytes.Buffer{}
	aiModelsCmd.SetOut(buf)
	oldJSON := aiModelsFlagJSON
	aiModelsFlagJSON = true
	defer func() { aiModelsFlagJSON = oldJSON }()

	require.NoError(t, runAIModels(aiModelsCmd, nil))

	var parsed struct {
		Providers []struct {
			ID     string   `json:"id"`
			Models []string `json:"models"`
			Error  string   `json:"error"`
		} `json:"providers"`
	}
	require.NoError(t, json.Unmarshal(buf.Bytes(), &parsed))
	for _, p := range parsed.Providers {
		if p.ID == "ollama" {
			assert.NotEmpty(t, p.Error)
			assert.Empty(t, p.Models)
		}
	}
}

func TestAIModels_HumanOutput(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	srv := httptest.NewServer(http.NewServeMux())
	deadURL := srv.URL
	srv.Close()
	pointOllamaAt(t, deadURL)

	buf := &bytes.Buffer{}
	aiModelsCmd.SetOut(buf)
	oldJSON := aiModelsFlagJSON
	aiModelsFlagJSON = false
	defer func() { aiModelsFlagJSON = oldJSON }()

	require.NoError(t, runAIModels(aiModelsCmd, nil))

	out := buf.String()
	assert.Contains(t, out, "* Claude (claude)")
	assert.Contains(t, out, "(not set — pick a model", "empty ollama resolution renders a hint, not a blank")
	assert.Contains(t, out, "light:  haiku")
	assert.Contains(t, out, "strong: opus")
	assert.Contains(t, out, "Codex (codex)")
	assert.Contains(t, out, "Ollama / Local (ollama)")
}

// Drive Cobra's real inherited pre-run, not only runAIModels: Settings catalog
// reads must preserve the file instance that daemon application binds to.
func TestAIModelsCommandPreservesLegacySavedFile(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/v1/models" {
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
		}
		requests.Add(1)
		_, _ = w.Write([]byte(`{"data":[{"id":"owned-local-model"}]}`))
	}))
	defer server.Close()
	cfg := filepath.Join(t.TempDir(), "config.yaml")
	original := []byte("# preserve this saved file\ndb: {schema_format: 0}\nai: {provider: claude, ollama_url: '" + server.URL + "'}\n")
	require.NoError(t, os.WriteFile(cfg, original, 0600))
	before, err := os.Stat(cfg)
	require.NoError(t, err)
	p := startCLI(t, "--config", cfg, "ai", "models", "--json")
	var lines []string
	for line := range p.lines {
		lines = append(lines, line)
	}
	require.NoError(t, p.wait())
	line := strings.Join(lines, "\n")
	require.True(t, json.Valid([]byte(line)), line)
	require.Contains(t, line, "owned-local-model")
	var catalog struct {
		ActiveProvider string `json:"active_provider"`
	}
	require.NoError(t, json.Unmarshal([]byte(line), &catalog))
	require.Equal(t, "claude", catalog.ActiveProvider)
	require.Equal(t, int32(1), requests.Load())
	after, err := os.Stat(cfg)
	require.NoError(t, err)
	data, err := os.ReadFile(cfg)
	require.NoError(t, err)
	require.Equal(t, string(original), string(data))
	require.True(t, os.SameFile(before, after), "metadata cannot invalidate saved_version by atomic rewrite")
	require.True(t, before.ModTime().Equal(after.ModTime()))
	require.Equal(t, before.Size(), after.Size())
	require.False(t, strings.Contains(p.stderr.String(), "schema"), p.stderr.String())
}
