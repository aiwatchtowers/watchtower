package cmd

import (
	"context"
	"crypto/rand"
	"errors"
	"os"
	"slices"
	"strings"

	"watchtower/internal/agentloop"
	"watchtower/internal/ai"
	"watchtower/internal/chat"
	"watchtower/internal/codex"
	"watchtower/internal/config"
	"watchtower/internal/digest"
	"watchtower/internal/providers"
	"watchtower/internal/specreview"
	"watchtower/internal/tools"
)

// This file is cmd's half of the one client factory (spec 2026-11-05 §3.4,
// LLMTRANSPORT-01): the constructors that need cmd's wiring — a chat
// session's backend, an automation agent() child, the spec reviewer, the
// runtime-B loop — and the few rules that belong to one transport. It is
// the only file in cmd that names a transport or builds an adapter's
// client; internal/providers/transport has the generators and queriers.

// transportWiring is a transport's cmd constructors.
type transportWiring struct {
	// newChatBackend is the `ai session` backend.
	newChatBackend func(sessionWiring) (chat.Backend, error)
	// newAgentClient is the headless child of one automation agent() call
	// with its cleanup; nil = no CLI child (agent() runs the runtime-B
	// loop in process).
	newAgentClient func(agentClientWiring) (ai.Provider, func(), error)
}

// wirings is every registry provider's cmd wiring, by id. It covers the
// registry exactly (TestLLMTRANSPORT01_WiringCoversRegistry), so wiringFor
// never meets a registered provider it cannot wire.
var wirings = map[string]transportWiring{
	"claude": {newChatBackend: newClaudeChatBackend, newAgentClient: newClaudeAgentClient},
	"codex":  {newChatBackend: newCodexChatBackend, newAgentClient: newCodexAgentClient},
	"ollama": {newChatBackend: newRuntimeBChatBackend},
}

// wiringFor is provider id's wiring. An unknown or empty id is the default
// provider's, as providers.ByID resolves it; a registry provider with no
// row is a bug the completeness test catches, and panics here rather than
// run another transport.
func wiringFor(id string) transportWiring {
	p := providers.ByID(id).ID
	w, ok := wirings[p]
	if !ok {
		panic("transport wiring: no constructors for provider " + p)
	}
	return w
}

// quickConnectionEnv is the environment a provider's child carries the
// owner's Quick Connections in, when the transport constrains it: a codex
// launch passes each server's env through its own environment, so a
// connection it cannot carry (codex.EnvConflicts) is left out
// (codexEnvSkips). nil = no constraint.
func quickConnectionEnv(provider string) []string {
	if providers.ByID(provider).ID == "codex" {
		return os.Environ()
	}
	return nil
}

// newClaudeChatBackend is the warm claude session.
func newClaudeChatBackend(w sessionWiring) (chat.Backend, error) {
	ext := loadExternalMCPServers(w.cfg, w.dbPath)
	if w.onMounted != nil {
		w.onMounted(ext)
	}
	opts := claudeSessionOptions(w, ext)
	if w.claudeAI.mode.On {
		sink := newRegistrySink(buildToolRegistry(w.cfg, w.database), w.database, w.conv, w.warn)
		opts = withClaudeAI(opts, w, ext, sink)
	}
	return chat.NewClaudeBackend(opts), nil
}

// newCodexChatBackend is stateless per turn: the backend replays the
// active path every turn. The MCP server reads the running turn from the
// turn file.
func newCodexChatBackend(w sessionWiring) (chat.Backend, error) {
	return chat.NewTurnBackend(codexSessionClient(w), w.database, w.conv.ID, chat.WithSystemPrompt(w.prompt)), nil
}

// newRuntimeBChatBackend is the ollama session's loop. Ollama ships no
// default model: without one every turn would fail as a retryable internal
// error, so the session refuses to start (provider_unavailable) with the
// fix in the message.
func newRuntimeBChatBackend(w sessionWiring) (chat.Backend, error) {
	if w.model == "" {
		return nil, errors.New("no Ollama model is configured: pick one in Settings → AI")
	}
	return chat.NewTurnBackend(runtimeBSessionClient(w), w.database, w.conv.ID, chat.WithSystemPrompt(w.prompt)), nil
}

