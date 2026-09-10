package cmd

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/externalmcp"
	"watchtower/internal/mcpoauth"
)

// writeConnectionsConfig points flagConfig at a temp workspace whose DB path
// lives under a temp HOME (the writeActionsConfig/writeFeaturesConfig
// precedent) and returns the resolved config for reading WorkspaceDir().
func writeConnectionsConfig(t *testing.T) *config.Config {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	tmpDir := t.TempDir()
	configPath := filepath.Join(tmpDir, "config.yaml")
	require.NoError(t, os.WriteFile(configPath, []byte("active_workspace: test\n"), 0o600))
	original := flagConfig
	flagConfig = configPath
	t.Cleanup(func() { flagConfig = original })

	cfg, err := config.Load(configPath)
	require.NoError(t, err)
	return cfg
}

// writeConnectionsConfigWithProvider is the writeConnectionsConfig precedent,
// but stamps ai.provider so ConfiguredProviderID() resolves to a specific
// value — used to exercise warnIfProviderIgnoresConnections under codex/ollama.
func writeConnectionsConfigWithProvider(t *testing.T, provider string) *config.Config {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	tmpDir := t.TempDir()
	configPath := filepath.Join(tmpDir, "config.yaml")
	configYAML := "active_workspace: test\nai:\n  provider: " + provider + "\n"
	require.NoError(t, os.WriteFile(configPath, []byte(configYAML), 0o600))
	original := flagConfig
	flagConfig = configPath
	t.Cleanup(func() { flagConfig = original })

	cfg, err := config.Load(configPath)
	require.NoError(t, err)
	return cfg
}

// runConnections executes the real "connections" command tree via rootCmd,
// the actions_test.go/runActions precedent, feeding stdin (if any) through
// rootCmd so it reaches InOrStdin() on the dispatched child command.
func runConnections(t *testing.T, stdin string, args ...string) (string, error) {
	t.Helper()
	var out bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&out)
	rootCmd.SetIn(strings.NewReader(stdin))
	rootCmd.SetArgs(append([]string{"connections"}, args...))
	err := rootCmd.Execute()
	rootCmd.SetArgs(nil)
	rootCmd.SetIn(nil)
	resetConnectionsFlags()
	return out.String(), err
}

// runConnectionsSplit is runConnections with stdout and stderr captured in
// SEPARATE buffers, so a test can prove WHICH stream a line landed on — the
// combined buffer above cannot tell a stderr warning from a stdout one.
func runConnectionsSplit(t *testing.T, stdin string, args ...string) (stdout, stderr string, err error) {
	t.Helper()
	var outBuf, errBuf bytes.Buffer
	rootCmd.SetOut(&outBuf)
	rootCmd.SetErr(&errBuf)
	rootCmd.SetIn(strings.NewReader(stdin))
	rootCmd.SetArgs(append([]string{"connections"}, args...))
	err = rootCmd.Execute()
	rootCmd.SetArgs(nil)
	rootCmd.SetIn(nil)
	resetConnectionsFlags()
	return outBuf.String(), errBuf.String(), err
}

// resetConnectionsFlags clears the package-level cobra flag vars between
// invocations (the pflag-singleton gotcha shared by every connections test).
func resetConnectionsFlags() {
	connectionsFlagJSON = false
	connectionsAddFlagName = ""
	connectionsAddFlagKind = ""
	connectionsAddFlagCommand = ""
	connectionsAddFlagArgs = nil
	connectionsAddFlagURL = ""
	connectionsAddFlagSecretStdin = false
	connectionsOAuthFlagAppReturn = false
	connectionsOAuthFlagNoOpen = false
	connectionsOAuthFlagClientID = ""
	connectionsOAuthFlagClientSecretStdin = false
	connectionsOAuthFlagScope = ""
}

