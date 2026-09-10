package cmd

import (
	"context"
	"log"
	"path/filepath"
	"time"

	"watchtower/internal/agentloop"
	"watchtower/internal/ai"
	"watchtower/internal/codex"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/externalmcp"
	"watchtower/internal/mcpoauth"
	"watchtower/internal/ollama"
	"watchtower/internal/providers"
	"watchtower/internal/sessions"
	"watchtower/internal/tools"
)

// externalMCPNow is a test seam for the pre-launch OAuth refresh check in
// loadExternalMCPServers (the internal/auth.openBrowserFunc precedent).
var externalMCPNow = time.Now

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
	noop := func() {}
	// Runtime B: the ollama provider on a tool-bearing chat surface gets the
	// in-process loop — it has no MCP subprocess. Handled first so we never build
	// (and discard) a plain ollama client, nor resolve the model twice.
	if aiFlagTools == "chat" && cfg.AI.Provider == "ollama" {
		model := aiFlagModel
		if model == "" {
			_, model = providers.ResolveModelsFor(cfg, cfg.AI.Provider)
		}
		database, err := db.Open(dbPath)
		if err != nil {
			return nil, noop, err
		}
		reg := buildToolRegistry(cfg, database)
		binding := tools.Binding{
			Surface:        aiFlagSurface,
			ConversationID: aiFlagConversation,
			ContextType:    aiFlagContextType,
			ContextID:      aiFlagContextID,
			TurnID:         aiFlagTurn,
		}
		return agentloop.NewClient(model, cfg.AI.OllamaURL, reg, binding), func() { _ = database.Close() }, nil
	}

	client := newAIClientWithModel(cfg, dbPath, aiFlagModel)
	if aiFlagTools == "chat" {
		if c, ok := client.(mcpConfigurable); ok {
			c.SetMCPArgs(chatMCPArgs()) // claude/codex reach tools via the MCP subprocess
		}
		if c, ok := client.(externalMCPConfigurable); ok {
			c.SetExternalMCPServers(loadExternalMCPServers(cfg, dbPath))
		}
	}
	return client, noop, nil
}

// loadExternalMCPServers reads the owner's enabled external MCP connections
// ("Quick Connections") plus their per-connection secrets, and maps them into
// the ai.Client DTO shape. These are optional extras layered on top of native
// chat: a DB-open error or a ListEnabledExternalConnections error is logged
// and yields zero external servers (chat keeps working with only its built-in
// tools); a per-connection secret-load error is logged and just skips that
// one connection, so one owner's corrupted secret file can't take down every
// other connection's tools. An OAuth connection degrades the same way on a
// refresh failure: EnsureFresh returning ErrInvalidGrant (or any other
// refresh error) marks the connection row status="revoked" and skips just
// that connection — a revoked grant can never take down the rest of the
// chat's external tools, and the owner sees the row surfaced as needing
// re-sign-in rather than a silently missing tool.
func loadExternalMCPServers(cfg *config.Config, dbPath string) []ai.ExternalMCPServer {
	database, err := db.Open(dbPath)
	if err != nil {
		log.Printf("external MCP: opening database: %v", err)
		return nil
	}
	defer func() { _ = database.Close() }()

	conns, err := database.ListEnabledExternalConnections()
	if err != nil {
		log.Printf("external MCP: listing enabled connections: %v", err)
		return nil
	}

	var servers []ai.ExternalMCPServer
	for _, c := range conns {
		server := ai.ExternalMCPServer{
			Name:    c.Name,
			Kind:    c.Kind,
			Command: c.Command,
			Args:    c.Args,
			URL:     c.URL,
		}
		store := externalmcp.NewSecretStore(cfg.WorkspaceDir(), c.ID)
		secret, err := store.Load()
		if err != nil {
			log.Printf("external MCP: loading secret for connection %d (%s): %v", c.ID, c.Name, err)
			continue
		}
		if secret != nil && secret.OAuth != nil {
			changed, err := mcpoauth.EnsureFresh(context.Background(), secret.OAuth, externalMCPNow())
			if err != nil {
				log.Printf("external connection %d (%s): token refresh failed, skipping: %v", c.ID, c.Name, err)
				if serr := database.SetExternalConnectionStatus(c.ID, "revoked", err.Error()); serr != nil {
					log.Printf("external connection %d (%s): recording revoked status: %v", c.ID, c.Name, serr)
				}
				continue
			}
			// Copy headers so the bearer token is never written back into
			// secret.Headers — this map, not secret.Headers, is what
			// travels into server.Headers below.
			headers := make(map[string]string, len(secret.Headers)+1)
			for k, v := range secret.Headers {
				headers[k] = v
			}
			headers["Authorization"] = "Bearer " + secret.OAuth.AccessToken
			if changed {
				// Persist the rotated token BEFORE it is handed out to the
				// caller — a save failure means the new token would be
				// unrecoverable once used, so skip this connection rather
				// than hand it out.
				if err := store.Save(secret); err != nil {
					log.Printf("external connection %d (%s): persisting rotated token: %v", c.ID, c.Name, err)
					continue
				}
			}
			server.Headers = headers
			server.Env = secret.Env
			if c.Status != "ok" {
				if serr := database.SetExternalConnectionStatus(c.ID, "ok", ""); serr != nil {
					log.Printf("external connection %d (%s): recording ok status: %v", c.ID, c.Name, serr)
				}
			}
		} else if secret != nil {
			server.Env = secret.Env
			server.Headers = secret.Headers
		}
		servers = append(servers, server)
	}
	return servers
}

// applyProviderOverride applies the --provider CLI flag to the config.
func applyProviderOverride(cfg *config.Config) {
	if flagProvider != "" {
		cfg.AI.Provider = flagProvider
	}
}