// codexSessionClient is the codex chat session's client: only the
// watchtower server and the enabled Quick Connections — the owner's own
// codex MCP servers are disabled per launch (board #594). Connections load
// per turn on the session's open database: each turn is a new codex
// launch, so OAuth tokens are refreshed as for claude (QC-04); tools are
// re-listed only when the cache needs it (mountConnection). A connection a
// launch cannot mount says so on its row (markCodexSkipped). The session's
// surfaces are main and target only, never automation_editor (D11). Stop
// and close cancel the turn: the whole process group goes (ai.ConfigureChild).
// The session alone searches the web, as only the Claude session unhides
// WebSearch (ask #533; the prompt reads the capability row).
func codexSessionClient(w sessionWiring) *codex.Client {
	c := codex.NewClient(w.model, w.dbPath, w.cfg.CodexPath)
	c.SetMCPArgs(w.mcpArgs)
	c.SetWebSearch()
	c.SetExternalMCPLoader(func() []ai.ExternalMCPServer {
		return loadExternalMCPServersFrom(w.cfg, w.database, os.Environ()) // the codex child's environment
	})
	// Live Slack: the chat alone keeps codex apps on, read-only, for a ChatGPT
	// login whose probe found the Slack app (codexSlackConnector).
	if len(w.codexSlack) > 0 {
		c.SetChatApps(w.codexSlack)
	}
	// CHAT-04 (spec §9): the client always routes the system prompt and
	// replayed history through stdin, never this process's argv.
	return c
}

// runtimeBSessionClient is the ollama chat session's loop (runtime B): the
// registry runs in-process and proposals bind to the running turn through
// the turn file. The enabled Quick Connections load per turn on the
// session's open database, as for codex (QC-04 refresh; the QC-02 allowed
// list and the organization's policy applied by loadExternalMCPServersFrom);
// the session's surfaces are main and target only, never automation_editor
// (D11).
func runtimeBSessionClient(w sessionWiring) *agentloop.Client {
	loop := agentloop.NewClient(w.model, w.cfg.AI.OllamaURL, buildToolRegistry(w.cfg, w.database), sessionToolBinding(w))
	loop.SetExternalMCPLoader(func() []ai.ExternalMCPServer {
		return loadExternalMCPServersFrom(w.cfg, w.database, nil)
	})
	return loop
}

// newRuntimeBQuerier is `ai query --tools chat` on a provider with no MCP
// child: the in-process tool loop over reg, with the owner's Quick
// Connections ext (nil on the automation editor).
func newRuntimeBQuerier(cfg *config.Config, model string, reg *tools.Registry, binding tools.Binding, ext []ai.ExternalMCPServer, toolEvents bool) ai.Provider {
	loop := agentloop.NewClient(model, cfg.AI.OllamaURL, reg, binding)
	if ext != nil {
		loop.SetExternalMCPServers(ext)
	}
	if toolEvents {
		loop.EmitToolEvents()
	}
	return loop
}

// agentClientWiring is what one agent() child is built from.
type agentClientWiring struct {
	cfg     *config.Config
	dbPath  string
	model   string
	mcpArgs []string
	env     []string // the child's whole environment (automationAgentEnv)
	tools   []string // the effective watchtower tools
}

// newClaudeAgentClient narrows --allowedTools to the effective set plus
// get_action and caps the run with --max-turns.
func newClaudeAgentClient(a agentClientWiring) (ai.Provider, func(), error) {
	c := ai.NewClient(a.model, a.dbPath, a.cfg.ClaudePath)
	c.SetMCPArgs(a.mcpArgs)
	c.SetWatchtowerTools(append(slices.Clone(a.tools), "get_action"))
	c.SetMaxTurns(automationAgentMaxTurns)
	c.SetChildEnv(a.env)
	return c, func() {}, nil
}

