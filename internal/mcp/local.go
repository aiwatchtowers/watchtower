package mcp

import (
	"context"
	"fmt"
	"sort"
	"strings"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"
)

// LocalSession is an in-process MCP client connected to a Server over an
// in-memory transport. It backs the `watchtower tools` CLI commands: the same
// read-only tools the MCP server exposes to LLM clients, callable from the
// console with identical validation and output, no stdio subprocess involved.
type LocalSession struct {
	client *mcpsdk.ClientSession
	server *mcpsdk.ServerSession
}

// ConnectLocal wires the server to an in-process client and returns the
// connected session. The caller must Close it.
func (srv *Server) ConnectLocal(ctx context.Context) (*LocalSession, error) {
	clientTransport, serverTransport := mcpsdk.NewInMemoryTransports()
	ss, err := srv.s.Connect(ctx, serverTransport, nil)
	if err != nil {
		return nil, fmt.Errorf("connecting server side: %w", err)
	}
	client := mcpsdk.NewClient(&mcpsdk.Implementation{
		Name:    "watchtower-cli",
		Title:   "Watchtower CLI",
		Version: version,
	}, nil)
	cs, err := client.Connect(ctx, clientTransport, nil)
	if err != nil {
		_ = ss.Close()
		return nil, fmt.Errorf("connecting client side: %w", err)
	}
	return &LocalSession{client: cs, server: ss}, nil
}

// Close tears down both sides of the in-memory connection.
func (ls *LocalSession) Close() error {
	err := ls.client.Close()
	_ = ls.server.Close()
	return err
}

// ToolArg describes one input argument of a tool, extracted from its JSON
// schema so CLI help always matches what the tool actually validates.
type ToolArg struct {
	Name        string
	Type        string // string | integer | number | boolean
	Description string
	Required    bool
}

// ToolInfo describes one registered tool.
type ToolInfo struct {
	Name        string
	Description string
	Args        []ToolArg
}

// Tools lists every registered tool with its arguments, sorted by name.
func (ls *LocalSession) Tools(ctx context.Context) ([]ToolInfo, error) {
	var out []ToolInfo
	cursor := ""
	for {
		res, err := ls.client.ListTools(ctx, &mcpsdk.ListToolsParams{Cursor: cursor})
		if err != nil {
			return nil, fmt.Errorf("listing tools: %w", err)
		}
		for _, t := range res.Tools {
			out = append(out, ToolInfo{
				Name:        t.Name,
				Description: t.Description,
				Args:        parseSchemaArgs(t.InputSchema),
			})
		}
		if res.NextCursor == "" {
			break
		}
		cursor = res.NextCursor
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}

// Call invokes a tool by name. It returns the concatenated text content and
// whether the tool reported a tool-level error (invalid argument, not found).
// A transport/protocol failure is returned as err instead.
func (ls *LocalSession) Call(ctx context.Context, name string, args map[string]any) (string, bool, error) {
	res, err := ls.client.CallTool(ctx, &mcpsdk.CallToolParams{Name: name, Arguments: args})
	if err != nil {
		return "", false, err
	}
	var b strings.Builder
	for _, c := range res.Content {
		if t, ok := c.(*mcpsdk.TextContent); ok {
			b.WriteString(t.Text)
		}
	}
	return b.String(), res.IsError, nil
}

// parseSchemaArgs extracts the flat argument list from a tool input schema as
// received on the client side (a map[string]any). All Watchtower tools take a
// flat object of scalar properties, so nested schemas are not handled.
func parseSchemaArgs(schema any) []ToolArg {
	m, ok := schema.(map[string]any)
	if !ok {
		return nil
	}
	required := map[string]bool{}
	if reqs, ok := m["required"].([]any); ok {
		for _, r := range reqs {
			if s, ok := r.(string); ok {
				required[s] = true
			}
		}
	}
	props, ok := m["properties"].(map[string]any)
	if !ok {
		return nil
	}
	args := make([]ToolArg, 0, len(props))
	for name, raw := range props {
		p, _ := raw.(map[string]any)
		a := ToolArg{Name: name, Required: required[name]}
		if t, ok := p["type"].(string); ok {
			a.Type = t
		}
		if d, ok := p["description"].(string); ok {
			a.Description = d
		}
		args = append(args, a)
	}
	sort.Slice(args, func(i, j int) bool { return args[i].Name < args[j].Name })
	return args
}
