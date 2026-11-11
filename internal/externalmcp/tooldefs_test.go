package externalmcp

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// ListToolDefs returns what a model is offered — description and input
// schema — beside the QC-02 fields ListTools returns.
func TestListToolDefs_DescriptionAndSchema(t *testing.T) {
	server := mcp.NewServer(&mcp.Implementation{Name: "fake", Version: "1"}, nil)
	server.AddTool(&mcp.Tool{Name: "get_issue", Description: "Read one issue.",
		Annotations: &mcp.ToolAnnotations{ReadOnlyHint: true},
		InputSchema: map[string]any{"type": "object", "properties": map[string]any{"key": map[string]any{"type": "string"}}}},
		func(context.Context, *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			return &mcp.CallToolResult{}, nil
		})
	srv := httptest.NewServer(mcp.NewStreamableHTTPHandler(func(*http.Request) *mcp.Server { return server }, nil))
	t.Cleanup(srv.Close)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	defs, err := ListToolDefs(ctx, ServerSpec{Kind: "http", URL: srv.URL})
	require.NoError(t, err)
	require.Len(t, defs, 1)
	assert.Equal(t, "get_issue", defs[0].Tool.Name)
	assert.True(t, defs[0].Tool.Annotated)
	assert.True(t, defs[0].Tool.ReadOnlyHint)
	assert.Equal(t, "Read one issue.", defs[0].Description)
	assert.JSONEq(t, `{"type":"object","properties":{"key":{"type":"string"}}}`, string(defs[0].InputSchema))

	tools, err := ListTools(ctx, ServerSpec{Kind: "http", URL: srv.URL})
	require.NoError(t, err)
	assert.Equal(t, defs[0].Tool, tools[0], "ListTools is the same listing")
}