// connectionsFakeOAuthServer is a minimal RFC 8414/7591/7009 authorization
// server for exercising `connections oauth`/`connections remove` end to
// end. It is a from-scratch reimplementation of the internal/mcpoauth
// package's own fakeAS (that type is unexported in a different package, so
// it cannot be imported here) — kept deliberately minimal: no PKCE/state
// enforcement, since those are internal/mcpoauth's own responsibility and
// are pinned by that package's tests already.
type connectionsFakeOAuthServer struct {
	server *httptest.Server

	NoRegistrationEndpoint bool // omit registration_endpoint from metadata
	RevokeFails            bool // /revoke always answers 500

	mu            sync.Mutex
	RevokedTokens []string
}

func newConnectionsFakeOAuthServer(t *testing.T) *connectionsFakeOAuthServer {
	t.Helper()
	as := &connectionsFakeOAuthServer{}

	mux := http.NewServeMux()
	mux.HandleFunc("/.well-known/oauth-authorization-server", func(w http.ResponseWriter, _ *http.Request) {
		meta := map[string]any{
			"issuer":                                as.server.URL,
			"authorization_endpoint":                as.server.URL + "/authorize",
			"token_endpoint":                        as.server.URL + "/token",
			"revocation_endpoint":                   as.server.URL + "/revoke",
			"code_challenge_methods_supported":      []string{"S256"},
			"token_endpoint_auth_methods_supported": []string{"none", "client_secret_post"},
		}
		if !as.NoRegistrationEndpoint {
			meta["registration_endpoint"] = as.server.URL + "/register"
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(meta)
	})
	mux.HandleFunc("/register", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		_ = json.NewEncoder(w).Encode(map[string]string{"client_id": "cid"})
	})
	mux.HandleFunc("/token", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"access_token":  "access-tok",
			"refresh_token": "refresh-tok",
			"expires_in":    3600,
		})
	})
	mux.HandleFunc("/revoke", func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		as.mu.Lock()
		as.RevokedTokens = append(as.RevokedTokens, r.PostForm.Get("token"))
		as.mu.Unlock()
		if as.RevokeFails {
			http.Error(w, "revocation failed", http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusOK)
	})

	as.server = httptest.NewServer(mux)
	t.Cleanup(as.server.Close)
	return as
}

// captureConnectionsAuthorizeCallback swaps mcpoauth.OpenBrowser so that,
// instead of launching a real browser, it parses the state/redirect_uri out
// of the authorize URL and drives the loopback callback itself (in a
// goroutine, since OpenBrowser is called synchronously from inside
// mcpoauth.Login while Login itself is still waiting on the callback).
func captureConnectionsAuthorizeCallback(t *testing.T) {
	t.Helper()
	captureConnectionsAuthorizeCallbackRecordingQuery(t, nil)
}

// captureConnectionsAuthorizeCallbackRecordingQuery is
// captureConnectionsAuthorizeCallback plus an optional hook that runs
// synchronously on the authorize URL's query before the loopback callback
// fires — used to assert on request params (e.g. "scope") that never
// travel any further than that URL in this fake-server setup.
func captureConnectionsAuthorizeCallbackRecordingQuery(t *testing.T, record func(url.Values)) {
	t.Helper()
	old := mcpoauth.OpenBrowser
	t.Cleanup(func() { mcpoauth.OpenBrowser = old })
	mcpoauth.OpenBrowser = func(rawURL string) {
		u, err := url.Parse(rawURL)
		if err != nil {
			t.Errorf("parsing authorize URL %q: %v", rawURL, err)
			return
		}
		if record != nil {
			record(u.Query())
		}
		redirectURI := u.Query().Get("redirect_uri")
		state := u.Query().Get("state")
		go func() {
			cb, err := url.Parse(redirectURI)
			if err != nil {
				return
			}
			q := cb.Query()
			q.Set("code", "any")
			q.Set("state", state)
			cb.RawQuery = q.Encode()
			resp, err := http.Get(cb.String()) //nolint:gosec,noctx
			if err == nil {
				resp.Body.Close()
			}
		}()
	}
}

