package externalmcp

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/stretchr/testify/require"
)

// fakeStdioServerEnv makes the test binary act as a stdio MCP server
// instead of running the tests, for the few tests of the real stdio wiring
// (spawn, pipes, env, process-group stop): "1" serves newFakeServer — its
// slow_thing starts a grandchild in the server's process group and writes
// "<server pid> <grandchild pid>" to WT_FAKE_PIDFILE; "garble" starts a
// grandchild, writes the same pids to WT_FAKE_PIDFILE and a line to stderr,
// answers initialize with junk and exits, leaving the grandchild behind.
// Every other test talks to newFakeServer in process (useFakeServer).
const fakeStdioServerEnv = "WT_EXTERNALMCP_FAKE_STDIO_SERVER"

// newFakeServer is the fake MCP server, in process or as the stdio child.
// slowStarted runs once slow_thing has started; slow_thing then answers
// only when its request's context ends.
func newFakeServer(slowStarted func()) *mcp.Server {
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
			slowStarted()
			<-ctx.Done()
			return nil, ctx.Err()
		})
	return server
}

// useFakeServer makes ListToolDefs and CallTool reach a fresh in-process
// newFakeServer over an in-memory transport, whatever the spec says. The
// returned channel is closed once slow_thing has started.
func useFakeServer(t *testing.T) <-chan struct{} {
	t.Helper()
	slow := make(chan struct{})
	prev := serverTransport
	serverTransport = func(ctx context.Context, _ ServerSpec) (mcp.Transport, *headBuffer, error) {
		clientSide, serverSide := mcp.NewInMemoryTransports()
		if _, err := newFakeServer(func() { close(slow) }).Connect(ctx, serverSide, nil); err != nil {
			return nil, nil, err
		}
		return clientSide, nil, nil
	}
	t.Cleanup(func() { serverTransport = prev })
	return slow
}

// fakePids parses "<server pid> <grandchild pid>" as the stdio fake wrote it.
func fakePids(t *testing.T, raw string) (server, grandchild int) {
	t.Helper()
	fields := strings.Fields(raw)
	require.Len(t, fields, 2, "pid file %q", raw)
	server, err := strconv.Atoi(fields[0])
	require.NoError(t, err)
	grandchild, err = strconv.Atoi(fields[1])
	require.NoError(t, err)
	return server, grandchild
}

// startGrandchild starts a process in this one's process group (stdio nil:
// it holds none of the server's pipes) and writes both pids to
// WT_FAKE_PIDFILE.
func startGrandchild() {
	child := exec.Command("sleep", "600")
	if err := child.Start(); err != nil {
		os.Exit(2)
	}
	pids := fmt.Sprintf("%d %d", os.Getpid(), child.Process.Pid)
	_ = os.WriteFile(os.Getenv("WT_FAKE_PIDFILE"), []byte(pids), 0o600)
}

func TestMain(m *testing.M) {
	switch os.Getenv(fakeStdioServerEnv) {
	case "garble":
		fmt.Fprintln(os.Stderr, "fake server: missing API key")
		startGrandchild()
		fmt.Println("not a JSON-RPC message")
		os.Exit(0)
	case "1":
		if err := newFakeServer(startGrandchild).Run(context.Background(), &mcp.StdioTransport{}); err != nil {
			os.Exit(1)
		}
		os.Exit(0)
	}
	os.Exit(m.Run())
}
