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

func TestClient_401RefreshesAndSavesRotatedPair(t *testing.T) {
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

func TestClient_ConcurrentRefreshSingleFlight(t *testing.T) {
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
