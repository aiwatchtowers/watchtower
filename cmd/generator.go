package cmd

import (
	"context"
	"errors"
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

// cliBoundedGenerator is cliGenerator plus the H8 wall-clock cap and nothing
// else — the shape a pipeline wired outside cliPooledGenerator needs. The
// memory pipeline is the one such pipeline (newMemoryPipelineFactory builds it
// for both the daemon phase and `watchtower memory consolidate`), and its
// daemon phase runs while holding sync.lock like any other, so it must not be
// the one AI path left unbounded. It is a var so the wiring test can pin that
// the factory sources its generator here rather than building a bare one.
var cliBoundedGenerator = func(cfg *config.Config) digest.Generator {
	return digest.WithCallTimeout(cliGenerator(cfg), digest.DaemonAICallTimeout)
}

// cliPooledGenerator creates a PooledGenerator backed by a concurrency pool.
// Each call creates a fresh session (--no-session-persistence / --ephemeral).
// The pool only limits how many AI processes run in parallel. The raw
// generator is wrapped with a wall-clock timeout (H8) so a hung claude/codex
// subprocess cannot freeze the daemon's sequential cycle forever while
// holding sync.lock.
//
// This path backs the daemon AND every batch CLI command that runs a pipeline
// (`sync`, `catchup`, `digest`, `inbox`, `tracks`, …). The cap applies to
// those too, deliberately: they run the same unattended pipelines, and a
// batch command that hangs for hours on one subprocess is no better at a
// terminal than in the daemon. cliGenerator (interactive commands like
// ask/chat) deliberately does NOT get this wrapper: those calls are already
// bounded by the user.
func cliPooledGenerator(cfg *config.Config, logger *log.Logger) (digest.Generator, func()) {
	rawGen := digest.WithCallTimeout(cliGenerator(cfg), digest.DaemonAICallTimeout)
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
// refresh failure: the row is marked status="revoked" when only a new
// sign-in can fix it (ErrInvalidGrant, ErrNoRefreshToken, ErrClientRejected,
// a rotated token that could not be saved) and "error" for a
// transient failure (network, 5xx, lock wait), and just that connection is
// skipped — a failed grant can never take down the rest of the chat's
// external tools, and the owner sees the row surfaced rather than a silently
// missing tool.
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
		server, ok := connectionServer(cfg, database, c)
		if !ok {
			continue
		}
		if !c.ToolsListed && c.AllowTools == nil {
			// Never listed (added before QC-02's allowlist, or the listing at
			// enable time failed): list once now and cache it. A failure
			// mounts nothing from this server — fail closed.
			if err := refreshConnectionTools(database, &c, server); err != nil {
				log.Printf("external connection %d (%s): listing tools failed, none allowed: %v", c.ID, c.Name, err)
				continue
			}
		}
		server.AllowTools, server.DenyTools = externalmcp.ResolveTools(c)
		if len(server.AllowTools) == 0 {
			log.Printf("external connection %d (%s): no tool allowed (none known read-only; `watchtower connections tools %d` to review), not mounted", c.ID, c.Name, c.ID)
			continue
		}
		servers = append(servers, server)
	}
	return servers
}

// connectionServer builds c's ai.ExternalMCPServer with its credentials: the
// secret's static env/headers, or a verified/refreshed OAuth bearer (QC-04).
// false means "skip this one", already logged (and recorded where it is the
// grant's fault).
func connectionServer(cfg *config.Config, database *db.DB, c db.ExternalConnection) (ai.ExternalMCPServer, bool) {
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
		return server, false
	}
	if secret != nil && secret.OAuth != nil {
		if !applyOAuthCredentials(database, store, &server, c) {
			return server, false
		}
	} else if secret != nil {
		server.Env = secret.Env
		server.Headers = secret.Headers
	}
	return server, true
}

// toolsListTimeout bounds one tools/list exchange (connect, list, stop).
var toolsListTimeout = 30 * time.Second

// refreshConnectionTools lists server's tools, caches them on c's row and
// updates c in place (QC-02).
func refreshConnectionTools(database *db.DB, c *db.ExternalConnection, server ai.ExternalMCPServer) error {
	ctx, cancel := context.WithTimeout(context.Background(), toolsListTimeout)
	defer cancel()
	tools, err := listServerTools(ctx, externalmcp.ServerSpec{
		Kind: server.Kind, Command: server.Command, Args: server.Args, URL: server.URL,
		Env: server.Env, Headers: server.Headers,
	})
	if err != nil {
		return err
	}
	listedAt := time.Now().UTC().Format(time.RFC3339)
	if err := database.SetExternalConnectionTools(c.ID, tools, listedAt); err != nil {
		return err
	}
	c.Tools, c.ToolsListed, c.ToolsListedAt = tools, true, listedAt
	return nil
}

