package externalmcp

import (
	"context"
	"fmt"
	"os"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// fakeStdioServerEnv makes the test binary act as a stdio MCP server (one
// tool, "list_things") instead of running the tests — TestListTools_Stdio
// starts it as a connection's command; "fail" makes it die at startup with a
// message on stderr.
const fakeStdioServerEnv = "WT_EXTERNALMCP_FAKE_STDIO_SERVER"

func TestMain(m *testing.M) {
	if os.Getenv(fakeStdioServerEnv) == "fail" {
		fmt.Fprintln(os.Stderr, "fake server: missing API key")
		os.Exit(1)
	}
	if os.Getenv(fakeStdioServerEnv) == "1" {
		server := mcp.NewServer(&mcp.Implementation{Name: "fake-stdio", Version: "1"}, nil)
		server.AddTool(&mcp.Tool{Name: "list_things", InputSchema: map[string]any{"type": "object"}},
			func(context.Context, *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
				return &mcp.CallToolResult{}, nil
			})
		if err := server.Run(context.Background(), &mcp.StdioTransport{}); err != nil {
			os.Exit(1)
		}
		os.Exit(0)
	}
	os.Exit(m.Run())
}