func TestConnections_AddListEnableDisableRemove(t *testing.T) {
	cfg := writeConnectionsConfig(t)

	secretJSON := `{"env":{"API_KEY":"s3cr3t"},"headers":{"X-Token":"tok"}}`
	out, err := runConnections(t, secretJSON,
		"add", "--name", "My-Server", "--kind", "stdio",
		"--command", "npx", "--arg", "-y", "--arg", "some-mcp-server",
		"--secret-stdin")
	require.NoError(t, err, out)
	assert.Contains(t, out, "Added connection")
	assert.Contains(t, out, "disabled")

	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })

	conns, err := database.ListExternalConnections()
	require.NoError(t, err)
	require.Len(t, conns, 1)
	added := conns[0]
	assert.Equal(t, "My-Server", added.Name)
	assert.Equal(t, "stdio", added.Kind)
	assert.Equal(t, "npx", added.Command)
	assert.Equal(t, []string{"-y", "some-mcp-server"}, added.Args)
	assert.False(t, added.Enabled, "add must create the row disabled — owner enables explicitly")

	secretPath := externalmcp.NewSecretStore(cfg.WorkspaceDir(), added.ID).Path()
	require.FileExists(t, secretPath, "secret-stdin must persist the secret via the SecretStore")
	sec, err := externalmcp.NewSecretStore(cfg.WorkspaceDir(), added.ID).Load()
	require.NoError(t, err)
	require.NotNil(t, sec)
	assert.Equal(t, "s3cr3t", sec.Env["API_KEY"])
	assert.Equal(t, "tok", sec.Headers["X-Token"])

	idArg := strconv.FormatInt(added.ID, 10)

	// enable
	out, err = runConnections(t, "", "enable", idArg)
	require.NoError(t, err, out)
	assert.Contains(t, out, "enabled")
	enabledConn, err := database.GetExternalConnection(added.ID)
	require.NoError(t, err)
	assert.True(t, enabledConn.Enabled)

	// list --json contains the name
	out, err = runConnections(t, "", "list", "--json")
	require.NoError(t, err, out)
	assert.Contains(t, out, "My-Server")
	assert.Contains(t, out, `"enabled": true`)

	// disable
	out, err = runConnections(t, "", "disable", idArg)
	require.NoError(t, err, out)
	assert.Contains(t, out, "disabled")
	disabledConn, err := database.GetExternalConnection(added.ID)
	require.NoError(t, err)
	assert.False(t, disabledConn.Enabled)

	// remove: row and secret file both gone
	out, err = runConnections(t, "", "remove", idArg)
	require.NoError(t, err, out)
	assert.Contains(t, out, "Removed connection")

	_, err = database.GetExternalConnection(added.ID)
	assert.Error(t, err, "row must be gone after remove")
	assert.NoFileExists(t, secretPath, "remove must best-effort delete the secret file")
}

func TestConnections_AddRejectsEmptyName(t *testing.T) {
	writeConnectionsConfig(t)
	out, err := runConnections(t, "", "add", "--name", "", "--kind", "stdio", "--command", "npx")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "--name is required")
	_ = out
}

func TestConnections_AddStdioRequiresCommand(t *testing.T) {
	writeConnectionsConfig(t)
	_, err := runConnections(t, "", "add", "--name", "N", "--kind", "stdio")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "--command is required")
}

func TestConnections_AddHTTPRequiresURL(t *testing.T) {
	writeConnectionsConfig(t)
	_, err := runConnections(t, "", "add", "--name", "N", "--kind", "http")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "--url is required")
}

func TestConnections_AddRejectsUnknownKind(t *testing.T) {
	writeConnectionsConfig(t)
	_, err := runConnections(t, "", "add", "--name", "N", "--kind", "carrier-pigeon")
	require.Error(t, err)
	assert.Contains(t, err.Error(), `--kind must be "stdio" or "http"`)
}