// listServerTools is externalmcp.ListTools; a var so tests can stub the
// network/subprocess exchange.
var listServerTools = externalmcp.ListTools

// oauthLockWait bounds how long a chat launch (or `connections oauth`)
// waits for another process to finish with a connection's grant: one
// token-endpoint round trip is capped at 30 s, so this leaves headroom
// without letting a wedged holder stall the launch indefinitely. A var so
// tests can shorten it.
var oauthLockWait = 45 * time.Second

// applyOAuthCredentials verifies or refreshes an OAuth connection's grant and
// puts the resulting bearer token on server. It reports whether the connection
// may be used for this launch; false means "skip this one" and the reason has
// already been logged and, unless the grant was removed meanwhile, recorded
// on the row.
//
// The load→refresh→save runs under the secret's cross-process lock, and the
// secret is re-read once the lock is held: every chat launch is its own
// process, and two launches refreshing with the same rotating refresh token
// would burn it (or, with reuse detection, the whole token family).
//
// Two orderings here are load-bearing for QC-04. The Authorization header goes
// into a COPY of the secret's headers, so a bearer can never be persisted as
// if it were a static secret. And a rotated refresh token is saved BEFORE the
// new access token is handed to the caller: if that save fails the token would
// be unrecoverable once used, so the connection is skipped instead.
func applyOAuthCredentials(
	database *db.DB,
	store *externalmcp.SecretStore,
	server *ai.ExternalMCPServer,
	c db.ExternalConnection,
) bool {
	fail := func(status, what string, err error) bool {
		log.Printf("external connection %d (%s): %s, skipping: %v", c.ID, c.Name, what, err)
		if serr := database.SetExternalConnectionStatus(c.ID, status, err.Error()); serr != nil {
			log.Printf("external connection %d (%s): recording %s status: %v", c.ID, c.Name, status, serr)
		}
		return false
	}

	lockCtx, cancel := context.WithTimeout(context.Background(), oauthLockWait)
	defer cancel()
	unlock, err := store.Lock(lockCtx)
	if err != nil {
		log.Printf("external connection %d (%s): %v", c.ID, c.Name, err)
		return fail("error", "waiting for the token lock",
			errors.New("another process was still refreshing this connection's token; retried on the next chat"))
	}
	defer unlock()
	secret, err := store.Load()
	if err != nil {
		return fail("error", "re-reading secret", err)
	}
	if secret == nil || secret.OAuth == nil {
		// Removed or signed out between the first read and the lock.
		log.Printf("external connection %d (%s): oauth grant gone, skipping", c.ID, c.Name)
		return false
	}

	changed, err := mcpoauth.EnsureFresh(context.Background(), secret.OAuth, externalMCPNow())
	if err != nil {
		return fail(refreshFailureStatus(err), "token refresh failed", err)
	}

	headers := make(map[string]string, len(secret.Headers)+1)
	for k, v := range secret.Headers {
		headers[k] = v
	}
	headers["Authorization"] = "Bearer " + secret.OAuth.AccessToken

	if changed {
		if err := store.Save(secret); err != nil {
			// The server has likely rotated the stored refresh token away, so
			// this is a sign-in-again state; a server that does not rotate
			// lets the next launch refresh again and flip the row back to ok.
			return fail("revoked", "persisting rotated token", err)
		}
	}

	server.Headers = headers
	server.Env = secret.Env
	markConnectionOK(database, c)
	return true
}

// refreshFailureStatus maps an EnsureFresh error to the row status QC-04
// records: "revoked" when only a new sign-in fixes it, "error" when the next
// launch may simply succeed (network, 5xx).
func refreshFailureStatus(err error) string {
	if errors.Is(err, mcpoauth.ErrInvalidGrant) || errors.Is(err, mcpoauth.ErrNoRefreshToken) ||
		errors.Is(err, mcpoauth.ErrClientRejected) {
		return "revoked"
	}
	return "error"
}

// markConnectionOK flips a usable connection's row back to ok. It re-reads
// the status rather than trusting c, the pre-lock snapshot: a parallel launch
// may have recorded an error while this one waited for the lock.
func markConnectionOK(database *db.DB, c db.ExternalConnection) {
	cur, err := database.GetExternalConnection(c.ID)
	if err != nil {
		log.Printf("external connection %d (%s): reading status: %v", c.ID, c.Name, err)
		return
	}
	if cur.Status == "ok" {
		return
	}
	if err := database.SetExternalConnectionStatus(c.ID, "ok", ""); err != nil {
		log.Printf("external connection %d (%s): recording ok status: %v", c.ID, c.Name, err)
	}
}

// applyProviderOverride applies the --provider CLI flag to the config.
func applyProviderOverride(cfg *config.Config) {
	if flagProvider != "" {
		cfg.AI.Provider = flagProvider
	}
}
