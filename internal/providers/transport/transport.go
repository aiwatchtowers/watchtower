// Package transport is the one client factory (spec 2026-11-05 §3.4): a
// row per registry provider whose constructors take an Options struct, so
// a caller states what it needs up front instead of probing a client for
// optional setters. It is an adapter package (LLMTRANSPORT-01): it may name
// the transports, and it imports the adapter packages to build their
// clients. It lives under internal/providers, not in it, because every
// adapter imports internal/providers. The constructors that need the cmd
// wiring (chat backends, the automation agent() runner) are in
// cmd/transport_wiring.go.
package transport

import (
	"watchtower/internal/ai"
	"watchtower/internal/codex"
	"watchtower/internal/config"
	"watchtower/internal/digest"
	"watchtower/internal/ollama"
	"watchtower/internal/providers"
)

// Options is what a caller asks of a constructed client. A transport that
// cannot honour a field ignores it; the caller checks the row's Caps first
// (an ollama querier has no MCP child, no file tools and no child process).
type Options struct {
	// Config gives the binary paths, the Ollama URL and, with Model "",
	// the models (providers.ResolveModelsFor).
	Config *config.Config
	// DBPath is the database the watchtower MCP server child reads; "" =
	// no server.
	DBPath string
	// Model overrides the resolved model: a querier's model, both tiers of
	// a generator. "" = resolved (a querier gets the strong tier).
	Model string
	// MCPArgs are the extra flags of the watchtower MCP server child
	// (chat mode).
	MCPArgs []string
	// ExternalMCP are the owner's Quick Connections mounted beside the
	// watchtower server; nil = none.
	ExternalMCP []ai.ExternalMCPServer
	// ReadFolder makes the run a read-only look at that folder.
	ReadFolder string
	// ToolEvents switches Query onto the protocol-v2 chat events.
	ToolEvents bool
	// IsolatedChild runs a generator's child through digest.IsolateChild.
	IsolatedChild bool
}

// Transport is one provider's row: its capabilities and its constructors.
type Transport struct {
	ID           string
	Caps         providers.Capabilities
	NewGenerator func(Options) digest.Generator
	NewQuerier   func(Options) ai.Provider
}

// For is the row of provider id. An unknown or empty id is the default
// provider's row, as providers.ByID resolves it; a registry provider with
// no case here is a bug, which panics rather than run another transport.
func For(id string) Transport {
	p := providers.ByID(id)
	t := Transport{ID: p.ID, Caps: p.Caps}
	switch p.ID {
	case "claude":
		t.NewGenerator, t.NewQuerier = newClaudeGenerator, newClaudeQuerier
	case "codex":
		t.NewGenerator, t.NewQuerier = newCodexGenerator, newCodexQuerier
	case "ollama":
		t.NewGenerator, t.NewQuerier = newOllamaGenerator, newOllamaQuerier
	default:
		panic("transport: no constructors for provider " + p.ID)
	}
	return t
}

// models is the generator's light and strong model under o.
func (o Options) models(id string) (light, strong string) {
	if o.Model != "" {
		return o.Model, o.Model
	}
	return providers.ResolveModelsFor(o.Config, id)
}

// model is the querier's model under o.
func (o Options) model(id string) string {
	if o.Model != "" {
		return o.Model
	}
	_, strong := providers.ResolveModelsFor(o.Config, id)
	return strong
}

func newClaudeGenerator(o Options) digest.Generator {
	light, strong := o.models("claude")
	g := digest.NewClaudeGenerator(light, strong, o.Config.ClaudePath)
	if o.IsolatedChild {
		g.SetIsolatedChild()
	}
	return g
}

func newCodexGenerator(o Options) digest.Generator {
	light, strong := o.models("codex")
	g := codex.NewCodexGenerator(light, strong, o.Config.CodexPath)
	if o.IsolatedChild {
		g.SetIsolatedChild()
	}
	return g
}

// newOllamaGenerator: an HTTP call has no child to isolate.
func newOllamaGenerator(o Options) digest.Generator {
	light, strong := o.models("ollama")
	return ollama.NewGenerator(light, strong, o.Config.AI.OllamaURL)
}

func newClaudeQuerier(o Options) ai.Provider {
	c := ai.NewClient(o.model("claude"), o.DBPath, o.Config.ClaudePath)
	c.SetMCPArgs(o.MCPArgs)
	if o.ExternalMCP != nil {
		c.SetExternalMCPServers(o.ExternalMCP)
	}
	if o.ReadFolder != "" {
		c.SetReadFolder(o.ReadFolder)
	}
	if o.ToolEvents {
		c.EmitToolEvents()
	}
	return c
}

func newCodexQuerier(o Options) ai.Provider {
	c := codex.NewClient(o.model("codex"), o.DBPath, o.Config.CodexPath)
	c.SetMCPArgs(o.MCPArgs)
	if o.ExternalMCP != nil {
		c.SetExternalMCPServers(o.ExternalMCP)
	}
	if o.ReadFolder != "" {
		c.SetReadFolder(o.ReadFolder)
	}
	if o.ToolEvents {
		c.EmitToolEvents()
	}
	return c
}

// newOllamaQuerier is the plain HTTP client: no tools, no folder, no child
// (the tool-bearing ollama chat is the runtime-B loop, built in cmd).
func newOllamaQuerier(o Options) ai.Provider {
	c := ollama.NewClient(o.model("ollama"), o.Config.AI.OllamaURL)
	if o.ToolEvents {
		c.EmitToolEvents()
	}
	return c
}