func TestConnections_AddRejectsUnsafeName(t *testing.T) {
	writeConnectionsConfig(t)

	// A comma would inject an extra --allowedTools token when joined as
	// mcp__<Name> (see buildArgs in internal/ai/client.go).
	_, err := runConnections(t, "", "add", "--name", "x,Bash", "--kind", "stdio", "--command", "npx")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "invalid")

	// A space is also rejected — only [A-Za-z0-9_-] is safe.
	_, err = runConnections(t, "", "add", "--name", "my server", "--kind", "stdio", "--command", "npx")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "invalid")
}

func TestConnections_AddRejectsReservedName(t *testing.T) {
	cfg := writeConnectionsConfig(t)

	// "watchtower" collides with the built-in MCP server key in
	// buildMCPConfig (map key collision) — rejected case-insensitively.
	_, err := runConnections(t, "", "add", "--name", "watchtower", "--kind", "stdio", "--command", "npx")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "reserved")

	_, err = runConnections(t, "", "add", "--name", "Watchtower", "--kind", "stdio", "--command", "npx")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "reserved")

	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	conns, err := database.ListExternalConnections()
	require.NoError(t, err)
	assert.Empty(t, conns, "a rejected reserved name must create no row")
}

// TestConnectionsEnable_WarnsUnderNonClaudeProvider covers the provider-
// honesty warning: codex/ollama chats never wire external connections
// (codex.Client has no SetExternalMCPServers, ollama routes through runtime
// B), so enabling a connection under either is inert. The warning must not
// block the enable — the row still ends up Enabled either way.
func TestConnectionsEnable_WarnsUnderNonClaudeProvider(t *testing.T) {
	tests := []struct {
		name        string
		provider    string
		wantWarning bool
	}{
		{"ollama provider warns", "ollama", true},
		{"claude provider silent", "claude", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg := writeConnectionsConfigWithProvider(t, tt.provider)

			out, err := runConnections(t, "", "add", "--name", "My-Server", "--kind", "stdio", "--command", "npx")
			require.NoError(t, err, out)

			database, err := db.Open(cfg.DBPath())
			require.NoError(t, err)
			t.Cleanup(func() { _ = database.Close() })
			conns, err := database.ListExternalConnections()
			require.NoError(t, err)
			require.Len(t, conns, 1)
			idArg := strconv.FormatInt(conns[0].ID, 10)

			// Re-run for "enable" with SPLIT stdout/stderr buffers so this
			// assertion only sees the enable output (not the add warning above)
			// AND can prove which stream the warning landed on.
			stdout, stderr, err := runConnectionsSplit(t, "", "enable", idArg)
			require.NoError(t, err, stdout+stderr)

			enabledConn, err := database.GetExternalConnection(conns[0].ID)
			require.NoError(t, err)
			assert.True(t, enabledConn.Enabled, "enable must still succeed regardless of provider")

			if tt.wantWarning {
				assert.Contains(t, stderr, "only")
				assert.Contains(t, stderr, "claude")
				assert.Contains(t, stderr, "My-Server")
				assert.NotContains(t, stdout, "warning", "the warning belongs on stderr, never stdout")
			} else {
				assert.Empty(t, stderr, "a claude provider must produce no warning at all")
			}
		})
	}
}

// TestConnectionsAdd_WarnsUnderNonClaudeProvider mirrors the enable case for
// "connections add" — non-claude warns (row still created disabled, as
// always), claude stays silent.
func TestConnectionsAdd_WarnsUnderNonClaudeProvider(t *testing.T) {
	tests := []struct {
		name        string
		provider    string
		wantWarning bool
	}{
		{"ollama provider warns", "ollama", true},
		{"claude provider silent", "claude", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg := writeConnectionsConfigWithProvider(t, tt.provider)

			stdout, stderr, err := runConnectionsSplit(t, "", "add", "--name", "My-Server", "--kind", "stdio", "--command", "npx")
			require.NoError(t, err, stdout+stderr)

			database, err := db.Open(cfg.DBPath())
			require.NoError(t, err)
			t.Cleanup(func() { _ = database.Close() })
			conns, err := database.ListExternalConnections()
			require.NoError(t, err)
			require.Len(t, conns, 1)
			assert.False(t, conns[0].Enabled, "add must still create the row disabled regardless of provider")

			if tt.wantWarning {
				assert.Contains(t, stderr, "only")
				assert.Contains(t, stderr, "claude")
				assert.Contains(t, stderr, "My-Server")
				assert.NotContains(t, stdout, "warning", "the warning belongs on stderr, never stdout")
			} else {
				assert.Empty(t, stderr, "a claude provider must produce no warning at all")
			}
		})
	}
}

