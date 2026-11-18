package jira

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// A refresh Atlassian answers with a refused client (the company rotated its
// secret or deleted its app) is ErrClientRejected — never ErrAuthRevoked,
// which the callers record as 'revoked' and PURGE-01 schedules for deletion.
// A refresh token named invalid stays a revoked grant.
func TestRefreshToken_ClientRejected(t *testing.T) {
	cases := []struct {
		name         string
		status       int
		body         string
		wantRejected bool
		wantRevoked  bool
	}{
		{"invalid_client 401", http.StatusUnauthorized, `{"error":"invalid_client"}`, true, false},
		{"invalid_client with refresh prose", http.StatusUnauthorized, `{"error":"invalid_client","error_description":"the refresh token is invalid for this client"}`, true, false},
		{"bare unauthorized_client", http.StatusForbidden, `{"error":"unauthorized_client","error_description":"client authentication failed"}`, true, false},
		{"unauthorized_client naming the refresh token", http.StatusForbidden, `{"error":"unauthorized_client","error_description":"refresh_token is invalid"}`, false, true},
		{"invalid_grant", http.StatusUnauthorized, `{"error":"invalid_grant"}`, false, true},
		{"proxy page", http.StatusBadGateway, `<html>invalid_client</html>`, false, false},
		{"server error", http.StatusInternalServerError, `{"error":"server_error"}`, false, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(tc.status)
				_, _ = w.Write([]byte(tc.body))
			}))
			t.Cleanup(srv.Close)

			_, err := refreshTokenAt(context.Background(), JiraOAuthConfig{ClientID: "cid"}, "rt", srv.URL)
			require.Error(t, err)
			assert.Equal(t, tc.wantRejected, errors.Is(err, ErrClientRejected), "rejected")
			assert.Equal(t, tc.wantRevoked, errors.Is(err, ErrAuthRevoked), "revoked")
		})
	}
}

// A client with an OAuth source asks it at each refresh: the refresh goes
// out with the source's client, and a source error sends nothing.
func TestClient_OAuthSourceAtRefresh(t *testing.T) {
	var gotClient atomic.Value
	var refreshes atomic.Int32
	tokens := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		refreshes.Add(1)
		var body map[string]string
		_ = json.NewDecoder(r.Body).Decode(&body)
		gotClient.Store(body["client_id"])
		_, _ = w.Write([]byte(`{"access_token":"at2","refresh_token":"rt2","expires_in":3600}`))
	}))
	t.Cleanup(tokens.Close)

	c := makeTestClient(t, "http://unused.invalid")
	c.tokenURL = tokens.URL
	c.SetOAuthSource(func() (JiraOAuthConfig, error) { return JiraOAuthConfig{ClientID: "new-client"}, nil })
	_, err := c.refresh(context.Background(), "rt")
	require.NoError(t, err)
	assert.Equal(t, "new-client", gotClient.Load(), "not the client the Client was built with (cid)")

	c.SetOAuthSource(func() (JiraOAuthConfig, error) {
		return JiraOAuthConfig{}, fmt.Errorf("%w: company changed its app", ErrClientRejected)
	})
	_, err = c.refresh(context.Background(), "rt")
	assert.ErrorIs(t, err, ErrClientRejected)
	assert.Equal(t, int32(1), refreshes.Load(), "a source error sends no refresh")
}

// The account's error code follows its company tie (#1887 P5).
func TestClientRejectedCode(t *testing.T) {
	assert.Equal(t, "invalid_client", ClientRejectedCode("acme"))
	assert.Equal(t, "unknown_client", ClientRejectedCode(""))
}

// A rejected client ends the whole pass like a revoked grant: swallowed per
// project, Sync would return nil and the daemon could never record it.
func TestSyncer_Sync_AbortsWholeAccountOnClientRejected(t *testing.T) {
	database, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { database.Close() })
	db.SeedTestJiraAccount(t, database)
	for i, key := range []string{"OPS", "SEC"} {
		require.NoError(t, database.UpsertJiraBoard(db.JiraBoard{
			AccountID: 1, ID: i + 1, Name: key, ProjectKey: key, IsSelected: true, SyncedAt: "now",
		}))
	}

	var apiCalls, refreshCalls atomic.Int32
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		apiCalls.Add(1)
		w.WriteHeader(http.StatusUnauthorized)
	}))
	t.Cleanup(api.Close)
	tokens := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		refreshCalls.Add(1)
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"error":"invalid_client"}`))
	}))
	t.Cleanup(tokens.Close)
	prev := jiraTokenEndpoint
	jiraTokenEndpoint = tokens.URL
	t.Cleanup(func() { jiraTokenEndpoint = prev })

	_, err = quietSyncer(t, database, api.URL).Sync(context.Background())

	require.Error(t, err)
	assert.True(t, errors.Is(err, ErrClientRejected), "got %v", err)
	assert.False(t, errors.Is(err, ErrAuthRevoked))
	assert.Equal(t, int32(1), refreshCalls.Load(), "the pass stops at the first refused refresh")
}
