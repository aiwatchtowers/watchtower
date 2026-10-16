package cmd

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/automations"
	"watchtower/internal/db"
	"watchtower/internal/externalmcp"
)

// fakeMCPServerEnv makes the cmd test binary act as a stdio MCP server
// (TestMain), so a connection's command can be a real process the caller
// starts. fakeMCPStartFileEnv names a file the server appends its pid to on
// startup: the test counts starts and reaps every group it saw.
const (
	fakeMCPServerEnv    = "WT_CMD_FAKE_MCP_SERVER"
	fakeMCPStartFileEnv = "WT_CMD_FAKE_MCP_START_FILE"
)

// serveFakeMCP is the fake stdio server: get_thing echoes its arguments.
func serveFakeMCP() {
	if path := os.Getenv(fakeMCPStartFileEnv); path != "" {
		f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
		if err == nil {
			_, _ = f.WriteString(strconv.Itoa(os.Getpid()) + "\n")
			_ = f.Close()
		}
	}
	server := mcp.NewServer(&mcp.Implementation{Name: "fake-stdio", Version: "1"}, nil)
	server.AddTool(&mcp.Tool{Name: "get_thing", InputSchema: map[string]any{"type": "object"}},
		func(_ context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			return &mcp.CallToolResult{StructuredContent: map[string]any{"input": string(req.Params.Arguments)}}, nil
		})
	if err := server.Run(context.Background(), &mcp.StdioTransport{}); err != nil {
		os.Exit(1)
	}
	os.Exit(0)
}

// fakeStarts returns the pids the fake server recorded in path.
func fakeStarts(t *testing.T, path string) []int {
	t.Helper()
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return nil
	}
	require.NoError(t, err)
	var pids []int
	for _, line := range strings.Fields(string(data)) {
		pid, err := strconv.Atoi(line)
		require.NoError(t, err)
		pids = append(pids, pid)
	}
	return pids
}

// insertFakeStdioConnection adds a stdio connection whose command is the
// fake server, with tools cached (nil = never listed) and its own start file.
func insertFakeStdioConnection(t *testing.T, database *db.DB, workspace, name string, enabled bool, tools []db.ExternalTool) (int64, string) {
	t.Helper()
	exe, err := os.Executable()
	require.NoError(t, err)
	id, err := database.InsertExternalConnection(db.ExternalConnection{
		Name: name, Kind: "stdio", Command: exe, Enabled: enabled,
	})
	require.NoError(t, err)
	startFile := filepath.Join(t.TempDir(), "starts")
	require.NoError(t, externalmcp.NewSecretStore(workspace, id).Save(&externalmcp.Secret{
		Env: map[string]string{fakeMCPServerEnv: "1", fakeMCPStartFileEnv: startFile},
	}))
	if tools != nil {
		require.NoError(t, database.SetExternalConnectionTools(id, tools, time.Now().UTC().Format(time.RFC3339)))
	}
	t.Cleanup(func() {
		// CallTool stops the group itself; this reaps one a failure left.
		for _, pid := range fakeStarts(t, startFile) {
			_ = syscall.Kill(-pid, syscall.SIGKILL)
		}
	})
	return id, startFile
}

func TestMCP_OnlyQC02AllowedTools(t *testing.T) {
	cfg := writeConnectionsConfig(t)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	ws := cfg.WorkspaceDir()

	listed := []db.ExternalTool{
		{Name: "get_thing", Annotated: true, ReadOnlyHint: true},
		{Name: "write_thing", Annotated: true, ReadOnlyHint: false},
		{Name: "create_thing"},
	}
	_, github := insertFakeStdioConnection(t, database, ws, "github", true, listed)
	ownerID, owner := insertFakeStdioConnection(t, database, ws, "github-owner", true, listed)
	require.NoError(t, database.SetExternalConnectionAllowTools(ownerID, []string{"get_thing", "write_thing"}))
	_, neverListed := insertFakeStdioConnection(t, database, ws, "never-listed", true, nil)
	_, disabled := insertFakeStdioConnection(t, database, ws, "disabled", false, listed)

	caller := newAutomationMCPCaller(cfg, database)
	cases := []struct {
		name, server, tool string
		startFile          string
		want               error // nil = called
	}{
		{"read-only-annotated tool is called", "github", "get_thing", github, nil},
		{"owner-allowed tool the server marks a write", "github-owner", "write_thing", owner, automations.ErrMCPToolNotAllowed},
		{"unannotated create_thing", "github", "create_thing", github, automations.ErrMCPToolNotAllowed},
		{"never-listed connection", "never-listed", "get_thing", neverListed, automations.ErrMCPNotAvailable},
		{"disabled connection", "disabled", "get_thing", disabled, automations.ErrMCPNotAvailable},
		{"unknown name", "gitlab", "get_thing", "", automations.ErrMCPNotAvailable},
		{"case-different name", "GitHub", "get_thing", github, automations.ErrMCPNotAvailable},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			before := 0
			if tc.startFile != "" {
				before = len(fakeStarts(t, tc.startFile))
			}
			out, err := caller.Call(context.Background(), tc.server, tc.tool, json.RawMessage(`{"id":"PAY-1"}`))
			after := 0
			if tc.startFile != "" {
				after = len(fakeStarts(t, tc.startFile))
			}
			if tc.want == nil {
				require.NoError(t, err)
				var got struct {
					Input string `json:"input"`
				}
				require.NoError(t, json.Unmarshal(out, &got))
				assert.JSONEq(t, `{"id":"PAY-1"}`, got.Input)
				assert.Equal(t, 1, after-before, "one server start per call")
				return
			}
			require.ErrorIs(t, err, tc.want)
			assert.Nil(t, out)
			assert.Equal(t, 0, after-before, "a refused call never starts the server")
		})
	}
}

