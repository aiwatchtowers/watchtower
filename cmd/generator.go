package cmd

import (
	"log"
	"path/filepath"

	"watchtower/internal/ai"
	"watchtower/internal/codex"
	"watchtower/internal/config"
	"watchtower/internal/digest"
	"watchtower/internal/ollama"
	"watchtower/internal/sessions"
)

// validateModel is a no-op kept for call-site compatibility.
// Model validation was removed — new model IDs often fail the check
// before the CLI is updated, producing false negatives.
func validateModel(_ *config.Config) error {
	return nil
}

// cliGenerator creates a bare Generator for one-off CLI commands.
// Selects Claude, Codex, or Ollama based on cfg.AI.Provider.
func cliGenerator(cfg *config.Config) digest.Generator {
	switch cfg.AI.Provider {
	case "codex":
		return codex.NewCodexGenerator(codex.ModelDefault, cfg.CodexPath)
	case "ollama":
		model := cfg.AI.Model
		if model == "" || model == config.DefaultAIModel {
			model = config.DefaultOllamaModel
		}
		return ollama.NewGenerator(model, cfg.OllamaURL)
	default:
		return digest.NewClaudeGenerator(digest.ModelSonnet, cfg.ClaudePath)
	}
}

// cliPooledGenerator creates a PooledGenerator backed by a concurrency pool.
// Each call creates a fresh session (--no-session-persistence / --ephemeral).
// The pool only limits how many AI processes run in parallel.
func cliPooledGenerator(cfg *config.Config, logger *log.Logger) (digest.Generator, func()) {
	rawGen := cliGenerator(cfg)
	poolSize := cfg.AI.Workers
	if poolSize <= 0 {
		poolSize = config.DefaultAIWorkers
	}
	pool := sessions.NewSessionPool(poolSize)
	gen := digest.NewPooledGenerator(rawGen, pool)

	sessionLogPath := filepath.Join(cfg.WorkspaceDir(), "sessions.log")
	gen.SetSessionLog(sessions.NewSessionLog(sessionLogPath))

	cleanup := func() { pool.Close() }
	return gen, cleanup
}

// newAIClient creates an ai.Provider for ask/chat commands.
// Selects Claude, Codex, or Ollama based on cfg.AI.Provider.
func newAIClient(cfg *config.Config, dbPath string) ai.Provider {
	switch cfg.AI.Provider {
	case "codex":
		model := cfg.AI.Model
		if model == "" || model == config.DefaultAIModel {
			model = codex.ModelDefault
		}
		return codex.NewClient(model, dbPath, cfg.CodexPath)
	case "ollama":
		model := cfg.AI.Model
		if model == "" || model == config.DefaultAIModel {
			model = config.DefaultOllamaModel
		}
		return ollama.NewClient(model, cfg.OllamaURL)
	default:
		return ai.NewClient(cfg.AI.Model, dbPath, cfg.ClaudePath)
	}
}

// applyProviderOverride applies the --provider CLI flag to the config.
func applyProviderOverride(cfg *config.Config) {
	if flagProvider != "" {
		cfg.AI.Provider = flagProvider
	}
}
