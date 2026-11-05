package agentloop

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"regexp"
	"slices"
	"strings"
	"time"

	"watchtower/internal/ai"
	"watchtower/internal/externalmcp"
	"watchtower/internal/logredact"
	"watchtower/internal/policy"
)

// Quick Connections in runtime B (QC-01..04, spec 2026-11-05 §3.3): the
// owner's external MCP servers, loaded by the caller exactly as for claude
// and codex (credentials, OAuth refresh, the QC-02 allowed list, the
// organization's policy), are offered to the model as tools named
// mcp__<server>__<tool>. Only a server's AllowTools are offered — its other
// tools, and any tool added after the last listing, never are, because this
// loop has no approval prompt. A call goes through externalmcp.CallTool and
// is a visible step like a registry tool. Secrets stay in the server spec
// (env for stdio, headers for http) and never reach an argv (QC-03).
//
// A client runs one turn at a time (the session's turn backend and a
// one-shot query both wait for a turn to end), so the loader and the
// listing cache need no lock.

const (
	// externalListTimeout bounds one server's tools/list at turn start, as
	// a chat launch waits for claude and codex.
	externalListTimeout = 10 * time.Second
	// externalListRetryAfter is how long a server whose listing failed stays
	// unmounted before a later turn lists it again, so a dead server does not
	// cost every turn a listing timeout.
	externalListRetryAfter = 5 * time.Minute
	// externalCallTimeout bounds one external tool call.
	externalCallTimeout = 2 * time.Minute
)

// functionName is what OpenAI-compatible servers accept as a function name;
// a strict one (vLLM, LM Studio) refuses the whole request otherwise.
var functionName = regexp.MustCompile(`^[a-zA-Z0-9_-]{1,64}$`)

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

// externalListing is one server's cached tools/list: the tools, or the
// failure and when it happened.
type externalListing struct {
	defs     []externalmcp.ToolDef
	failedAt time.Time // zero = listed
}

// SetExternalMCPServers mounts servers for every later turn (`ai query
// --tools chat`, one turn per process).
func (c *Client) SetExternalMCPServers(servers []ai.ExternalMCPServer) {
	c.SetExternalMCPLoader(func() []ai.ExternalMCPServer { return servers })
}

// SetExternalMCPLoader makes every turn load its servers from load (the
// chat session: each turn refreshes OAuth tokens, QC-04, as each codex
// launch does).
func (c *Client) SetExternalMCPLoader(load func() []ai.ExternalMCPServer) { c.extLoader = load }

// ExternalServersForTest returns what the loader hands a turn. It runs the
// loader, which in cmd opens the database and may refresh OAuth grants.
func (c *Client) ExternalServersForTest() []ai.ExternalMCPServer {
	if c.extLoader == nil {
		return nil
	}
	return c.extLoader()
}

// mountExternal loads this turn's servers and the tools each offers. A
// server the policy forbids, or one that cannot be listed, mounts nothing;
// the turn runs without it.
func (c *Client) mountExternal(ctx context.Context) mountedExternal {
	m := mountedExternal{tools: map[string]externalTool{}}
	// A gated loop (an automation's agent()) has its tools decided by its
	// manifest, and Options.Gate covers registry tools only: it is never
	// given Quick Connections, whatever a caller set.
	if c.extLoader == nil || c.opts.Gate != nil {
		return m
	}
	for _, s := range c.extLoader() {
		if externalmcp.ReservedName(s.Name) {
			log.Printf("runtime B: Quick Connection %d not mounted: reserved name", s.ID)
			continue
		}
		if !policy.Current().ConnectionAllowed(s.Kind, s.URL, s.Command) {
			log.Printf("runtime B: Quick Connection %d not mounted: not allowed by the organization's policy", s.ID)
			continue
		}
		defs, err := c.externalDefs(ctx, s)
		if err != nil {
			if ctx.Err() == nil {
				log.Printf("runtime B: Quick Connection %d not mounted: %v", s.ID, err)
			}
			continue
		}
		offered := false
		for _, d := range defs {
			name := "mcp__" + s.Name + "__" + d.Tool.Name
			// The fresh listing can mark a tool a write after the cached
			// allowed list was resolved: a write is never offered (QC-02).
			if !slices.Contains(s.AllowTools, d.Tool.Name) || externalmcp.IsAnnotatedWrite(d.Tool) ||
				(c.allowed != nil && !c.allowed[name]) {
				continue
			}
			if !functionName.MatchString(name) {
				log.Printf("runtime B: Quick Connection %d: a tool skipped, its name is not a valid function name", s.ID)
				continue
			}
			// Names may contain "__", so two server/tool pairs can render the
			// same name: the first keeps it, and a call never reaches the other.
			if _, dup := m.tools[name]; dup {
				log.Printf("runtime B: Quick Connection %d: a tool skipped, its name is taken by another connection's tool", s.ID)
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
// session lists each server once, and again when the connection's transport
// or allowed list changes). A failed listing is remembered for
// externalListRetryAfter; its error is fingerprinted (FILES-01).
func (c *Client) externalDefs(ctx context.Context, s ai.ExternalMCPServer) ([]externalmcp.ToolDef, error) {
	allow := slices.Sorted(slices.Values(s.AllowTools))
	key := fmt.Sprintf("%d/%s/%s/%s/%s/%s/%s", s.ID, s.Name, s.Kind, s.URL, s.Command,
		strings.Join(s.Args, "\x00"), strings.Join(allow, "\x00"))
	if l, ok := c.extListings[key]; ok {
		if l.failedAt.IsZero() {
			return l.defs, nil
		}
		if time.Since(l.failedAt) < externalListRetryAfter {
			return nil, errors.New("its last listing failed; retried after five minutes")
		}
	}
	lctx, cancel := context.WithTimeout(ctx, externalListTimeout)
	defer cancel()
	defs, err := externalmcp.ListToolDefs(lctx, serverSpec(s))
	if c.extListings == nil {
		c.extListings = map[string]externalListing{}
	}
	if err != nil {
		if ctx.Err() == nil { // a cancelled turn says nothing about the server
			c.extListings[key] = externalListing{failedAt: time.Now()}
		}
		return nil, logredact.Errorf("listing its tools (%s): %s", errorClass(err), logredact.Text(err.Error()))
	}
	c.extListings[key] = externalListing{defs: defs}
	return defs, nil
}

// errorClass is a content-free word for an external failure, for a log line
// that shows only a fingerprint of the text.
func errorClass(err error) string {
	switch {
	case errors.Is(err, context.DeadlineExceeded):
		return "timeout"
	case errors.Is(err, context.Canceled):
		return "cancelled"
	}
	return "error"
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
			return errJSON(toolErr.Message) // the tool's own answer
		}
		log.Printf("runtime B: Quick Connection %d call failed: %v", t.server.ID,
			logredact.Errorf("%s: %s", errorClass(err), logredact.Text(err.Error())))
		return errJSON(fmt.Sprintf("calling %s on %s failed (%s)", t.tool, t.server.Name, errorClass(err)))
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
