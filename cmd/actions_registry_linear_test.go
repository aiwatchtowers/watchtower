package cmd

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"sync"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/linear"
)

func TestLinearWriteClientFactory_NoTokenNamesLogin(t *testing.T) {
	database := db.OpenTestDB(t)
	cfg := &config.Config{ActiveWorkspace: "test"}
	t.Setenv("HOME", t.TempDir())

	client, err := linearWriteClientFactory(cfg, database)(db.LinearAccount{ID: 7})
	require.Error(t, err)
	assert.Nil(t, client, "never a typed-nil client inside the interface")
	assert.Contains(t, err.Error(), "watchtower linear login --account 7")
}

// redirectTransport sends every request to target, keeping path and body.
type redirectTransport struct {
	target *url.URL
	base   http.RoundTripper
}

func (rt redirectTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	req = req.Clone(req.Context())
	req.URL.Scheme, req.URL.Host = rt.target.Scheme, rt.target.Host
	return rt.base.RoundTrip(req)
}

func TestLinearWriteClientFactory_RefreshIssueDelegatesToSyncer(t *testing.T) {
	var (
		mu      sync.Mutex
		queries []map[string]any
	)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Variables map[string]any `json:"variables"`
		}
		_ = json.NewDecoder(r.Body).Decode(&req)
		mu.Lock()
		queries = append(queries, req.Variables)
		mu.Unlock()
		_, _ = w.Write([]byte(`{"data":{"issues":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":""}}}}`))
	}))
	t.Cleanup(srv.Close)
	target, err := url.Parse(srv.URL)
	require.NoError(t, err)
	// The Linear client's http.Client has no transport of its own, so the
	// default one carries its calls; point it at the fake for this test.
	oldTransport := http.DefaultTransport
	http.DefaultTransport = redirectTransport{target: target, base: oldTransport}
	t.Cleanup(func() { http.DefaultTransport = oldTransport })

	t.Setenv("HOME", t.TempDir())
	cfg := &config.Config{ActiveWorkspace: "test"}
	database := db.OpenTestDB(t)
	id, err := database.CreateLinearAccount("acme")
	require.NoError(t, err)
	require.NoError(t, linear.NewTokenStore(cfg.WorkspaceDir(), id).Save(linear.APIKeyToken("lin_api_x")))

	client, err := linearWriteClientFactory(cfg, database)(db.LinearAccount{ID: id})
	require.NoError(t, err)
	err = client.RefreshIssue(context.Background(), "i-1")
	// The syncer's one-issue refresh ran: it asked for exactly that issue and
	// reports the empty answer in its own words.
	require.EqualError(t, err, "refreshing linear issue i-1: not found")
	mu.Lock()
	defer mu.Unlock()
	require.NotEmpty(t, queries)
	filter, _ := queries[0]["filter"].(map[string]any)
	assert.Equal(t, map[string]any{"eq": "i-1"}, filter["id"])
}