// newCodexAgentClient runs codex in a scrubbed per-run CODEX_HOME
// (codexAgentHome) that joins the env allowlist instead of ~/.codex; the
// run's rollout is written there and counted for the turn cap (AUTO-08),
// and goes with the home (the returned cleanup).
func newCodexAgentClient(a agentClientWiring) (ai.Provider, func(), error) {
	home, removeHome, err := codexAgentHome(a.dbPath, a.mcpArgs)
	if err != nil {
		return nil, nil, err
	}
	c := codex.NewClient(a.model, a.dbPath, a.cfg.CodexPath)
	c.SetMCPArgs(a.mcpArgs)
	c.SetMCPEnvVars(codexAgentServerEnv)
	c.SetChildEnv(a.env)
	c.SetRunHome(home)
	c.SetServersFromHome()
	c.SetMaxTurns(automationAgentMaxTurns)
	return c, removeHome, nil
}

// specReviewReadFolder runs the reviewer as a read-folder child of the
// configured provider (claude or codex; the caller checked the capability)
// and returns its answer. The error is already labelled for the caller.
func specReviewReadFolder(ctx context.Context, cfg *config.Config, model, folder, system, user string) (string, error) {
	if providers.ByID(cfg.AI.Provider).ID == "codex" {
		home, removeHome, err := specReviewCodexHome()
		if err != nil {
			return "", wrapSpecReviewErr("codex reviewer", err)
		}
		defer removeHome()
		out, _, err := specReviewCodexClient(cfg, model, folder, home).QuerySync(ctx, system, user, "")
		return out, wrapSpecReviewErr("codex reviewer", err)
	}
	out, _, err := specReviewClaudeClient(cfg, model, folder).QuerySync(ctx, system, user, "")
	return out, wrapSpecReviewErr("claude reviewer", err)
}

// specReviewClaudeClient: no database path, so no --mcp-config; with
// --strict-mcp-config claude then mounts no server.
func specReviewClaudeClient(cfg *config.Config, model, folder string) *ai.Client {
	c := ai.NewClient(model, "", cfg.ClaudePath)
	c.SetReadFolder(folder)
	c.SetMaxTurns(specreview.MaxTurns)
	return c
}

// specReviewCodexClient: SetNoMCPServers disables the owner's codex servers
// and mounts none (an empty database path alone would leave them on). The
// run is capped at specreview.MaxTurns model turns, as claude's --max-turns
// caps the claude reviewer (SPECREVIEW-01, AUTO-08's turn unit): counted
// from its rollout in home (specReviewCodexHome), or by the stream rule in
// the owner's home, --ephemeral, when home is "".
func specReviewCodexClient(cfg *config.Config, model, folder, home string) *codex.Client {
	c := codex.NewClient(model, "", cfg.CodexPath)
	c.SetReadFolder(folder)
	c.SetNoMCPServers()
	if home != "" {
		c.SetRunHome(home)
	}
	c.SetMaxTurns(specreview.MaxTurns)
	return c
}

// runConnectionProbe sends the test request. Codex gets a system prompt
// naming a fresh nonce, so the probe goes through the system-prompt path
// every codex call uses (the model_instructions_file, or stdin on a codex
// too old for one): an answer without the nonce means the prompt never
// reached the model and fails as invalid_output, with a content-free stderr
// line. Claude and Ollama keep the bare request. Both calls carry the
// "probe" source (TierForSource).
func runConnectionProbe(ctx context.Context, provider string, gen digest.Generator) error {
	probeCtx := digest.WithSource(ctx, "probe")
	if providers.ByID(provider).ID != "codex" {
		_, _, _, err := gen.Generate(probeCtx, "", "respond with exactly: OK", "")
		return err
	}
	nonce := "wt-probe-" + rand.Text()
	text, _, _, err := gen.Generate(probeCtx, "You are a connection test. Reply with exactly this word and nothing else: "+nonce, "Reply now.", "")
	if err != nil {
		return err
	}
	// Case-insensitive: a model that lowercases the nonce still saw it.
	if !strings.Contains(strings.ToLower(text), strings.ToLower(nonce)) {
		stderrLogf("ai test: the codex answer (%d chars) lacks the system prompt's nonce", len(text))
		return providers.WithFailure("codex", providers.InvalidOutput, errProbeNonceMissing)
	}
	return nil
}

// errProbeNonceMissing is the codex probe's answer without its nonce: codex
// ran, but the system prompt did not reach the model.
var errProbeNonceMissing = errors.New("the answer lacks the system prompt's nonce")
