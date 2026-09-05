package cmd

import (
	"log"
	"path/filepath"

	"watchtower/internal/agentloop"
	"watchtower/internal/ai"
	"watchtower/internal/codex"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/ollama"
	"watchtower/internal/providers"
	"watchtower/internal/sessions"
	"watchtower/internal/tools"
)

// validateModel is a no-op kept for call-site compatibility.
// Model validation was removed — new model IDs often fail the check
// before the CLI is updated, producing false negatives.
func validateModel(_ *config.Config) error {
	return nil
}

// cliGenerator creates a bare Generator for one-off CLI commands.
// The provider comes from cfg.AI.Provider; the per-tier models resolve
// through the provider registry (config overrides win, registry defaults
// otherwise — see providers.ResolveModelsFor).
func cliGenerator(cfg *config.Config) digest.Generator {
	light, strong := providers.ResolveModelsFor(cfg, cfg.AI.Provider)
	switch cfg.AI.Provider {
	case "codex":
		return codex.NewCodexGenerator(light, strong, cfg.CodexPath)
	case "ollama":
		return ollama.NewGenerator(light, strong, cfg.AI.OllamaURL)
	default:
		return digest.NewClaudeGenerator(light, strong, cfg.ClaudePath)
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

// newAIClient creates an ai.Provider for ask/chat commands, using the
// resolved strong-tier model.
func newAIClient(cfg *config.Config, dbPath string) ai.Provider {
	return newAIClientWithModel(cfg, dbPath, "")
}

// newAIClientWithModel is newAIClient with an explicit model override
// (e.g. the --model flag of `watchtower ai query`); empty means the
// resolved strong-tier model.
func newAIClientWithModel(cfg *config.Config, dbPath, modelOverride string) ai.Provider {
	model := modelOverride
	if model == "" {
		_, model = providers.ResolveModelsFor(cfg, cfg.AI.Provider)
	}
	switch cfg.AI.Provider {
	case "codex":
		return codex.NewClient(model, dbPath, cfg.CodexPath)
	case "ollama":
		return ollama.NewClient(model, cfg.AI.OllamaURL)
	default:
		return ai.NewClient(model, dbPath, cfg.ClaudePath)
	}
}

// newQueryClient builds the ai.Provider for `watchtower ai query`. On a
// tool-bearing chat surface (--tools chat) it wires tools two ways: claude/codex
// get the MCP-args set on their client (the subprocess MCP path); the ollama
// provider gets the runtime-B in-process tool loop (agentloop) instead, since it
// has no subprocess. It returns a cleanup to run after the query drains (closing
// the tool-loop's DB, if one was opened); the cleanup is a no-op otherwise.
func newQueryClient(cfg *config.Config, dbPath string) (ai.Provider, func(), error) {
	client := newAIClientWithModel(cfg, dbPath, aiFlagModel)
	noop := func() {}
	if aiFlagTools != "chat" {
		return client, noop, nil
	}
	if c, ok := client.(mcpConfigurable); ok {
		c.SetMCPArgs(chatMCPArgs())
		return client, noop, nil
	}
	if cfg.AI.Provider == "ollama" {
		model := aiFlagModel
		if model == "" {
			_, model = providers.ResolveModelsFor(cfg, cfg.AI.Provider)
		}
		database, err := db.Open(dbPath)
		if err != nil {
			return nil, noop, err
		}
		reg := buildToolRegistry(cfg, database)
		return agentloop.NewClient(model, cfg.AI.OllamaURL, reg, chatBinding()), func() { _ = database.Close() }, nil
	}
	return client, noop, nil
}

// chatBinding assembles the runtime-B proposal binding from the `ai query`
// chat flags — the same surface/conversation/turn the MCP path passes as args.
func chatBinding() tools.Binding {
	return tools.Binding{
		Surface:        aiFlagSurface,
		ConversationID: aiFlagConversation,
		ContextType:    aiFlagContextType,
		ContextID:      aiFlagContextID,
		TurnID:         aiFlagTurn,
	}
}

// applyProviderOverride applies the --provider CLI flag to the config.
func applyProviderOverride(cfg *config.Config) {
	if flagProvider != "" {
		cfg.AI.Provider = flagProvider
	}
}
