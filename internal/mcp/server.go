// Package mcp implements a read-only Model Context Protocol server that
// exposes Watchtower's curated product data to MCP clients. Every registered
// tool is read-only; no tool mutates the database.
package mcp

import (
	"context"
	"encoding/json"
	"fmt"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
)

// version is reported to MCP clients in the server handshake.
const version = "0.1.0"

// defaultListLimit caps list_ tools that the caller left unbounded, so a single
// tool call cannot dump an entire table into an LLM context window.
const defaultListLimit = 50

// listLimit applies defaultListLimit when the caller passed 0 (unbounded).
func listLimit(n int) int {
	if n <= 0 {
		return defaultListLimit
	}
	return n
}

// Server wraps the SDK server so callers (cmd, tests) do not import the SDK.
type Server struct {
	s *mcpsdk.Server
}

// NewServer builds an MCP server over the given database and registers every
// read-only domain tool.
func NewServer(database *db.DB) *Server {
	s := mcpsdk.NewServer(&mcpsdk.Implementation{
		Name:    "watchtower",
		Title:   "Watchtower",
		Version: version,
	}, nil)

	registerTargets(s, database)
	registerDigests(s, database)
	registerPeople(s, database)
	registerJira(s, database)

	return &Server{s: s}
}

// ServeStdio runs the server over stdio until the context is cancelled or the
// client disconnects.
func (srv *Server) ServeStdio(ctx context.Context) error {
	return srv.s.Run(ctx, &mcpsdk.StdioTransport{})
}

// jsonResult marshals v to indented JSON and returns it as text content.
func jsonResult(v any) (*mcpsdk.CallToolResult, any, error) {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return errResult(fmt.Sprintf("marshaling result: %v", err)), nil, nil
	}
	return &mcpsdk.CallToolResult{
		Content: []mcpsdk.Content{&mcpsdk.TextContent{Text: string(b)}},
	}, nil, nil
}

// jsonListResult marshals a list, rendering a nil/empty slice as [] (not null)
// so list_ tools always return a JSON array.
func jsonListResult[T any](items []T) (*mcpsdk.CallToolResult, any, error) {
	if items == nil {
		items = []T{}
	}
	return jsonResult(items)
}

// errResult builds a tool-level error result with a human-readable message.
func errResult(msg string) *mcpsdk.CallToolResult {
	return &mcpsdk.CallToolResult{
		IsError: true,
		Content: []mcpsdk.Content{&mcpsdk.TextContent{Text: msg}},
	}
}

// itoa avoids importing strconv in every tool file.
func itoa(n int) string { return fmt.Sprintf("%d", n) }
