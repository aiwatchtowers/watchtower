package agentloop

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"slices"
	"time"

	"watchtower/internal/ai"
	"watchtower/internal/externalmcp"
	"watchtower/internal/logredact"
	"watchtower/internal/policy"
)

// Quick Connections in runtime B (spec 2026-11-05 L8, QC-01..04): the
// owner's external MCP servers, loaded by the caller exactly as for claude
// and codex (credentials, OAuth refresh, the QC-02 allowed list, the
// organization's policy), are offered to the model as tools named
// mcp__<server>__<tool>. Only a server's AllowTools are offered — its other
// tools, and any tool added after the last listing, never are, because this
// loop has no approval prompt. A call goes through externalmcp.CallTool and
// is a visible step like a registry tool. Secrets stay in the server spec
// (env for stdio, headers for http) and never reach an argv (QC-03).

const (
	// externalListTimeout bounds one server's tools/list at turn start, as
	// a chat launch waits for claude and codex.
	externalListTimeout = 10 * time.Second
	// externalCallTimeout bounds one external tool call.
	externalCallTimeout = 2 * time.Minute
)

// externalTool is one offered Quick Connection tool.
type externalTool struct {
	server ai.ExternalMCPServer
	tool   string // the server's own tool name
}

// mountedExternal is what one run offers from the Quick Connections.
type mountedExternal struct {
	servers []ai.ExternalMCPServer  // the servers with at least one tool offered
	tools   map[string]externalTool // by offered name
	defs    []oaTool                // in server, then listing, order
}

// SetExternalMCPServers mounts servers for every later turn (`ai query
// --tools chat`, one turn per process).
func (c *Client) SetExternalMCPServers(servers []ai.ExternalMCPServer) {
	c.SetExternalMCPLoader(func() []ai.ExternalMCPServer { return servers })
}

// SetExternalMCPLoader makes every turn load its servers from load (the
// chat session: each turn refreshes OAuth tokens, QC-04, as each codex
// launch does).
func (c *Client) SetExternalMCPLoader(load func() []ai.ExternalMCPServer) {
	c.extMu.Lock()
	defer c.extMu.Unlock()
	c.extLoader = load
}

// ExternalServersForTest returns what the loader hands a turn.
func (c *Client) ExternalServersForTest() []ai.ExternalMCPServer {
	c.extMu.Lock()
	load := c.extLoader
	c.extMu.Unlock()
	if load == nil {
		return nil
	}
	return load()
}

// mountExternal loads this turn's servers and the tools each offers. A
// server the policy forbids, or one that cannot be listed, mounts nothing;
// the turn runs without it.
func (c *Client) mountExternal(ctx context.Context) mountedExternal {
	m := mountedExternal{tools: map[string]externalTool{}}
	c.extMu.Lock()
	load := c.extLoader
	c.extMu.Unlock()
	// A gated loop (an automation's agent()) has its tools decided by its
	// manifest, and Options.Gate covers registry tools only: it is never
	// given Quick Connections, whatever a caller set.
	if load == nil || c.opts.Gate != nil {
		return m
	}
	for _, s := range load() {
		if externalmcp.ReservedName(s.Name) || !policy.Current().ConnectionAllowed(s.Kind, s.URL, s.Command) {
			log.Printf("runtime B: Quick Connection %d not mounted: not allowed", s.ID)
			continue
		}
		defs, err := c.externalDefs(ctx, s)
		if err != nil {
			log.Printf("runtime B: Quick Connection %d not mounted: %v", s.ID,
				logredact.Errorf("listing its tools: %s", logredact.Text(err.Error())))
			continue
		}
		offered := false
		for _, d := range defs {
			name := "mcp__" + s.Name + "__" + d.Tool.Name
			if !slices.Contains(s.AllowTools, d.Tool.Name) || (c.allowed != nil && !c.allowed[name]) {
				continue
			}
			params := d.InputSchema
			if params == nil {
				params = json.RawMessage(`{"type":"object"}`)
			}
			m.tools[name] = externalTool{server: s, tool: d.Tool.Name}
			m.defs = append(m.defs, oaTool{Type: "function", Function: oaToolDef{
				Name: name, Description: fmt.Sprintf("[Quick Connection %s] %s", s.Name, d.Description), Parameters: params,
			}})
			offered = true
		}
		if offered {
			m.servers = append(m.servers, s)
		}
	}
	return m
}

// externalDefs is s's tool listing, cached for the client's life (a chat
// session lists each server once); a failed listing is not cached.
func (c *Client) externalDefs(ctx context.Context, s ai.ExternalMCPServer) ([]externalmcp.ToolDef, error) {
	key := fmt.Sprintf("%d/%s/%s/%s/%s", s.ID, s.Name, s.Kind, s.URL, s.Command)
	c.extMu.Lock()
	defs, ok := c.extDefs[key]
	c.extMu.Unlock()
	if ok {
		return defs, nil
	}
	lctx, cancel := context.WithTimeout(ctx, externalListTimeout)
	defer cancel()
	defs, err := externalmcp.ListToolDefs(lctx, serverSpec(s))
	if err != nil {
		return nil, err
	}
	c.extMu.Lock()
	if c.extDefs == nil {
		c.extDefs = map[string][]externalmcp.ToolDef{}
	}
	c.extDefs[key] = defs
	c.extMu.Unlock()
	return defs, nil
}

// callExternal runs one offered Quick Connection tool and returns the
// tool-result message: the server's result, or an error JSON fed back to
// the model (a tool's own failure, an unreachable server).
func (c *Client) callExternal(ctx context.Context, t externalTool, args json.RawMessage) string {
	ctx, cancel := context.WithTimeout(ctx, externalCallTimeout)
	defer cancel()
	if len(args) == 0 {
		args = nil
	}
	out, err := externalmcp.CallTool(ctx, serverSpec(t.server), t.tool, args)
	if err != nil {
		var toolErr *externalmcp.ToolError
		if errors.As(err, &toolErr) {
			return errJSON(toolErr.Message)
		}
		return errJSON(fmt.Sprintf("calling %s on %s: %v", t.tool, t.server.Name, err))
	}
	if c.opts.ResultCheck != nil {
		if err := c.opts.ResultCheck(out); err != nil {
			return errJSON(err.Error())
		}
	}
	return string(out)
}

// serverSpec is how externalmcp reaches s: its transport and credentials.
func serverSpec(s ai.ExternalMCPServer) externalmcp.ServerSpec {
	return externalmcp.ServerSpec{Kind: s.Kind, Command: s.Command, Args: s.Args, URL: s.URL,
		Env: s.Env, Headers: s.Headers}
}
