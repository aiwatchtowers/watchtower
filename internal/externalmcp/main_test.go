package externalmcp

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// fakeStdioServerEnv makes the test binary act as a stdio MCP server (one
// tool, "list_things") instead of running the tests — TestListTools_Stdio
// starts it as a connection's command; "fail" makes it die at startup with a
// message on stderr; "garble" starts a grandchild in its process group,
// writes its own pid to WT_FAKE_PIDFILE, answers initialize with junk and
// exits, leaving the grandchild behind.
const fakeStdioServerEnv = "WT_EXTERNALMCP_FAKE_STDIO_SERVER"

func TestMain(m *testing.M) {
	if os.Getenv(fakeStdioServerEnv) == "fail" {
		fmt.Fprintln(os.Stderr, "fake server: missing API key")
		os.Exit(1)
	}
	if os.Getenv(fakeStdioServerEnv) == "garble" {
		child := exec.Command("sleep", "60")
		if err := child.Start(); err != nil {
			os.Exit(2)
		}
		_ = os.WriteFile(os.Getenv("WT_FAKE_PIDFILE"), []byte(strconv.Itoa(os.Getpid())), 0o600)
		fmt.Println("not a JSON-RPC message")
		os.Exit(0)
	}
	if os.Getenv(fakeStdioServerEnv) == "1" {
		server := mcp.NewServer(&mcp.Implementation{Name: "fake-stdio", Version: "1"}, nil)
		server.AddTool(&mcp.Tool{Name: "list_things", InputSchema: map[string]any{"type": "object"}},
			func(context.Context, *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
				return &mcp.CallToolResult{}, nil
			})
		server.AddTool(&mcp.Tool{Name: "get_thing", InputSchema: map[string]any{"type": "object"}},
			func(_ context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
				// Echoes what the call carried, so tests see the arguments,
				// argv and env as the server got them.
				return &mcp.CallToolResult{StructuredContent: map[string]any{
					"args":   os.Args,
					"input":  string(req.Params.Arguments),
					"secret": os.Getenv("WT_FAKE_SECRET"),
				}}, nil
			})
		server.AddTool(&mcp.Tool{Name: "text_thing", InputSchema: map[string]any{"type": "object"}},
			func(context.Context, *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
				return &mcp.CallToolResult{Content: []mcp.Content{
					&mcp.TextContent{Text: "line one"}, &mcp.TextContent{Text: "line two"}}}, nil
			})
		server.AddTool(&mcp.Tool{Name: "fail_thing", InputSchema: map[string]any{"type": "object"}},
			func(context.Context, *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
				return &mcp.CallToolResult{IsError: true,
					Content: []mcp.Content{&mcp.TextContent{Text: "rate limited"}}}, nil
			})
		server.AddTool(&mcp.Tool{Name: "slow_thing", InputSchema: map[string]any{"type": "object"}},
			func(ctx context.Context, _ *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
				if path := os.Getenv("WT_FAKE_PIDFILE"); path != "" {
					_ = os.WriteFile(path, []byte(strconv.Itoa(os.Getpid())), 0o600)
				}
				<-ctx.Done()
				return nil, ctx.Err()
			})
		if err := server.Run(context.Background(), &mcp.StdioTransport{}); err != nil {
			os.Exit(1)
		}
		os.Exit(0)
	}
	os.Exit(m.Run())
}
