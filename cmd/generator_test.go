package cmd

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/externalmcp"
)

// tokenResponse is the RFC 6749 token endpoint success body the fake token
// server in these tests writes back.
type tokenResponse struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	ExpiresIn    int    `json:"expires_in"`
}

// newFakeTokenServer starts a loopback httptest server answering
// grant_type=refresh_token with a rotated access/refresh token pair; hits is
// incremented on every request the test can read back afterwards.
func newFakeTokenServer(t *testing.T, invalidGrant bool) (server *httptest.Server, hits *int) {
	t.Helper()
	hits = new(int)
	server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		*hits++
		if invalidGrant {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadRequest)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": "invalid_grant"})
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(tokenResponse{
			AccessToken:  "access-token-2",
			RefreshToken: "refresh-token-2",
			ExpiresIn:    3600,
		})
	}))
	t.Cleanup(server.Close)
	return server, hits
}

// setupOAuthConnection creates one enabled http connection in cfg's DB plus
// its secret file holding an oauth grant pointing at tokenEndpoint, and
// returns the connection id and the store used to read the secret back.
func setupOAuthConnection(t *testing.T, database *db.DB, cfg interface{ WorkspaceDir() string }, tokenEndpoint string, expiresAt time.Time) (int64, *externalmcp.SecretStore) {
	t.Helper()
	id, err := database.InsertExternalConnection(db.ExternalConnection{
		Name:    "oauth-conn",
		Kind:    "http",
		URL:     "https://example.com/mcp",
		Enabled: true,
	})
	require.NoError(t, err)

	store := externalmcp.NewSecretStore(cfg.WorkspaceDir(), id)
	secret := &externalmcp.Secret{
		Headers: map[string]string{"X-Foo": "bar"},
		OAuth: &externalmcp.OAuthGrant{
			AccessToken:   "access-token-1",
			RefreshToken:  "refresh-token-1",
			ExpiresAt:     expiresAt,
			TokenEndpoint: tokenEndpoint,
			ClientID:      "test-client-id",
		},
	}
	require.NoError(t, store.Save(secret))
	return id, store
}

func TestLoadExternalMCPServers_OAuth_Fresh(t *testing.T) {
	cfg := writeConnectionsConfig(t)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })

	server, hits := newFakeTokenServer(t, false)
	now := time.Now()
	id, store := setupOAuthConnection(t, database, cfg, server.URL, now.Add(time.Hour))

	originalNow := externalMCPNow
	externalMCPNow = func() time.Time { return now }
	t.Cleanup(func() { externalMCPNow = originalNow })

	before, err := os.ReadFile(store.Path())
	require.NoError(t, err)

	servers := loadExternalMCPServers(cfg, cfg.DBPath())
	require.Len(t, servers, 1)
	require.Equal(t, "Bearer access-token-1", servers[0].Headers["Authorization"])
	require.Equal(t, "bar", servers[0].Headers["X-Foo"])
	require.Equal(t, 0, *hits, "a fresh grant must not hit the token endpoint")

	after, err := os.ReadFile(store.Path())
	require.NoError(t, err)
	require.Equal(t, string(before), string(after), "secret file must be unchanged for a fresh grant")

	conn, err := database.GetExternalConnection(id)
	require.NoError(t, err)
	require.Equal(t, "ok", conn.Status)
}

func TestLoadExternalMCPServers_OAuth_Expiring(t *testing.T) {
	cfg := writeConnectionsConfig(t)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })

	server, hits := newFakeTokenServer(t, false)
	now := time.Now()
	id, store := setupOAuthConnection(t, database, cfg, server.URL, now.Add(30*time.Second))

	originalNow := externalMCPNow
	externalMCPNow = func() time.Time { return now }
	t.Cleanup(func() { externalMCPNow = originalNow })

	servers := loadExternalMCPServers(cfg, cfg.DBPath())
	require.Len(t, servers, 1)
	require.Equal(t, "Bearer access-token-2", servers[0].Headers["Authorization"])
	require.Equal(t, 1, *hits, "an expiring grant must refresh exactly once")

	persisted, err := store.Load()
	require.NoError(t, err)
	require.Equal(t, "access-token-2", persisted.OAuth.AccessToken)
	require.Equal(t, "refresh-token-2", persisted.OAuth.RefreshToken)
	_, hasAuthHeader := persisted.Headers["Authorization"]
	require.False(t, hasAuthHeader, "the bearer token must never be persisted into secret.Headers")

	conn, err := database.GetExternalConnection(id)
	require.NoError(t, err)
	require.Equal(t, "ok", conn.Status)
}

func TestLoadExternalMCPServers_OAuth_InvalidGrantRevokesAndSkips(t *testing.T) {
	cfg := writeConnectionsConfig(t)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })

	server, _ := newFakeTokenServer(t, true)
	now := time.Now()
	id, _ := setupOAuthConnection(t, database, cfg, server.URL, now.Add(30*time.Second))

	// A second, non-OAuth connection must be unaffected by the first one's
	// invalid_grant.
	otherID, err := database.InsertExternalConnection(db.ExternalConnection{
		Name:    "plain-conn",
		Kind:    "http",
		URL:     "https://example.com/other",
		Enabled: true,
	})
	require.NoError(t, err)

	originalNow := externalMCPNow
	externalMCPNow = func() time.Time { return now }
	t.Cleanup(func() { externalMCPNow = originalNow })

	servers := loadExternalMCPServers(cfg, cfg.DBPath())
	require.Len(t, servers, 1)
	require.Equal(t, "plain-conn", servers[0].Name)

	conn, err := database.GetExternalConnection(id)
	require.NoError(t, err)
	require.Equal(t, "revoked", conn.Status)
	require.NotEmpty(t, conn.Error)

	otherConn, err := database.GetExternalConnection(otherID)
	require.NoError(t, err)
	require.Equal(t, "ok", otherConn.Status, "the sibling non-OAuth connection's status must be untouched by the first one's invalid_grant")
}

func TestLoadExternalMCPServers_OAuth_RevokedConnectionRecoversToOK(t *testing.T) {
	cfg := writeConnectionsConfig(t)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })

	server, _ := newFakeTokenServer(t, false)
	now := time.Now()
	id, _ := setupOAuthConnection(t, database, cfg, server.URL, now.Add(30*time.Second))
	require.NoError(t, database.SetExternalConnectionStatus(id, "revoked", "sign in again"))

	originalNow := externalMCPNow
	externalMCPNow = func() time.Time { return now }
	t.Cleanup(func() { externalMCPNow = originalNow })

	servers := loadExternalMCPServers(cfg, cfg.DBPath())
	require.Len(t, servers, 1)

	conn, err := database.GetExternalConnection(id)
	require.NoError(t, err)
	require.Equal(t, "ok", conn.Status)
	require.Equal(t, "", conn.Error)
}