func TestConnections_AddHTTPWithoutSecretStdinCreatesNoSecretFile(t *testing.T) {
	cfg := writeConnectionsConfig(t)
	out, err := runConnections(t, "", "add", "--name", "Web-Tool", "--kind", "http", "--url", "https://example.com/mcp")
	require.NoError(t, err, out)

	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	conns, err := database.ListExternalConnections()
	require.NoError(t, err)
	require.Len(t, conns, 1)
	assert.Equal(t, "https://example.com/mcp", conns[0].URL)

	secretPath := externalmcp.NewSecretStore(cfg.WorkspaceDir(), conns[0].ID).Path()
	assert.NoFileExists(t, secretPath, "no --secret-stdin means no secret file at all")
}

// addHTTPConnection is a small test helper: adds an http connection pointed
// at url and returns its row.
func addHTTPConnection(t *testing.T, cfg *config.Config, name, connURL string) db.ExternalConnection {
	t.Helper()
	out, err := runConnections(t, "", "add", "--name", name, "--kind", "http", "--url", connURL)
	require.NoError(t, err, out)

	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	defer database.Close()
	conns, err := database.ListExternalConnections()
	require.NoError(t, err)
	for _, c := range conns {
		if c.Name == name {
			return c
		}
	}
	t.Fatalf("connection %q not found after add", name)
	return db.ExternalConnection{}
}

func TestConnectionsOAuth_SignsInAndEnables(t *testing.T) {
	cfg := writeConnectionsConfig(t)
	as := newConnectionsFakeOAuthServer(t)
	captureConnectionsAuthorizeCallback(t)

	conn := addHTTPConnection(t, cfg, "Web-Tool", as.server.URL)
	idArg := strconv.FormatInt(conn.ID, 10)

	// Deliberately WITHOUT --no-open: --no-open bypasses OpenBrowser
	// entirely, but the captured hook above is what drives the loopback
	// callback for this test.
	out, err := runConnections(t, "", "oauth", idArg)
	require.NoError(t, err, out)
	assert.Contains(t, out, "signed in and enabled")

	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	got, err := database.GetExternalConnection(conn.ID)
	require.NoError(t, err)
	assert.True(t, got.Enabled, "oauth sign-in must enable the connection")
	assert.Equal(t, "ok", got.Status)

	secret, err := externalmcp.NewSecretStore(cfg.WorkspaceDir(), conn.ID).Load()
	require.NoError(t, err)
	require.NotNil(t, secret)
	require.NotNil(t, secret.OAuth, "a successful sign-in must persist the OAuth grant")
	assert.Equal(t, "access-tok", secret.OAuth.AccessToken)
	assert.Equal(t, "refresh-tok", secret.OAuth.RefreshToken)
}

// TestConnectionsOAuth_ScopeFlagRequestsScope pins I2: --scope threads
// through to the authorize request's "scope" param, since that is the only
// way an owner can ask a server for a scope like offline_access that some
// servers require before they will issue a refresh token at all.
func TestConnectionsOAuth_ScopeFlagRequestsScope(t *testing.T) {
	cfg := writeConnectionsConfig(t)
	as := newConnectionsFakeOAuthServer(t)
	var gotScope string
	sawScope := false
	captureConnectionsAuthorizeCallbackRecordingQuery(t, func(q url.Values) {
		gotScope, sawScope = q.Get("scope"), q.Has("scope")
	})

	conn := addHTTPConnection(t, cfg, "Web-Tool", as.server.URL)
	idArg := strconv.FormatInt(conn.ID, 10)

	out, err := runConnections(t, "", "oauth", idArg, "--scope", "offline_access read:page")
	require.NoError(t, err, out)
	assert.True(t, sawScope, "authorize request must carry a scope param when --scope is set")
	assert.Equal(t, "offline_access read:page", gotScope)
}

