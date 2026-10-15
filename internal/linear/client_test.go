package linear

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func newTestClient(t *testing.T, gql http.HandlerFunc, token http.HandlerFunc) (*Client, *TokenStore) {
	t.Helper()
	g := httptest.NewServer(gql)
	t.Cleanup(g.Close)
	store := NewTokenStore(t.TempDir(), 1)
	require.NoError(t, store.Save(&Token{AccessToken: "a0", RefreshToken: "r0", Expiry: time.Now().Add(time.Hour).Format(time.RFC3339)}))
	c := NewClient(OAuthConfig{ClientID: "cid"}, store)
	c.endpoint = g.URL
	if token != nil {
		tk := httptest.NewServer(token)
		t.Cleanup(tk.Close)
		c.tokenURL = tk.URL
	}
	return c, store
}

func TestClient_DecodesData(t *testing.T) {
	c, _ := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		assert.Equal(t, "Bearer a0", r.Header.Get("Authorization"))
		_, _ = w.Write([]byte(`{"data":{"viewer":{"id":"user-1"}}}`))
	}, nil)
	var out struct{ Viewer struct{ ID string } }
	require.NoError(t, c.Do(context.Background(), `query { viewer { id } }`, nil, &out))
	assert.Equal(t, "user-1", out.Viewer.ID)
}

func TestLinear02_RefreshSavesRotatedPair(t *testing.T) {
	var calls atomic.Int32
	c, store := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		if calls.Add(1) == 1 {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		assert.Equal(t, "Bearer a1", r.Header.Get("Authorization"))
		_, _ = w.Write([]byte(`{"data":{}}`))
	}, func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		assert.Equal(t, "r0", r.PostForm.Get("refresh_token"))
		_, _ = w.Write([]byte(`{"access_token":"a1","refresh_token":"r1","expires_in":86399}`))
	})
	require.NoError(t, c.Do(context.Background(), `query { viewer { id } }`, nil, &struct{}{}))
	saved, err := store.Load()
	require.NoError(t, err)
	assert.Equal(t, "r1", saved.RefreshToken) // the rotated refresh token is persisted before use
}

