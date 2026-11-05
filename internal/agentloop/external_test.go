package agentloop

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/ai"
	"watchtower/internal/policy"
	"watchtower/internal/policy/policytest"
	"watchtower/internal/tools"
)

// fakeMCP is a Quick Connection over streamable HTTP with a read tool
// (get_issue) and a write tool (create_issue); it records every call.
type fakeMCP struct {
	url   string
	mu    sync.Mutex
	calls []string
	args  []string
}

func newFakeMCP(t *testing.T) *fakeMCP {
	t.Helper()
	f := &fakeMCP{}
	server := mcp.NewServer(&mcp.Implementation{Name: "fake", Version: "1"}, nil)
	record := func(name string) mcp.ToolHandler {
		return func(_ context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			f.mu.Lock()
			f.calls = append(f.calls, name)
			f.args = append(f.args, string(req.Params.Arguments))
			f.mu.Unlock()
			return &mcp.CallToolResult{StructuredContent: map[string]any{"key": "PAY-1", "status": "open"}}, nil
		}
	}
	server.AddTool(&mcp.Tool{Name: "get_issue", Description: "Read one issue.",
		InputSchema: map[string]any{"type": "object", "properties": map[string]any{"key": map[string]any{"type": "string"}}}},
		record("get_issue"))
	server.AddTool(&mcp.Tool{Name: "create_issue", Description: "Create an issue.",
		InputSchema: map[string]any{"type": "object"}}, record("create_issue"))
	handler := mcp.NewStreamableHTTPHandler(func(*http.Request) *mcp.Server { return server }, nil)
	srv := httptest.NewServer(handler)
	t.Cleanup(srv.Close)
	f.url = srv.URL
	return f
}

func (f *fakeMCP) seen() ([]string, []string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.calls...), append([]string(nil), f.args...)
}

func (f *fakeMCP) server() ai.ExternalMCPServer {
	return ai.ExternalMCPServer{ID: 1, Name: "acme", Kind: "http", URL: f.url,
		AllowTools: []string{"get_issue"}, DenyTools: []string{"create_issue"}}
}

// recordingServer is a model server that answers responses in turn and
// keeps every request it was sent.
func recordingServer(t *testing.T, responses ...oaResponse) (*httptest.Server, func() []oaRequest) {
	t.Helper()
	var mu sync.Mutex
	var reqs []oaRequest
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req oaRequest
		_ = json.NewDecoder(r.Body).Decode(&req)
		mu.Lock()
		i := len(reqs)
		reqs = append(reqs, req)
		mu.Unlock()
		if i >= len(responses) {
			i = len(responses) - 1
		}
		_ = json.NewEncoder(w).Encode(responses[i])
	}))
	t.Cleanup(srv.Close)
	return srv, func() []oaRequest {
		mu.Lock()
		defer mu.Unlock()
		return append([]oaRequest(nil), reqs...)
	}
}

func offered(req oaRequest) []string {
	var names []string
	for _, tl := range req.Tools {
		names = append(names, tl.Function.Name)
	}
	return names
}

// TestAgentloop_QuickConnectionToolIsCalledAndShownAsStep: an allowed read
// tool of a Quick Connection is offered as mcp__<server>__<tool>, the model's
// call reaches the server through externalmcp, its result goes back to the
// model, and the call is a visible step (tool_start/tool_end).
func TestAgentloop_QuickConnectionToolIsCalledAndShownAsStep(t *testing.T) {
	mcpSrv := newFakeMCP(t)
	model, requests := recordingServer(t,
		toolCallResp("mcp__acme__get_issue", `{"key":"PAY-1"}`), finalResp("PAY-1 is open."))
	c := clientWith(&fakeReg{tools: map[string]*tools.Tool{"list_targets": tools.NewListTargets()}}, model.URL)
	c.EmitToolEvents()
	c.SetExternalMCPServers([]ai.ExternalMCPServer{mcpSrv.server()})

	chunks, err := collect(t, c)
	require.NoError(t, err)

	calls, args := mcpSrv.seen()
	assert.Equal(t, []string{"get_issue"}, calls, "the call reached the server")
	assert.JSONEq(t, `{"key":"PAY-1"}`, args[0])

	reqs := requests()
	require.Len(t, reqs, 2)
	assert.ElementsMatch(t, []string{"list_targets", "mcp__acme__get_issue"}, offered(reqs[0]))
	assert.Contains(t, reqs[0].Messages[0].Content, "EXTERNAL SERVER DATA", "the external-data fence is in the system prompt")
	last := reqs[1].Messages[len(reqs[1].Messages)-1]
	assert.Equal(t, "tool", last.Role)
	assert.JSONEq(t, `{"key":"PAY-1","status":"open"}`, last.Content, "the result goes back to the model")

	var start, end *ai.ToolEvent
	for _, ch := range chunks {
		if ch.Tool != nil && !ch.Tool.Done {
			start = ch.Tool
		} else if ch.Tool != nil {
			end = ch.Tool
		}
	}
	require.NotNil(t, start, "tool_start")
	require.NotNil(t, end, "tool_end")
	assert.Equal(t, "mcp__acme__get_issue", start.Name)
	assert.True(t, end.OK)
	assert.Equal(t, "PAY-1 is open.", chunks[len(chunks)-1].Text)
}