// TestConnectionsOAuth_NoScopeFlagOmitsScope pins the other half of I2: with
// no --scope, the authorize request carries no scope param at all (the
// pre-fix behavior) rather than defaulting to some hardcoded value —
// Quick Connections has no per-service assumptions to default it from.
func TestConnectionsOAuth_NoScopeFlagOmitsScope(t *testing.T) {
	cfg := writeConnectionsConfig(t)
	as := newConnectionsFakeOAuthServer(t)
	sawScope := true // start true so a bug that never calls the hook still fails loudly below
	called := false
	captureConnectionsAuthorizeCallbackRecordingQuery(t, func(q url.Values) {
		sawScope, called = q.Has("scope"), true
	})

	conn := addHTTPConnection(t, cfg, "Web-Tool", as.server.URL)
	idArg := strconv.FormatInt(conn.ID, 10)

	out, err := runConnections(t, "", "oauth", idArg)
	require.NoError(t, err, out)
	require.True(t, called, "the authorize-URL hook must have run")
	assert.False(t, sawScope, "authorize request must carry no scope param when --scope is not set")
}

func TestConnectionsOAuth_RejectsStdioKind(t *testing.T) {
	cfg := writeConnectionsConfig(t)
	out, err := runConnections(t, "", "add", "--name", "Stdio-Tool", "--kind", "stdio", "--command", "npx")
	require.NoError(t, err, out)

	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	conns, err := database.ListExternalConnections()
	require.NoError(t, err)
	require.Len(t, conns, 1)
	idArg := strconv.FormatInt(conns[0].ID, 10)

	_, err = runConnections(t, "", "oauth", idArg, "--no-open")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "OAuth sign-in applies to http servers only")
}

func TestConnectionsOAuth_NoRegistrationNeedsClientID(t *testing.T) {
	cfg := writeConnectionsConfig(t)
	as := newConnectionsFakeOAuthServer(t)
	as.NoRegistrationEndpoint = true

	conn := addHTTPConnection(t, cfg, "Web-Tool", as.server.URL)
	idArg := strconv.FormatInt(conn.ID, 10)

	_, err := runConnections(t, "", "oauth", idArg, "--no-open")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "--client-id")
}

func TestConnectionsOAuth_BYOClientIDAndSecretStdin(t *testing.T) {
	cfg := writeConnectionsConfig(t)
	as := newConnectionsFakeOAuthServer(t)
	as.NoRegistrationEndpoint = true
	captureConnectionsAuthorizeCallback(t)

	conn := addHTTPConnection(t, cfg, "Web-Tool", as.server.URL)
	idArg := strconv.FormatInt(conn.ID, 10)

	const clientSecret = "s3cr3t-client-secret"
	args := []string{"oauth", idArg, "--client-id", "byo-client", "--client-secret-stdin"}
	for _, a := range args {
		assert.NotContains(t, a, clientSecret, "the client secret must never appear in the CLI args slice")
	}

	out, err := runConnections(t, clientSecret, args...)
	require.NoError(t, err, out)
	assert.Contains(t, out, "signed in and enabled")

	secret, err := externalmcp.NewSecretStore(cfg.WorkspaceDir(), conn.ID).Load()
	require.NoError(t, err)
	require.NotNil(t, secret)
	require.NotNil(t, secret.OAuth)
	assert.Equal(t, "byo-client", secret.OAuth.ClientID, "BYO client id must be used verbatim (no registration call)")
}

