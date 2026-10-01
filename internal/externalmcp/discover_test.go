package externalmcp

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// TestListTools_HTTP lists a real (in-process) streamable-HTTP MCP server:
// every tool comes back with its annotations, and the connection's headers
// reach the server on every request.
func TestListTools_HTTP(t *testing.T) {
	server := mcp.NewServer(&mcp.Implementation{Name: "fake", Version: "1"}, nil)
	noop := func(context.Context, *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		return &mcp.CallToolResult{}, nil
	}
	schema := map[string]any{"type": "object"}
	server.AddTool(&mcp.Tool{Name: "getIssue", InputSchema: schema}, noop)
	server.AddTool(&mcp.Tool{Name: "createIssue", InputSchema: schema,
		Annotations: &mcp.ToolAnnotations{Title: "Create"}}, noop)
	server.AddTool(&mcp.Tool{Name: "summarize", InputSchema: schema,
		Annotations: &mcp.ToolAnnotations{ReadOnlyHint: true}}, noop)

	var missingAuth atomic.Int32
	handler := mcp.NewStreamableHTTPHandler(func(*http.Request) *mcp.Server { return server }, nil)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer tok" {
			missingAuth.Add(1)
		}
		handler.ServeHTTP(w, r)
	}))
	t.Cleanup(srv.Close)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	tools, err := ListTools(ctx, ServerSpec{Kind: "http", URL: srv.URL,
		Headers: map[string]string{"Authorization": "Bearer tok"}})
	require.NoError(t, err)

	byName := map[string]db.ExternalTool{}
	for _, tool := range tools {
		byName[tool.Name] = tool
	}
	assert.Equal(t, db.ExternalTool{Name: "getIssue"}, byName["getIssue"])
	assert.Equal(t, db.ExternalTool{Name: "createIssue", Annotated: true}, byName["createIssue"])
	assert.Equal(t, db.ExternalTool{Name: "summarize", Annotated: true, ReadOnlyHint: true}, byName["summarize"])
	assert.Len(t, tools, 3)
	assert.Zero(t, missingAuth.Load(), "every request must carry the connection's headers")
}

func TestListTools_UnreachableServerFails(t *testing.T) {
	srv := httptest.NewServer(http.NotFoundHandler())
	t.Cleanup(srv.Close)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_, err := ListTools(ctx, ServerSpec{Kind: "http", URL: srv.URL})
	require.Error(t, err)
}

func TestListTools_UnknownKind(t *testing.T) {
	_, err := ListTools(context.Background(), ServerSpec{Kind: "ftp"})
	require.ErrorContains(t, err, "unknown connection kind")
}

// TestListTools_Stdio starts a stdio server (this test binary, re-executed),
// passes the connection's env to it, and stops it before returning.
func TestListTools_Stdio(t *testing.T) {
	exe, err := os.Executable()
	require.NoError(t, err)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	tools, err := ListTools(ctx, ServerSpec{Kind: "stdio", Command: exe,
		Env: map[string]string{fakeStdioServerEnv: "1"}})
	require.NoError(t, err)
	assert.Equal(t, []db.ExternalTool{{Name: "list_things"}}, tools)
}

// TestListTools_StdioStartupFailureQuotesStderr: a server that dies at
// startup fails the listing with its own stderr in the error.
func TestListTools_StdioStartupFailureQuotesStderr(t *testing.T) {
	exe, err := os.Executable()
	require.NoError(t, err)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	_, err = ListTools(ctx, ServerSpec{Kind: "stdio", Command: exe,
		Env: map[string]string{fakeStdioServerEnv: "fail"}})
	require.ErrorContains(t, err, "missing API key")
}

func TestLookPathIn(t *testing.T) {
	dir := t.TempDir()
	bin := filepath.Join(dir, "fake-mcp")
	require.NoError(t, os.WriteFile(bin, []byte("#!/bin/sh\n"), 0o755))
	assert.Equal(t, bin, lookPathIn("fake-mcp", "/nonexistent:"+dir))
	assert.Equal(t, "fake-mcp", lookPathIn("fake-mcp", "/nonexistent"), "not found: left for exec to report")
	assert.Equal(t, "./x/fake-mcp", lookPathIn("./x/fake-mcp", dir), "a path is used as given")
}