// TestAgentloop_QuickConnectionWriteToolNeverMounted (QC-02): a tool outside
// the allowed read list is not offered, and a call naming it anyway never
// reaches the server.
func TestAgentloop_QuickConnectionWriteToolNeverMounted(t *testing.T) {
	mcpSrv := newFakeMCP(t)
	model, requests := recordingServer(t,
		toolCallResp("mcp__acme__create_issue", `{}`), finalResp("done"))
	c := clientWith(&fakeReg{tools: map[string]*tools.Tool{}}, model.URL)
	c.EmitToolEvents()
	c.SetExternalMCPServers([]ai.ExternalMCPServer{mcpSrv.server()})

	chunks, err := collect(t, c)
	require.NoError(t, err)
	reqs := requests()
	require.NotEmpty(t, reqs)
	assert.Equal(t, []string{"mcp__acme__get_issue"}, offered(reqs[0]), "only the allowed read tool is offered")
	calls, _ := mcpSrv.seen()
	assert.Empty(t, calls, "the write tool never reached the server")
	for _, ch := range chunks {
		if ch.Tool != nil && ch.Tool.Done {
			assert.False(t, ch.Tool.OK)
			assert.NotEmpty(t, ch.Tool.Result, "a refused call says why")
		}
	}
}

// TestAgentloop_PolicyDisallowedConnectionNotMounted: a connection the
// organization's AllowedQuickConnections leaves out is never listed, offered
// or called, whatever the loader handed in.
func TestAgentloop_PolicyDisallowedConnectionNotMounted(t *testing.T) {
	mcpSrv := newFakeMCP(t)
	policytest.Set(t, map[string]any{policy.KeyAllowedQuickConnections: []any{"https://mcp.example.com"}})
	model, requests := recordingServer(t,
		toolCallResp("mcp__acme__get_issue", `{"key":"PAY-1"}`), finalResp("done"))
	c := clientWith(&fakeReg{tools: map[string]*tools.Tool{}}, model.URL)
	c.SetExternalMCPServers([]ai.ExternalMCPServer{mcpSrv.server()})

	_, err := collect(t, c)
	require.NoError(t, err)
	reqs := requests()
	require.NotEmpty(t, reqs)
	assert.Empty(t, offered(reqs[0]), "a disallowed connection offers nothing")
	assert.NotContains(t, reqs[0].Messages[0].Content, "EXTERNAL SERVER DATA", "no fence for a server not mounted")
	calls, _ := mcpSrv.seen()
	assert.Empty(t, calls)
}

// A server the loop cannot list mounts nothing; the turn still runs.
func TestAgentloop_UnlistableConnectionMountsNothing(t *testing.T) {
	model, requests := recordingServer(t, finalResp("fine"))
	c := clientWith(&fakeReg{tools: map[string]*tools.Tool{}}, model.URL)
	c.SetExternalMCPServers([]ai.ExternalMCPServer{{ID: 2, Name: "gone", Kind: "http", URL: "http://127.0.0.1:1/mcp",
		AllowTools: []string{"get_issue"}}})

	chunks, err := collect(t, c)
	require.NoError(t, err)
	assert.Equal(t, "fine", chunks[len(chunks)-1].Text)
	assert.Empty(t, offered(requests()[0]))
}

// A gated loop (an automation's agent()) is never given Quick Connections:
// its Gate covers registry tools only.
func TestAgentloop_GatedLoopMountsNoQuickConnections(t *testing.T) {
	mcpSrv := newFakeMCP(t)
	model, requests := recordingServer(t, toolCallResp("mcp__acme__get_issue", `{}`), finalResp("done"))
	c := clientWith(&fakeReg{tools: map[string]*tools.Tool{}}, model.URL)
	c.opts.Gate = func(_ context.Context, _ *tools.Tool, args json.RawMessage) (json.RawMessage, error) {
		return args, nil
	}
	c.SetExternalMCPServers([]ai.ExternalMCPServer{mcpSrv.server()})

	_, err := collect(t, c)
	require.NoError(t, err)
	assert.Empty(t, offered(requests()[0]))
	calls, _ := mcpSrv.seen()
	assert.Empty(t, calls)
}