func TestConnectionsList_ShowsAuthColumn(t *testing.T) {
	cfg := writeConnectionsConfig(t)

	oauthConn := addHTTPConnection(t, cfg, "OAuth-Tool", "https://example.com/mcp")
	require.NoError(t, externalmcp.NewSecretStore(cfg.WorkspaceDir(), oauthConn.ID).Save(&externalmcp.Secret{
		OAuth: &externalmcp.OAuthGrant{AccessToken: "tok"},
	}))

	out, err := runConnections(t, `{"env":{"API_KEY":"s3cr3t"}}`,
		"add", "--name", "Static-Tool", "--kind", "stdio", "--command", "npx", "--secret-stdin")
	require.NoError(t, err, out)

	out, err = runConnections(t, "", "add", "--name", "None-Tool", "--kind", "stdio", "--command", "npx")
	require.NoError(t, err, out)

	out, err = runConnections(t, "", "list", "--json")
	require.NoError(t, err, out)

	var wire []connectionJSON
	require.NoError(t, json.Unmarshal([]byte(out), &wire))
	byName := make(map[string]connectionJSON, len(wire))
	for _, w := range wire {
		byName[w.Name] = w
	}
	require.Contains(t, byName, "OAuth-Tool")
	require.Contains(t, byName, "Static-Tool")
	require.Contains(t, byName, "None-Tool")
	assert.Equal(t, "oauth", byName["OAuth-Tool"].Auth)
	assert.Equal(t, "static", byName["Static-Tool"].Auth)
	assert.Equal(t, "none", byName["None-Tool"].Auth)

	// The plain-text listing must also show the auth column, not just --json.
	out, err = runConnections(t, "", "list")
	require.NoError(t, err, out)
	assert.Contains(t, out, "auth=oauth")
	assert.Contains(t, out, "auth=static")
	assert.Contains(t, out, "auth=none")
}

func TestConnectionsRemove_RevokesBestEffort(t *testing.T) {
	cfg := writeConnectionsConfig(t)
	as := newConnectionsFakeOAuthServer(t)
	as.RevokeFails = true

	conn := addHTTPConnection(t, cfg, "Web-Tool", as.server.URL)
	idArg := strconv.FormatInt(conn.ID, 10)

	store := externalmcp.NewSecretStore(cfg.WorkspaceDir(), conn.ID)
	require.NoError(t, store.Save(&externalmcp.Secret{
		OAuth: &externalmcp.OAuthGrant{
			AccessToken:        "tok",
			RefreshToken:       "refresh-tok",
			ClientID:           "cid",
			RevocationEndpoint: as.server.URL + "/revoke",
		},
	}))

	stdout, stderr, err := runConnectionsSplit(t, "", "remove", idArg)
	require.NoError(t, err, stdout+stderr)
	assert.Contains(t, stdout, "Removed connection")
	assert.Contains(t, stderr, "warning: token revocation failed")

	as.mu.Lock()
	revoked := append([]string(nil), as.RevokedTokens...)
	as.mu.Unlock()
	require.Len(t, revoked, 1, "remove must attempt revocation exactly once even though it fails")
	assert.Equal(t, "refresh-tok", revoked[0], "revocation must post the refresh token")

	assert.NoFileExists(t, store.Path(), "a failed revocation must still remove the secret file")

	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	_, err = database.GetExternalConnection(conn.ID)
	assert.Error(t, err, "a failed revocation must still remove the row")
}

