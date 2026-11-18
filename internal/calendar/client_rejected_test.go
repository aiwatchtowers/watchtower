package calendar

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/oauthclient"
)

// A refresh Google refuses for the client ends the pass with
// oauthclient.ErrClientRejected and marks the account 'error' with its code
// (invalid_client: tied to a company) — never 'revoked' (PURGE-01, #1887).
func TestCalendarRefresh_InvalidClientIsError(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/users/me/calendarList", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"error":"invalid_client"}`))
	}))
	t.Cleanup(tokenSrv.Close)
	prevAPI, prevTok := calendarAPIBase, googleTokenEndpoint
	calendarAPIBase, googleTokenEndpoint = srv.URL, tokenSrv.URL
	t.Cleanup(func() { calendarAPIBase, googleTokenEndpoint = prevAPI, prevTok })

	database := db.OpenTestDB(t)
	id, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "a@example.com", CompanySlug: "acme"})
	require.NoError(t, err)

	client := &Client{hc: srv.Client(), accessToken: "stale"}
	_, err = NewSyncer(client, database, &config.Config{}, nil, id).Sync(context.Background())
	require.ErrorIs(t, err, oauthclient.ErrClientRejected)
	assert.NotErrorIs(t, err, ErrAuthRevoked)

	a, err := database.GetGoogleAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "error", a.Status)
	assert.Equal(t, oauthclient.CodeInvalidClient, a.Error)
}
