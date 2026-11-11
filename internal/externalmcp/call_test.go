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
	ctx, cancel := context.WithTimeout(context.Background(), hangGuard)
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
	ctx, cancel := context.WithTimeout(context.Background(), hangGuard)
	defer cancel()
	out, err := CallTool(ctx, fakeStdioSpec(t, map[string]string{}), "text_thing", nil)
	require.NoError(t, err)
	assert.JSONEq(t, `{"text":"line one\nline two"}`, string(out))
}

func TestCallTool_IsErrorIsToolError(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), hangGuard)
	defer cancel()
	_, err := CallTool(ctx, fakeStdioSpec(t, map[string]string{}), "fail_thing", nil)
	var toolErr *ToolError
	require.ErrorAs(t, err, &toolErr)
	assert.Equal(t, "rate limited", toolErr.Message)
}

// TestCallTool_ContextEndStopsServer: a tool that never answers ends with
// the context's error, and the server process is gone afterwards. The
// context ends once the slow tool has started — the server writes its pid
// into a FIFO the test reads — not after a fixed time a loaded machine may
// spend on starting the server.
func TestCallTool_ContextEndStopsServer(t *testing.T) {
	fifo := filepath.Join(t.TempDir(), "pid")
	require.NoError(t, syscall.Mkfifo(fifo, 0o600))
	spec := fakeStdioSpec(t, map[string]string{"WT_FAKE_PIDFILE": fifo})

	// Opened read-write so the open never blocks; closing it in the cleanup
	// ends a read the server never answered, so the reader cannot leak.
	r, err := os.OpenFile(fifo, os.O_RDWR, 0)
	require.NoError(t, err)
	t.Cleanup(func() { _ = r.Close() })

	// The hang guard only ends a run whose server never reaches the tool:
	// the cancel below always comes first, and a deadline fails the
	// context.Canceled assertion.
	ctx, cancel := context.WithTimeout(context.Background(), hangGuard)
	defer cancel()
	started := make(chan string, 1)
	go func() {
		buf := make([]byte, 32)
		n, err := r.Read(buf) // blocks until the slow tool writes its pid
		if err != nil {
			return
		}
		started <- string(buf[:n])
		cancel()
	}()
	var pid int
	t.Cleanup(func() {
		if pid > 0 {
			_ = syscall.Kill(-pid, syscall.SIGKILL)
		}
	})

	_, err = CallTool(ctx, spec, "slow_thing", nil)
	require.ErrorIs(t, err, context.Canceled)

	var raw string
	select {
	case raw = <-started:
	default:
		t.Fatal("the call ended before the slow tool started")
	}
	pid, err = strconv.Atoi(raw)
	require.NoError(t, err)
	// The server is not this process's child: its end is observed by
	// polling, bounded only by a hang guard.
	assert.Eventually(t, func() bool { return syscall.Kill(pid, 0) != nil },
		hangGuard, 20*time.Millisecond, "server process must be gone")
	assert.Eventually(t, func() bool { return syscall.Kill(-pid, 0) != nil },
		hangGuard, 20*time.Millisecond, "server process group must be gone")
}

// A stdio server that starts but fails the handshake is still stopped as a
// group: its grandchild does not outlive CallTool or ListTools.
func TestCallTool_FailedHandshakeStopsServerGroup(t *testing.T) {
	for name, call := range map[string]func(context.Context, ServerSpec) error{
		"CallTool": func(ctx context.Context, spec ServerSpec) error {
			_, err := CallTool(ctx, spec, "get_thing", nil)
			return err
		},
		"ListTools": func(ctx context.Context, spec ServerSpec) error {
			_, err := ListTools(ctx, spec)
			return err
		},
	} {
		t.Run(name, func(t *testing.T) {
			pidFile := filepath.Join(t.TempDir(), "pid")
			exe, err := os.Executable()
			require.NoError(t, err)
			spec := ServerSpec{Kind: "stdio", Command: exe, Env: map[string]string{fakeStdioServerEnv: "garble", "WT_FAKE_PIDFILE": pidFile}}
			var pid int
			t.Cleanup(func() {
				if pid > 0 {
					_ = syscall.Kill(-pid, syscall.SIGKILL)
				}
			})
			ctx, cancel := context.WithTimeout(context.Background(), hangGuard)
			defer cancel()
			require.Error(t, call(ctx, spec))
			require.NoError(t, ctx.Err(), "the handshake failed, the context did not end")

			raw, rerr := os.ReadFile(pidFile)
			require.NoError(t, rerr, "the server must have started")
			pid, rerr = strconv.Atoi(string(raw))
			require.NoError(t, rerr)
			assert.Eventually(t, func() bool { return syscall.Kill(-pid, 0) != nil },
				hangGuard, 20*time.Millisecond, "the server's process group must be gone")
		})
	}
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

	ctx, cancel := context.WithTimeout(context.Background(), hangGuard)
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
	ctx, cancel := context.WithTimeout(context.Background(), hangGuard)
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