// TestConnectionsOAuth_PreservesExistingSecret pins that a sign-in on a
// connection that already has an Env/Headers secret (e.g. added with
// --secret-stdin before OAuth was wired up) keeps those fields — only
// secret.OAuth is set, never a wholesale overwrite of the Secret.
func TestConnectionsOAuth_PreservesExistingSecret(t *testing.T) {
	cfg := writeConnectionsConfig(t)
	as := newConnectionsFakeOAuthServer(t)
	captureConnectionsAuthorizeCallback(t)

	conn := addHTTPConnection(t, cfg, "Web-Tool", as.server.URL)
	idArg := strconv.FormatInt(conn.ID, 10)

	store := externalmcp.NewSecretStore(cfg.WorkspaceDir(), conn.ID)
	require.NoError(t, store.Save(&externalmcp.Secret{
		Headers: map[string]string{"X-Extra": "1"},
		Env:     map[string]string{"FOO": "bar"},
	}))

	out, err := runConnections(t, "", "oauth", idArg)
	require.NoError(t, err, out)
	assert.Contains(t, out, "signed in and enabled")

	secret, err := store.Load()
	require.NoError(t, err)
	require.NotNil(t, secret)
	require.NotNil(t, secret.OAuth, "oauth must set the grant")
	assert.Equal(t, "1", secret.Headers["X-Extra"], "pre-existing Headers must survive an oauth sign-in")
	assert.Equal(t, "bar", secret.Env["FOO"], "pre-existing Env must survive an oauth sign-in")
}

// TestConnectionsOAuth_WarnsUnderNonClaudeProvider mirrors the add/enable
// provider-honesty warning for "connections oauth": a successful sign-in
// under a non-claude provider still enables the connection but warns on
// stderr; claude stays silent. The add/enable precedent's table shape.
func TestConnectionsOAuth_WarnsUnderNonClaudeProvider(t *testing.T) {
	tests := []struct {
		name        string
		provider    string
		wantWarning bool
	}{
		{"ollama provider warns", "ollama", true},
		{"claude provider silent", "claude", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg := writeConnectionsConfigWithProvider(t, tt.provider)
			as := newConnectionsFakeOAuthServer(t)
			captureConnectionsAuthorizeCallback(t)

			conn := addHTTPConnection(t, cfg, "Web-Tool", as.server.URL)
			idArg := strconv.FormatInt(conn.ID, 10)

			stdout, stderr, err := runConnectionsSplit(t, "", "oauth", idArg)
			require.NoError(t, err, stdout+stderr)
			assert.Contains(t, stdout, "signed in and enabled")

			if tt.wantWarning {
				assert.Contains(t, stderr, "only")
				assert.Contains(t, stderr, "claude")
				assert.Contains(t, stderr, "Web-Tool")
			} else {
				assert.Empty(t, stderr, "a claude provider must produce no warning at all")
			}
		})
	}
}

// TestConnectionsRemove_RevokesSuccessfully is the successful-revocation
// counterpart to TestConnectionsRemove_RevokesBestEffort: no warning, the
// grant's refresh token is the one posted to /revoke, and the row + secret
// file are both gone.
func TestConnectionsRemove_RevokesSuccessfully(t *testing.T) {
	cfg := writeConnectionsConfig(t)
	as := newConnectionsFakeOAuthServer(t)

	conn := addHTTPConnection(t, cfg, "Web-Tool", as.server.URL)
	idArg := strconv.FormatInt(conn.ID, 10)

	store := externalmcp.NewSecretStore(cfg.WorkspaceDir(), conn.ID)
	require.NoError(t, store.Save(&externalmcp.Secret{
		OAuth: &externalmcp.OAuthGrant{
			AccessToken:        "tok",
			RefreshToken:       "refresh-tok",
			ClientID:           "cid",
			RevocationEndpoint: as.server.URL + "/revoke",
		},
	}))

	stdout, stderr, err := runConnectionsSplit(t, "", "remove", idArg)
	require.NoError(t, err, stdout+stderr)
	assert.Contains(t, stdout, "Removed connection")
	assert.NotContains(t, stderr, "warning", "a successful revocation must not warn")

	as.mu.Lock()
	revoked := append([]string(nil), as.RevokedTokens...)
	as.mu.Unlock()
	require.Len(t, revoked, 1)
	assert.Equal(t, "refresh-tok", revoked[0])

	assert.NoFileExists(t, store.Path())

	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	_, err = database.GetExternalConnection(conn.ID)
	assert.Error(t, err, "row must be gone after remove")
}
