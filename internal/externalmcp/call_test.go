package externalmcp

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func fakeStdioSpec(t *testing.T, env map[string]string) ServerSpec {
	t.Helper()
	exe, err := os.Executable()
	require.NoError(t, err)
	env[fakeStdioServerEnv] = "1"
	return ServerSpec{Kind: "stdio", Command: exe, Env: env}
}

func TestCallTool_StdioStructuredResult(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	out, err := CallTool(ctx, fakeStdioSpec(t, map[string]string{}), "get_thing", json.RawMessage(`{"id":"PAY-1"}`))
	require.NoError(t, err)
	var got struct {
		Input string `json:"input"`
	}
	require.NoError(t, json.Unmarshal(out, &got))
	assert.JSONEq(t, `{"id":"PAY-1"}`, got.Input)
}

func TestCallTool_TextResultWrapped(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	out, err := CallTool(ctx, fakeStdioSpec(t, map[string]string{}), "text_thing", nil)
	require.NoError(t, err)
	assert.JSONEq(t, `{"text":"line one\nline two"}`, string(out))
}

func TestCallTool_IsErrorIsToolError(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	_, err := CallTool(ctx, fakeStdioSpec(t, map[string]string{}), "fail_thing", nil)
	var toolErr *ToolError
	require.ErrorAs(t, err, &toolErr)
	assert.Equal(t, "rate limited", toolErr.Message)
}

// TestCallTool_ContextDeadlineStopsServer: a tool that never answers ends
// with the context's error, and the server process is gone afterwards.
func TestCallTool_ContextDeadlineStopsServer(t *testing.T) {
	pidFile := filepath.Join(t.TempDir(), "pid")
	spec := fakeStdioSpec(t, map[string]string{"WT_FAKE_PIDFILE": pidFile})
	var pid int
	t.Cleanup(func() {
		if pid > 0 {
			_ = syscall.Kill(-pid, syscall.SIGKILL)
		}
	})

	ctx, cancel := context.WithTimeout(context.Background(), 1500*time.Millisecond)
	defer cancel()
	_, err := CallTool(ctx, spec, "slow_thing", nil)
	require.ErrorIs(t, err, context.DeadlineExceeded)

	raw, rerr := os.ReadFile(pidFile)
	require.NoError(t, rerr, "the slow tool must have started")
	pid, rerr = strconv.Atoi(string(raw))
	require.NoError(t, rerr)
	assert.Eventually(t, func() bool { return syscall.Kill(pid, 0) != nil },
		5*time.Second, 20*time.Millisecond, "server process must be gone")
	assert.Eventually(t, func() bool { return syscall.Kill(-pid, 0) != nil },
		5*time.Second, 20*time.Millisecond, "server process group must be gone")
}

func TestCallTool_HTTPHeaders(t *testing.T) {
	server := mcp.NewServer(&mcp.Implementation{Name: "fake", Version: "1"}, nil)
	server.AddTool(&mcp.Tool{Name: "get_thing", InputSchema: map[string]any{"type": "object"}},
		func(context.Context, *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			return &mcp.CallToolResult{StructuredContent: map[string]any{"ok": true}}, nil
		})
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
	out, err := CallTool(ctx, ServerSpec{Kind: "http", URL: srv.URL,
		Headers: map[string]string{"Authorization": "Bearer tok"}}, "get_thing", nil)
	require.NoError(t, err)
	assert.JSONEq(t, `{"ok":true}`, string(out))
	assert.Zero(t, missingAuth.Load(), "every request must carry the connection's headers")
}

// TestCallTool_SecretsTravelInEnvNotArgv (QC-03): a secret env value reaches
// the server through its environment and never through its command line.
func TestCallTool_SecretsTravelInEnvNotArgv(t *testing.T) {
	const secret = "s3cr3t-token-value"
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	out, err := CallTool(ctx, fakeStdioSpec(t, map[string]string{"WT_FAKE_SECRET": secret}), "get_thing", nil)
	require.NoError(t, err)
	var got struct {
		Args   []string `json:"args"`
		Secret string   `json:"secret"`
	}
	require.NoError(t, json.Unmarshal(out, &got))
	assert.Equal(t, secret, got.Secret)
	for _, a := range got.Args {
		assert.NotContains(t, a, secret)
	}
}
