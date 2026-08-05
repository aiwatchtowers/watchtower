package jira

import (
	"context"
	"errors"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// stubTokenEndpoint points the OAuth refresh at a local server that always
// mints a fresh access token, so a 401 from the API can only mean the grant
// itself is gone — the exact condition client.do reports as ErrAuthRevoked.
func stubTokenEndpoint(t *testing.T) {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"access_token":"at-refreshed","refresh_token":"rt2","expires_in":3600}`))
	}))
	t.Cleanup(srv.Close)

	prev := jiraTokenEndpoint
	jiraTokenEndpoint = srv.URL
	t.Cleanup(func() { jiraTokenEndpoint = prev })
}

// revokedSyncerDB opens a test DB with one Jira account (id 1) and returns it.
func revokedSyncerDB(t *testing.T) *db.DB {
	t.Helper()
	database, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { database.Close() })
	db.SeedTestJiraAccount(t, database)
	return database
}

func quietSyncer(t *testing.T, database *db.DB, baseURL string) *Syncer {
	t.Helper()
	s := NewSyncer(makeTestClient(t, baseURL), database, nil, nil, 1)
	s.SetLogger(log.New(io.Discard, "", 0))
	return s
}

// TestSyncer_Sync_AbortsWholeAccountOnRevokedGrant pins the per-project
// swallow exception: an ordinary project failure is logged and skipped, but a
// revoked grant would fail every remaining project identically. Swallowing it
// per project would leave the daemon with a nil error — an account that syncs
// nothing behind a green badge.
func TestSyncer_Sync_AbortsWholeAccountOnRevokedGrant(t *testing.T) {
	database := revokedSyncerDB(t)
	for i, key := range []string{"OPS", "SEC"} {
		require.NoError(t, database.UpsertJiraBoard(db.JiraBoard{
			AccountID: 1, ID: i + 1, Name: key, ProjectKey: key, IsSelected: true, SyncedAt: "now",
		}))
	}

	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls.Add(1)
		w.WriteHeader(http.StatusUnauthorized)
	}))
	t.Cleanup(srv.Close)
	stubTokenEndpoint(t)

	_, err := quietSyncer(t, database, srv.URL).Sync(context.Background())

	require.Error(t, err)
	assert.True(t, errors.Is(err, ErrAuthRevoked), "a revoked grant must reach the caller, not be logged per project")
	assert.Equal(t, int32(4), calls.Load(),
		"Sync must abort after the first project exhausts its refresh retries, not retry every board")
}

// TestSyncer_Sync_PropagatesRevokedGrantFromSprintPath covers the account whose
// boards carry no project key: the issue loop skips every board, so the sprint
// fetch is the FIRST call that touches Atlassian and the only place a revoked
// grant can surface.
//
// Fails on the pre-fix code: the sprint error was logged and Sync returned nil,
// so the daemon saw a clean pass and never flagged the account for re-login.
func TestSyncer_Sync_PropagatesRevokedGrantFromSprintPath(t *testing.T) {
	database := revokedSyncerDB(t)
	require.NoError(t, database.UpsertJiraBoard(db.JiraBoard{
		AccountID: 1, ID: 9, Name: "Kanban", ProjectKey: "", IsSelected: true, SyncedAt: "now",
	}))

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	}))
	t.Cleanup(srv.Close)
	stubTokenEndpoint(t)

	_, err := quietSyncer(t, database, srv.URL).Sync(context.Background())

	require.Error(t, err)
	assert.True(t, errors.Is(err, ErrAuthRevoked))
}

// TestSyncer_Sync_PropagatesRevokedGrantFromReleasesPath is the same guard one
// step later in the pass: issues and sprints answer normally and only the
// versions endpoint reports the revoked grant.
//
// Fails on the pre-fix code: syncReleases logged the error and always returned
// nil, so Sync reported success.
func TestSyncer_Sync_PropagatesRevokedGrantFromReleasesPath(t *testing.T) {
	database := revokedSyncerDB(t)
	require.NoError(t, database.UpsertJiraBoard(db.JiraBoard{
		AccountID: 1, ID: 3, Name: "Ops", ProjectKey: "OPS", IsSelected: true, SyncedAt: "now",
	}))

	mux := http.NewServeMux()
	mux.HandleFunc("/rest/api/3/search/jql", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"issues":[],"isLast":true}`))
	})
	mux.HandleFunc("/rest/agile/1.0/board/3/sprint", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"values":[]}`))
	})
	mux.HandleFunc("/rest/api/3/project/OPS/versions", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	stubTokenEndpoint(t)

	_, err := quietSyncer(t, database, srv.URL).Sync(context.Background())

	require.Error(t, err)
	assert.True(t, errors.Is(err, ErrAuthRevoked))
}
