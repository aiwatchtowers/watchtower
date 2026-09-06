// Package mcp implements a read-only Model Context Protocol server that
// exposes Watchtower's curated product data to MCP clients. Every registered
// tool is a read surface; the deliberate writes are memory_open's best-effort
// usage-stats bump (telemetry, not domain data) and, when
// WithMemoryRetrieveCompare is supplied, memory_recall's dark retrieval-
// compare shadow row (also telemetry — Slice B Task 8, memory_retrieve_shadow
// only, never the tool's own response).
package mcp

import (
	"context"
	"encoding/json"
	"fmt"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
	"watchtower/internal/tools"
)

// version is reported to MCP clients in the server handshake.
const version = "0.1.0"

// maxListLimit caps a memory tool's explicit request so a single call can never
// dump an entire table into an LLM context window. (The migrated read tools
// carry their own clamp in internal/tools/limit.go; only memory.go still uses
// this one.)
const maxListLimit = 200

// Server wraps the SDK server so callers (cmd, tests) do not import the SDK.
type Server struct {
	s *mcpsdk.Server

	// memoryVaultPath is the workspace memory vault directory; empty when
	// memory is disabled — the memory_ tools then answer "not initialized".
	memoryVaultPath string

	// retrieveShadowDB is a SEPARATE, ordinarily-writable *db.DB handle used
	// ONLY for memory_recall's dark retrieval-compare shadow write (Slice B
	// Task 8). The server's main `database` handle is deliberately
	// PRAGMA query_only=ON at the call sites (cmd/mcp.go, cmd/tools.go) so
	// no tool handler can write; this field is the one narrow, explicit
	// exception, threaded in only when memory.retrieve.recall_compare is on.
	// nil means the flag is off — memory_recall behaves byte-identically to
	// before this field existed.
	retrieveShadowDB *db.DB

	// skillsDir is the workspace persona-skills directory
	// (WorkspaceDir()/skills); empty when no workspace was resolved — the
	// load_skill tool then reports skills as unavailable.
	skillsDir string

	// registry sources the assistant's tools. Both modes have one: dev mode
	// passes none, so NewServer builds a read-only registry (NewReadRegistry) and
	// leaves mountWrites false — only read tools mount; chat mode (WithRegistry)
	// sets it with the write tools + get_action and mountWrites true, stamping
	// proposals with the binding. mountWrites is the switch — false on the dev
	// surface, so it never sees a write tool (AGENT-02).
	registry    *tools.Registry
	binding     tools.Binding
	mountWrites bool
}

// ServerOption customizes NewServer additively, so existing call sites keep
// compiling as new dependencies are introduced.
type ServerOption func(*Server)

// WithMemoryVault points the memory_ tools at the workspace memory vault
// directory (WorkspaceDir()/memory). Callers pass it only when memory is
// enabled; without it the tools report memory as not initialized.
func WithMemoryVault(path string) ServerOption {
	return func(srv *Server) { srv.memoryVaultPath = path }
}

// WithMemoryRetrieveCompare enables memory_recall's dark retrieval-compare
// mode (Slice B Task 8, memory.retrieve.recall_compare): shadowDB must be an
// ordinarily-writable *db.DB (NOT the server's read-only main handle) used
// exclusively for the one memory_retrieve_shadow insert per call. Absent
// (nil) or never called, memory_recall never touches that table.
func WithMemoryRetrieveCompare(shadowDB *db.DB) ServerOption {
	return func(srv *Server) { srv.retrieveShadowDB = shadowDB }
}

// WithSkillsDir points load_skill at the workspace persona-skills directory
// (skills.Dir(WorkspaceDir())). Without it the tool is still registered — the
// tool set must not vary between sessions — but reports skills as unavailable.
func WithSkillsDir(path string) ServerOption {
	return func(srv *Server) { srv.skillsDir = path }
}

// NewServer builds an MCP server over the given database and registers every
// domain tool.
func NewServer(database *db.DB, opts ...ServerOption) *Server {
	srv := &Server{s: mcpsdk.NewServer(&mcpsdk.Implementation{
		Name:    "watchtower",
		Title:   "Watchtower",
		Version: version,
	}, nil)}
	for _, opt := range opts {
		opt(srv)
	}
	// Dev mode supplies no registry: build the read-only one so the migrated
	// read tools mount. Chat mode's WithRegistry already set a registry (with
	// write tools) and mountWrites=true. Either way the migrated reads dispatch
	// through the registry, not a per-domain handler.
	if srv.registry == nil {
		srv.registry = tools.NewReadRegistry(database)
	}

	registerMemory(srv.s, database, srv.memoryVaultPath, srv.retrieveShadowDB)
	registerSkills(srv.s, srv.skillsDir)
	// Every pure-db read tool now lives in the registry (tools.ReadTools) and
	// mounts from here instead of a per-domain register* handler — the registry
	// is the single source both server modes and the runtime-B loop share.
	// mountWrites gates the write tools + get_action to chat mode.
	registerRegistry(srv.s, database, srv.registry, srv.binding, srv.mountWrites)

	return srv
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
