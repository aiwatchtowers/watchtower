package externalmcp

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"syscall"
	"testing"
	"testing/synctest"
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

func TestCallTool_StructuredResult(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		useFakeServer(t)
		out, err := CallTool(t.Context(), ServerSpec{Kind: "stdio"}, "get_thing", json.RawMessage(`{"id":"PAY-1"}`))
		require.NoError(t, err)
		var got struct {
			Input string `json:"input"`
		}
		require.NoError(t, json.Unmarshal(out, &got))
		assert.JSONEq(t, `{"id":"PAY-1"}`, got.Input)
	})
}

func TestCallTool_TextResultWrapped(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		useFakeServer(t)
		out, err := CallTool(t.Context(), ServerSpec{Kind: "stdio"}, "text_thing", nil)
		require.NoError(t, err)
		assert.JSONEq(t, `{"text":"line one\nline two"}`, string(out))
	})
}

func TestCallTool_IsErrorIsToolError(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		useFakeServer(t)
		_, err := CallTool(t.Context(), ServerSpec{Kind: "stdio"}, "fail_thing", nil)
		var toolErr *ToolError
		require.ErrorAs(t, err, &toolErr)
		assert.Equal(t, "rate limited", toolErr.Message)
	})
}

// TestCallTool_ContextEndEndsTheCall: a tool that never answers ends with
// the context's error once the context ends (cancelled only once the tool
// has started, so the cause is the context and not a slow start).
func TestCallTool_ContextEndEndsTheCall(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		started := useFakeServer(t)
		ctx, cancel := context.WithCancel(t.Context())
		defer cancel()
		go func() {
			select {
			case <-started:
				cancel()
			case <-ctx.Done():
			}
		}()
		_, err := CallTool(ctx, ServerSpec{Kind: "stdio"}, "slow_thing", nil)
		require.ErrorIs(t, err, context.Canceled)
	})
}

// TestCallTool_DeadlineEndsTheCall: a context deadline ends a call the tool
// never answers with context.DeadlineExceeded (virtual time).
func TestCallTool_DeadlineEndsTheCall(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		useFakeServer(t)
		ctx, cancel := context.WithTimeout(t.Context(), time.Minute)
		defer cancel()
		_, err := CallTool(ctx, ServerSpec{Kind: "stdio"}, "slow_thing", nil)
		require.ErrorIs(t, err, context.DeadlineExceeded)
	})
}

// TestStdio_ServerGroupStops is the real stdio wiring of a stopped server
// (the test binary re-executed as the server, with a grandchild in its
// process group that never exits on its own): when the call's context
// ends, and when the server starts but fails the handshake or dies before
// it — CallTool and ListTools alike, quoting the server's stderr — the
// grandchild is gone after the call. The server itself is this process's
// child, reaped by the call (cmd.Wait); the grandchild is waited for on its
// exit event only (kqueue NOTE_EXIT / pidfd), never on time, so a group
// left running hangs the test into go test -timeout.
func TestStdio_ServerGroupStops(t *testing.T) {
	t.Run("context end", func(t *testing.T) {
		fifo := filepath.Join(t.TempDir(), "pid")
		require.NoError(t, syscall.Mkfifo(fifo, 0o600))
		spec := fakeStdioSpec(t, map[string]string{"WT_FAKE_PIDFILE": fifo})

		// Opened read-write so the open never blocks; closing it in the
		// cleanup ends a read the server never answered, so the reader
		// cannot leak.
		r, err := os.OpenFile(fifo, os.O_RDWR, 0)
		require.NoError(t, err)
		t.Cleanup(func() { _ = r.Close() })

		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		started := make(chan string, 1)
		go func() {
			buf := make([]byte, 64)
			n, err := r.Read(buf) // blocks until the slow tool writes its pids
			if err != nil {
				return
			}
			started <- string(buf[:n])
			cancel()
		}()

		_, callErr := CallTool(ctx, spec, "slow_thing", nil)
		var raw string
		select {
		case raw = <-started:
		default:
			t.Fatalf("the call ended before the slow tool started: %v", callErr)
		}
		requireGrandchildGone(t, raw)
		require.ErrorIs(t, callErr, context.Canceled)
	})

	exe, err := os.Executable()
	require.NoError(t, err)
	calls := map[string]func(context.Context, ServerSpec) error{
		"CallTool": func(ctx context.Context, spec ServerSpec) error {
			_, err := CallTool(ctx, spec, "get_thing", nil)
			return err
		},
		"ListTools": func(ctx context.Context, spec ServerSpec) error {
			_, err := ListTools(ctx, spec)
			return err
		},
	}
	for _, mode := range []string{"garble", "fail"} {
		for name, call := range calls {
			t.Run(mode+" "+name, func(t *testing.T) {
				pidFile := filepath.Join(t.TempDir(), "pid")
				spec := ServerSpec{Kind: "stdio", Command: exe, Env: map[string]string{fakeStdioServerEnv: mode, "WT_FAKE_PIDFILE": pidFile}}
				ctx, cancel := context.WithCancel(context.Background())
				defer cancel()
				callErr := call(ctx, spec)

				raw, rerr := os.ReadFile(pidFile)
				require.NoError(t, rerr, "the server must have started")
				requireGrandchildGone(t, string(raw))
				require.ErrorContains(t, callErr, "missing API key", "a failed start quotes the server's stderr")
				require.NoError(t, ctx.Err(), "the server failed, the context did not end")
			})
		}
	}
}

// requireGrandchildGone waits for the stdio fake's grandchild (named in raw,
// see fakePids) to exit. Until it has, a cleanup kills it, so a test that
// fails first leaves nothing behind.
func requireGrandchildGone(t *testing.T, raw string) {
	t.Helper()
	_, grandchild := fakePids(t, raw)
	gone := false
	t.Cleanup(func() {
		if !gone {
			_ = syscall.Kill(grandchild, syscall.SIGKILL)
		}
	})
	waitProcessExit(t, grandchild)
	gone = true
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

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	out, err := CallTool(ctx, ServerSpec{Kind: "http", URL: srv.URL,
		Headers: map[string]string{"Authorization": "Bearer tok"}}, "get_thing", nil)
	require.NoError(t, err)
	assert.JSONEq(t, `{"ok":true}`, string(out))
	assert.Zero(t, missingAuth.Load(), "every request must carry the connection's headers")
}

// TestCallTool_SecretsTravelInEnvNotArgv (QC-03): a secret env value reaches
// the server through its environment and never through its command line.
// It is also the real stdio wiring of a successful call: the test binary is
// started as the server and answers over its pipes.
func TestCallTool_SecretsTravelInEnvNotArgv(t *testing.T) {
	const secret = "s3cr3t-token-value"
	ctx, cancel := context.WithCancel(context.Background())
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