func TestClient_RepeatedAuthFailureIsRevoked(t *testing.T) {
	c, _ := newTestClient(t, func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	}, func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"access_token":"a1","refresh_token":"r1","expires_in":86399}`))
	})
	err := c.Do(context.Background(), `query { viewer { id } }`, nil, &struct{}{})
	assert.ErrorIs(t, err, ErrAuthRevoked)
}

func TestClient_RateLimitedIsTyped(t *testing.T) {
	c, _ := newTestClient(t, func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_ = json.NewEncoder(w).Encode(map[string]any{"errors": []any{map[string]any{
			"message": "rate limited", "extensions": map[string]any{"code": "RATELIMITED"}}}})
	}, nil)
	err := c.Do(context.Background(), `query { viewer { id } }`, nil, &struct{}{})
	assert.ErrorIs(t, err, ErrRateLimited)
}

func TestClient_GateRefusesLongWait(t *testing.T) {
	reset := time.Now().Add(time.Hour).UnixMilli()
	c, _ := newTestClient(t, func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("X-RateLimit-Complexity-Remaining", "10")
		w.Header().Set("X-RateLimit-Complexity-Reset", jsonInt(reset))
		_, _ = w.Write([]byte(`{"data":{}}`))
	}, nil)
	require.NoError(t, c.Do(context.Background(), `query { a }`, nil, &struct{}{}))
	err := c.Do(context.Background(), `query { a }`, nil, &struct{}{})
	assert.ErrorIs(t, err, ErrRateLimited)
}

func TestLinear02_ConcurrentRefreshSingleFlight(t *testing.T) {
	var refreshes atomic.Int32
	c, _ := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") == "Bearer a0" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		_, _ = w.Write([]byte(`{"data":{}}`))
	}, func(w http.ResponseWriter, _ *http.Request) {
		refreshes.Add(1)
		_, _ = w.Write([]byte(`{"access_token":"a1","refresh_token":"r1","expires_in":86399}`))
	})
	var wg sync.WaitGroup
	for range 8 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			assert.NoError(t, c.Do(context.Background(), `query { a }`, nil, &struct{}{}))
		}()
	}
	wg.Wait()
	assert.Equal(t, int32(1), refreshes.Load())
}

func jsonInt(v int64) string { b, _ := json.Marshal(v); return string(b) }

func TestClient_StalledTokenEndpointTimesOut(t *testing.T) {
	old := tokenHTTPClient
	tokenHTTPClient = &http.Client{Timeout: 200 * time.Millisecond}
	t.Cleanup(func() { tokenHTTPClient = old })
	release := make(chan struct{})
	c, store := newTestClient(t, func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	}, func(_ http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		select { // never answers; released by the cleanup below or a dropped connection
		case <-r.Context().Done():
		case <-release:
		}
	})
	t.Cleanup(func() { close(release) }) // runs before the servers' Close (LIFO)
	start := time.Now()
	err := c.Do(context.Background(), `query { a }`, nil, &struct{}{})
	require.Error(t, err)
	assert.NotErrorIs(t, err, ErrAuthRevoked)
	assert.Less(t, time.Since(start), 5*time.Second)
	// The lock is released: a later refresh attempt is not blocked.
	unlock, err := store.Lock(context.Background())
	require.NoError(t, err)
	unlock()
}

// Two Client values on one token file stand in for two processes (the daemon
// and a CLI command): only the file lock serializes them, not Client.mu.
func TestLinear02_TwoClientsOneStoreSingleRefresh(t *testing.T) {
	for _, tc := range []struct {
		name    string
		initial *Token
	}{
		{"both hit 401", &Token{AccessToken: "a0", RefreshToken: "r0", Expiry: time.Now().Add(time.Hour).Format(time.RFC3339)}},
		{"both start expired", &Token{AccessToken: "a0", RefreshToken: "r0", Expiry: time.Now().Add(-time.Hour).Format(time.RFC3339)}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var refreshes atomic.Int32
			gql := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Header.Get("Authorization") == "Bearer a0" {
					w.WriteHeader(http.StatusUnauthorized)
					return
				}
				_, _ = w.Write([]byte(`{"data":{}}`))
			}))
			t.Cleanup(gql.Close)
			tok := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				_ = r.ParseForm()
				n := refreshes.Add(1)
				time.Sleep(50 * time.Millisecond) // widen the race window
				if r.PostForm.Get("refresh_token") != "r0" || n > 1 {
					w.WriteHeader(http.StatusBadRequest)
					_, _ = w.Write([]byte(`{"error":"invalid_grant"}`))
					return
				}
				_, _ = w.Write([]byte(`{"access_token":"a1","refresh_token":"r1","expires_in":86399}`))
			}))
			t.Cleanup(tok.Close)

			dir := t.TempDir()
			require.NoError(t, NewTokenStore(dir, 1).Save(tc.initial))
			clients := make([]*Client, 2)
			for i := range clients {
				c := NewClient(OAuthConfig{ClientID: "cid"}, NewTokenStore(dir, 1))
				c.endpoint, c.tokenURL = gql.URL, tok.URL
				clients[i] = c
			}
			var wg sync.WaitGroup
			for _, c := range clients {
				for range 4 {
					wg.Add(1)
					go func() {
						defer wg.Done()
						assert.NoError(t, c.Do(context.Background(), `query { a }`, nil, &struct{}{}))
					}()
				}
			}
			wg.Wait()
			assert.Equal(t, int32(1), refreshes.Load())
			saved, err := NewTokenStore(dir, 1).Load()
			require.NoError(t, err)
			assert.Equal(t, "r1", saved.RefreshToken)
		})
	}
}

func TestFetchViewerWithToken(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer good" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		_, _ = w.Write([]byte(`{"data":{"viewer":{"id":"user-1","name":"Owner","email":"owner@example.com",
			"organization":{"id":"org-1","name":"Acme","urlKey":"acme"}}}}`))
	}))
	t.Cleanup(srv.Close)
	old := graphqlEndpoint
	graphqlEndpoint = srv.URL
	t.Cleanup(func() { graphqlEndpoint = old })

	v, err := FetchViewerWithToken(context.Background(), "good")
	require.NoError(t, err)
	assert.Equal(t, Viewer{UserID: "user-1", Email: "owner@example.com", Name: "Owner", OrgID: "org-1", OrgName: "Acme", URLKey: "acme"}, v)

	_, err = FetchViewerWithToken(context.Background(), "stale")
	assert.ErrorIs(t, err, ErrAuthRevoked)
}