// TestMCPCaller_OAuthBearerUsed: an OAuth connection's grant is refreshed
// (QC-04) and the new bearer reaches the HTTP server on the call.
func TestMCPCaller_OAuthBearerUsed(t *testing.T) {
	cfg := writeConnectionsConfig(t)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	tokenServer, tokenHits := newFakeTokenServer(t, false)

	var mu sync.Mutex
	var auth []string
	server := mcp.NewServer(&mcp.Implementation{Name: "fake-http", Version: "1"}, nil)
	server.AddTool(&mcp.Tool{Name: "get_item", InputSchema: map[string]any{"type": "object"}},
		func(context.Context, *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			return &mcp.CallToolResult{StructuredContent: map[string]any{"ok": true}}, nil
		})
	handler := mcp.NewStreamableHTTPHandler(func(*http.Request) *mcp.Server { return server }, nil)
	mcpServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		auth = append(auth, r.Header.Get("Authorization"))
		mu.Unlock()
		handler.ServeHTTP(w, r)
	}))
	t.Cleanup(mcpServer.Close)

	id, err := database.InsertExternalConnection(db.ExternalConnection{
		Name: "github", Kind: "http", URL: mcpServer.URL, Enabled: true,
	})
	require.NoError(t, err)
	cacheReadOnlyTool(t, database, id)
	require.NoError(t, externalmcp.NewSecretStore(cfg.WorkspaceDir(), id).Save(&externalmcp.Secret{
		OAuth: &externalmcp.OAuthGrant{
			AccessToken:   "access-token-1",
			RefreshToken:  "refresh-token-1",
			ExpiresAt:     time.Now().Add(-time.Minute),
			TokenEndpoint: tokenServer.URL,
			ClientID:      "test-client-id",
		},
	}))

	out, err := newAutomationMCPCaller(cfg, database).Call(context.Background(), "github", "get_item", nil)
	require.NoError(t, err)
	assert.JSONEq(t, `{"ok":true}`, string(out))
	assert.Equal(t, int64(1), tokenHits.Load(), "the expired grant is refreshed once")
	mu.Lock()
	defer mu.Unlock()
	require.NotEmpty(t, auth)
	for _, h := range auth {
		assert.Equal(t, "Bearer access-token-2", h)
	}
}

// TestMCPCaller_ThirtySecondBound: the call runs under a 30 s deadline.
func TestMCPCaller_ThirtySecondBound(t *testing.T) {
	cfg := writeConnectionsConfig(t)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	id := insertStaticConnection(t, database, cfg)
	cacheReadOnlyTool(t, database, id)

	var deadline time.Time
	var hasDeadline bool
	var gotSpec externalmcp.ServerSpec
	original := callServerTool
	callServerTool = func(ctx context.Context, spec externalmcp.ServerSpec, _ string, _ json.RawMessage) (json.RawMessage, error) {
		deadline, hasDeadline = ctx.Deadline()
		gotSpec = spec
		return json.RawMessage(`{}`), nil
	}
	t.Cleanup(func() { callServerTool = original })

	start := time.Now()
	_, err = newAutomationMCPCaller(cfg, database).Call(context.Background(), "acme", "get_item", nil)
	require.NoError(t, err)
	require.True(t, hasDeadline)
	assert.WithinDuration(t, start.Add(30*time.Second), deadline, 2*time.Second)
	assert.Equal(t, "https://example.com/mcp", gotSpec.URL)
	assert.Equal(t, "k", gotSpec.Headers["X-Api-Key"], "the static secret reaches the call")
}
